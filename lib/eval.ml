open Lwt.Syntax

type env = (string, string) Hashtbl.t

let create_env () : env =
  let t = Hashtbl.create 64 in
  Array.iter (fun s ->
    match String.split_on_char '=' s with
    | k :: vs -> Hashtbl.replace t k (String.concat "=" vs)
    | []      -> ()
  ) (Unix.environment ());
  t

let builtins = ["cd"; "exit"; "export"; "echo"; "pwd"; "history"; "set"; "ansible"; "ocaml"; "hsearch"]

let expand_vars env s =
  let buf = Buffer.create (String.length s) in
  let len = String.length s in
  let i   = ref 0 in
  while !i < len do
    if s.[!i] = '$' && !i + 1 < len then begin
      incr i;
      let braced = s.[!i] = '{' in
      if braced then incr i;
      let start = !i in
      let j = ref !i in
      while !j < len &&
            (s.[!j] = '_' ||
             (Char.code s.[!j] >= 65 && Char.code s.[!j] <= 90) ||
             (Char.code s.[!j] >= 97 && Char.code s.[!j] <= 122) ||
             (Char.code s.[!j] >= 48 && Char.code s.[!j] <= 57)) do
        incr j
      done;
      let var = String.sub s start (!j - start) in
      Buffer.add_string buf
        (Option.value ~default:""
          (Hashtbl.find_opt env var));
      if braced && !j < len && s.[!j] = '}' then incr j;
      i := !j
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let last_exit_code = ref 0

let run_builtin env argv =
  match argv with
  | ["cd"] ->
      let home = Option.value ~default:"/" (Hashtbl.find_opt env "HOME") in
      (try Unix.chdir home with Unix.Unix_error _ -> ());
      Lwt.return 0
  | "cd" :: dir :: _ ->
      (try Unix.chdir dir; Lwt.return 0
       with Unix.Unix_error (e, _, _) ->
         Printf.eprintf "ocash: cd: %s\n%!" (Unix.error_message e);
         Lwt.return 1)
  | ["pwd"] ->
      print_endline (Unix.getcwd ()); Lwt.return 0
  | "echo" :: args ->
      print_endline (String.concat " " args); Lwt.return 0
  | ["exit"] ->
      exit !last_exit_code
  | "exit" :: code :: _ ->
      exit (int_of_string_opt code |> Option.value ~default:0)
  | "export" :: rest ->
      List.iter (fun kv ->
        match String.split_on_char '=' kv with
        | k :: vs ->
            let v = String.concat "=" vs in
            Hashtbl.replace env k v;
            Unix.putenv k v
        | [] -> ()
      ) rest;
      Lwt.return 0
  | "set" :: [] ->
      Hashtbl.iter (fun k v -> Printf.printf "%s=%s\n" k v) env;
      Lwt.return 0
  | "history" :: _ ->
      List.iteri (fun i s -> Printf.printf "%5d  %s\n" (i+1) s) (History.all ());
      Lwt.return 0
  | "hsearch" :: rest ->
      let q = String.concat " " rest in
      let matches = History.fuzzy_search ~limit:20 q in
      List.iter (fun m -> print_endline m) matches;
      Lwt.return (if matches = [] then 1 else 0)
  | "ansible" :: rest ->
      Ansible.dispatch rest
  | "ocaml" :: rest ->
      Ocaml_eval.dispatch rest
  | _ ->
      Lwt.return 127

let find_in_path cmd =
  if String.contains cmd '/' then
    (if Sys.file_exists cmd then Some cmd else None)
  else
    let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
    String.split_on_char ':' path
    |> List.find_map (fun dir ->
        let full = Filename.concat dir cmd in
        if Sys.file_exists full then Some full else None)

(* Aplica redirects globalmente y devuelve los fds salvados para restaurar.
   Solo se usa para builtins fuera de pipelines (Single sin Pipe). *)
let apply_redirects redirects =
  List.filter_map (fun r ->
    match r with
    | Ast.Stdout_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
        let saved = Unix.dup Unix.stdout in
        Unix.dup2 fd Unix.stdout;
        Unix.close fd;
        Some (Unix.stdout, saved)
    | Ast.Append_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o644 in
        let saved = Unix.dup Unix.stdout in
        Unix.dup2 fd Unix.stdout;
        Unix.close fd;
        Some (Unix.stdout, saved)
    | Ast.Stdin_from f ->
        let fd = Unix.openfile f [Unix.O_RDONLY] 0 in
        let saved = Unix.dup Unix.stdin in
        Unix.dup2 fd Unix.stdin;
        Unix.close fd;
        Some (Unix.stdin, saved)
    | Ast.Stderr_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
        let saved = Unix.dup Unix.stderr in
        Unix.dup2 fd Unix.stderr;
        Unix.close fd;
        Some (Unix.stderr, saved)
  ) redirects

let restore_redirects saved =
  List.iter (fun (orig, saved_fd) ->
    Unix.dup2 saved_fd orig;
    Unix.close saved_fd
  ) saved

(* Resuelve redirects a (stdin_fd, stdout_fd, stderr_fd, fds_to_close_in_parent).
   No muta stdout global: solo abre archivos para los fds de un subproceso. *)
let resolve_redirects redirects (in0, out0, err0) =
  let i = ref in0 in
  let o = ref out0 in
  let e = ref err0 in
  let opened = ref [] in
  List.iter (fun r ->
    match r with
    | Ast.Stdout_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC] 0o644 in
        o := fd; opened := fd :: !opened
    | Ast.Append_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_APPEND] 0o644 in
        o := fd; opened := fd :: !opened
    | Ast.Stdin_from f ->
        let fd = Unix.openfile f [Unix.O_RDONLY] 0 in
        i := fd; opened := fd :: !opened
    | Ast.Stderr_to f ->
        let fd = Unix.openfile f [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC] 0o644 in
        e := fd; opened := fd :: !opened
  ) redirects;
  (!i, !o, !e, !opened)

(* Lanza un comando como subproceso con los fds dados.
   close_in_child son fds extras (típicamente otros extremos de pipes)
   que el child debe cerrar tras dup2. *)
let spawn_command env argv redirects stdin_fd stdout_fd close_in_child =
  match argv with
  | [] -> Lwt.return 0
  | prog :: _ ->
      let (i, o, e, opened) =
        resolve_redirects redirects (stdin_fd, stdout_fd, Unix.stderr)
      in
      let close_in_parent () =
        List.iter (fun fd -> try Unix.close fd with _ -> ()) opened
      in
      if List.mem prog builtins then begin
        (* Builtin en pipeline: fork para aislar dup2 y env del padre.
           En el child no podemos llamar Lwt_main.run (Lwt cree que el padre
           ya está corriendo). Extraemos el resultado del promise asumiendo
           que el builtin es síncrono (echo/pwd/cd/export/exit/set lo son). *)
        match Unix.fork () with
        | 0 ->
            (try
              if i <> Unix.stdin then begin
                Unix.dup2 i Unix.stdin;
                Unix.close i
              end;
              if o <> Unix.stdout then begin
                Unix.dup2 o Unix.stdout;
                Unix.close o
              end;
              if e <> Unix.stderr then begin
                Unix.dup2 e Unix.stderr;
                Unix.close e
              end;
              List.iter (fun fd -> try Unix.close fd with _ -> ()) close_in_child;
              let promise = run_builtin env argv in
              let code = match Lwt.state promise with
                | Lwt.Return n -> n
                | Lwt.Fail _   -> 1
                | Lwt.Sleep    ->
                    Printf.eprintf
                      "ocash: builtin '%s' en pipe requiere I/O async — no soportado\n%!"
                      prog;
                    1
              in
              exit code
            with exn ->
              Printf.eprintf "ocash: builtin error: %s\n%!" (Printexc.to_string exn);
              exit 1)
        | pid ->
            close_in_parent ();
            let* (_, status) = Lwt_unix.waitpid [] pid in
            let code = match status with
              | Unix.WEXITED n -> n
              | Unix.WSIGNALED _ -> 130
              | Unix.WSTOPPED _ -> 128
            in
            last_exit_code := code;
            Lwt.return code
      end else begin
        match find_in_path prog with
        | None ->
            close_in_parent ();
            Printf.eprintf "ocash: %s: comando no encontrado\n%!" prog;
            Lwt.return 127
        | Some full_path ->
            let pid = Unix.create_process full_path
              (Array.of_list argv) i o e
            in
            close_in_parent ();
            let* (_, status) = Lwt_unix.waitpid [] pid in
            let code = match status with
              | Unix.WEXITED n   -> n
              | Unix.WSIGNALED _ -> 130
              | Unix.WSTOPPED _  -> 128
            in
            last_exit_code := code;
            Lwt.return code
      end

(* Recorre el pipeline y devuelve un promise por cada etapa,
   garantizando que cada child cierra los pipe fds que no necesita. *)
let run_pipeline env pipeline =
  let rec aux p stdin_fd stdout_fd close_in_child =
    match p with
    | Ast.Single cmd ->
        let argv = List.map (expand_vars env) cmd.Ast.argv in
        spawn_command env argv cmd.Ast.redirects
          stdin_fd stdout_fd close_in_child
    | Ast.Pipe (left, right) ->
        let (pipe_r, pipe_w) = Unix.pipe ~cloexec:true () in
        (* left escribe a pipe_w; debe cerrar pipe_r (extremo de lectura del padre).
           right lee de pipe_r; debe cerrar pipe_w (extremo de escritura del padre). *)
        let left_t  = aux left  stdin_fd pipe_w (pipe_r :: close_in_child) in
        let right_t = aux right pipe_r stdout_fd (pipe_w :: close_in_child) in
        (* En el padre cerramos ambos extremos: los children ya tienen sus copias. *)
        (try Unix.close pipe_w with _ -> ());
        (try Unix.close pipe_r with _ -> ());
        let* _ = left_t in
        let* code = right_t in
        Lwt.return code
  in
  match pipeline with
  | Ast.Single cmd ->
      (* Single sin pipe: builtins corren in-process para que cd/export
         afecten al padre. Redirects via apply/restore globales. *)
      let argv = List.map (expand_vars env) cmd.Ast.argv in
      (match argv with
       | [] -> Lwt.return 0
       | prog :: _ when List.mem prog builtins ->
           let saved = apply_redirects cmd.Ast.redirects in
           Lwt.finalize
             (fun () -> run_builtin env argv)
             (fun () -> restore_redirects saved; Lwt.return ())
       | _ ->
           aux pipeline Unix.stdin Unix.stdout [])
  | Ast.Pipe _ -> aux pipeline Unix.stdin Unix.stdout []

let rec eval_statement env stmt =
  match stmt with
  | Ast.Empty      -> Lwt.return 0
  | Ast.Assign (k, v) ->
      let v' = expand_vars env v in
      Hashtbl.replace env k v';
      Lwt.return 0
  | Ast.Exec p ->
      run_pipeline env p
  | Ast.And (a, b) ->
      let* code = eval_statement env a in
      if code = 0 then eval_statement env b
      else Lwt.return code
  | Ast.Or (a, b) ->
      let* code = eval_statement env a in
      if code <> 0 then eval_statement env b
      else Lwt.return code
  | Ast.Seq (a, b) ->
      let* _ = eval_statement env a in
      eval_statement env b
  | Ast.Background stmt ->
      Lwt.async (fun () ->
        let* _ = eval_statement env stmt in
        Lwt.return ());
      Lwt.return 0
