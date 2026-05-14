(** REPL OCaml embebido + compilación de archivos .ml.
    Usa compiler-libs.toplevel para evaluar expresiones in-process. *)

open Lwt.Syntax

let initialized = ref false

let init () =
  if not !initialized then begin
    Toploop.set_paths ();
    Compmisc.init_path ();
    Toploop.initialize_toplevel_env ();
    initialized := true
  end

(* Captura stderr durante eval para devolver mensaje de error al AI *)
let last_error_msg = ref ""

let eval_phrase_raw code =
  init ();
  let code = String.trim code in
  let code =
    if String.length code >= 2
       && String.sub code (String.length code - 2) 2 = ";;"
    then code
    else code ^ ";;"
  in
  try
    let lexbuf = Lexing.from_string code in
    Location.init lexbuf "//ocash//";
    let phrase = !Toploop.parse_toplevel_phrase lexbuf in
    let buf = Buffer.create 256 in
    let err_buf_formatter = Format.formatter_of_buffer buf in
    let ok =
      try Toploop.execute_phrase true Format.std_formatter phrase
      with exn ->
        Location.report_exception err_buf_formatter exn;
        Format.pp_print_flush err_buf_formatter ();
        last_error_msg := Buffer.contents buf;
        false
    in
    Format.pp_print_flush Format.std_formatter ();
    Format.pp_print_flush err_buf_formatter ();
    if not ok && !last_error_msg = "" then last_error_msg := Buffer.contents buf;
    if ok then 0 else 1
  with
  | Sys.Break -> 130
  | exn ->
      let buf = Buffer.create 256 in
      let f = Format.formatter_of_buffer buf in
      Location.report_exception f exn;
      Format.pp_print_flush f ();
      last_error_msg := Buffer.contents buf;
      Printf.eprintf "%s%!" !last_error_msg;
      1

(** Evalúa una frase OCaml ("List.map succ [1;2;3]" o "let x = 42").
    Imprime el resultado en stdout. Devuelve 0 si éxito, 1 en error.
    Si falla y el AI está habilitada, intenta self-correct (offering
    al usuario un fix sugerido). *)
let eval_phrase code =
  last_error_msg := "";
  eval_phrase_raw code

(* Self-correct: pide al AI que arregle un fragmento OCaml roto.
   Devuelve Some fixed_code si lo logra, None si no. *)
let self_correct ~code ~error =
  let open Lwt.Syntax in
  if not !Ai.ai_enabled then Lwt.return None
  else begin
    let prompt = Printf.sprintf
      "El siguiente código OCaml falla:\n```ocaml\n%s\n```\n\nError:\n%s\n\n\
       Devuelve SOLO el código OCaml corregido (sin markdown, sin explicación)."
      code error in
    let* result = Ai.query ~user_input:prompt () in
    match result with
    | Ai.Command fixed -> Lwt.return (Some fixed)
    | _ -> Lwt.return None
  end

(** Carga un archivo .ml dentro del toploop (equivalente a #use). *)
let use_file path =
  init ();
  if Toploop.use_input Format.std_formatter (Toploop.File path) then 0 else 1

(** Compila un archivo .ml a bytecode (.cmo) usando compiler-libs.
    Para link a binario nativo, se delega a `ocamlfind` si está en PATH. *)
let compile_bytecode src =
  init ();
  try
    let prefix = Filename.chop_extension src in
    Compile.implementation ~start_from:Clflags.Compiler_pass.Parsing
      ~source_file:src ~output_prefix:prefix;
    Printf.printf "ocash[ocaml]: %s.cmo generado\n%!" prefix;
    0
  with exn ->
    Location.report_exception Format.err_formatter exn;
    1

let cli_available bin =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  String.split_on_char ':' path
  |> List.exists (fun dir -> Sys.file_exists (Filename.concat dir bin))

(** Compila .ml → ejecutable nativo. Si ocamlfind está disponible
    lo usa con los paquetes pedidos; si no, ocamlopt directo. *)
let compile_native ?(packages=[]) ?(output=None) src =
  let out = match output with
    | Some o -> o
    | None   -> Filename.chop_extension src
  in
  let cmd_parts =
    if cli_available "ocamlfind" then
      let pkg_args = match packages with
        | [] -> []
        | ps -> ["-package"; String.concat "," ps; "-linkpkg"]
      in
      ["ocamlfind"; "ocamlopt"] @ pkg_args @ ["-o"; out; src]
    else
      ["ocamlopt"; "-o"; out; src]
  in
  match cmd_parts with
  | [] -> Lwt.return 1
  | prog :: _ ->
      Printf.printf "ocash[ocaml]: %s\n%!" (String.concat " " cmd_parts);
      let cmd = (prog, Array.of_list cmd_parts) in
      let* status = Lwt_process.exec cmd in
      match status with
      | Unix.WEXITED n   -> Lwt.return n
      | Unix.WSIGNALED _ -> Lwt.return 130
      | Unix.WSTOPPED _  -> Lwt.return 128

let print_help () =
  print_endline {|ocaml — compilador OCaml embebido en ocash

Uso:
  ocaml eval <expr>           Evalúa OCaml en el toploop embebido
  ocaml use <file.ml>         Carga un archivo (#use)
  ocaml compile <file.ml>     Compila a bytecode (.cmo) con compiler-libs
  ocaml build <file.ml> [-p pkg1,pkg2] [-o out]
                              Compila a binario nativo (vía ocamlfind)
  ocaml help                  Esta ayuda

Prefijo de shell:
  ml: <expr>                  Atajo para `ocaml eval <expr>`|};
  Lwt.return 0

let rec take_opt key = function
  | [] -> None, []
  | k :: v :: tl when k = key -> Some v, tl
  | x :: tl ->
      let v, rest = take_opt key tl in
      v, x :: rest

let dispatch args =
  match args with
  | [] | ["help"] | ["--help"] | ["-h"] -> print_help ()
  | "eval" :: rest ->
      let code = String.concat " " rest in
      Lwt.return (eval_phrase code)
  | ["use"; f] ->
      Lwt.return (use_file f)
  | ["compile"; f] ->
      Lwt.return (compile_bytecode f)
  | "build" :: file :: rest ->
      let pkgs_opt, rest' = take_opt "-p" rest in
      let pkgs_opt = match pkgs_opt with
        | Some _ -> pkgs_opt
        | None -> fst (take_opt "--packages" rest)
      in
      let out, _ = take_opt "-o" rest' in
      let packages = match pkgs_opt with
        | Some s -> String.split_on_char ',' s
        | None   -> []
      in
      compile_native ~packages ~output:out file
  | other ->
      Printf.eprintf "ocash[ocaml]: subcomando desconocido: %s\n%!"
        (String.concat " " other);
      Lwt.return 2
