open Angstrom

let is_space = function ' ' | '\t' -> true | _ -> false

let is_word_char = function
  | ' ' | '\t' | '\n' | '|' | '&' | ';' | '<' | '>' | '"' | '\'' -> false
  | _ -> true

let spaces     = skip_while is_space
let word       = take_while1 is_word_char

let quoted_double =
  char '"' *> take_while (fun c -> c <> '"') <* char '"'

let quoted_single =
  char '\'' *> take_while (fun c -> c <> '\'') <* char '\''

let token = quoted_double <|> quoted_single <|> word

let redirect_append = string ">>" *> spaces *> word >>| fun f -> Ast.Append_to f
let redirect_stdout = char '>'   *> spaces *> word >>| fun f -> Ast.Stdout_to f
let redirect_stdin  = char '<'   *> spaces *> word >>| fun f -> Ast.Stdin_from f
let redirect_stderr = string "2>" *> spaces *> word >>| fun f -> Ast.Stderr_to f

let redirect = redirect_append <|> redirect_stderr <|> redirect_stdout <|> redirect_stdin

let command =
  let+ first = token
  and+ rest  = many (spaces *> (
    (redirect >>| fun r -> `Redir r) <|>
    (token    >>| fun t -> `Arg   t)
  )) in
  let argv      = first :: List.filter_map (function `Arg a  -> Some a | _ -> None) rest in
  let redirects = List.filter_map (function `Redir r -> Some r | _ -> None) rest in
  Ast.{ argv; redirects }

let pipeline =
  let+ head = command
  and+ tail = many (spaces *> char '|' *> spaces *> command) in
  List.fold_left
    (fun acc cmd -> Ast.Pipe (acc, Ast.Single cmd))
    (Ast.Single head)
    tail

let assign_value =
  quoted_double
  <|> quoted_single
  <|> take_while (fun c -> c <> ' ' && c <> '\t' && c <> '\n')

let assign =
  let+ key = take_while1 (fun c ->
    let code = Char.code c in
    (code >= Char.code 'A' && code <= Char.code 'Z') ||
    (code >= Char.code 'a' && code <= Char.code 'z') ||
    (code >= Char.code '0' && code <= Char.code '9') ||
    c = '_')
  and+ _   = char '='
  and+ v   = assign_value in
  Ast.Assign (key, v)

let statement =
  spaces *> (
    (assign >>| fun a -> a) <|>
    (pipeline >>| fun p -> Ast.Exec p)
  ) <* spaces

let parse input =
  let s = String.trim input in
  if s = "" then Ok Ast.Empty
  else parse_string ~consume:All statement s
