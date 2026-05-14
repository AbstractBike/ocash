open Lwt.Syntax

let nl_prefixes = ["habla:"; "ai:"; "?:"; "haz:"; "make:"; "di:"]
let ocaml_prefixes = ["ml:"; "ocaml:"]

(* Sufijo `ç` (o ` ç`) al final del input → modo AI con historial como contexto. *)
let history_trigger_suffixes = ["ç"; " ç"]

let is_history_ai input =
  let s = String.trim input in
  List.exists (fun suf ->
    String.length s >= String.length suf &&
    String.sub s (String.length s - String.length suf) (String.length suf) = suf
  ) history_trigger_suffixes

let strip_history_trigger input =
  let s = String.trim input in
  List.fold_left (fun acc suf ->
    if String.length acc >= String.length suf &&
       String.sub acc (String.length acc - String.length suf) (String.length suf) = suf
    then String.trim (String.sub acc 0 (String.length acc - String.length suf))
    else acc
  ) s history_trigger_suffixes

let strip_prefix prefixes input =
  let s = String.trim input in
  List.find_map (fun p ->
    if String.starts_with ~prefix:p s then
      Some (String.sub s (String.length p)
              (String.length s - String.length p) |> String.trim)
    else None
  ) prefixes

let is_nl input = strip_prefix nl_prefixes input <> None
let is_ocaml input = strip_prefix ocaml_prefixes input <> None

let strip_nl_prefix input =
  strip_prefix nl_prefixes input
  |> Option.value ~default:(String.trim input)

let strip_ocaml_prefix input =
  strip_prefix ocaml_prefixes input
  |> Option.value ~default:(String.trim input)

let c_reset  = "\027[0m"
let c_green  = "\027[32m"
let c_blue   = "\027[34m"
let c_cyan   = "\027[36m"
let c_yellow = "\027[33m"
let c_red    = "\027[31m"
let c_bold   = "\027[1m"
let c_dim    = "\027[2m"

let color c s = c ^ s ^ c_reset

let build_prompt () =
  let user = Option.value ~default:"user" (Sys.getenv_opt "USER") in
  let cwd  =
    let full = try Unix.getcwd () with _ -> "/" in
    let home = Option.value ~default:"" (Sys.getenv_opt "HOME") in
    if String.starts_with ~prefix:home full then
      "~" ^ String.sub full (String.length home)
              (String.length full - String.length home)
    else full
  in
  let count =
    try
      let entries = Sys.readdir "." in
      Array.length entries
    with _ -> 0
  in
  let ai_badge =
    if !Ai.ai_enabled then color c_cyan " [AI]" else ""
  in
  Printf.sprintf "%s%s %s %s{%d}%s%s $ "
    (color c_green user)
    ai_badge
    (color c_blue cwd)
    c_dim count c_reset
    c_bold

class shell_readline term completions prompt_str = object(self)
  inherit LTerm_read_line.read_line ()
  inherit [Zed_string.t] LTerm_read_line.term term

  initializer
    self#set_prompt (React.S.const (LTerm_text.of_utf8 prompt_str))

  method! show_box = false

  method! completion =
    let prefix =
      Zed_rope.to_string (Zed_edit.text self#edit)
      |> Zed_string.to_utf8
      |> String.split_on_char ' '
      |> List.rev
      |> (function [] -> "" | h :: _ -> h)
    in
    let matches =
      List.filter (String.starts_with ~prefix) completions
      |> List.map (fun s ->
          (Zed_string.of_utf8 s, Zed_string.of_utf8 ""))
    in
    self#set_completion 0 matches
end

(* REPL "tonto" para modo no-TTY (scripts, pipes, CI). *)
let read_input_dumb ~with_prompt () =
  if with_prompt then begin
    print_string (build_prompt ());
    flush stdout
  end;
  try Lwt.return_some (input_line stdin)
  with End_of_file -> Lwt.return_none

let is_tty = lazy (try Unix.isatty Unix.stdin with _ -> false)

let read_input () =
  if not (Lazy.force is_tty) then
    read_input_dumb ~with_prompt:false ()
  else
    let completions = Completion.get_all "" in
    let prompt      = build_prompt () in
    Lwt.catch
      (fun () ->
        let* term = Lazy.force LTerm.stdout in
        let rl = new shell_readline term completions prompt in
        let* result = rl#run in
        Lwt.return_some (Zed_string.to_utf8 result))
      (function
        | LTerm_read_line.Interrupt -> Lwt.return_some ""
        | End_of_file               -> exit 0
        | exn                       -> Lwt.fail exn)
