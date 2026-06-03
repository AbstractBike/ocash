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

let builtins = ["cd"; "exit"; "export"; "echo"; "pwd"; "history"; "set"; "ansible"; "ocaml"; "hsearch"; "alias"; "unalias"; "source"; "."; "jobs"; "fg"; "bg"]

(* ===== Job control ===================================================== *)

type job_state = Running | Stopped | Done

type job = {
  id      : int;       (* job number, 1-based *)
  pid     : int;       (* PID del proceso (o grupo) *)
  cmdline : string;
  mutable state : job_state;
}

let jobs : job list ref = ref []
let next_job_id = ref 1

(* PID del proceso foreground actual (0 = ninguno). Lo usa el handler de
   SIGINT para reenviar la señal si fuera necesario (en TTY normalmente
   el kernel ya la entrega al grupo foreground). *)
let current_fg_pid : int ref = ref 0

let add_job ~pid ~cmdline ~state =
  let id = !next_job_id in
  incr next_job_id;
  jobs := !jobs @ [{ id; pid; cmdline; state }];
  id

let remove_job id =
  jobs := List.filter (fun j -> j.id <> id) !jobs

let find_job id = List.find_opt (fun j -> j.id = id) !jobs

let state_label = function
  | Running -> "Running"
  | Stopped -> "Stopped"
  | Done    -> "Done"

(* Sondea sin bloquear todos los jobs y actualiza su estado. *)
let reap_jobs () =
  List.iter (fun j ->
    if j.state <> Done then
      try
        let (pid, status) = Unix.waitpid [Unix.WNOHANG; Unix.WUNTRACED] j.pid in
        if pid = 0 then () (* sin cambios *)
        else match status with
          | Unix.WEXITED _ | Unix.WSIGNALED _ -> j.state <- Done
          | Unix.WSTOPPED _ -> j.state <- Stopped
      with Unix.Unix_error _ -> j.state <- Done
  ) !jobs

(* Limpia los jobs que terminaron (tras reportarlos al usuario). *)
let purge_done_jobs () =
  jobs := List.filter (fun j -> j.state <> Done) !jobs

(* Render simple de un statement a string para mostrar en `jobs`. *)
let rec render_pipeline = function
  | Ast.Single { Ast.argv; _ } -> String.concat " " argv
  | Ast.Pipe (a, b) -> render_pipeline a ^ " | " ^ render_pipeline b

let rec render_statement = function
  | Ast.Empty       -> ""
  | Ast.Assign (k, v) -> k ^ "=" ^ v
  | Ast.Exec p      -> render_pipeline p
  | Ast.And (a, b)  -> render_statement a ^ " && " ^ render_statement b
  | Ast.Or  (a, b)  -> render_statement a ^ " || " ^ render_statement b
  | Ast.Seq (a, b)  -> render_statement a ^ "; "  ^ render_statement b
  | Ast.Background s -> render_statement s ^ " &"

(* Tabla de aliases mutables. expand_alias se aplica al primer token. *)
let aliases : (string, string) Hashtbl.t = Hashtbl.create 32

let expand_alias argv =
  match argv with
  | [] -> argv
  | head :: rest ->
      (match Hashtbl.find_opt aliases head with
       | Some expanded ->
           (* expanded puede ser "ls -la --color=auto"; split por espacios *)
           let parts = String.split_on_char ' ' expanded
             |> List.filter (fun s -> s <> "") in
           parts @ rest
       | None -> argv)

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

(* Expande un `~` o `~/...` inicial usando $HOME. No soporta `~usuario`
   (eso cae a bash). Cualquier otra forma se devuelve sin tocar. *)
let expand_tilde env s =
  if s = "~" then
    Option.value ~default:"~" (Hashtbl.find_opt env "HOME")
  else if String.length s >= 2 && s.[0] = '~' && s.[1] = '/' then
    (match Hashtbl.find_opt env "HOME" with
     | Some home -> home ^ String.sub s 1 (String.length s - 1)
     | None -> s)
  else s

let last_exit_code = ref 0

(* Forward-reference para que `source` pueda re-entrar al eval. *)
let eval_statement_ref : (Ast.statement -> int Lwt.t) ref =
  ref (fun _ -> Lwt.return 0)

(* Cambia de directorio actualizando PWD/OLDPWD (env del padre y del
   proceso) como hace un shell POSIX. Devuelve el exit code. *)
let do_cd env target =
  let oldpwd = try Unix.getcwd () with _ -> "" in
  try
    Unix.chdir target;
    let newpwd = try Unix.getcwd () with _ -> target in
    if oldpwd <> "" then begin
      Hashtbl.replace env "OLDPWD" oldpwd;
      (try Unix.putenv "OLDPWD" oldpwd with _ -> ())
    end;
    Hashtbl.replace env "PWD" newpwd;
    (try Unix.putenv "PWD" newpwd with _ -> ());
    Lwt.return 0
  with Unix.Unix_error (e, _, _) ->
    Printf.eprintf "ocash: cd: %s: %s\n%!" target (Unix.error_message e);
    Lwt.return 1

let run_builtin env argv =
  match argv with
  | ["cd"] ->
      let home = Option.value ~default:"/" (Hashtbl.find_opt env "HOME") in
      do_cd env home
  | "cd" :: "-" :: _ ->
      (match Hashtbl.find_opt env "OLDPWD" with
       | Some prev -> print_endline prev; do_cd env prev
       | None ->
           Printf.eprintf "ocash: cd: OLDPWD no establecido\n%!";
           Lwt.return 1)
  | "cd" :: dir :: _ ->
      do_cd env (expand_tilde env dir)
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
  | ["alias"] ->
      Hashtbl.iter (fun k v -> Printf.printf "alias %s='%s'\n" k v) aliases;
      Lwt.return 0
  | "alias" :: rest ->
      (* `alias name=value` o `alias name='value with spaces'` *)
      List.iter (fun spec ->
        match String.index_opt spec '=' with
        | None ->
            (match Hashtbl.find_opt aliases spec with
             | Some v -> Printf.printf "alias %s='%s'\n" spec v
             | None -> Printf.eprintf "ocash: alias: %s: no encontrado\n%!" spec)
        | Some i ->
            let name = String.sub spec 0 i in
            let value = String.sub spec (i+1) (String.length spec - i - 1) in
            let value =
              if String.length value >= 2 && value.[0] = '\''
                 && value.[String.length value - 1] = '\''
              then String.sub value 1 (String.length value - 2)
              else if String.length value >= 2 && value.[0] = '"'
                      && value.[String.length value - 1] = '"'
              then String.sub value 1 (String.length value - 2)
              else value
            in
            Hashtbl.replace aliases name value
      ) rest;
      Lwt.return 0
  | "unalias" :: names ->
      List.iter (Hashtbl.remove aliases) names;
      Lwt.return 0
  | ("source" | ".") :: file :: _ ->
      let expanded = expand_vars env file in
      let path =
        if String.length expanded > 1 && String.sub expanded 0 2 = "~/" then
          let home = try Sys.getenv "HOME" with Not_found -> "" in
          home ^ String.sub expanded 1 (String.length expanded - 1)
        else expanded
      in
      if not (Sys.file_exists path) then begin
        Printf.eprintf "ocash: source: %s: no existe\n%!" path;
        Lwt.return 1
      end else begin
        let ic = open_in path in
        let rec loop_lines () =
          match input_line ic with
          | exception End_of_file -> Lwt.return 0
          | line ->
              let line = String.trim line in
              if line = "" || String.length line > 0 && line.[0] = '#'
              then loop_lines ()
              else begin
                match Parser.parse line with
                | Ok stmt ->
                    let* _ = !eval_statement_ref stmt in
                    loop_lines ()
                | Error _ -> loop_lines ()
              end
        in
        let* code = loop_lines () in
        close_in ic;
        Lwt.return code
      end
  (* time se maneja en main.ml para envolver el pipeline completo *)
  | "jobs" :: _ ->
      reap_jobs ();
      List.iter (fun j ->
        Printf.printf "[%d] %d %s  %s\n" j.id j.pid (state_label j.state) j.cmdline
      ) !jobs;
      purge_done_jobs ();
      Lwt.return 0
  | ("fg" | "bg") as op :: rest ->
      reap_jobs ();
      let parse_id s =
        let s = if String.length s > 0 && s.[0] = '%'
                then String.sub s 1 (String.length s - 1) else s in
        int_of_string_opt s
      in
      let target =
        match rest with
        | [] ->
            (* default: el job más reciente que no esté Done *)
            (match List.rev (List.filter (fun j -> j.state <> Done) !jobs) with
             | j :: _ -> Some j | [] -> None)
        | id_s :: _ ->
            (match parse_id id_s with
             | Some id -> find_job id
             | None    -> None)
      in
      (match target with
       | None ->
           Printf.eprintf "ocash: %s: no such job\n%!" op;
           Lwt.return 1
       | Some j ->
           (try Unix.kill j.pid Sys.sigcont with Unix.Unix_error _ -> ());
           j.state <- Running;
           if op = "bg" then begin
             Printf.printf "[%d] %d %s &\n" j.id j.pid j.cmdline;
             Lwt.return 0
           end else begin
             (* fg: esperar a que termine o se pare *)
             Printf.printf "%s\n%!" j.cmdline;
             current_fg_pid := j.pid;
             let code =
               try
                 let (_, status) = Unix.waitpid [Unix.WUNTRACED] j.pid in
                 current_fg_pid := 0;
                 match status with
                 | Unix.WEXITED n -> j.state <- Done; n
                 | Unix.WSIGNALED _ -> j.state <- Done; 130
                 | Unix.WSTOPPED _ -> j.state <- Stopped; 128
               with Unix.Unix_error _ ->
                 current_fg_pid := 0; j.state <- Done; 1
             in
             if j.state = Done then remove_job j.id;
             last_exit_code := code;
             Lwt.return code
           end)
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
        let argv = expand_alias argv in
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
             (fun () -> run_builtin env (expand_alias argv))
             (fun () -> restore_redirects saved; Lwt.return ())
       | _ ->
           aux pipeline Unix.stdin Unix.stdout [])
  | Ast.Pipe _ -> aux pipeline Unix.stdin Unix.stdout []

let rec eval_statement (env : env) (stmt : Ast.statement) : int Lwt.t =
  eval_statement_ref := (fun s -> eval_statement env s);
  eval_statement_internal env stmt
and eval_statement_internal env stmt =
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
      let* _ = eval_statement_internal env a in
      eval_statement_internal env b
  | Ast.Background stmt ->
      let cmdline = render_statement stmt in
      (* Intento de fast-path: Exec (Single cmd) con programa externo →
         create_process sin esperar. Para los demás casos forkeamos un
         proceso que evalúa el statement de forma síncrona y exit. *)
      let pid_opt =
        match stmt with
        | Ast.Exec (Ast.Single cmd) ->
            let argv = List.map (expand_vars env) cmd.Ast.argv in
            let argv = expand_alias argv in
            (match argv with
             | [] -> None
             | prog :: _ when List.mem prog builtins -> None
             | prog :: _ ->
                 (match find_in_path prog with
                  | None ->
                      Printf.eprintf "ocash: %s: comando no encontrado\n%!" prog;
                      None
                  | Some full_path ->
                      let (i, o, e, opened) =
                        resolve_redirects cmd.Ast.redirects
                          (Unix.stdin, Unix.stdout, Unix.stderr)
                      in
                      let pid = Unix.create_process full_path
                        (Array.of_list argv) i o e in
                      List.iter (fun fd -> try Unix.close fd with _ -> ()) opened;
                      Some pid))
        | _ -> None
      in
      (match pid_opt with
       | Some pid ->
           let id = add_job ~pid ~cmdline ~state:Running in
           Printf.printf "[%d] %d\n%!" id pid;
           Lwt.return 0
       | None ->
           (* Fork genérico: el child ejecuta el statement y exit *)
           (match Unix.fork () with
            | 0 ->
                let promise = eval_statement_internal env stmt in
                let code = match Lwt.state promise with
                  | Lwt.Return n -> n
                  | _ -> 0
                in
                exit code
            | pid ->
                let id = add_job ~pid ~cmdline ~state:Running in
                Printf.printf "[%d] %d\n%!" id pid;
                Lwt.return 0))
