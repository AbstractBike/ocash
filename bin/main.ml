open Lwt.Syntax

let () = Lwt_engine.set (new Lwt_engine.libev ())

(* Signal handling: el padre intercepta SIGINT con un handler que no hace
   nada relevante. Si hay un proceso foreground corriendo, ese también
   recibe la señal del TTY y muere; ocash sigue vivo. Si no hay proceso
   foreground, simplemente ignoramos (lambda-term redibuja la prompt).
   Importante: usar Signal_handle (no Signal_ignore) porque SIG_IGN se
   hereda a través de execve, mientras que los handlers se resetean a
   default — así los children sí responden a Ctrl-C normalmente. *)
let () =
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    (* nada: en el padre absorbemos. El child foreground muere por su
       propio default handler y waitpid retorna con WSIGNALED. *)
    ()
  ));
  (* SIGQUIT también — Ctrl-\ no debería matar ocash. *)
  Sys.set_signal Sys.sigquit (Sys.Signal_handle (fun _ -> ()));
  (* SIGTSTP en el padre: no detener ocash. Children pueden ser detenidos
     individualmente vía kill -STOP. *)
  Sys.set_signal Sys.sigtstp (Sys.Signal_handle (fun _ -> ()))

(* Historial persistente (Ocash_lib.History) reemplaza el Queue local. *)
let add_history line = Ocash_lib.History.add line

let last_line = ref ""
let last_exit = ref 0
let last_stderr = ref ""

(* Self-correction: si el último comando falló (exit != 0) y AI está
   activa, ofrece al usuario que el AI proponga una corrección. *)
let maybe_self_correct env =
  let open Ocash_lib in
  if !last_exit = 0 || !last_line = "" || not !Ai.ai_enabled then Lwt.return ()
  else if not (Lazy.force Readline.is_tty) then Lwt.return ()
  else begin
    Printf.printf "%s↳ exit %d. ¿AI auto-corregir?%s [s/N] %!"
      Readline.c_yellow !last_exit Readline.c_reset;
    let ans = try input_line stdin |> String.trim |> String.lowercase_ascii
              with End_of_file -> "n" in
    match ans with
    | "s" | "si" | "sí" | "y" | "yes" ->
        let prompt = Ai.build_correction_prompt
          ~failed_cmd:!last_line ~exit_code:!last_exit ~stderr:!last_stderr in
        let* result = Ai.query ~user_input:prompt () in
        (match result with
         | Ai.Command cmd ->
             Printf.printf "%s→ %s%s\n%!" Readline.c_cyan cmd Readline.c_reset;
             Printf.printf "%s¿ejecutar?%s [S/n] %!"
               Readline.c_yellow Readline.c_reset;
             let go = try input_line stdin |> String.trim |> String.lowercase_ascii
                      with End_of_file -> "n" in
             (match go with
              | "" | "s" | "y" | "yes" | "si" | "sí" ->
                  let* _ = Eval.eval_statement env
                    (match Parser.parse cmd with Ok s -> s | _ -> Ast.Empty) in
                  Lwt.return ()
              | _ -> Lwt.return ())
         | _ -> Lwt.return ())
    | _ -> Lwt.return ()
  end

(* Wrapper de `time cmd ...`: mide y reporta wall/user/sys. *)
let eval_line_timed env line =
  let t0 = Unix.gettimeofday () in
  let tms0 = Unix.times () in
  let* code = match Ocash_lib.Parser.parse line with
    | Ok s -> Ocash_lib.Eval.eval_statement env s
    | Error _ -> Lwt.return 1
  in
  let t1 = Unix.gettimeofday () in
  let tms1 = Unix.times () in
  Printf.eprintf "\nreal\t%.3fs\nuser\t%.3fs\nsys\t%.3fs\n%!"
    (t1 -. t0)
    (tms1.tms_cutime -. tms0.tms_cutime)
    (tms1.tms_cstime -. tms0.tms_cstime);
  Lwt.return code

let eval_line env line =
  last_line := line;
  add_history line;
  (* Prefijo `time `: medir el resto del pipeline *)
  if String.length line > 5 && String.sub line 0 5 = "time " then
    eval_line_timed env (String.sub line 5 (String.length line - 5))
  else
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
          (fun () ->
            let* code = Ocash_lib.Eval.eval_statement env stmt in
            last_exit := code;
            Lwt.return code)
          (fun exn ->
            Printf.eprintf "\027[31merror:\027[0m %s\n%!" (Printexc.to_string exn);
            last_exit := 1;
            Lwt.return 1)

let last_history_entries n = Ocash_lib.History.last_n n

let handle_nl ?(with_history=false) env input =
  let open Ocash_lib in
  let query =
    if with_history then Readline.strip_history_trigger input
    else Readline.strip_nl_prefix input
  in
  let history_ctx = if with_history then last_history_entries 8 else [] in
  (* RAG: si OCASH_RAG=1, augmenta query con snippets del proyecto *)
  let rag_on = match Sys.getenv_opt "OCASH_RAG" with
    | Some ("1" | "true" | "on" | "yes") -> true
    | _ -> false
  in
  let augmented_query = if rag_on then Ocash_lib.Rag.augment ~query else query in
  Printf.printf "%s⟳ pensando%s%s%s...%s\r%!"
    Readline.c_yellow
    (if with_history then " (con contexto)" else "")
    (if rag_on then " (con RAG)" else "")
    "" Readline.c_reset;
  Ai.conv_add_user query;
  let* result = Ai.query ~history:history_ctx ~multi_turn:true ~user_input:augmented_query () in
  print_string "                    \r";
  match result with
  | Ai.Disabled ->
      Printf.printf "%s✗ AI no disponible%s\n%!" Readline.c_yellow Readline.c_reset;
      Lwt.return ()
  | Ai.AiError msg ->
      Printf.printf "%s✗ %s%s\n%!" Readline.c_red msg Readline.c_reset;
      Lwt.return ()
  | Ai.Command cmd ->
      Ai.conv_add_assistant cmd;
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

let version_string = "ocash 0.1.0"

let help_text = {|ocash — OCaml shell interactiva con AI

USO:
  ocash [OPTIONS]

OPCIONES:
  --help, -h       Muestra esta ayuda y termina
  --version, -V    Muestra la versión y termina

VARIABLES DE ENTORNO:
  OCASH_AI_BACKEND   Backend AI: local | claude | codex | anthropic | openai
  OCASH_AI_URL       URL del backend (default http://localhost:8080 para local)
  OCASH_AI_MODEL     Modelo (para backends API)
  OCASH_AI_STREAM    1/0 — streaming SSE en backend local (default 1)
  OCASH_RAG          1 — augmenta queries AI con snippets del cwd
  ANTHROPIC_API_KEY  Key para backend anthropic
  OPENAI_API_KEY     Key para backend openai

ARCHIVOS:
  ~/.ocashrc         Se ejecuta al arrancar (si existe)
  ~/.ocash/history   Historial persistente

Ver `man ocash` para más detalle.
|}

let handle_argv () =
  let args = Array.to_list Sys.argv in
  let has flag = List.exists (fun a -> a = flag) args in
  if has "--help" || has "-h" then begin
    print_string help_text;
    exit 0
  end;
  if has "--version" || has "-V" then begin
    print_endline version_string;
    exit 0
  end

let () =
  handle_argv ();
  let interactive = Lazy.force Ocash_lib.Readline.is_tty in
  Lwt_main.run begin
    Ocash_lib.History.load ();
    if interactive then banner ();
    let env = Ocash_lib.Eval.create_env () in
    let* () = Ocash_lib.Ai.init () in
    (* Cargar ~/.ocashrc si existe *)
    let rc = Filename.concat
      (try Sys.getenv "HOME" with Not_found -> "/tmp") ".ocashrc" in
    let* () =
      if Sys.file_exists rc then
        let stmt = match Ocash_lib.Parser.parse (Printf.sprintf "source %s" rc) with
          | Ok s -> s | Error _ -> Ocash_lib.Ast.Empty in
        let* _ = Ocash_lib.Eval.eval_statement env stmt in
        Lwt.return ()
      else Lwt.return ()
    in
    let rec loop () =
      let history_ctx = last_history_entries 8 in
      let* input_opt = Ocash_lib.Readline.read_input ~history:history_ctx () in
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
              let rc = Ocash_lib.Ocaml_eval.eval_phrase code in
              if rc <> 0 && !Ocash_lib.Ai.ai_enabled
                 && Lazy.force Ocash_lib.Readline.is_tty then begin
                let err = !Ocash_lib.Ocaml_eval.last_error_msg in
                Printf.printf "%s↳ ¿AI auto-corregir el OCaml?%s [s/N] %!"
                  Ocash_lib.Readline.c_yellow Ocash_lib.Readline.c_reset;
                let ans = try input_line stdin |> String.trim |> String.lowercase_ascii
                          with End_of_file -> "n" in
                if List.mem ans ["s"; "si"; "sí"; "y"; "yes"] then begin
                  let* fix = Ocash_lib.Ocaml_eval.self_correct ~code ~error:err in
                  match fix with
                  | Some fixed ->
                      Printf.printf "%s→ %s%s\n%!"
                        Ocash_lib.Readline.c_cyan fixed Ocash_lib.Readline.c_reset;
                      let _ = Ocash_lib.Ocaml_eval.eval_phrase fixed in
                      Lwt.return ()
                  | None -> Lwt.return ()
                end else Lwt.return ()
              end else Lwt.return ()
            end
            else begin
              let* _ = eval_line env line in
              maybe_self_correct env
            end
          in
          loop ()
    in
    loop ()
  end
