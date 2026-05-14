open Lwt.Syntax

(* ============================================================ *)
(* Backends                                                       *)
(* ============================================================ *)

type backend =
  | Local       (* HTTP a llama-server (default, OpenAI-compatible) *)
  | Claude_cli  (* subprocess `claude --print` *)
  | Codex_cli   (* subprocess `codex exec` *)
  | Anthropic   (* HTTP a api.anthropic.com *)
  | Openai      (* HTTP a api.openai.com *)

let backend_of_string = function
  | "local" | "llama" | ""    -> Local
  | "claude" | "claude-cli"   -> Claude_cli
  | "codex"  | "codex-cli"    -> Codex_cli
  | "anthropic" | "api"       -> Anthropic
  | "openai"                  -> Openai
  | s -> Printf.eprintf "ocash: backend AI desconocido '%s', usando local\n%!" s;
         Local

let backend_to_string = function
  | Local      -> "local (llama-server)"
  | Claude_cli -> "claude CLI"
  | Codex_cli  -> "codex CLI"
  | Anthropic  -> "Anthropic API"
  | Openai     -> "OpenAI API"

let current_backend = ref Local
let server_url = ref "http://localhost:8080"
let ai_enabled = ref false

let system_prompt = {|You are ocash's AI assistant. The user speaks Spanish (or any language).
Your ONLY job: translate natural language intent into valid shell commands.

STRICT RULES:
- Reply with ONLY the shell command, no explanation, no markdown, no code blocks
- Use pipes, redirects, and shell features as needed
- For multiple commands use ; or &&
- Prefer safe options (avoid rm -rf, etc. unless explicitly requested)
- If impossible to express as shell command reply: ERROR: <reason in Spanish>

Examples:
  User: listar archivos OCaml del proyecto
  Reply: find . -name "*.ml" -not -path "./_build/*"

  User: cuántas líneas de código OCaml tengo
  Reply: find . -name "*.ml" | xargs wc -l | tail -1

  User: compilar el proyecto con dune
  Reply: dune build 2>&1

  User: ver procesos que usan más memoria
  Reply: ps aux --sort=-%mem | head -20

  User: ejecutar playbook ansible site.yml en todos los hosts
  Reply: ansible playbook site.yml

  User: ping a todos los hosts ansible
  Reply: ansible ping all
|}

type ai_result =
  | Command  of string
  | AiError  of string
  | Disabled

(* ============================================================ *)
(* Helpers                                                        *)
(* ============================================================ *)

let strip_markdown content =
  let s = String.trim content in
  let s = if String.starts_with ~prefix:"```bash" s
          then String.sub s 7 (String.length s - 7) |> String.trim
          else if String.starts_with ~prefix:"```sh" s
          then String.sub s 5 (String.length s - 5) |> String.trim
          else if String.starts_with ~prefix:"```" s
          then String.sub s 3 (String.length s - 3) |> String.trim
          else s in
  let s = if String.length s >= 3 && String.sub s (String.length s - 3) 3 = "```"
          then String.sub s 0 (String.length s - 3) |> String.trim
          else s in
  (* Si el modelo devuelve varias líneas, toma la primera no vacía *)
  let lines = String.split_on_char '\n' s |> List.filter (fun l -> String.trim l <> "") in
  let s = match lines with
    | [] -> s
    | hd :: _ -> String.trim hd
  in
  (* Strip leading "$ " o "# " que el LLM a veces pone para señalar shell prompt *)
  let s = if String.starts_with ~prefix:"$ " s then String.sub s 2 (String.length s - 2)
          else if String.starts_with ~prefix:"# " s then String.sub s 2 (String.length s - 2)
          else if s = "$" || s = "#" then ""
          else s in
  String.trim s

let cli_available bin =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  String.split_on_char ':' path
  |> List.exists (fun dir -> Sys.file_exists (Filename.concat dir bin))

let read_all ic =
  let buf = Buffer.create 1024 in
  try
    while true do Buffer.add_channel buf ic 1024 done;
    assert false
  with End_of_file -> Buffer.contents buf

(* ============================================================ *)
(* Backend: Local llama-server (OpenAI-compatible)               *)
(* ============================================================ *)

(* Streaming SSE: lee "data: {...}" líneas, extrae delta.content, imprime
   en stdout token a token. Devuelve la concatenación final. *)
let stream_enabled () =
  match Sys.getenv_opt "OCASH_AI_STREAM" with
  | Some ("0" | "false" | "no" | "off") -> false
  | _ -> true  (* default: streaming on para mejor UX *)

(* Parser SSE smart: detecta formato OpenAI (choices[0].delta.content) o
   Anthropic (type=content_block_delta, delta.text). Ignora líneas event:/
   pings/[DONE]/JSON sin texto útil. *)
let parse_sse_line line =
  let line = String.trim line in
  if String.length line < 6 || String.sub line 0 6 <> "data: " then None
  else
    let payload = String.sub line 6 (String.length line - 6) in
    if payload = "[DONE]" then None
    else
      try
        let json = Yojson.Basic.from_string payload in
        let open Yojson.Basic.Util in
        (* Anthropic: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}} *)
        let typ = json |> member "type" |> to_string_option in
        (match typ with
         | Some "content_block_delta" ->
             let txt = json |> member "delta" |> member "text" |> to_string_option in
             (match txt with Some s -> Some s | None -> None)
         | Some _ -> None  (* message_start, content_block_start, ping, etc. *)
         | None ->
             (* OpenAI: choices[0].delta.content *)
             let delta = json |> member "choices" |> index 0 |> member "delta" in
             (match delta |> member "content" |> to_string_option with
              | Some s -> Some s
              | None -> None))
      with _ -> None

let query_openai_compat ~url ~headers ~user_input =
  let stream = stream_enabled () in
  let body = Yojson.Basic.to_string (`Assoc [
    ("stream",      `Bool stream);
    ("max_tokens",  `Int 300);
    ("temperature", `Float 0.05);
    ("messages", `List [
      `Assoc [("role", `String "system"); ("content", `String system_prompt)];
      `Assoc [("role", `String "user");   ("content", `String user_input)];
    ])
  ]) in
  let uri = Uri.of_string (url ^ "/v1/chat/completions") in
  let headers = Cohttp.Header.add_list (Cohttp.Header.init ())
    (("Content-Type", "application/json") :: headers) in
  Lwt.catch (fun () ->
    let* (_, body_resp) = Cohttp_lwt_unix.Client.post
      ~headers ~body:(Cohttp_lwt.Body.of_string body) uri in
    if stream then begin
      (* Streaming: leemos chunks, parseamos SSE, imprimimos cada delta *)
      let buf = Buffer.create 256 in
      let* stream_body = Cohttp_lwt.Body.to_stream body_resp |> Lwt.return in
      let* () = Lwt_stream.iter_s (fun chunk ->
        let lines = String.split_on_char '\n' chunk in
        List.iter (fun line ->
          match parse_sse_line line with
          | Some delta when delta <> "" ->
              Buffer.add_string buf delta;
              print_string delta; flush stdout
          | _ -> ()
        ) lines;
        Lwt.return ()
      ) stream_body in
      print_newline ();
      let content = strip_markdown (Buffer.contents buf) in
      if String.starts_with ~prefix:"ERROR:" content
      then Lwt.return (AiError content)
      else Lwt.return (Command content)
    end else begin
      let* body_str = Cohttp_lwt.Body.to_string body_resp in
      let json = Yojson.Basic.from_string body_str in
      let open Yojson.Basic.Util in
      let content = json |> member "choices" |> index 0
        |> member "message" |> member "content" |> to_string in
      let content = strip_markdown content in
      if String.starts_with ~prefix:"ERROR:" content
      then Lwt.return (AiError content)
      else Lwt.return (Command content)
    end)
   (fun exn -> Lwt.return (AiError ("conexión fallida: " ^ Printexc.to_string exn)))

(* ============================================================ *)
(* Backend: Anthropic API                                         *)
(* ============================================================ *)

let query_anthropic ~user_input =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None -> Lwt.return (AiError "ANTHROPIC_API_KEY no está definido")
  | Some key ->
      let model = Option.value ~default:"claude-haiku-4-5-20251001"
        (Sys.getenv_opt "OCASH_AI_MODEL") in
      let stream = stream_enabled () in
      let body = Yojson.Basic.to_string (`Assoc [
        ("model", `String model);
        ("max_tokens", `Int 300);
        ("stream", `Bool stream);
        ("system", `String system_prompt);
        ("messages", `List [
          `Assoc [("role", `String "user"); ("content", `String user_input)]
        ])
      ]) in
      let uri = Uri.of_string "https://api.anthropic.com/v1/messages" in
      let headers = Cohttp.Header.of_list [
        ("Content-Type", "application/json");
        ("x-api-key", key);
        ("anthropic-version", "2023-06-01");
      ] in
      Lwt.catch (fun () ->
        let* (_, body_resp) = Cohttp_lwt_unix.Client.post
          ~headers ~body:(Cohttp_lwt.Body.of_string body) uri in
        if stream then begin
          let buf = Buffer.create 256 in
          let* stream_body = Cohttp_lwt.Body.to_stream body_resp |> Lwt.return in
          let* () = Lwt_stream.iter_s (fun chunk ->
            let lines = String.split_on_char '\n' chunk in
            List.iter (fun line ->
              match parse_sse_line line with
              | Some delta when delta <> "" ->
                  Buffer.add_string buf delta;
                  print_string delta; flush stdout
              | _ -> ()
            ) lines;
            Lwt.return ()
          ) stream_body in
          print_newline ();
          let content = strip_markdown (Buffer.contents buf) in
          if String.starts_with ~prefix:"ERROR:" content
          then Lwt.return (AiError content)
          else Lwt.return (Command content)
        end else begin
          let* body_str = Cohttp_lwt.Body.to_string body_resp in
          let json = Yojson.Basic.from_string body_str in
          let open Yojson.Basic.Util in
          let content = json |> member "content" |> index 0
            |> member "text" |> to_string in
          let content = strip_markdown content in
          if String.starts_with ~prefix:"ERROR:" content
          then Lwt.return (AiError content)
          else Lwt.return (Command content)
        end)
       (fun exn -> Lwt.return (AiError ("Anthropic API: " ^ Printexc.to_string exn)))

(* ============================================================ *)
(* Backend: subprocess CLI (claude, codex)                       *)
(* ============================================================ *)

let query_cli_subprocess ~bin ~args ~user_input =
  if not (cli_available bin) then
    Lwt.return (AiError (Printf.sprintf "`%s` no está en PATH" bin))
  else begin
    let full_prompt = Printf.sprintf "%s\n\nUser: %s\nReply:" system_prompt user_input in
    Lwt.catch (fun () ->
      let cmd = (bin, Array.of_list (bin :: args)) in
      let* output = Lwt_process.with_process_full cmd (fun proc ->
        let* () = Lwt_io.write proc#stdin full_prompt in
        let* () = Lwt_io.close proc#stdin in
        let* out = Lwt_io.read proc#stdout in
        let* _err = Lwt_io.read proc#stderr in
        let* _ = proc#close in
        Lwt.return out
      ) in
      let content = strip_markdown output in
      if String.starts_with ~prefix:"ERROR:" content
      then Lwt.return (AiError content)
      else if content = ""
      then Lwt.return (AiError (Printf.sprintf "`%s` no devolvió output" bin))
      else Lwt.return (Command content))
     (fun exn -> Lwt.return (AiError (Printexc.to_string exn)))
  end

(* ============================================================ *)
(* Dispatcher                                                     *)
(* ============================================================ *)

(* Construye un prompt con contexto: últimas N entradas del historial
   antes del input del usuario. Usado por el modo `ç`. *)
let build_input_with_context ~history ~user_input =
  if history = [] then user_input
  else
    let ctx = String.concat "\n  " (List.map (fun h -> "$ " ^ h) history) in
    Printf.sprintf
      "Contexto: el usuario acaba de ejecutar estos comandos:\n  %s\n\n\
       Petición actual: %s"
      ctx user_input

(* ============================================================ *)
(* Multi-turn: conversación AI persistente durante la sesión    *)
(* ============================================================ *)

let conversation : (string * string) list ref = ref []  (* (role, content) *)
let max_turns = 6

let conv_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "." in
  Filename.concat home ".ocash/conv.json"

(* Escritura atómica: write a tmp + rename. Evita corrupción si crashea
   mid-write o si dos procesos escriben a la vez. *)
let write_atomic path content =
  let tmp = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  let oc = open_out tmp in
  (try
     output_string oc content;
     close_out oc
   with e -> (try close_out_noerr oc; Sys.remove tmp with _ -> ()); raise e);
  Sys.rename tmp path

let conv_save () =
  try
    let path = conv_path () in
    let dir = Filename.dirname path in
    (if not (Sys.file_exists dir) then
       try Unix.mkdir dir 0o755 with _ -> ());
    let json = `List (List.map (fun (role, msg) ->
      `Assoc [("role", `String role); ("content", `String msg)]) !conversation) in
    write_atomic path (Yojson.Basic.to_string json)
  with _ -> ()  (* fallo silencioso: no rompemos UX por persistencia *)

let conv_load () =
  let path = conv_path () in
  if not (Sys.file_exists path) then conversation := []
  else
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      let json = Yojson.Basic.from_string s in
      let open Yojson.Basic.Util in
      let items = json |> to_list |> List.map (fun obj ->
        let role = obj |> member "role" |> to_string in
        let content = obj |> member "content" |> to_string in
        (role, content)) in
      conversation := items
    with _ -> conversation := []  (* corrupto: ignora *)

let conv_trim () =
  while List.length !conversation > max_turns * 2 do
    conversation := List.tl !conversation
  done

let conv_add_user msg =
  conversation := !conversation @ [("user", msg)];
  conv_trim ();
  conv_save ()

let conv_add_assistant msg =
  conversation := !conversation @ [("assistant", msg)];
  conv_trim ();
  conv_save ()

let conv_reset () =
  conversation := [];
  conv_save ()

(* ============================================================ *)
(* Self-correction: dado comando fallido + stderr, propone fix   *)
(* ============================================================ *)

let build_correction_prompt ~failed_cmd ~exit_code ~stderr =
  Printf.sprintf
    "El usuario ejecutó este comando que falló:\n  $ %s\n\
     Exit code: %d\nStderr:\n%s\n\n\
     Sugiere UN comando shell corregido. Solo el comando, sin explicación."
    failed_cmd exit_code stderr

let query ?(history=[]) ?(multi_turn=false) ~user_input () =
  if not !ai_enabled then Lwt.return Disabled
  else
    let user_input =
      if multi_turn && !conversation <> [] then
        let convo = String.concat "\n" (List.map (fun (role, msg) ->
          Printf.sprintf "%s: %s" role msg) !conversation) in
        Printf.sprintf "Conversación previa:\n%s\n\nuser: %s" convo user_input
      else
        build_input_with_context ~history ~user_input
    in
    match !current_backend with
    | Local ->
        query_openai_compat ~url:!server_url ~headers:[] ~user_input
    | Anthropic ->
        query_anthropic ~user_input
    | Openai ->
        (match Sys.getenv_opt "OPENAI_API_KEY" with
         | None -> Lwt.return (AiError "OPENAI_API_KEY no está definido")
         | Some key ->
             let url = Option.value ~default:"https://api.openai.com"
               (Sys.getenv_opt "OCASH_AI_URL") in
             query_openai_compat ~url
               ~headers:[("Authorization", "Bearer " ^ key)]
               ~user_input)
    | Claude_cli ->
        query_cli_subprocess ~bin:"claude" ~args:["--print"; "--output-format"; "text"] ~user_input
    | Codex_cli ->
        query_cli_subprocess ~bin:"codex" ~args:["exec"; "-q"] ~user_input

(* ============================================================ *)
(* Init: selecciona backend y comprueba disponibilidad           *)
(* ============================================================ *)

let check_local_server () =
  Lwt.catch
    (fun () ->
      let uri = Uri.of_string (!server_url ^ "/health") in
      let* (resp, _) = Cohttp_lwt_unix.Client.get uri in
      Lwt.return (Cohttp.Response.status resp = `OK))
    (fun _ -> Lwt.return false)

let init () =
  conv_load ();
  let backend_str = try Sys.getenv "OCASH_AI_BACKEND" with Not_found -> "" in
  current_backend := backend_of_string backend_str;
  let url = Option.value ~default:"http://localhost:8080"
    (Sys.getenv_opt "OCASH_AI_URL") in
  server_url := url;
  let* available =
    match !current_backend with
    | Local      -> check_local_server ()
    | Claude_cli -> Lwt.return (cli_available "claude")
    | Codex_cli  -> Lwt.return (cli_available "codex")
    | Anthropic  -> Lwt.return (Sys.getenv_opt "ANTHROPIC_API_KEY" <> None)
    | Openai     -> Lwt.return (Sys.getenv_opt "OPENAI_API_KEY" <> None)
  in
  ai_enabled := available;
  let backend_name = backend_to_string !current_backend in
  let detail = match !current_backend with
    | Local -> Printf.sprintf " @ %s" !server_url
    | Anthropic | Openai -> " (vía API key)"
    | _ -> ""
  in
  if available then
    Printf.printf "\027[32m\xe2\x9c\x93 AI activa\027[0m [%s%s]\n%!" backend_name detail
  else begin
    let hint = match !current_backend with
      | Local      -> "inicia llama-server o cambia OCASH_AI_BACKEND"
      | Claude_cli -> "instala claude CLI: npm install -g @anthropic-ai/claude-code"
      | Codex_cli  -> "instala codex CLI"
      | Anthropic  -> "exporta ANTHROPIC_API_KEY"
      | Openai     -> "exporta OPENAI_API_KEY"
    in
    Printf.printf "\027[33m\xe2\x9a\xa0 AI no disponible\027[0m [%s] (%s)\n%!"
      backend_name hint
  end;
  Lwt.return ()
