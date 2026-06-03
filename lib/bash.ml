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
  (* Primer token del input (para casos especiales como `cd`). *)
  let first_word =
    let t = String.trim s in
    match String.index_opt t ' ' with
    | Some i -> String.sub t 0 i
    | None   -> t
  in
  (* `cd` debe ejecutarse siempre nativo para que el cambio de directorio
     persista en ocash. La expansión de `~`/`~/` la hace el builtin cd,
     así que un tilde en un `cd` no debe forzar el fallback a bash. *)
  let is_cd = first_word = "cd" in
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
  (* Glob characters. Un `?` que forma parte de `$?` (exit code) no es
     glob y lo expande ocash nativamente. *)
  contains_substr "*" ||
  (let rec has_glob_q i =
     match String.index_from_opt s i '?' with
     | None -> false
     | Some k -> if k > 0 && s.[k-1] = '$' then has_glob_q (k+1) else true
   in has_glob_q 0) ||
  (* Character classes en path *)
  (let re = Str.regexp "\\[[^]]*\\]" in
   try ignore (Str.search_forward re s 0); true with Not_found -> false) ||
  (* Tilde expansion (salvo en `cd`, que lo maneja nativo para persistir) *)
  ((not is_cd) &&
   (let re = Str.regexp "\\(^\\|[ =:]\\)~" in
    try ignore (Str.search_forward re s 0); true with Not_found -> false)) ||
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

(* Ejecuta el input vía `bash -c`. Hereda env del padre (incluido lo
   que se haya exportado con `export`). *)
let run input =
  let cmd = ("bash", [| "bash"; "-c"; input |]) in
  let* status = Lwt_process.exec cmd in
  match status with
  | Unix.WEXITED n   -> Lwt.return n
  | Unix.WSIGNALED _ -> Lwt.return 130
  | Unix.WSTOPPED _  -> Lwt.return 128

(* Sincroniza las variables locales (no exportadas) al environment
   antes del fallback, para que `bash -c` las vea. Útil cuando el
   usuario tiene MY_VAR=hello (no export) y luego ejecuta algo que
   necesita la variable. *)
let sync_env env =
  Hashtbl.iter (fun k v ->
    try Unix.putenv k v with _ -> ()
  ) env
