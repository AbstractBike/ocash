open Lwt.Syntax

let nl_prefixes = ["habla:"; "ai:"; "?:"; "haz:"; "make:"; "di:"]

let is_nl input =
  List.exists (fun p -> String.starts_with ~prefix:p (String.trim input)) nl_prefixes

let strip_nl_prefix input =
  let s = String.trim input in
  List.find_map (fun p ->
    if String.starts_with ~prefix:p s then
      Some (String.sub s (String.length p)
              (String.length s - String.length p) |> String.trim)
    else None
  ) nl_prefixes
  |> Option.value ~default:s

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
  let ai_badge =
    if !Ai.ai_enabled then color c_cyan " [AI]" else ""
  in
  Printf.sprintf "%s%s %s%s%s $ "
    (color c_green user)
    ai_badge
    (color c_blue cwd)
    c_reset
    c_bold

class shell_readline completions prompt_str = object(self)
  inherit LTerm_read_line.read_line () as super
  inherit [Zed_string.t] LTerm_read_line.term (Lazy.force LTerm.stdout)

  initializer
    self#set_prompt (React.S.const (LTerm_text.of_string prompt_str));
    ignore completions

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
    self#set_completion 0 matches;
    ignore super
end

let read_input () =
  let completions = Completion.get_all "" in
  let prompt      = build_prompt () in
  Lwt.catch
    (fun () ->
      let rl = new shell_readline completions prompt in
      let* result = rl#run in
      Lwt.return_some (Zed_string.to_utf8 result))
    (function
      | LTerm_read_line.Interrupt -> Lwt.return_some ""
      | End_of_file               -> exit 0
      | exn                       -> Lwt.fail exn)
