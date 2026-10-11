(** Fallback a `bash -c` para inputs que usan construcciones que
    ocash no parsea nativamente (control flow, command substitution,
    heredocs, glob, brace expansion, tests, etc.).

    Estrategia: heurística sobre el string crudo. Si detecta algo
    fuera del subset nativo (pipes + redirects + assigns simples),
    delega todo el input a `bash -c "..."`. *)

open Lwt.Syntax

(* Tokens/patrones que indican que necesitamos bash. *)
let needs_bash input =
  let s = input in
  let len = String.length s in
  (* Detecta substring fuera de strings entrecomilladas. Simplificado:
     no intentamos parsear quoting; aceptamos falsos positivos
     (un comando con literal "&&" entre comillas caerá a bash, no pasa nada). *)
  let contains_substr sub =
    let sl = String.length sub in
    if sl > len then false
    else
      let rec loop i =
        if i + sl > len then false
        else if String.sub s i sl = sub then true
        else loop (i + 1)
      in
      loop 0
  in
  let has_kw kw =
    (* keyword al inicio de la línea o tras ; & | *)
    let pat = Str.regexp ("\\(^\\|[ \t;&|({]\\)" ^ kw ^ "\\([ \t\n;]\\|$\\)") in
    try ignore (Str.search_forward pat s 0); true
    with Not_found -> false
  in
  let starts_with_assign_then_cmd () =
    (* FOO=bar comando ... → bash debe expandir FOO solo para comando.
       Solo matcheamos si el valor NO empieza con quote, para no
       confundir `MSG="hola mundo"` (assignment puro, native lo maneja)
       con `FOO=bar comando` (env temporal). *)
    let re = Str.regexp
      "^[ \t]*[A-Za-z_][A-Za-z0-9_]*=[^\"' \t\n][^ \t\n]*[ \t]+[A-Za-z]" in
    Str.string_match re s 0
  in
  (* Multi-línea: bash *)
  String.contains s '\n' ||
  (* Command substitution *)
  contains_substr "$(" || String.contains s '`' ||
  (* Sequence operators no soportados en parser actual *)
  contains_substr "&&" || contains_substr "||" ||
  contains_substr ";" ||
  (* Background `&` se maneja en el parser nativo, no en bash. *)
  (* Heredoc *)
  contains_substr "<<" ||
  (* Tests *)
  contains_substr "[[" || contains_substr "[ " ||
  (* Brace expansion / blocks *)
  String.contains s '{' ||
  (* Glob characters *)
  contains_substr "*" ||
  (* `?` es glob salvo en `$?`, que ocash expande nativamente *)
  (let re = Str.regexp "\\(^\\|[^$]\\)\\?" in
   try ignore (Str.search_forward re s 0); true with Not_found -> false) ||
  (* Character classes en path *)
  (let re = Str.regexp "\\[[^]]*\\]" in
   try ignore (Str.search_forward re s 0); true with Not_found -> false) ||
  (* Tilde expansion *)
  (let re = Str.regexp "\\(^\\|[ =:]\\)~" in
   try ignore (Str.search_forward re s 0); true with Not_found -> false) ||
  (* Parameter expansion compleja: ${VAR:-...} ${VAR%...} etc. *)
  contains_substr "${" && (
    let re = Str.regexp "\\${[^}]*[:%#/!^,?+=-][^}]*}" in
    try ignore (Str.search_forward re s 0); true with Not_found -> false
  ) ||
  (* Keywords de control flow *)
  has_kw "if" || has_kw "then" || has_kw "else" || has_kw "elif" ||
  has_kw "fi" || has_kw "for" || has_kw "while" || has_kw "until" ||
  has_kw "do" || has_kw "done" || has_kw "case" || has_kw "esac" ||
  has_kw "function" || has_kw "select" || has_kw "in" ||
  (* assign + comando en misma línea (env temporal) *)
  starts_with_assign_then_cmd ()

(* Variables que bash gestiona por su cuenta y no deben volver a ocash. *)
let ignored_vars = ["_"; "SHLVL"; "BASH_EXECUTION_STRING"]

(* Al salir, bash vuelca su cwd y sus variables exportadas (separadas
   por NUL) a un fichero temporal. Usa solo builtins de bash (compgen,
   indirección ${!n}) para no depender de `env -0`, que no existe en macOS. *)
let dump_trap state_file =
  Printf.sprintf
    "trap '__ocash_rc=$?; { printf \"%%s\\0\" \"$PWD\"; \
     for __ocash_n in $(compgen -e); do \
     printf \"%%s=%%s\\0\" \"$__ocash_n\" \"${!__ocash_n}\"; done; } \
     > %s 2>/dev/null; exit $__ocash_rc' EXIT"
    (Filename.quote state_file)

let read_file path =
  try
    let ic = open_in_bin path in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Some s
  with _ -> None

(* compgen -e solo lista nombres válidos; variables como
   `BASH_FUNC_f%%` nunca vuelven y no deben tomarse por borradas. *)
let is_identifier k =
  k <> "" && not ('0' <= k.[0] && k.[0] <= '9')
  && String.for_all (fun c ->
       c = '_' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
       || ('0' <= c && c <= '9')) k

(* Aplica al proceso ocash el cwd y las variables que dejó bash. Las
   variables exportadas antes de la llamada que ya no aparecen se
   consideran `unset`. OCaml no expone unsetenv: se dejan vacías. *)
let apply_state env ~before dump =
  match String.split_on_char '\000' dump with
  | [] | [_] -> ()
  | pwd :: entries ->
      (if pwd <> "" && pwd <> (try Sys.getcwd () with Sys_error _ -> "") then
         try Unix.chdir pwd with Unix.Unix_error _ -> ());
      let after = Hashtbl.create 64 in
      List.iter (fun kv ->
        match String.index_opt kv '=' with
        | None -> ()
        | Some i ->
            let k = String.sub kv 0 i in
            let v = String.sub kv (i + 1) (String.length kv - i - 1) in
            if not (List.mem k ignored_vars) then begin
              Hashtbl.replace after k ();
              if Hashtbl.find_opt env k <> Some v then begin
                Hashtbl.replace env k v;
                (try Unix.putenv k v with _ -> ())
              end
            end
      ) entries;
      List.iter (fun k ->
        if not (Hashtbl.mem after k) && not (List.mem k ignored_vars)
           && is_identifier k && Hashtbl.mem env k then begin
          Hashtbl.remove env k;
          (try Unix.putenv k "" with _ -> ())
        end
      ) before

let env_keys () =
  Array.to_list (Unix.environment ())
  |> List.filter_map (fun kv ->
       match String.index_opt kv '=' with
       | Some i -> Some (String.sub kv 0 i)
       | None -> None)

let contains_dollar_question s =
  let re = Str.regexp_string "$?" in
  try ignore (Str.search_forward re s 0); true with Not_found -> false

(* Ejecuta el input vía `bash -c`. Hereda env del padre (incluido lo
   que se haya exportado con `export`). Con ~env, además sincroniza de
   vuelta el cwd y las variables exportadas, para que `cd ~/x`,
   `export P=$(...)` o `source venv/bin/activate` tengan efecto en ocash.
   ~last_status permite que `$?` en bash vea el exit del comando previo. *)
let run ?env ?(last_status = 0) input =
  let input =
    if last_status <> 0 && contains_dollar_question input
    then Printf.sprintf "(exit %d); %s" last_status input
    else input
  in
  match env with
  | None ->
      let* status = Lwt_process.exec ("bash", [| "bash"; "-c"; input |]) in
      Lwt.return (Exit_status.of_status status)
  | Some env ->
      let state_file = Filename.temp_file "ocash" ".state" in
      let before = env_keys () in
      let script = dump_trap state_file ^ "; " ^ input in
      Lwt.finalize
        (fun () ->
          let* status = Lwt_process.exec ("bash", [| "bash"; "-c"; script |]) in
          (match read_file state_file with
           | Some dump -> apply_state env ~before dump
           | None -> ());
          Lwt.return (Exit_status.of_status status))
        (fun () ->
          (try Sys.remove state_file with Sys_error _ -> ());
          Lwt.return ())

(* Sincroniza las variables locales (no exportadas) al environment
   antes del fallback, para que `bash -c` las vea. Útil cuando el
   usuario tiene MY_VAR=hello (no export) y luego ejecuta algo que
   necesita la variable. *)
let sync_env env =
  Hashtbl.iter (fun k v ->
    try Unix.putenv k v with _ -> ()
  ) env
