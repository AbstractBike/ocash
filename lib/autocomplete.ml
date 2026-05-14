(** Autocomplete on-the-fly basado en historial + AI.

    Cuando el usuario está escribiendo, tras ~200ms de idle, manda
    (prefix actual + últimas N entradas del historial) al backend AI
    y recibe una continuación a mostrar en gris detrás del cursor.

    Habilitado solo si hay GPU detectada (autocomplete necesita
    inferencia rápida) o el backend es Claude/Codex CLI (que se
    asume rápido por ser remoto/cloud). *)

open Lwt.Syntax

let enabled () =
  Lazy.force Gpu.has_gpu ||
  (match !Ai.current_backend with
   | Ai.Claude_cli | Ai.Codex_cli | Ai.Anthropic | Ai.Openai -> true
   | Ai.Local -> Lazy.force Gpu.has_gpu)

let autocomplete_prompt = {|You are a shell autocomplete assistant. The user is mid-typing a command.
Given the recent command history and the current partial command, predict the
MOST LIKELY continuation. Output ONLY the missing characters, nothing else.

RULES:
- If the partial command is empty, output a likely first command
- If the partial command is complete enough, output an empty string
- No explanation, no markdown, no quotes
- Max 80 characters of completion
|}

let build_completion_query ~history ~current =
  let hist =
    if history = [] then "(none)"
    else String.concat "\n" (List.map (fun h -> "$ " ^ h) history)
  in
  Printf.sprintf
    "Recent history:\n%s\n\nCurrent partial input: %s\nCompletion:"
    hist current

(* Cache simple en memoria para evitar pedir lo mismo dos veces *)
let cache : (string, string) Hashtbl.t = Hashtbl.create 256

let suggest ~history ~current =
  if String.length current < 1 then Lwt.return None
  else
    (* Fish-style: primero busca en historial (instantáneo, offline).
       Solo si NO hay match en historial, y AI está habilitada,
       cae al LLM. *)
    match History.find_prefix current with
    | Some hist_match ->
        (* Devuelve solo el sufijo que falta tras el prefix *)
        let suffix = String.sub hist_match (String.length current)
                       (String.length hist_match - String.length current) in
        Lwt.return (Some suffix)
    | None ->
        if not (enabled ()) || String.length current < 2 then
          Lwt.return None
        else
          let key = String.concat "|" history ^ "::" ^ current in
          match Hashtbl.find_opt cache key with
          | Some s -> Lwt.return (Some s)
          | None ->
              let query_text = build_completion_query ~history ~current in
              let* result = Ai.query ~user_input:query_text () in
              match result with
              | Ai.Command s when s <> "" ->
                  let suggestion =
                    if String.starts_with ~prefix:current s
                    then String.sub s (String.length current)
                           (String.length s - String.length current)
                    else s
                  in
                  let suggestion = String.trim suggestion in
                  if suggestion = "" then Lwt.return None
                  else begin
                    Hashtbl.replace cache key suggestion;
                    Lwt.return (Some suggestion)
                  end
              | _ -> Lwt.return None

(* Para integración futura con lambda-term: el callback recibe la sugerencia
   y la pinta en gris (ANSI dim) tras el cursor. Por ahora exponemos solo
   la lógica; la UI inline requiere subclase de LTerm_read_line con
   override de #draw o uso de #set_completion con un display custom. *)
