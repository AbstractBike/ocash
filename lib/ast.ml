(** Tipos del AST de la shell *)

type redirect =
  | Stdout_to of string
  | Stderr_to of string
  | Append_to of string
  | Stdin_from of string

type command = {
  argv      : string list;
  redirects : redirect list;
}

type pipeline =
  | Single of command
  | Pipe   of pipeline * pipeline

type statement =
  | Exec       of pipeline
  | And        of statement * statement
  | Or         of statement * statement
  | Seq        of statement * statement
  | Background of statement
  | Assign     of string * string
  | Empty
