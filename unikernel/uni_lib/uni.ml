(** Módulo Uni: API expuesta al Toploop para que los handlers generados
    por el LLM puedan registrarse. Como esta biblioteca es `(wrapped false)`,
    el toploop ve el módulo `Uni` directamente. *)

let cache : (string * (string -> string option)) list ref = ref []

let register name fn =
  Printf.printf "[uni] handler registrado: %s\n%!" name;
  cache := (name, fn) :: !cache

let dispatch q =
  List.find_map (fun (_, h) -> try h q with _ -> None) !cache

let count () = List.length !cache
