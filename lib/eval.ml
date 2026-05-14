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

let builtins = ["cd"; "exit"; "export"; "echo"; "pwd"; "history"; "set"; "ansible"; "ocaml"]

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

let run_external _env argv stdin_fd stdout_fd =
  match argv with
  | [] -> Lwt.return 0
  | prog :: _ ->
      match find_in_path prog with
      | None ->
          Printf.eprintf "ocash: %s: comando no encontrado\n%!" prog;
          Lwt.return 127
      | Some full_path ->
          let pid = Unix.create_process full_path
            (Array.of_list argv)
            stdin_fd stdout_fd Unix.stderr
          in
          let* (_, status) = Lwt_unix.waitpid [] pid in
          let code = match status with
            | Unix.WEXITED n   -> n
            | Unix.WSIGNALED _ -> 130
            | Unix.WSTOPPED _  -> 128
          in
          last_exit_code := code;
          Lwt.return code

let rec run_pipeline env pipeline stdin_fd stdout_fd =
  match pipeline with
  | Ast.Single cmd ->
      let argv = List.map (expand_vars env) cmd.Ast.argv in
      (match argv with
       | [] -> Lwt.return 0
       | prog :: _ ->
           if List.mem prog builtins then begin
             let saved = apply_redirects cmd.Ast.redirects in
             let* code = run_builtin env argv in
             restore_redirects saved;
             Lwt.return code
           end else begin
             let saved = apply_redirects cmd.Ast.redirects in
             let* code = run_external env argv stdin_fd stdout_fd in
             restore_redirects saved;
             Lwt.return code
           end)
  | Ast.Pipe (left, right) ->
      let (pipe_r, pipe_w) = Unix.pipe () in
      let* _  = run_pipeline env left  stdin_fd pipe_w in
      Unix.close pipe_w;
      let* code = run_pipeline env right pipe_r stdout_fd in
      Unix.close pipe_r;
      Lwt.return code

let rec eval_statement env stmt =
  match stmt with
  | Ast.Empty      -> Lwt.return 0
  | Ast.Assign (k, v) ->
      let v' = expand_vars env v in
      Hashtbl.replace env k v';
      Lwt.return 0
  | Ast.Exec p ->
      run_pipeline env p Unix.stdin Unix.stdout
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
