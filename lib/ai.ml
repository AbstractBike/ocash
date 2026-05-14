open Lwt.Syntax

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

  User: buscar TODO en el código
  Reply: grep -rn "TODO" --include="*.ml" .

  User: ejecutar playbook ansible site.yml en todos los hosts
  Reply: ansible playbook site.yml

  User: ping a todos los hosts ansible
  Reply: ansible ping all
|}

type ai_result =
  | Command  of string
  | AiError  of string
  | Disabled

let query ~user_input =
  if not !ai_enabled then Lwt.return Disabled
  else begin
    let body = Yojson.Basic.to_string (`Assoc [
      ("stream",      `Bool false);
      ("max_tokens",  `Int 300);
      ("temperature", `Float 0.05);
      ("messages", `List [
        `Assoc [("role", `String "system"); ("content", `String system_prompt)];
        `Assoc [("role", `String "user");   ("content", `String user_input)];
      ])
    ]) in
    let uri     = Uri.of_string (!server_url ^ "/v1/chat/completions") in
    let headers = Cohttp.Header.of_list [("Content-Type", "application/json")] in
    Lwt.catch
      (fun () ->
        let* (_, body_resp) = Cohttp_lwt_unix.Client.post
          ~headers
          ~body:(Cohttp_lwt.Body.of_string body)
          uri
        in
        let* body_str = Cohttp_lwt.Body.to_string body_resp in
        let json    = Yojson.Basic.from_string body_str in
        let open Yojson.Basic.Util in
        let content = json
          |> member "choices" |> index 0
          |> member "message" |> member "content"
          |> to_string
          |> String.trim
        in
        if String.starts_with ~prefix:"ERROR:" content
        then Lwt.return (AiError content)
        else Lwt.return (Command content))
      (fun exn ->
        Lwt.return (AiError ("conexión fallida: " ^ Printexc.to_string exn)))
  end

let check_server () =
  Lwt.catch
    (fun () ->
      let uri = Uri.of_string (!server_url ^ "/health") in
      let* (resp, _) = Cohttp_lwt_unix.Client.get uri in
      if Cohttp.Response.status resp = `OK then begin
        ai_enabled := true;
        Lwt.return true
      end else
        Lwt.return false)
    (fun _ -> Lwt.return false)

let init () =
  let url = Option.value ~default:"http://localhost:8080"
    (Sys.getenv_opt "OCASH_AI_URL") in
  server_url := url;
  let* ok = check_server () in
  if ok then
    Printf.printf "\027[32m\xe2\x9c\x93 AI activa\027[0m (Qwen2.5-OCamler @ %s)\n%!" url
  else
    Printf.printf "\027[33m\xe2\x9a\xa0 AI no disponible\027[0m (inicia llama-server para activarla)\n%!";
  Lwt.return ()
