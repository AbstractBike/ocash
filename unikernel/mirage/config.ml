(** Mirage config DSL para ocash-ai-unikernel Fase 2 (Solo5).

    Genera el `main.ml` que conecta los devices virtuales (KV store, stack TCP,
    HTTP server, cliente HTTP saliente al LLM) con el módulo {!Unikernel.Main}.

    Construye con:
    {[
      mirage configure -t hvt    # o -t spt, -t unix
      make depend
      dune build
    ]}
*)

open Mirage

let port =
  let doc = Key.Arg.info ~doc:"Puerto HTTP" ["port"] in
  Key.(create "port" Arg.(opt int 8081 doc))

let upstream =
  let doc = Key.Arg.info ~doc:"URL del LLM upstream" ["upstream"] in
  Key.(create "upstream" Arg.(opt string "http://10.0.0.2:8080" doc))

(* KV de solo-lectura para handlers persistidos / embebidos en build time. *)
let handlers_kv = generic_kv_ro "handlers"

(* Stack de red para Solo5 + cliente HTTP saliente. *)
let stack = generic_stackv4v6 default_network

(* DNS + TCP client para hablar con el LLM upstream. *)
let dns_client = generic_dns_client stack
let http_client =
  let connect _ modname = function
    | [ _pclock; _tcp_ctx; _dns ] ->
        Fmt.str
          "Lwt.return (%s.create_ctx ~happy_eyeballs:_happy ~authenticator:None)"
          modname
    | _ -> assert false
  in
  let packages = [ package "http-mirage-client" ] in
  impl ~packages ~connect "Http_mirage_client" (pclock @-> tcpv4v6 @-> dns_client @-> http_client)

(* HTTP server: cohttp-mirage usa la pila TCP/IP directamente. *)
let http_srv = cohttp_server (conduit_direct ~tls:false stack)

let main =
  main
    ~keys:[ Key.v port; Key.v upstream ]
    ~packages:[
      package "cohttp-mirage";
      package "http-mirage-client";
      package "yojson";
      package "mirage-kv";
      package "logs";
      (* compiler-libs.toplevel: NO listado a propósito — ver blocker en README. *)
    ]
    "Unikernel.Main"
    (kv_ro @-> http @-> stackv4v6 @-> job)

let () =
  register "ocash-ai-unikernel"
    [ main $ handlers_kv $ http_srv $ stack ]
