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
    try
      let entries = Sys.readdir "." in
      Array.length entries
    with _ -> 0
  in
  let ai_badge =
    if !Ai.ai_enabled then color c_cyan " [AI]" else ""
  in
  Printf.sprintf "%s%s %s %s{%d}%s%s $ "
    (color c_green user)
    ai_badge
    (color c_blue cwd)
    c_dim count c_reset
    c_bold

(* Ghost-text inline: sugerencia AI mostrada en gris detrás del cursor,
   actualizada en cada cambio de input. Tab inserta la sugerencia. *)
class shell_readline ?(history_ctx=[]) term completions prompt_str =
  let suggestion = ref "" in
  let last_query_text = ref "" in
  object(self)
    inherit LTerm_read_line.read_line () as super
    inherit [Zed_string.t] LTerm_read_line.term term

    initializer
      self#set_prompt (React.S.const (LTerm_text.of_utf8 prompt_str));
      (* Cada vez que cambia el texto, dispara una query AI (debounced
         por el cache de Autocomplete). Cuando llega la sugerencia, la
         guardamos en ref. El siguiente redraw la incluirá en #stylise. *)
      if Autocomplete.enabled () then begin
        let _evt = React.E.map (fun _change ->
          let s = Zed_string.to_utf8 (Zed_rope.to_string (Zed_edit.text self#edit)) in
          if String.length s >= 2 && s <> !last_query_text then begin
            last_query_text := s;
            Lwt.async (fun () ->
              let open Lwt.Syntax in
              let* sugg = Autocomplete.suggest ~history:history_ctx ~current:s in
              (match sugg with
               | Some s' when s' <> "" -> suggestion := s'
               | _ -> suggestion := "");
              Lwt.return ())
          end;
          if String.length s = 0 then suggestion := ""
        ) (Zed_edit.changes self#edit) in
        ignore _evt
      end

    method! show_box = false

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

(* REPL "tonto" para modo no-TTY (scripts, pipes, CI). *)
let read_input_dumb ~with_prompt () =
  if with_prompt then begin
    print_string (build_prompt ());
    flush stdout
  end;
  try Lwt.return_some (input_line stdin)
  with End_of_file -> Lwt.return_none

let is_tty = lazy (try Unix.isatty Unix.stdin with _ -> false)

let read_input ?(history=[]) () =
  if not (Lazy.force is_tty) then
    read_input_dumb ~with_prompt:false ()
  else
    let completions = Completion.get_all "" in
    let prompt      = build_prompt () in
    Lwt.catch
      (fun () ->
        let* term = Lazy.force LTerm.stdout in
        let rl = new shell_readline ~history_ctx:history term completions prompt in
        let* result = rl#run in
        Lwt.return_some (Zed_string.to_utf8 result))
      (function
        | LTerm_read_line.Interrupt -> Lwt.return_some ""
        | End_of_file               -> exit 0
        | exn                       -> Lwt.fail exn)
