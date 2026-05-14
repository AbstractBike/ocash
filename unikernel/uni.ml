(** ocash-ai-unikernel (Linux binary, Fase 1).

    Servidor HTTP compatible OpenAI (/v1/chat/completions) que mantiene un
    cache de handlers OCaml (`string -> string option`). En miss, pide al
    LLM upstream que GENERE un handler OCaml, lo compila vía Toploop y lo
    añade al cache. Los handlers se persisten en handlers/h_NNN.ml para
    sobrevivir reinicios. *)

open Lwt.Syntax

(* La cache vive en uni_lib/uni.ml expuesta como módulo Uni (wrapped false).
   El toploop ve `Uni.register` directamente porque la lib se linkea con -linkall. *)
module Handlers = Uni

(* ============================================================ *)
(* Métricas Prometheus                                           *)
(* ============================================================ *)

module Metrics = struct
  let queries_total = ref 0
  let cache_hits    = ref 0
  let cache_misses  = ref 0
  let llm_failures  = ref 0
  let handlers_compiled = ref 0
  let compile_errors    = ref 0
  let started_at        = Unix.gettimeofday ()
  let last_query_ms     = ref 0.0

  let persist_file () =
    let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
    Filename.concat home ".ocash/metrics.txt"

  let save () =
    try
      let path = persist_file () in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
      let oc = open_out path in
      Printf.fprintf oc "queries_total %d\n" !queries_total;
      Printf.fprintf oc "cache_hits %d\n" !cache_hits;
      Printf.fprintf oc "cache_misses %d\n" !cache_misses;
      Printf.fprintf oc "llm_failures %d\n" !llm_failures;
      Printf.fprintf oc "handlers_compiled %d\n" !handlers_compiled;
      Printf.fprintf oc "compile_errors %d\n" !compile_errors;
      close_out oc
    with _ -> ()

  let load () =
    let path = persist_file () in
    if Sys.file_exists path then begin
      try
        let ic = open_in path in
        (try while true do
          let line = input_line ic in
          match String.split_on_char ' ' line with
          | ["queries_total"; n]     -> queries_total := int_of_string n
          | ["cache_hits"; n]        -> cache_hits := int_of_string n
          | ["cache_misses"; n]      -> cache_misses := int_of_string n
          | ["llm_failures"; n]      -> llm_failures := int_of_string n
          | ["handlers_compiled"; n] -> handlers_compiled := int_of_string n
          | ["compile_errors"; n]    -> compile_errors := int_of_string n
          | _ -> ()
        done with End_of_file -> ());
        close_in ic
      with _ -> ()
    end

  (* Formato exposition Prometheus *)
  let render () =
    let uptime = Unix.gettimeofday () -. started_at in
    let cache_size = Uni.count () in
    Printf.sprintf
{|# HELP ocash_uni_queries_total Total queries received
# TYPE ocash_uni_queries_total counter
ocash_uni_queries_total %d
# HELP ocash_uni_cache_hits_total Total cache hits
# TYPE ocash_uni_cache_hits_total counter
ocash_uni_cache_hits_total %d
# HELP ocash_uni_cache_misses_total Total cache misses
# TYPE ocash_uni_cache_misses_total counter
ocash_uni_cache_misses_total %d
# HELP ocash_uni_llm_failures_total Total LLM upstream errors
# TYPE ocash_uni_llm_failures_total counter
ocash_uni_llm_failures_total %d
# HELP ocash_uni_handlers_compiled_total Total handlers compiled OK
# TYPE ocash_uni_handlers_compiled_total counter
ocash_uni_handlers_compiled_total %d
# HELP ocash_uni_compile_errors_total Total handler compilation failures
# TYPE ocash_uni_compile_errors_total counter
ocash_uni_compile_errors_total %d
# HELP ocash_uni_cache_size Current size of handler cache
# TYPE ocash_uni_cache_size gauge
ocash_uni_cache_size %d
# HELP ocash_uni_uptime_seconds Process uptime
# TYPE ocash_uni_uptime_seconds gauge
ocash_uni_uptime_seconds %.0f
# HELP ocash_uni_last_query_ms Latency of last query
# TYPE ocash_uni_last_query_ms gauge
ocash_uni_last_query_ms %.2f
|} !queries_total !cache_hits !cache_misses !llm_failures
   !handlers_compiled !compile_errors cache_size uptime !last_query_ms
end

(* ============================================================ *)
(* Toploop helper                                                *)
(* ============================================================ *)

let toploop_inited = ref false

(* Localiza el .cmi de Uni para que el toploop pueda resolver `Uni.register`.
   Busca primero variables de entorno, luego rutas relativas al binario. *)
let find_uni_cmi_dir () =
  let candidates =
    let cwd = Sys.getcwd () in
    let exe_dir = Filename.dirname Sys.executable_name in
    [
      Sys.getenv_opt "OCASH_UNI_CMI_DIR";
      Some "_build/default/unikernel/uni_lib/.uni_lib.objs/byte/";
      Some (Filename.concat cwd "_build/default/unikernel/uni_lib/.uni_lib.objs/byte/");
      Some (Filename.concat exe_dir "../uni_lib/.uni_lib.objs/byte/");
      Some (Filename.concat exe_dir "uni_lib/.uni_lib.objs/byte/");
    ]
  in
  List.find_map (fun c ->
    match c with
    | Some d when Sys.file_exists (Filename.concat d "uni.cmi") -> Some d
    | _ -> None
  ) candidates

let toploop_init () =
  if not !toploop_inited then begin
    Toploop.set_paths ();
    Compmisc.init_path ();
    Toploop.initialize_toplevel_env ();
    (match find_uni_cmi_dir () with
     | Some d ->
         Printf.printf "[uni] toploop: añadiendo cmi path %s\n%!" d;
         Topdirs.dir_directory d
     | None ->
         Printf.eprintf "[uni] WARN: no encuentro uni.cmi, handlers fallarán\n%!");
    toploop_inited := true
  end

let eval_ocaml code =
  toploop_init ();
  let code =
    if String.length code >= 2
       && String.sub code (String.length code - 2) 2 = ";;"
    then code else code ^ ";;"
  in
  try
    let lexbuf = Lexing.from_string code in
    Location.init lexbuf "//uni//";
    let phrase = !Toploop.parse_toplevel_phrase lexbuf in
    let ok = Toploop.execute_phrase true Format.std_formatter phrase in
    Format.pp_print_flush Format.std_formatter ();
    ok
  with exn ->
    Location.report_exception Format.err_formatter exn;
    false

(* ============================================================ *)
(* Persistencia                                                  *)
(* ============================================================ *)

let handlers_dir =
  let base = match Sys.getenv_opt "OCASH_HANDLERS_DIR" with
    | Some d -> d
    | None ->
        let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
        Filename.concat home ".ocash/handlers"
  in
  base

let ensure_dir d =
  let rec aux p =
    if Sys.file_exists p then ()
    else begin
      aux (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  aux d

let next_handler_id () =
  ensure_dir handlers_dir;
  let n = Array.length (Sys.readdir handlers_dir) in
  Printf.sprintf "h_%03d" n

let save_handler_source name code =
  let path = Filename.concat handlers_dir (name ^ ".ml") in
  let oc = open_out path in
  output_string oc code;
  close_out oc;
  path

let load_persisted_handlers () =
  if not (Sys.file_exists handlers_dir) then ()
  else
    let files = Sys.readdir handlers_dir in
    Array.sort String.compare files;
    Array.iter (fun f ->
      if Filename.check_suffix f ".ml" then begin
        let path = Filename.concat handlers_dir f in
        Printf.printf "[uni] cargando handler persistido %s\n%!" f;
        let ic = open_in path in
        let len = in_channel_length ic in
        let code = really_input_string ic len in
        close_in ic;
        ignore (eval_ocaml code)
      end
    ) files

(* ============================================================ *)
(* Cliente LLM upstream                                          *)
(* ============================================================ *)

let llm_url = ref "http://localhost:8080"

let llm_prompt = {|Eres un compilador de lenguaje natural a comandos shell.

Recibes una intención en español. Devuelves SOLO un bloque de código OCaml
con este formato exacto:

let handler q =
  (* tu lógica aquí *)
  ...
let () = Uni.register "nombre-corto" handler

REGLAS:
- handler tiene tipo (string -> string option)
- Some s si la query encaja en este PATRÓN de intención (no solo esta query
  exacta, sino variaciones razonables); None si no aplica
- Sé generoso con sinónimos: "lista", "muestra", "enumera", "ls"...
- Solo OCaml puro: String, List, Printf, Filename. No abras módulos extras.
- No incluyas explicaciones ni markdown, SOLO el código
- nombre-corto: un identificador kebab-case que describa la intención

Ejemplo de query: "lista los 3 archivos .py en lib"
Tu respuesta:

let handler q =
  let q = String.lowercase_ascii q in
  let words = String.split_on_char ' ' q in
  let starts = List.exists (fun w -> w = "lista" || w = "muestra" || w = "enumera") words in
  if not starts then None
  else
    let n = List.find_map (fun w -> int_of_string_opt w) words in
    let ext = List.find_map (fun w ->
      if String.length w > 1 && w.[0] = '.' then
        Some (String.sub w 1 (String.length w - 1))
      else if String.length w >= 2 && String.sub w 0 2 = "*." then
        Some (String.sub w 2 (String.length w - 2))
      else None) words in
    let dir = List.find_opt (fun w ->
      String.length w > 0 && (w.[0] = '/' || w.[0] = '.' ||
        (String.length w > 1 && w.[1] = '/')))
      words |> Option.value ~default:"." in
    match ext with
    | None -> None
    | Some e ->
        let head = match n with Some k -> Printf.sprintf " | head -%d" k | _ -> "" in
        Some (Printf.sprintf "find %s -name \"*.%s\"%s" dir e head)
let () = Uni.register "lista-archivos-ext" handler
|}

let llm_generate ~user_input =
  let body = Yojson.Basic.to_string (`Assoc [
    ("stream", `Bool false);
    ("max_tokens", `Int 800);
    ("temperature", `Float 0.1);
    ("messages", `List [
      `Assoc [("role", `String "system"); ("content", `String llm_prompt)];
      `Assoc [("role", `String "user"); ("content", `String user_input)];
    ])
  ]) in
  let uri = Uri.of_string (!llm_url ^ "/v1/chat/completions") in
  let headers = Cohttp.Header.of_list [("Content-Type", "application/json")] in
  Lwt.catch (fun () ->
    let* (_, body_resp) = Cohttp_lwt_unix.Client.post
      ~headers ~body:(Cohttp_lwt.Body.of_string body) uri in
    let* body_str = Cohttp_lwt.Body.to_string body_resp in
    let json = Yojson.Basic.from_string body_str in
    let open Yojson.Basic.Util in
    let content = json |> member "choices" |> index 0
      |> member "message" |> member "content" |> to_string |> String.trim in
    (* Strip markdown fences si las hay *)
    let strip_fences s =
      let s = if String.starts_with ~prefix:"```ocaml" s
              then String.sub s 8 (String.length s - 8) |> String.trim
              else s in
      let s = if String.starts_with ~prefix:"```" s
              then String.sub s 3 (String.length s - 3) |> String.trim
              else s in
      let s = if String.length s >= 3 && String.sub s (String.length s - 3) 3 = "```"
              then String.sub s 0 (String.length s - 3) |> String.trim
              else s in
      s
    in
    Lwt.return_ok (strip_fences content))
   (fun exn -> Lwt.return_error (Printexc.to_string exn))

(* ============================================================ *)
(* Lógica principal                                              *)
(* ============================================================ *)

let process_query query =
  let t0 = Unix.gettimeofday () in
  incr Metrics.queries_total;
  let finish result =
    Metrics.last_query_ms := (Unix.gettimeofday () -. t0) *. 1000.0;
    Metrics.save ();
    result
  in
  match Handlers.dispatch query with
  | Some cmd ->
      incr Metrics.cache_hits;
      Printf.printf "[uni] CACHE HIT: %s → %s\n%!" query cmd;
      finish (Lwt.return_ok cmd)
  | None ->
      incr Metrics.cache_misses;
      Printf.printf "[uni] CACHE MISS: %s → pidiendo handler al LLM\n%!" query;
      let* gen = llm_generate ~user_input:query in
      match gen with
      | Error e ->
          incr Metrics.llm_failures;
          finish (Lwt.return_error ("LLM falló: " ^ e))
      | Ok code ->
          let id = next_handler_id () in
          let path = save_handler_source id code in
          Printf.printf "[uni] persistido en %s\n%!" path;
          let before = Handlers.count () in
          let ok = eval_ocaml code in
          let after = Handlers.count () in
          if not ok || after = before then begin
            (try Sys.remove path with _ -> ());
            incr Metrics.compile_errors;
            finish (Lwt.return_error "compilación del handler generado falló o no registró")
          end else begin
            incr Metrics.handlers_compiled;
            match Handlers.dispatch query with
            | Some cmd ->
                Printf.printf "[uni] NUEVO handler aplicado: %s → %s\n%!" query cmd;
                finish (Lwt.return_ok cmd)
            | None ->
                finish (Lwt.return_error "handler compilado pero no encaja con la query")
          end

(* ============================================================ *)
(* HTTP server (compat OpenAI /v1/chat/completions)              *)
(* ============================================================ *)

let openai_response content =
  Yojson.Basic.to_string (`Assoc [
    ("choices", `List [
      `Assoc [
        ("message", `Assoc [
          ("role", `String "assistant");
          ("content", `String content)
        ])
      ]
    ])
  ])

let extract_user_msg body_str =
  try
    let json = Yojson.Basic.from_string body_str in
    let open Yojson.Basic.Util in
    let msgs = json |> member "messages" |> to_list in
    let user = List.find (fun m ->
      try (member "role" m |> to_string) = "user" with _ -> false
    ) msgs in
    user |> member "content" |> to_string |> Option.some
  with _ -> None

let callback _ req body =
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  match path with
  | "/health" ->
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body:"ok" ()
  | "/stats" ->
      let s = Printf.sprintf "handlers cached: %d\n" (Handlers.count ()) in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body:s ()
  | "/metrics" ->
      Cohttp_lwt_unix.Server.respond_string ~status:`OK
        ~headers:(Cohttp.Header.of_list [("Content-Type", "text/plain; version=0.0.4")])
        ~body:(Metrics.render ()) ()
  | "/v1/chat/completions" ->
      let* body_str = Cohttp_lwt.Body.to_string body in
      (match extract_user_msg body_str with
       | None ->
           Cohttp_lwt_unix.Server.respond_string ~status:`Bad_request
             ~body:"missing user message" ()
       | Some q ->
           let* result = process_query q in
           let content = match result with
             | Ok cmd -> cmd
             | Error msg -> "ERROR: " ^ msg
           in
           Cohttp_lwt_unix.Server.respond_string ~status:`OK
             ~headers:(Cohttp.Header.of_list [("Content-Type", "application/json")])
             ~body:(openai_response content) ())
  | _ ->
      Cohttp_lwt_unix.Server.respond_string ~status:`Not_found ~body:"not found" ()

let () =
  let port = try int_of_string (Sys.getenv "PORT") with _ -> 8081 in
  let upstream = try Sys.getenv "UPSTREAM_LLM" with Not_found -> "http://localhost:8080" in
  llm_url := upstream;
  ignore Uni.register;  (* keep alive *)
  Lwt_main.run begin
    Printf.printf "[uni] ocash-ai-unikernel arrancando en puerto %d\n%!" port;
    Printf.printf "[uni] LLM upstream: %s\n%!" !llm_url;
    toploop_init ();
    load_persisted_handlers ();
    Metrics.load ();
    Printf.printf "[uni] %d handlers cargados desde disco (métricas: %d queries previas)\n%!"
      (Handlers.count ()) !Metrics.queries_total;
    let server = Cohttp_lwt_unix.Server.make ~callback () in
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) server
  end
