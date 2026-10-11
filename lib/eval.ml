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

let builtins = ["cd"; "exit"; "export"; "echo"; "pwd"; "history"; "set"; "ansible"; "ocaml"; "hsearch"; "alias"; "unalias"; "unset"; "source"; "."; "jobs"; "fg"; "bg"]

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

(* Avisa de los jobs en background que terminaron, como bash antes del
   prompt: `[1]+  Done  sleep 5`. *)
let notify_done_jobs () =
  if !jobs <> [] then begin
    reap_jobs ();
    List.iter (fun j ->
      if j.state = Done then
        Printf.printf "[%d]+  Done\t\t%s\n%!" j.id j.cmdline
    ) !jobs;
    purge_done_jobs ()
  end

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

let last_exit_code = ref 0

(* Tabla de aliases mutables. expand_alias se aplica al primer token. *)
let aliases : (string, string) Hashtbl.t = Hashtbl.create 32

(* argv está en forma escapada (ver Parser): `\ls` no coincide con el
   alias `ls`, igual que en bash. *)
let expand_alias argv =
  match argv with
  | [] -> argv
  | head :: rest ->
      (match Hashtbl.find_opt aliases head with
       | Some expanded ->
           let parts = match Parser.split_words expanded with
             | Some ws -> ws
             | None ->
                 String.split_on_char ' ' expanded
                 |> List.filter (fun s -> s <> "")
                 |> List.map Parser.escape_all
           in
           parts @ rest
       | None -> argv)

(* Expansión textual del alias de la primera palabra de una línea.
   Necesaria cuando la línea va a `bash -c` (bash no conoce nuestros
   aliases) o cuando el alias contiene pipes/operadores que no caben en
   un argv. Con ~force:false solo expande este segundo caso. *)
let expand_alias_text ~force line =
  let trimmed = String.trim line in
  let len = String.length trimmed in
  let i = try String.index trimmed ' ' with Not_found -> len in
  let head = String.sub trimmed 0 i in
  match Hashtbl.find_opt aliases head with
  | Some v when force || Parser.split_words v = None ->
      Some (v ^ String.sub trimmed i (len - i))
  | _ -> None

let is_var_char c =
  c = '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')

(* Resuelve una palabra en forma escapada: `\c` → c literal, `$VAR`,
   `${VAR}`, `$?` y `$$` se expanden; un `$` que no va seguido de un
   nombre se queda literal (como en bash: `sed 's/$/x/'`). *)
let expand_word env s =
  let buf = Buffer.create (String.length s) in
  let len = String.length s in
  let i   = ref 0 in
  while !i < len do
    let c = s.[!i] in
    if c = '\\' && !i + 1 < len then begin
      Buffer.add_char buf s.[!i + 1];
      i := !i + 2
    end else if c = '$' && !i + 1 < len && s.[!i + 1] = '?' then begin
      Buffer.add_string buf (string_of_int !last_exit_code);
      i := !i + 2
    end else if c = '$' && !i + 1 < len && s.[!i + 1] = '$' then begin
      Buffer.add_string buf (string_of_int (Unix.getpid ()));
      i := !i + 2
    end else if c = '$' && !i + 1 < len
                && (is_var_char s.[!i + 1] || s.[!i + 1] = '{') then begin
      let braced = s.[!i + 1] = '{' in
      let start = !i + (if braced then 2 else 1) in
      let j = ref start in
      while !j < len && is_var_char s.[!j] do incr j done;
      if braced && not (!j < len && s.[!j] = '}') then begin
        (* `${` sin cerrar: literal *)
        Buffer.add_char buf '$';
        incr i
      end else begin
        let var = String.sub s start (!j - start) in
        Buffer.add_string buf
          (Option.value ~default:"" (Hashtbl.find_opt env var));
        i := if braced then !j + 1 else !j
      end
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

(* Compatibilidad: nombre histórico. *)
let expand_vars = expand_word

let expand_redirect env = function
  | Ast.Stdout_to f  -> Ast.Stdout_to (expand_word env f)
  | Ast.Stderr_to f  -> Ast.Stderr_to (expand_word env f)
  | Ast.Append_to f  -> Ast.Append_to (expand_word env f)
  | Ast.Stdin_from f -> Ast.Stdin_from (expand_word env f)

let set_var env k v =
  Hashtbl.replace env k v;
  Unix.putenv k v


(* Forward-reference para que `source` pueda re-entrar al eval. *)
let eval_statement_ref : (Ast.statement -> int Lwt.t) ref =
  ref (fun _ -> Lwt.return 0)

(* Evaluador de líneas completas para `source`. main.ml lo sustituye por
   su eval_line (fallback a bash, aliases); por defecto solo el parser
   nativo, descartando lo que no parsea. *)
let source_line_ref : (string -> int Lwt.t) option ref = ref None

let run_builtin env argv =
  match argv with
  | "cd" :: rest ->
      let home = Option.value ~default:"/" (Hashtbl.find_opt env "HOME") in
      let target, print_it = match rest with
        | [] -> Some home, false
        | "-" :: _ -> Hashtbl.find_opt env "OLDPWD", true
        | dir :: _ -> Some dir, false
      in
      (match target with
       | None ->
           Printf.eprintf "ocash: cd: OLDPWD no definido\n%!";
           Lwt.return 1
       | Some dir ->
           let old = try Sys.getcwd () with Sys_error _ -> "" in
           (try
              Unix.chdir dir;
              let cwd = try Sys.getcwd () with Sys_error _ -> dir in
              if old <> "" then set_var env "OLDPWD" old;
              set_var env "PWD" cwd;
              if print_it then print_endline cwd;
              Lwt.return 0
            with Unix.Unix_error (e, _, _) ->
              Printf.eprintf "ocash: cd: %s: %s\n%!" dir (Unix.error_message e);
              Lwt.return 1))
  | ["pwd"] ->
      print_endline (Unix.getcwd ()); Lwt.return 0
  | "echo" :: "-n" :: args ->
      print_string (String.concat " " args); flush stdout; Lwt.return 0
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
  | "unset" :: names ->
      (* OCaml 4.14 no expone unsetenv: la variable queda vacía en el
         entorno de los hijos, pero desaparece de la tabla de ocash. *)
      List.iter (fun k ->
        if Hashtbl.mem env k then begin
          Hashtbl.remove env k;
          (try Unix.putenv k "" with _ -> ())
        end) names;
      Lwt.return 0
  | "unalias" :: names ->
      List.iter (Hashtbl.remove aliases) names;
      Lwt.return 0
  | ("source" | ".") :: file :: _ ->
      (* argv ya llega expandido; solo resolvemos `~/` *)
      let path =
        if String.length file > 1 && String.sub file 0 2 = "~/" then
          let home = try Sys.getenv "HOME" with Not_found -> "" in
          home ^ String.sub file 1 (String.length file - 1)
        else file
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
                match !source_line_ref, Parser.parse line with
                | Some eval_line, _ ->
                    let* _ = eval_line line in
                    loop_lines ()
                | None, Ok stmt ->
                    let* _ = !eval_statement_ref stmt in
                    loop_lines ()
                | None, Error _ -> loop_lines ()
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
                 | Unix.WEXITED _ | Unix.WSIGNALED _ ->
                     j.state <- Done; Exit_status.of_status status
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
let restore_redirects saved =
  List.iter (fun (orig, saved_fd) ->
    Unix.dup2 saved_fd orig;
    Unix.close saved_fd
  ) saved

let open_redirect = function
  | Ast.Stdout_to f ->
      Unix.stdout, Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644
  | Ast.Append_to f ->
      Unix.stdout, Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o644
  | Ast.Stdin_from f ->
      Unix.stdin, Unix.openfile f [Unix.O_RDONLY] 0
  | Ast.Stderr_to f ->
      Unix.stderr, Unix.openfile f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644

(* Si un open falla, deshace los redirects ya aplicados y relanza. *)
let apply_redirects redirects =
  List.fold_left (fun saved r ->
    match open_redirect r with
    | exception exn -> restore_redirects saved; raise exn
    | (target, fd) ->
        let backup = Unix.dup target in
        Unix.dup2 fd target;
        Unix.close fd;
        (target, backup) :: saved
  ) [] redirects
  |> List.rev

let redirect_error = function
  | Unix.Unix_error (e, _, file) ->
      Printf.eprintf "ocash: %s: %s\n%!" file (Unix.error_message e)
  | exn ->
      Printf.eprintf "ocash: %s\n%!" (Printexc.to_string exn)

(* Resuelve redirects a (stdin_fd, stdout_fd, stderr_fd, fds_to_close_in_parent).
   No muta stdout global: solo abre archivos para los fds de un subproceso. *)
let resolve_redirects redirects (in0, out0, err0) =
  let i = ref in0 in
  let o = ref out0 in
  let e = ref err0 in
  let opened = ref [] in
  (try
     List.iter (fun r ->
       let (target, fd) = open_redirect r in
       opened := fd :: !opened;
       if target = Unix.stdin then i := fd
       else if target = Unix.stdout then o := fd
       else e := fd
     ) redirects
   with exn ->
     List.iter (fun fd -> try Unix.close fd with _ -> ()) !opened;
     raise exn);
  (!i, !o, !e, !opened)

(* Lanza un comando como subproceso con los fds dados.
   close_in_child son fds extras (típicamente otros extremos de pipes)
   que el child debe cerrar tras dup2. *)
let spawn_command env argv redirects stdin_fd stdout_fd close_in_child =
  match argv with
  | [] -> Lwt.return 0
  | prog :: _ ->
      match resolve_redirects redirects (stdin_fd, stdout_fd, Unix.stderr) with
      | exception exn -> redirect_error exn; Lwt.return 1
      | (i, o, e, opened) ->
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
            let code = Exit_status.of_status status in
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
            let code = Exit_status.of_status status in
            last_exit_code := code;
            Lwt.return code
      end

(* Recorre el pipeline y devuelve un promise por cada etapa,
   garantizando que cada child cierra los pipe fds que no necesita. *)
let run_pipeline env pipeline =
  let rec aux p stdin_fd stdout_fd close_in_child =
    match p with
    | Ast.Single cmd ->
        let argv = List.map (expand_word env) (expand_alias cmd.Ast.argv) in
        let redirects = List.map (expand_redirect env) cmd.Ast.redirects in
        spawn_command env argv redirects
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
      (* El alias se expande antes de mirar si es builtin: así
         `alias ..='cd ..'` cambia el cwd del propio ocash. *)
      let argv = List.map (expand_word env) (expand_alias cmd.Ast.argv) in
      (match argv with
       | [] -> Lwt.return 0
       | prog :: _ when List.mem prog builtins ->
           let redirects = List.map (expand_redirect env) cmd.Ast.redirects in
           (match apply_redirects redirects with
            | exception exn -> redirect_error exn; Lwt.return 1
            | saved ->
                Lwt.finalize
                  (fun () -> run_builtin env argv)
                  (fun () -> restore_redirects saved; Lwt.return ()))
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
      let v' = expand_word env v in
      Hashtbl.replace env k v';
      Lwt.return 0
  | Ast.Exec p ->
      let* code = run_pipeline env p in
      last_exit_code := code;
      Lwt.return code
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
      let launch =
        match stmt with
        | Ast.Exec (Ast.Single cmd) ->
            let argv = List.map (expand_word env) (expand_alias cmd.Ast.argv) in
            let redirects = List.map (expand_redirect env) cmd.Ast.redirects in
            (match argv with
             | [] -> `Failed 0
             | prog :: _ when List.mem prog builtins -> `Fork
             | prog :: _ ->
                 (match find_in_path prog with
                  | None ->
                      Printf.eprintf "ocash: %s: comando no encontrado\n%!" prog;
                      `Failed 127
                  | Some full_path ->
                      (match resolve_redirects redirects
                               (Unix.stdin, Unix.stdout, Unix.stderr) with
                       | exception exn -> redirect_error exn; `Failed 1
                       | (i, o, e, opened) ->
                           let pid = Unix.create_process full_path
                             (Array.of_list argv) i o e in
                           List.iter (fun fd -> try Unix.close fd with _ -> ()) opened;
                           `Spawned pid)))
        | _ -> `Fork
      in
      (match launch with
       | `Failed code -> Lwt.return code
       | `Spawned pid ->
           let id = add_job ~pid ~cmdline ~state:Running in
           Printf.printf "[%d] %d\n%!" id pid;
           Lwt.return 0
       | `Fork ->
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
