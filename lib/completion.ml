let get_path_commands () =
  try
    String.split_on_char ':' (Sys.getenv "PATH")
    |> List.concat_map (fun dir ->
        try Array.to_list (Sys.readdir dir)
        with _ -> [])
    |> List.sort_uniq String.compare
  with Not_found -> []

let is_dir path = try Sys.is_directory path with Sys_error _ -> false

(* Ficheros que completan `prefix`, admitiendo subdirectorios (`src/fo`)
   y `~/`. Devuelve la palabra completa tal como debe quedar en la línea;
   los directorios llevan `/` final. Los ocultos solo aparecen si el
   prefijo del nombre empieza por `.`, como en bash. *)
let get_local_files prefix =
  let slash = String.rindex_opt prefix '/' in
  let dir_part, base = match slash with
    | Some i -> String.sub prefix 0 (i + 1),
                String.sub prefix (i + 1) (String.length prefix - i - 1)
    | None -> "", prefix
  in
  let lookup_dir =
    if dir_part = "" then "."
    else if String.length dir_part >= 2 && String.sub dir_part 0 2 = "~/" then
      let home = try Sys.getenv "HOME" with Not_found -> "" in
      home ^ String.sub dir_part 1 (String.length dir_part - 1)
    else dir_part
  in
  let show_hidden = String.length base > 0 && base.[0] = '.' in
  try
    Array.to_list (Sys.readdir lookup_dir)
    |> List.filter (fun f ->
        String.starts_with ~prefix:base f
        && (show_hidden || f.[0] <> '.'))
    |> List.map (fun f ->
        let full = dir_part ^ f in
        if is_dir (Filename.concat lookup_dir f) then full ^ "/" else full)
  with _ -> []

let builtins = Eval.builtins

(* Candidatos para la palabra bajo el cursor. En posición de comando
   (primera palabra, o tras `|`) y sin `/`: builtins, aliases y PATH;
   en el resto, rutas. *)
let complete_word ~command word =
  let cands =
    if command && not (String.contains word '/') then
      builtins
      @ Hashtbl.fold (fun k _ acc -> k :: acc) Eval.aliases []
      @ get_path_commands ()
      @ (get_local_files word |> List.filter (fun f -> is_dir f))
    else get_local_files word
  in
  List.filter (String.starts_with ~prefix:word) cands
  |> List.sort_uniq String.compare

(* ¿La palabra que empieza tras `before` está en posición de comando? *)
let is_command_position before =
  let t = String.trim before in
  t = "" || (let c = t.[String.length t - 1] in c = '|' || c = ';' || c = '&')

let get_all prefix =
  let cmds  = builtins @ get_path_commands () in
  let files = get_local_files prefix in
  let all   = cmds @ files in
  List.filter (String.starts_with ~prefix) all
  |> List.sort_uniq String.compare
