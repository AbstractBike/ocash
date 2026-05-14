open Lwt.Syntax

let nl_prefixes = ["habla:"; "ai:"; "?:"; "haz:"; "make:"; "di:"]
let ocaml_prefixes = ["ml:"; "ocaml:"]

(* Sufijo `ç` (o ` ç`) al final del input → modo AI con historial como contexto. *)
let history_trigger_suffixes = ["ç"; " ç"]

let is_history_ai input =
  let s = String.trim input in
  List.exists (fun suf ->
    String.length s >= String.length suf &&
    String.sub s (String.length s - String.length suf) (String.length suf) = suf
  ) history_trigger_suffixes

let strip_history_trigger input =
  let s = String.trim input in
  List.fold_left (fun acc suf ->
    if String.length acc >= String.length suf &&
       String.sub acc (String.length acc - String.length suf) (String.length suf) = suf
    then String.trim (String.sub acc 0 (String.length acc - String.length suf))
    else acc
  ) s history_trigger_suffixes

let strip_prefix prefixes input =
  let s = String.trim input in
  List.find_map (fun p ->
    if String.starts_with ~prefix:p s then
      Some (String.sub s (String.length p)
              (String.length s - String.length p) |> String.trim)
    else None
  ) prefixes

let is_nl input = strip_prefix nl_prefixes input <> None
let is_ocaml input = strip_prefix ocaml_prefixes input <> None

let strip_nl_prefix input =
  strip_prefix nl_prefixes input
  |> Option.value ~default:(String.trim input)

let strip_ocaml_prefix input =
  strip_prefix ocaml_prefixes input
  |> Option.value ~default:(String.trim input)

let c_reset  = "\027[0m"
let c_green  = "\027[32m"
let c_blue   = "\027[34m"
let c_cyan   = "\027[36m"
let c_yellow = "\027[33m"
let c_red    = "\027[31m"
let c_bold   = "\027[1m"
let c_dim    = "\027[2m"

let color c s = c ^ s ^ c_reset

(* Devuelve (branch, dirty) si estamos en un repo git, None si no. *)
let git_info () =
  try
    let read_first_line cmd =
      let ic = Unix.open_process_in cmd in
      let line = try input_line ic with End_of_file -> "" in
      ignore (Unix.close_process_in ic);
      String.trim line
    in
    let inside = read_first_line "git rev-parse --is-inside-work-tree 2>/dev/null" in
    if inside <> "true" then None
    else begin
      let branch = read_first_line "git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null" in
      let dirty = read_first_line "git status --porcelain 2>/dev/null | head -1" in
      Some (branch, dirty <> "")
    end
  with _ -> None

let build_prompt () =
  let user = Option.value ~default:"user" (Sys.getenv_opt "USER") in
  let cwd  =
    let full = try Unix.getcwd () with _ -> "/" in
    let home = Option.value ~default:"" (Sys.getenv_opt "HOME") in
    if String.starts_with ~prefix:home full then
      "~" ^ String.sub full (String.length home)
              (String.length full - String.length home)
    else full
  in
  let count =
    try Array.length (Sys.readdir ".") with _ -> 0
  in
  let ai_badge =
    if !Ai.ai_enabled then color c_cyan " [AI]" else ""
  in
  let git_badge = match git_info () with
    | Some (branch, dirty) ->
        Printf.sprintf " %s(%s%s%s%s)%s"
          c_dim
          c_yellow branch c_reset
          (if dirty then color c_red "*" else "")
          c_reset
    | None -> ""
  in
  Printf.sprintf "%s%s %s%s %s{%d}%s%s $ "
    (color c_green user)
    ai_badge
    (color c_blue cwd)
    git_badge
    c_dim count c_reset
    c_bold

(* Excepción inyectada en el mvar self#interrupt cuando el usuario pulsa
   Ctrl-R. Lleva el texto actual del buffer (para precargar el picker). *)
exception Trigger_hsearch of string

(* Ghost-text inline: sugerencia AI mostrada en gris detrás del cursor,
   actualizada en cada cambio de input. Tab inserta la sugerencia. *)
class shell_readline ?(history_ctx=[]) ?(prefill="") term completions prompt_str =
  let suggestion = ref "" in
  let last_query_text = ref "" in
  object(self)
    inherit LTerm_read_line.read_line () as super
    inherit [Zed_string.t] LTerm_read_line.term term

    initializer
      self#set_prompt (React.S.const (LTerm_text.of_utf8 prompt_str));
      (* Si se nos pasó texto a precargar (e.g. tras un Ctrl-R picker que
         seleccionó un comando) lo insertamos antes de arrancar el loop. *)
      if prefill <> "" then begin
        let zs = Zed_rope.of_string (Zed_string.of_utf8 prefill) in
        Zed_edit.insert self#context zs
      end;
      (* Cada vez que cambia el texto, dispara una query AI (debounced
         por el cache de Autocomplete). Cuando llega la sugerencia, la
         guardamos en ref Y forzamos un redraw inmediato vía
         self#draw_update — sin esperar a la siguiente tecla. *)
      if Autocomplete.enabled () then begin
        let _evt = React.E.map (fun _change ->
          let s = Zed_string.to_utf8 (Zed_rope.to_string (Zed_edit.text self#edit)) in
          if String.length s >= 2 && s <> !last_query_text then begin
            last_query_text := s;
            Lwt.async (fun () ->
              let open Lwt.Syntax in
              let* sugg = Autocomplete.suggest ~history:history_ctx ~current:s in
              let changed = match sugg with
                | Some s' when s' <> "" ->
                    let prev = !suggestion in
                    suggestion := s';
                    prev <> s'
                | _ ->
                    let prev = !suggestion in
                    suggestion := "";
                    prev <> ""
              in
              (* Live redraw: sólo si el texto del buffer no ha cambiado
                 desde que se lanzó la query (evita pintar sobre un
                 estado distinto). Lwt es cooperativo, así que no
                 colisiona con el draw del main loop. *)
              if changed then begin
                let now = Zed_string.to_utf8 (Zed_rope.to_string (Zed_edit.text self#edit)) in
                if now = s then
                  Lwt.catch (fun () -> self#draw_update) (fun _ -> Lwt.return_unit)
                else Lwt.return_unit
              end else Lwt.return_unit)
          end;
          if String.length s = 0 then suggestion := ""
        ) (Zed_edit.changes self#edit) in
        ignore _evt
      end

    method! show_box = false

    (* Interceptamos Prev_search (Ctrl-R por defecto) para lanzar el
       picker fuzzy. Empujamos una excepción al mvar de interrupt — eso
       hace que #run salga limpiamente y read_input pueda capturarla y
       lanzar el picker. *)
    method! send_action action =
      match action with
      | LTerm_read_line.Prev_search ->
          let cur = Zed_string.to_utf8 (Zed_rope.to_string (Zed_edit.text self#edit)) in
          Lwt.async (fun () ->
            Lwt_mvar.put self#interrupt (Trigger_hsearch cur))
      | _ -> super#send_action action

    (* Añade el sufijo ghost en gris al texto stylise-ado. Solo cuando
       no estamos en modo "return" (final del input). *)
    method! stylise last =
      let (styled, cursor) = super#stylise last in
      if last || !suggestion = "" then (styled, cursor)
      else begin
        let dim = LTerm_style.{ none with foreground = Some lblack } in
        let ghost_arr = LTerm_text.of_utf8 !suggestion in
        let ghost_dim = Array.map (fun (c, _) -> (c, dim)) ghost_arr in
        (Array.append styled ghost_dim, cursor)
      end

    (* Tab inserta la sugerencia si hay una; si no, hace completion
       normal (paths, builtins). *)
    method! complete =
      if !suggestion <> "" then begin
        let sugg = !suggestion in
        suggestion := "";
        let zs = Zed_rope.of_string (Zed_string.of_utf8 sugg) in
        Zed_edit.insert self#context zs
      end else begin
        let full_input =
          Zed_rope.to_string (Zed_edit.text self#edit) |> Zed_string.to_utf8
        in
        let last_word =
          full_input
          |> String.split_on_char ' '
          |> List.rev
          |> (function [] -> "" | h :: _ -> h)
        in
        let local =
          List.filter (String.starts_with ~prefix:last_word) completions
          |> List.map (fun s ->
              (Zed_string.of_utf8 s, Zed_string.of_utf8 ""))
        in
        self#set_completion (String.length full_input - String.length last_word) local
      end

  end

(* ───────────────────────── Ctrl-R Fuzzy picker ─────────────────────────
   Picker estilo fzf implementado con LTerm bajo nivel (read_event, draw).
   No subclase de LTerm_read_line porque queremos control total del
   layout (lista de matches + barra de input + highlight) y el modelo
   de LTerm_read_line.term está orientado a una sola línea de input.

   Devuelve Some cmd si el usuario aceptó con Enter, None si canceló
   con Esc o Ctrl-C. *)
let fuzzy_picker ~term ~initial_query : string option Lwt.t =
  let open Lwt.Syntax in
  let query = ref initial_query in
  let cursor = ref (String.length initial_query) in
  let selected = ref 0 in
  let max_rows = 10 in
  let compute_matches () = History.fuzzy_search ~limit:max_rows !query in
  let matches = ref (compute_matches ()) in
  let recompute () =
    matches := compute_matches ();
    if !selected >= List.length !matches then selected := 0
  in
  let nth_opt lst n =
    try Some (List.nth lst n) with _ -> None
  in
  let render () =
    (* Limpia y dibuja la UI desde la posición actual hacia abajo. *)
    let lines = ref [] in
    let header =
      Printf.sprintf "%s%s┃%s %s%s%s"
        c_dim c_cyan c_reset c_bold !query c_reset
    in
    lines := header :: !lines;
    let n = List.length !matches in
    let rows =
      if n = 0 then [c_dim ^ "  (sin matches)" ^ c_reset]
      else
        List.mapi (fun i m ->
          if i = !selected then
            Printf.sprintf "%s▶ %s%s" c_yellow m c_reset
          else
            "  " ^ m
        ) !matches
    in
    List.iter (fun r -> lines := r :: !lines) rows;
    let lines = List.rev !lines in
    let total = List.length lines in
    let* () = LTerm.fprint term "\r" in
    let* () = LTerm.clear_line term in
    let* () = Lwt_list.iter_s (fun l ->
      let* () = LTerm.fprintl term l in
      LTerm.clear_line term) lines in
    (* Sube el cursor hasta justo bajo la primera línea (la barra de
       query) para que parezca un "modal" inline. *)
    let* () = LTerm.move term (-(total - 1)) 0 in
    (* Coloca el cursor dentro del query, offset = strlen prefix "┃ " = 2 *)
    let* () = LTerm.fprint term "\r" in
    let prefix_width = 2 in
    let* () = LTerm.move term 0 (prefix_width + !cursor) in
    LTerm.flush term
  in
  let clear_ui () =
    (* Asume cursor en la línea del query. Limpia max_rows+1 líneas
       hacia abajo y vuelve. *)
    let* () = LTerm.fprint term "\r" in
    let* () = LTerm.clear_line term in
    let* () =
      let n = max_rows in
      let rec loop i =
        if i = 0 then Lwt.return_unit
        else
          let* () = LTerm.fprint term "\n" in
          let* () = LTerm.clear_line term in
          loop (i - 1)
      in
      loop n
    in
    let* () = LTerm.move term (-max_rows) 0 in
    LTerm.fprint term "\r"
  in
  let* mode = LTerm.enter_raw_mode term in
  Lwt.finalize
    (fun () ->
      let rec loop () =
        let* () = render () in
        let* ev = LTerm.read_event term in
        match ev with
        | LTerm_event.Key { code = LTerm_key.Escape; _ } ->
            let* () = clear_ui () in
            Lwt.return None
        | LTerm_event.Key { control = true; code = LTerm_key.Char c; _ }
          when (try let ch = Uchar.to_char c in ch = 'c' || ch = 'g'
                with _ -> false) ->
            let* () = clear_ui () in
            Lwt.return None
        | LTerm_event.Key { code = LTerm_key.Enter; _ } ->
            let* () = clear_ui () in
            Lwt.return (nth_opt !matches !selected)
        | LTerm_event.Key { code = LTerm_key.Up; _ } ->
            if !selected > 0 then decr selected;
            loop ()
        | LTerm_event.Key { control = true; code = LTerm_key.Char c; _ }
          when (try Uchar.to_char c = 'p' with _ -> false) ->
            if !selected > 0 then decr selected;
            loop ()
        | LTerm_event.Key { code = LTerm_key.Down; _ } ->
            let n = List.length !matches in
            if !selected < n - 1 then incr selected;
            loop ()
        | LTerm_event.Key { control = true; code = LTerm_key.Char c; _ }
          when (try Uchar.to_char c = 'n' with _ -> false) ->
            let n = List.length !matches in
            if !selected < n - 1 then incr selected;
            loop ()
        | LTerm_event.Key { code = LTerm_key.Backspace; _ } ->
            if !cursor > 0 then begin
              let q = !query in
              query := String.sub q 0 (!cursor - 1)
                       ^ String.sub q !cursor (String.length q - !cursor);
              decr cursor;
              recompute ()
            end;
            loop ()
        | LTerm_event.Key { code = LTerm_key.Char ch; control = false;
                            meta = false; _ } ->
            (try
              let c = Uchar.to_char ch in
              let q = !query in
              query := String.sub q 0 !cursor ^ String.make 1 c
                       ^ String.sub q !cursor (String.length q - !cursor);
              incr cursor;
              recompute ()
            with _ -> ());
            loop ()
        | _ -> loop ()
      in
      loop ())
    (fun () -> LTerm.leave_raw_mode term mode)

(* REPL "tonto" para modo no-TTY (scripts, pipes, CI). Reintenta tras
   EINTR (e.g. SIGINT entrega y vuelve), para no morir si el usuario
   manda Ctrl-C al proceso. *)
let rec read_input_dumb ~with_prompt () =
  if with_prompt then begin
    print_string (build_prompt ());
    flush stdout
  end;
  try Lwt.return_some (input_line stdin)
  with
  | End_of_file -> Lwt.return_none
  | Sys_error _ ->
      (* Probable EINTR por señal interrumpiendo input_line.
         Reintenta sin reimprimir prompt. *)
      read_input_dumb ~with_prompt:false ()

let is_tty = lazy (try Unix.isatty Unix.stdin with _ -> false)

let read_input ?(history=[]) () =
  if not (Lazy.force is_tty) then
    read_input_dumb ~with_prompt:false ()
  else
    let completions = Completion.get_all "" in
    let prompt      = build_prompt () in
    let rec attempt ?(prefill="") () =
      Lwt.catch
        (fun () ->
          let* term = Lazy.force LTerm.stdout in
          let rl = new shell_readline ~history_ctx:history ~prefill
                     term completions prompt in
          let* result = rl#run in
          Lwt.return_some (Zed_string.to_utf8 result))
        (function
          | Trigger_hsearch initial ->
              (* El loop de read_line ya hizo cleanup al raise.
                 Lanzamos el picker; cuando termine reentramos con el
                 comando elegido como prefill. *)
              let* term = Lazy.force LTerm.stdout in
              let* picked = fuzzy_picker ~term ~initial_query:initial in
              (match picked with
               | Some cmd -> attempt ~prefill:cmd ()
               | None     -> attempt ~prefill:initial ())
          | LTerm_read_line.Interrupt -> Lwt.return_some ""
          | End_of_file               -> exit 0
          | exn                       -> Lwt.fail exn)
    in
    attempt ()
