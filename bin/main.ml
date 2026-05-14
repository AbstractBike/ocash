open Lwt.Syntax

let () = Lwt_engine.set (new Lwt_engine.libev ())

let history : string Queue.t = Queue.create ()
let max_history = 1000

let add_history line =
  if String.trim line <> "" then begin
    Queue.push line history;
    if Queue.length history > max_history then
      ignore (Queue.pop history)
  end

let eval_line env line =
  add_history line;
  (* Fallback a bash si el input usa construcciones que ocash no parsea
     nativamente (if/for/$()/&&/;/[[ ]]/heredocs/glob/tilde/...). *)
  if Ocash_lib.Bash.needs_bash line then begin
    Ocash_lib.Bash.sync_env env;
    Lwt.catch
      (fun () -> Ocash_lib.Bash.run line)
      (fun exn ->
        Printf.eprintf "\027[31mbash error:\027[0m %s\n%!" (Printexc.to_string exn);
        Lwt.return 1)
  end else
    match Ocash_lib.Parser.parse line with
    | Error _ ->
        (* Si el parser nativo falla, cae a bash como último recurso. *)
        Ocash_lib.Bash.sync_env env;
        Ocash_lib.Bash.run line
    | Ok stmt ->
        Lwt.catch
          (fun () -> Ocash_lib.Eval.eval_statement env stmt)
          (fun exn ->
            Printf.eprintf "\027[31merror:\027[0m %s\n%!" (Printexc.to_string exn);
            Lwt.return 1)

let last_history_entries n =
  let lst = ref [] in
  Queue.iter (fun s -> lst := s :: !lst) history;
  let recent = List.rev !lst in
  let len = List.length recent in
  if len <= n then recent
  else List.filteri (fun i _ -> i >= len - n) recent

let handle_nl ?(with_history=false) env input =
  let open Ocash_lib in
  let query =
    if with_history then Readline.strip_history_trigger input
    else Readline.strip_nl_prefix input
  in
  let history_ctx = if with_history then last_history_entries 8 else [] in
  Printf.printf "%s⟳ pensando%s%s...%s\r%!"
    Readline.c_yellow
    (if with_history then " (con contexto)" else "")
    "" Readline.c_reset;
  let* result = Ai.query ~history:history_ctx ~user_input:query () in
  print_string "                    \r";
  match result with
  | Ai.Disabled ->
      Printf.printf "%s✗ AI no disponible%s\n%!" Readline.c_yellow Readline.c_reset;
      Lwt.return ()
  | Ai.AiError msg ->
      Printf.printf "%s✗ %s%s\n%!" Readline.c_red msg Readline.c_reset;
      Lwt.return ()
  | Ai.Command cmd ->
      Printf.printf "%s→ %s%s%s\n%!"
        Readline.c_cyan Readline.c_bold cmd Readline.c_reset;
      Printf.printf "%s¿ejecutar?%s [S/n/e] %!"
        Readline.c_yellow Readline.c_reset;
      let answer =
        try input_line stdin |> String.trim |> String.lowercase_ascii
        with End_of_file -> "n"
      in
      (match answer with
       | "" | "s" | "si" | "sí" | "y" | "yes" ->
           let* _ = eval_line env cmd in
           Lwt.return ()
       | "e" ->
           Printf.printf "%seditar:%s " Readline.c_dim Readline.c_reset;
           let edited = try input_line stdin with End_of_file -> cmd in
           let* _ = eval_line env edited in
           Lwt.return ()
       | _ ->
           Printf.printf "%scancelado%s\n%!" Readline.c_dim Readline.c_reset;
           Lwt.return ())

let banner () =
  let open Ocash_lib.Readline in
  Printf.printf
    "\n  %s╔═══════════════════════════╗%s\n\
     \  %s║   ocash — OCaml Shell     ║%s\n\
     \  %s║   + AI (multi-backend)    ║%s\n\
     \  %s║   + Ansible builtin       ║%s\n\
     \  %s║   + OCaml toploop (ml:)   ║%s\n\
     \  %s╚═══════════════════════════╝%s\n\
     \  %shabla: <texto>%s    → modo AI en español\n\
     \  %s<texto> ç%s          → AI con contexto del historial\n\
     \  %sml:    <expr>%s     → evalúa OCaml en el toploop embebido\n\
     \  %sansible help%s      → ayuda del builtin Ansible\n\
     \  %socaml help%s        → ayuda del compilador OCaml\n\
     \  %sGPU:%s %s — %s\n\n"
    c_cyan c_reset
    c_cyan c_reset
    c_cyan c_reset
    c_cyan c_reset
    c_cyan c_reset
    c_cyan c_reset
    c_bold c_reset
    c_bold c_reset
    c_bold c_reset
    c_bold c_reset
    c_bold c_reset
    c_dim c_reset
    (Ocash_lib.Gpu.label ())
    (if Lazy.force Ocash_lib.Gpu.has_gpu
     then "autocomplete on-the-fly habilitado"
     else "autocomplete on-the-fly deshabilitado")

let () =
  let interactive = Lazy.force Ocash_lib.Readline.is_tty in
  Lwt_main.run begin
    if interactive then banner ();
    let env = Ocash_lib.Eval.create_env () in
    let* () = Ocash_lib.Ai.init () in
    let rec loop () =
      let* input_opt = Ocash_lib.Readline.read_input () in
      match input_opt with
      | None       ->
          (* EOF: en TTY lambda-term ya hizo exit; en no-TTY salimos limpio. *)
          if interactive then loop () else Lwt.return ()
      | Some ""    -> loop ()
      | Some line  ->
          let* () =
            if Ocash_lib.Readline.is_history_ai line then
              handle_nl ~with_history:true env line
            else if Ocash_lib.Readline.is_nl line then
              handle_nl env line
            else if Ocash_lib.Readline.is_ocaml line then begin
              let code = Ocash_lib.Readline.strip_ocaml_prefix line in
              let _ = Ocash_lib.Ocaml_eval.eval_phrase code in
              Lwt.return ()
            end
            else
              let* _ = eval_line env line in
              Lwt.return ()
          in
          loop ()
    in
    loop ()
  end
