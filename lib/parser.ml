open Angstrom

(* Los tokens se devuelven en "forma escapada": `\c` significa el carácter
   literal c (sin expansión) y `$` sin escapar marca una expansión de
   variable. Eval.expand_word resuelve ambas cosas. Así las comillas
   simples protegen `$` como en bash ('$HOME' se queda literal), las
   dobles permiten la expansión ("$HOME" expande) y `\$` funciona fuera
   de comillas. *)

let is_space = function ' ' | '\t' -> true | _ -> false

let is_word_char = function
  | ' ' | '\t' | '\n' | '|' | '&' | ';' | '<' | '>' | '"' | '\'' | '\\' -> false
  | _ -> true

let spaces     = skip_while is_space
let word       = take_while1 is_word_char

(* Escapa todo carácter con significado en la forma escapada. *)
let escape_all s =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    if c = '\\' || c = '$' then Buffer.add_char b '\\';
    Buffer.add_char b c) s;
  Buffer.contents b

(* `\c` fuera de comillas: c literal. *)
let escaped = char '\\' *> any_char >>| fun c -> Printf.sprintf "\\%c" c

let quoted_single =
  char '\'' *> take_while (fun c -> c <> '\'') <* char '\'' >>| escape_all

(* Dentro de comillas dobles bash solo trata como escape un backslash
   seguido de dólar, backtick, comilla doble o backslash; cualquier otro
   backslash es literal. El dólar sigue expandiendo. *)
let quoted_double =
  let dq_escape =
    char '\\' *> any_char >>| function
      | ('$' | '`' | '"' | '\\') as c -> Printf.sprintf "\\%c" c
      | c -> Printf.sprintf "\\\\%c" c
  in
  let dq_plain = take_while1 (fun c -> c <> '"' && c <> '\\') in
  char '"' *> many (dq_plain <|> dq_escape) <* char '"' >>| String.concat ""

(* Un token es la concatenación de uno o más atoms (word|quoted) sin espacio
   entre ellos. Permite parsear correctamente `alias l="ls -la"` como un
   solo argumento "l=ls -la", a la bash. *)
let token =
  let atom = quoted_double <|> quoted_single <|> escaped <|> word in
  many1 atom >>| String.concat ""

let redirect_append = string ">>" *> spaces *> token >>| fun f -> Ast.Append_to f
let redirect_stdout = char '>'   *> spaces *> token >>| fun f -> Ast.Stdout_to f
let redirect_stdin  = char '<'   *> spaces *> token >>| fun f -> Ast.Stdin_from f
let redirect_stderr = string "2>" *> spaces *> token >>| fun f -> Ast.Stderr_to f

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

let assign_value = option "" token

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

(* Statement con trailing `&` opcional → Background. *)
let statement_with_bg =
  let+ s   = statement
  and+ bg  = option false (spaces *> char '&' *> spaces *> return true) in
  if bg then Ast.Background s else s

let parse input =
  let s = String.trim input in
  if s = "" then Ok Ast.Empty
  else parse_string ~consume:All statement_with_bg s

(* Divide un texto en palabras (forma escapada) si solo contiene palabras
   simples: sin pipes, redirects ni operadores. Lo usan los aliases. *)
let split_words input =
  let p = spaces *> many (token <* spaces) in
  match parse_string ~consume:All p input with
  | Ok words -> Some words
  | Error _  -> None
