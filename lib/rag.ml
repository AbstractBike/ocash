(** RAG sobre el proyecto: indexa archivos de texto en el cwd, busca los
    más relevantes para una query, e inyecta sus fragmentos en el prompt
    del AI para queries context-aware.

    No usamos embeddings de modelo (sin sentence-transformers en runtime
    OCaml). Usamos BM25 simple sobre tokens word-split, lo cual funciona
    sorprendentemente bien para queries cortas. *)

let extensions_to_index = [
  ".ml"; ".mli"; ".re"; ".rei";
  ".py"; ".rs"; ".go"; ".js"; ".ts"; ".jsx"; ".tsx";
  ".c"; ".cc"; ".cpp"; ".h"; ".hpp";
  ".sh"; ".bash"; ".fish";
  ".md"; ".txt"; ".rst";
  ".yaml"; ".yml"; ".toml"; ".json"; ".ini"; ".conf";
  ".sql"; ".html"; ".css"; ".scss";
  ".dune"; ".opam"
]

let exclude_dirs = ["_build"; "node_modules"; ".git"; "target"; "dist"; "build"]

let max_file_size = 200 * 1024  (* 200 KB *)
let max_files = 500
let snippet_size = 600  (* chars per relevant snippet *)

type doc = {
  path: string;
  tokens: string list;
  size: int;
}

let index : doc list ref = ref []
let indexed = ref false

let tokenize s =
  let buf = Buffer.create 32 in
  let tokens = ref [] in
  let flush () =
    if Buffer.length buf > 0 then begin
      let t = Buffer.contents buf |> String.lowercase_ascii in
      if String.length t >= 2 then tokens := t :: !tokens;
      Buffer.clear buf
    end
  in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
       (c >= '0' && c <= '9') || c = '_'
    then Buffer.add_char buf c
    else flush ()
  ) s;
  flush ();
  List.rev !tokens

let should_index path =
  let base = Filename.basename path in
  if String.length base > 0 && base.[0] = '.' then false
  else
    List.exists (fun ext -> Filename.check_suffix path ext) extensions_to_index

let rec walk dir acc =
  if List.length acc >= max_files then acc
  else if List.mem (Filename.basename dir) exclude_dirs then acc
  else
    try
      let entries = Sys.readdir dir in
      Array.fold_left (fun acc e ->
        if List.length acc >= max_files then acc
        else
          let full = Filename.concat dir e in
          try
            let st = Unix.stat full in
            match st.st_kind with
            | Unix.S_DIR ->
                if List.mem e exclude_dirs then acc
                else walk full acc
            | Unix.S_REG when should_index full && st.st_size <= max_file_size ->
                full :: acc
            | _ -> acc
          with _ -> acc
      ) acc entries
    with _ -> acc

let read_file path =
  try
    let ic = open_in path in
    let len = in_channel_length ic in
    let s = really_input_string ic len in
    close_in ic;
    Some s
  with _ -> None

let build () =
  if !indexed then ()
  else begin
    let paths = walk (Sys.getcwd ()) [] in
    let docs = List.filter_map (fun p ->
      match read_file p with
      | Some content ->
          Some { path = p; tokens = tokenize content; size = String.length content }
      | None -> None
    ) paths in
    index := docs;
    indexed := true
  end

let refresh () = indexed := false; build ()

(* Score BM25 simplificado: TF * IDF estimado *)
let score query_tokens doc =
  let doc_tokens = doc.tokens in
  let doc_len = List.length doc_tokens in
  if doc_len = 0 then 0.0
  else begin
    let tf t =
      List.fold_left (fun acc x -> if x = t then acc + 1 else acc) 0 doc_tokens
    in
    let num_docs = List.length !index in
    let idf t =
      let with_t = List.length (List.filter (fun d ->
        List.exists ((=) t) d.tokens) !index) in
      if with_t = 0 then 0.0
      else log (float_of_int num_docs /. float_of_int with_t +. 1.0)
    in
    List.fold_left (fun acc t ->
      let tf_t = float_of_int (tf t) in
      let idf_t = idf t in
      acc +. (tf_t *. idf_t /. (tf_t +. 1.5))
    ) 0.0 query_tokens
  end

let top_k k query =
  build ();
  let qt = tokenize query in
  if qt = [] then []
  else begin
    let scored = List.map (fun d -> (score qt d, d)) !index in
    let nonzero = List.filter (fun (s, _) -> s > 0.0) scored in
    let sorted = List.sort (fun (a, _) (b, _) -> compare b a) nonzero in
    let rec take n = function
      | [] -> []
      | _ when n <= 0 -> []
      | x :: xs -> x :: take (n - 1) xs
    in
    take k sorted |> List.map snd
  end

(* Extrae un snippet "relevante" de un archivo: la ventana de
   snippet_size chars con más matches del query. *)
let best_snippet ~query ~content =
  let qt = tokenize query in
  let lc = String.lowercase_ascii content in
  let len = String.length content in
  if len <= snippet_size then content
  else begin
    let best_score = ref 0 in
    let best_off = ref 0 in
    let step = snippet_size / 2 in
    let off = ref 0 in
    while !off + snippet_size <= len do
      let window = String.sub lc !off snippet_size in
      let s = List.fold_left (fun acc t ->
        let rec count_occ i acc =
          if i > String.length window - String.length t then acc
          else if String.sub window i (String.length t) = t
          then count_occ (i + String.length t) (acc + 1)
          else count_occ (i + 1) acc
        in
        acc + count_occ 0 0
      ) 0 qt in
      if s > !best_score then begin
        best_score := s;
        best_off := !off
      end;
      off := !off + step
    done;
    String.sub content !best_off snippet_size
  end

(* Construye un prompt augmentado con los k archivos más relevantes. *)
let augment ~query =
  let docs = top_k 3 query in
  if docs = [] then query
  else begin
    let snippets = List.map (fun d ->
      match read_file d.path with
      | Some content ->
          let snippet = best_snippet ~query ~content in
          Printf.sprintf "### %s\n```\n%s\n```\n" d.path snippet
      | None -> ""
    ) docs in
    Printf.sprintf
      "Contexto del proyecto (archivos más relevantes):\n%s\n\nPetición: %s"
      (String.concat "\n" snippets) query
  end
