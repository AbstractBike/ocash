let get_path_commands () =
  try
    String.split_on_char ':' (Sys.getenv "PATH")
    |> List.concat_map (fun dir ->
        try Array.to_list (Sys.readdir dir)
        with _ -> [])
    |> List.sort_uniq String.compare
  with Not_found -> []

let get_local_files prefix =
  let dir  = if String.contains prefix '/'
             then Filename.dirname prefix
             else "." in
  let base = if String.contains prefix '/'
             then Filename.basename prefix
             else prefix in
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (String.starts_with ~prefix:base)
    |> List.map (fun f ->
        if dir = "." then f
        else Filename.concat dir f)
  with _ -> []

let builtins = Eval.builtins

let get_all prefix =
  let cmds  = builtins @ get_path_commands () in
  let files = get_local_files prefix in
  let all   = cmds @ files in
  List.filter (String.starts_with ~prefix) all
  |> List.sort_uniq String.compare
