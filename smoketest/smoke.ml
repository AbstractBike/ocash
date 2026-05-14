(* smoke test: invoca conv_save tras añadir mensajes y verifica JSON válido *)
let () =
  let tmphome = Filename.concat (Filename.get_temp_dir_name ()) ("ocash_smoke_" ^ string_of_int (Unix.getpid ())) in
  Unix.putenv "HOME" tmphome;
  Unix.mkdir tmphome 0o755;
  Ocash_lib.Ai.conv_add_user "hola";
  Ocash_lib.Ai.conv_add_assistant "echo hola";
  Ocash_lib.Ai.conv_add_user "lista archivos";
  let path = Filename.concat tmphome ".ocash/conv.json" in
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  let _ = Yojson.Basic.from_string s in  (* fails if invalid *)
  Printf.printf "smoke OK: %s (%d bytes) JSON válido\n" path n;
  (* Verifica que no quedaron tmp files *)
  let dir = Filename.concat tmphome ".ocash" in
  Array.iter (fun f ->
    if String.length f >= 4 && String.sub f 0 4 = "conv" && f <> "conv.json" then
      Printf.printf "  WARN: file leftover: %s\n" f
  ) (Sys.readdir dir);
  (* Cleanup *)
  Sys.remove path;
  Unix.rmdir dir;
  Unix.rmdir tmphome
