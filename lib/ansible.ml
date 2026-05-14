(** Wrapper Ansible sobre el CLI ansible/ansible-playbook.
    Integrado como builtin `ansible` de ocash. *)

open Lwt.Syntax

let c_reset  = "\027[0m"
let c_green  = "\027[32m"
let c_yellow = "\027[33m"
let c_red    = "\027[31m"
let c_cyan   = "\027[36m"
let c_bold   = "\027[1m"

let default_inventory () =
  Sys.getenv_opt "OCASH_ANSIBLE_INVENTORY"

let cli_available bin =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  String.split_on_char ':' path
  |> List.exists (fun dir -> Sys.file_exists (Filename.concat dir bin))

let warn_missing bin =
  Printf.eprintf "%socash[ansible]:%s `%s` no está en PATH. Instálalo: pip install ansible\n%!"
    c_red c_reset bin

let run_proc prog args =
  if not (cli_available prog) then begin
    warn_missing prog;
    Lwt.return 127
  end else begin
    let cmd = (prog, Array.of_list (prog :: args)) in
    let* status = Lwt_process.exec cmd in
    match status with
    | Unix.WEXITED n   -> Lwt.return n
    | Unix.WSIGNALED _ -> Lwt.return 130
    | Unix.WSTOPPED _  -> Lwt.return 128
  end

let with_inventory ?inventory args =
  let inv = match inventory with
    | Some i -> Some i
    | None   -> default_inventory ()
  in
  match inv with
  | Some i -> ["-i"; i] @ args
  | None   -> args

let run_playbook ?inventory ?(extra_vars=[]) ?(tags=[]) ?(limit=None) playbook =
  let base = [playbook] in
  let base = with_inventory ?inventory base in
  let base = match limit with
    | Some l -> base @ ["--limit"; l]
    | None   -> base
  in
  let base = if tags = [] then base
             else base @ ["--tags"; String.concat "," tags]
  in
  let base = List.fold_left (fun acc (k, v) ->
    acc @ ["--extra-vars"; Printf.sprintf "%s=%s" k v]
  ) base extra_vars in
  Printf.printf "%socash[ansible]:%s ejecutando playbook %s%s%s\n%!"
    c_cyan c_reset c_bold playbook c_reset;
  run_proc "ansible-playbook" base

let ping ?inventory hosts =
  let args = with_inventory ?inventory [hosts; "-m"; "ping"] in
  Printf.printf "%socash[ansible]:%s ping → %s\n%!" c_cyan c_reset hosts;
  run_proc "ansible" args

let ad_hoc ?inventory ~module_name ?(args="") hosts =
  let cli = with_inventory ?inventory [hosts; "-m"; module_name] in
  let cli = if args = "" then cli else cli @ ["-a"; args] in
  Printf.printf "%socash[ansible]:%s %s %s %s\n%!"
    c_cyan c_reset hosts module_name args;
  run_proc "ansible" cli

let list_hosts ?inventory pattern =
  let args = with_inventory ?inventory [pattern; "--list-hosts"] in
  run_proc "ansible" args

let list_inventory ?inventory () =
  let args = with_inventory ?inventory ["--list"] in
  run_proc "ansible-inventory" args

let print_help () =
  Printf.printf "%sansible%s — builtin Ansible de ocash\n\n\
    Uso:\n\
    \  ansible playbook <file.yml> [--limit H] [--tags T1,T2] [-e K=V ...]\n\
    \  ansible ping <hosts>\n\
    \  ansible run <hosts> <módulo> [args]      Ad-hoc: ansible run web shell \"uptime\"\n\
    \  ansible hosts <pattern>                  Lista hosts que coinciden\n\
    \  ansible inventory                        Vuelca el inventario en JSON\n\
    \  ansible help                             Muestra esta ayuda\n\n\
    Variables de entorno:\n\
    \  OCASH_ANSIBLE_INVENTORY                  Inventory por defecto\n%!"
    c_bold c_reset;
  Lwt.return 0

let parse_extra_vars args =
  let extras = ref [] in
  let other  = ref [] in
  let rec loop = function
    | "-e" :: kv :: tl | "--extra-vars" :: kv :: tl ->
        (match String.index_opt kv '=' with
         | Some i ->
             let k = String.sub kv 0 i in
             let v = String.sub kv (i+1) (String.length kv - i - 1) in
             extras := (k, v) :: !extras
         | None -> ());
        loop tl
    | x :: tl -> other := x :: !other; loop tl
    | [] -> ()
  in
  loop args;
  (List.rev !extras, List.rev !other)

let rec take_opt key = function
  | [] -> None, []
  | k :: v :: tl when k = key -> Some v, tl
  | x :: tl ->
      let v, rest = take_opt key tl in
      v, x :: rest

let dispatch args =
  match args with
  | [] | ["help"] | ["--help"] | ["-h"] -> print_help ()
  | "playbook" :: file :: rest ->
      let extras, rest' = parse_extra_vars rest in
      let limit, rest'  = take_opt "--limit" rest' in
      let tags_opt, _   = take_opt "--tags" rest' in
      let tags = match tags_opt with
        | Some s -> String.split_on_char ',' s
        | None   -> []
      in
      run_playbook ~extra_vars:extras ~tags ~limit file
  | ["ping"] -> ping "all"
  | ["ping"; hosts] -> ping hosts
  | "run" :: hosts :: modulo :: rest ->
      let args_str = String.concat " " rest in
      ad_hoc ~module_name:modulo ~args:args_str hosts
  | ["hosts"; pattern] -> list_hosts pattern
  | ["hosts"] -> list_hosts "all"
  | ["inventory"] -> list_inventory ()
  | other ->
      Printf.eprintf "%socash[ansible]:%s subcomando desconocido: %s\n%!"
        c_red c_reset (String.concat " " other);
      Printf.eprintf "Usa `ansible help` para ver la ayuda.\n%!";
      Lwt.return 2
