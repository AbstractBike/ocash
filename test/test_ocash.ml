(** Suite de tests Alcotest para ocash.

    Cubre: Parser, Eval (pipes/cd/redirects), Bash needs_bash classifier,
    History fuzzy_score, Ai strip_markdown, Autocomplete history prefix,
    Rag tokenize. *)

open Ocash_lib

(* ============================================================ *)
(* Parser                                                        *)
(* ============================================================ *)

let parse_ok input =
  match Parser.parse input with
  | Ok s -> s
  | Error msg -> Alcotest.failf "parse failed for %S: %s" input msg

let parse_err input =
  match Parser.parse input with
  | Ok _ -> false
  | Error _ -> true

let test_parser_simple_cmd () =
  match parse_ok "ls" with
  | Ast.Exec (Ast.Single { argv = ["ls"]; redirects = [] }) -> ()
  | _ -> Alcotest.fail "expected Single ls"

let test_parser_cmd_with_args () =
  match parse_ok "ls -la /tmp" with
  | Ast.Exec (Ast.Single { argv; redirects = [] }) ->
      Alcotest.(check (list string)) "argv" ["ls"; "-la"; "/tmp"] argv
  | _ -> Alcotest.fail "expected Single with args"

let test_parser_pipe_simple () =
  match parse_ok "echo hi | wc -c" with
  | Ast.Exec (Ast.Pipe (Ast.Single { argv = ["echo"; "hi"]; _ },
                        Ast.Single { argv = ["wc"; "-c"]; _ })) -> ()
  | _ -> Alcotest.fail "expected pipe echo | wc"

let test_parser_pipe_triple () =
  match parse_ok "a | b | c" with
  | Ast.Exec (Ast.Pipe (Ast.Pipe (Ast.Single _, Ast.Single _), Ast.Single _)) -> ()
  | _ -> Alcotest.fail "expected nested pipe"

let test_parser_redirect_stdout () =
  match parse_ok "echo hi > out.txt" with
  | Ast.Exec (Ast.Single { argv = ["echo"; "hi"]; redirects = [Ast.Stdout_to "out.txt"] }) -> ()
  | _ -> Alcotest.fail "expected stdout redirect"

let test_parser_redirect_append () =
  match parse_ok "echo hi >> out.txt" with
  | Ast.Exec (Ast.Single { redirects = [Ast.Append_to "out.txt"]; _ }) -> ()
  | _ -> Alcotest.fail "expected append redirect"

let test_parser_redirect_stdin () =
  match parse_ok "cat < in.txt" with
  | Ast.Exec (Ast.Single { redirects = [Ast.Stdin_from "in.txt"]; _ }) -> ()
  | _ -> Alcotest.fail "expected stdin redirect"

let test_parser_redirect_stderr () =
  match parse_ok "cmd 2> err.txt" with
  | Ast.Exec (Ast.Single { redirects = [Ast.Stderr_to "err.txt"]; _ }) -> ()
  | _ -> Alcotest.fail "expected stderr redirect"

let test_parser_assign_with_quotes () =
  match parse_ok "alias l=\"ls -la\"" with
  | Ast.Exec (Ast.Single { argv = ["alias"; "l=ls -la"]; _ }) -> ()
  | _ -> Alcotest.fail "expected alias l=ls -la"

let test_parser_assign_var () =
  match parse_ok "FOO=bar" with
  | Ast.Assign ("FOO", "bar") -> ()
  | _ -> Alcotest.fail "expected Assign FOO=bar"

let test_parser_seq_fails_native () =
  Alcotest.(check bool) "; rejected by native parser"
    true (parse_err "echo a ; echo b")

let test_parser_empty () =
  match parse_ok "" with
  | Ast.Empty -> ()
  | _ -> Alcotest.fail "expected Empty"

let parser_tests = [
  Alcotest.test_case "simple cmd"      `Quick test_parser_simple_cmd;
  Alcotest.test_case "cmd with args"   `Quick test_parser_cmd_with_args;
  Alcotest.test_case "pipe simple"     `Quick test_parser_pipe_simple;
  Alcotest.test_case "pipe triple"     `Quick test_parser_pipe_triple;
  Alcotest.test_case "redirect stdout" `Quick test_parser_redirect_stdout;
  Alcotest.test_case "redirect append" `Quick test_parser_redirect_append;
  Alcotest.test_case "redirect stdin"  `Quick test_parser_redirect_stdin;
  Alcotest.test_case "redirect stderr" `Quick test_parser_redirect_stderr;
  Alcotest.test_case "assign w/ quote" `Quick test_parser_assign_with_quotes;
  Alcotest.test_case "assign var"      `Quick test_parser_assign_var;
  Alcotest.test_case "seq ; fails"     `Quick test_parser_seq_fails_native;
  Alcotest.test_case "empty input"     `Quick test_parser_empty;
]

(* ============================================================ *)
(* Eval                                                          *)
(* ============================================================ *)

let with_tmp_file f =
  let path = Filename.temp_file "ocash_test" ".out" in
  let r = f path in
  (try Sys.remove path with _ -> ());
  r

let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  s

let run_line env line =
  match Parser.parse line with
  | Ok stmt -> Lwt_main.run (Eval.eval_statement env stmt)
  | Error msg -> Alcotest.failf "parse failed: %s" msg

let test_eval_pipe_redirect () =
  with_tmp_file (fun out ->
    let env = Eval.create_env () in
    let code = run_line env (Printf.sprintf "echo hola | wc -c > %s" out) in
    Alcotest.(check int) "exit 0" 0 code;
    let content = read_file out in
    (* "hola\n" -> wc -c = 5 *)
    Alcotest.(check string) "5 bytes" "5\n" (String.trim content ^ "\n"))

let test_eval_cd_persists () =
  let env = Eval.create_env () in
  let orig = Sys.getcwd () in
  let _ = run_line env "cd /tmp" in
  let after = Sys.getcwd () in
  (* restaurar antes de assert para no contaminar siguientes tests *)
  Unix.chdir orig;
  Alcotest.(check bool) "cwd cambió a /tmp"
    true (after = "/tmp" || after = "/private/tmp")

let test_eval_redirect_writes_file () =
  with_tmp_file (fun out ->
    let env = Eval.create_env () in
    let code = run_line env (Printf.sprintf "echo abc > %s" out) in
    Alcotest.(check int) "exit 0" 0 code;
    Alcotest.(check string) "abc en archivo" "abc\n" (read_file out))

let test_eval_append () =
  with_tmp_file (fun out ->
    let env = Eval.create_env () in
    let _ = run_line env (Printf.sprintf "echo a > %s" out) in
    let _ = run_line env (Printf.sprintf "echo b >> %s" out) in
    Alcotest.(check string) "a y b" "a\nb\n" (read_file out))

let eval_tests = [
  Alcotest.test_case "pipe + redirect" `Quick test_eval_pipe_redirect;
  Alcotest.test_case "cd persists"     `Quick test_eval_cd_persists;
  Alcotest.test_case "redirect file"   `Quick test_eval_redirect_writes_file;
  Alcotest.test_case "append redirect" `Quick test_eval_append;
]

(* ============================================================ *)
(* Bash needs_bash                                              *)
(* ============================================================ *)

let nb input expected =
  let name = Printf.sprintf "needs_bash %S" input in
  Alcotest.test_case name `Quick (fun () ->
    Alcotest.(check bool) name expected (Bash.needs_bash input))

let bash_tests = [
  nb "ls" false;
  nb "echo hi | wc -l" false;
  nb "echo hi > out" false;
  nb "echo a && echo b" true;
  nb "echo a ; echo b" true;
  nb "if [ -f x ]; then echo y; fi" true;
  nb "for i in 1 2 3; do echo $i; done" true;
  nb "echo $(date)" true;
  nb "ls *.ml" true;
  nb "echo ~/file" true;
  nb "echo `whoami`" true;
  nb "echo {1..5}" true;
  nb "FOO=bar ls" true;
]

(* ============================================================ *)
(* History fuzzy_score                                          *)
(* ============================================================ *)

let test_fuzzy_prefix_bonus () =
  let prefix = History.fuzzy_score "git" "git status" in
  let middle = History.fuzzy_score "git" "do git stuff" in
  Alcotest.(check bool) "prefix > middle" true (prefix > middle)

let test_fuzzy_consecutive_bonus () =
  let consec    = History.fuzzy_score "abc" "abcdef" in
  let scattered = History.fuzzy_score "abc" "axbxcx" in
  Alcotest.(check bool) "consecutive > scattered" true (consec > scattered)

let test_fuzzy_no_match () =
  Alcotest.(check int) "-1 si no match" (-1) (History.fuzzy_score "xyz" "abc")

let test_fuzzy_empty () =
  Alcotest.(check int) "0 si query vacía" 0 (History.fuzzy_score "" "anything")

let history_tests = [
  Alcotest.test_case "prefix bonus"      `Quick test_fuzzy_prefix_bonus;
  Alcotest.test_case "consecutive bonus" `Quick test_fuzzy_consecutive_bonus;
  Alcotest.test_case "no match -> -1"    `Quick test_fuzzy_no_match;
  Alcotest.test_case "empty query -> 0"  `Quick test_fuzzy_empty;
]

(* ============================================================ *)
(* Ai strip_markdown                                            *)
(* ============================================================ *)

let test_strip_bash_fence () =
  Alcotest.(check string) "limpia ```bash"
    "ls -la"
    (Ai.strip_markdown "```bash\nls -la\n```")

let test_strip_sh_fence () =
  Alcotest.(check string) "limpia ```sh"
    "pwd"
    (Ai.strip_markdown "```sh\npwd\n```")

let test_strip_plain_fence () =
  Alcotest.(check string) "limpia ```"
    "echo hi"
    (Ai.strip_markdown "```\necho hi\n```")

let test_strip_dollar_prompt () =
  Alcotest.(check string) "limpia '$ '"
    "ls"
    (Ai.strip_markdown "$ ls")

let test_strip_hash_prompt () =
  Alcotest.(check string) "limpia '# '"
    "ls"
    (Ai.strip_markdown "# ls")

let test_strip_multiline_first () =
  Alcotest.(check string) "primera línea no vacía"
    "echo primera"
    (Ai.strip_markdown "\n\necho primera\necho segunda")

let test_strip_plain () =
  Alcotest.(check string) "sin cambios"
    "ls -la"
    (Ai.strip_markdown "ls -la")

let ai_tests = [
  Alcotest.test_case "strip ```bash"    `Quick test_strip_bash_fence;
  Alcotest.test_case "strip ```sh"      `Quick test_strip_sh_fence;
  Alcotest.test_case "strip ```"        `Quick test_strip_plain_fence;
  Alcotest.test_case "strip $ prompt"   `Quick test_strip_dollar_prompt;
  Alcotest.test_case "strip # prompt"   `Quick test_strip_hash_prompt;
  Alcotest.test_case "multiline first"  `Quick test_strip_multiline_first;
  Alcotest.test_case "plain unchanged"  `Quick test_strip_plain;
]

(* ============================================================ *)
(* Autocomplete (vía History.find_prefix, parte síncrona pura)  *)
(* ============================================================ *)

let test_history_prefix_returns_suffix () =
  (* No tocar el archivo en disco: manipulamos la lista directamente. *)
  let saved = History.all () in
  History.entries := ["git status"; "git commit -m fix"];
  let result = History.find_prefix "git st" in
  History.entries := saved;
  match result with
  | Some s -> Alcotest.(check string) "git status" "git status" s
  | None -> Alcotest.fail "expected match"

let test_history_prefix_no_match () =
  let saved = History.all () in
  History.entries := ["ls"; "pwd"];
  let result = History.find_prefix "xyzzy" in
  History.entries := saved;
  Alcotest.(check bool) "no match" true (result = None)

let test_history_prefix_empty () =
  Alcotest.(check bool) "empty prefix -> None"
    true (History.find_prefix "" = None)

let autocomplete_tests = [
  Alcotest.test_case "prefix match → completo" `Quick test_history_prefix_returns_suffix;
  Alcotest.test_case "no match"                 `Quick test_history_prefix_no_match;
  Alcotest.test_case "empty prefix"             `Quick test_history_prefix_empty;
]

(* ============================================================ *)
(* Rag tokenize                                                 *)
(* ============================================================ *)

let test_rag_lowercase () =
  Alcotest.(check (list string)) "lowercase"
    ["hello"; "world"]
    (Rag.tokenize "Hello World")

let test_rag_non_alnum_split () =
  Alcotest.(check (list string)) "split punctuation"
    ["foo"; "bar"; "baz"]
    (Rag.tokenize "foo-bar.baz")

let test_rag_min_len_2 () =
  Alcotest.(check (list string)) "drop len<2"
    ["foo"; "bar"]
    (Rag.tokenize "a foo b bar c")

let test_rag_keeps_underscore_digits () =
  Alcotest.(check (list string)) "underscore y dígitos"
    ["my_var"; "v2"]
    (Rag.tokenize "my_var v2")

let test_rag_empty () =
  Alcotest.(check (list string)) "vacío" [] (Rag.tokenize "")

let rag_tests = [
  Alcotest.test_case "lowercase"          `Quick test_rag_lowercase;
  Alcotest.test_case "split non-alnum"    `Quick test_rag_non_alnum_split;
  Alcotest.test_case "len>=2"             `Quick test_rag_min_len_2;
  Alcotest.test_case "underscore/digits"  `Quick test_rag_keeps_underscore_digits;
  Alcotest.test_case "empty"              `Quick test_rag_empty;
]

(* ============================================================ *)
(* Runner                                                        *)
(* ============================================================ *)

let () =
  Alcotest.run "ocash" [
    "parser",       parser_tests;
    "eval",         eval_tests;
    "bash",         bash_tests;
    "history",      history_tests;
    "ai",           ai_tests;
    "autocomplete", autocomplete_tests;
    "rag",          rag_tests;
  ]
