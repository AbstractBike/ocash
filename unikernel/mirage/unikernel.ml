(** Unikernel ocash-ai Fase 2 — MirageOS / Solo5.

    Esta es la variante "estática": los handlers se precompilan en build-time
    desde un KV embebido (mirage-kv-mem) y se enlazan estáticamente. El JIT
    runtime (Toploop+Dynlink) NO está disponible en Solo5; ver
    `unikernel/mirage/README.md` para el blocker técnico y alternativas. *)

open Lwt.Syntax

module Main
    (KV : Mirage_kv.RO)
    (HTTP : Cohttp_lwt.S.Server)
    (S : Tcpip.Stack.V4V6) = struct

  (* -------- Métricas -------- *)
  module Metrics = struct
    let queries_total = ref 0
    let cache_hits = ref 0
    let cache_misses = ref 0
    let llm_failures = ref 0
    let handlers_compiled = ref 0   (* en modo estático, siempre 0 *)
    let compile_errors = ref 0

    let render () =
      Printf.sprintf
{|# HELP ocash_uni_queries_total queries
# TYPE ocash_uni_queries_total counter
ocash_uni_queries_total %d
ocash_uni_cache_hits_total %d
ocash_uni_cache_misses_total %d
ocash_uni_llm_failures_total %d
ocash_uni_handlers_compiled_total %d
ocash_uni_compile_errors_total %d
|} !queries_total !cache_hits !cache_misses !llm_failures
   !handlers_compiled !compile_errors
  end

  (* -------- Cache de handlers (precompilados estáticamente) -------- *)
  (* En la versión Solo5 los handlers se embeben en build-time. Aquí solo
     listamos la API; la implementación real se generaría con un PPX o un
     script de build que lea handlers/*.ml y los incluya como módulos. *)
  let handlers : (string * (string -> string option)) list ref = ref []

  let register name fn =
    Logs.info (fun m -> m "handler registrado: %s" name);
    handlers := (name, fn) :: !handlers

  let dispatch q =
    List.find_map (fun (_, h) -> try h q with _ -> None) !handlers

  (* -------- Carga de handlers desde KV (solo metadatos, no eval) -------- *)
  let load_handlers_from_kv kv =
    let* keys = KV.list kv Mirage_kv.Key.empty in
    match keys with
    | Error e ->
        Logs.warn (fun m -> m "KV.list error: %a" KV.pp_error e);
        Lwt.return_unit
    | Ok ks ->
        Lwt_list.iter_s (fun (k, _kind) ->
          Logs.info (fun m -> m "handler estático disponible: %a" Mirage_kv.Key.pp k);
          Lwt.return_unit
        ) ks

  (* -------- Cliente LLM upstream vía http-mirage-client -------- *)
  (* TODO: implementar con http-mirage-client; aquí stub. *)
  let llm_generate ~user_input:_ =
    Lwt.return_error "llm_generate no implementado en Mirage (necesita http-mirage-client + handshake)"

  (* -------- HTTP server callback (cohttp-mirage) -------- *)
  let callback _conn req body =
    let uri = Cohttp.Request.uri req in
    let path = Uri.path uri in
    match path with
    | "/health" ->
        HTTP.respond_string ~status:`OK ~body:"ok" ()
    | "/metrics" ->
        HTTP.respond_string ~status:`OK ~body:(Metrics.render ()) ()
    | "/v1/chat/completions" ->
        let* body_str = Cohttp_lwt.Body.to_string body in
        incr Metrics.queries_total;
        (* Extraer la query del JSON *)
        let q =
          try
            let json = Yojson.Basic.from_string body_str in
            let open Yojson.Basic.Util in
            json |> member "messages" |> to_list
            |> List.find (fun m -> member "role" m |> to_string = "user")
            |> member "content" |> to_string
          with _ -> ""
        in
        (match dispatch q with
         | Some cmd ->
             incr Metrics.cache_hits;
             HTTP.respond_string ~status:`OK ~body:cmd ()
         | None ->
             incr Metrics.cache_misses;
             let* gen = llm_generate ~user_input:q in
             match gen with
             | Error e ->
                 incr Metrics.llm_failures;
                 HTTP.respond_string ~status:`Internal_server_error
                   ~body:("LLM falló: " ^ e) ()
             | Ok _code ->
                 (* BLOCKER: en Solo5 no podemos Toploop.execute_phrase.
                    Devolvemos error indicativo. *)
                 incr Metrics.compile_errors;
                 HTTP.respond_string ~status:`Not_implemented
                   ~body:"JIT runtime no disponible en Solo5 (ver README)" ())
    | _ ->
        HTTP.respond_string ~status:`Not_found ~body:"not found" ()

  (* -------- Entry point -------- *)
  let start kv http _stack =
    let port = Key_gen.port () in
    Logs.info (fun m -> m "ocash-ai-unikernel (mirage) en puerto %d" port);
    let* () = load_handlers_from_kv kv in
    let spec = HTTP.make ~callback () in
    http (`TCP port) spec
end
