(** Detección de GPU (NVIDIA / AMD / Apple Silicon).
    Habilita autocomplete on-the-fly cuando hay aceleración disponible. *)

let cli_available bin =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  String.split_on_char ':' path
  |> List.exists (fun dir -> Sys.file_exists (Filename.concat dir bin))

let detect () =
  if Sys.file_exists "/dev/nvidia0" || cli_available "nvidia-smi" then
    Some "NVIDIA"
  else if Sys.file_exists "/dev/kfd" || Sys.file_exists "/dev/dri/renderD128" then
    Some "AMD/GPU"
  else if cli_available "system_profiler" then
    (* macOS: Apple Silicon vía Metal *)
    let ic = Unix.open_process_in "uname -m 2>/dev/null" in
    let arch = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    if arch = "arm64" then Some "Apple Silicon" else None
  else
    None

let has_gpu = lazy (detect () <> None)

let label () = match detect () with
  | Some name -> name
  | None -> "no-gpu"
