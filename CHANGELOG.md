# Changelog

All notable changes to **ocash** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed (interactive)
- Tab completion never inserted anything: ocash overrode lambda-term's
  `complete` (which performs the insertion) with code that only filled the
  hidden candidate list. It now completes commands (builtins, aliases, PATH)
  in command position and paths elsewhere, including subdirectories
  (`src/fo`), `~/`, a trailing `/` on directories, and hides dotfiles unless
  the prefix starts with `.`. PATH is no longer scanned on every prompt.
- Ctrl-R picker / `hsearch` results were sorted alphabetically instead of by
  match score, and de-duplication ran after truncation (fewer results than
  the limit).
- AI ghost-text dropped the leading space of a suggestion (`git` +
  ` status` became `gitstatus`).
- Prompt `~` abbreviation matched partial path components
  (`/home/username` with `HOME=/home/user` showed `~name`) and an empty
  `HOME` turned every path into `~...`.
- `ansible` and `ocaml` builtins shadowed the real CLIs: unknown subcommands
  (`ansible all -m ping`, `ocaml script.ml`, `ocaml -version`) are now passed
  to the binary in PATH.

### Fixed
- Single quotes now prevent variable expansion (`echo '$HOME'` printed the
  home directory); double quotes honour `\"`, `\$`, `\\`; unquoted `\c` is
  a literal `c`. A `$` not followed by a name stays literal (`sed 's/$/x/'`
  used to lose it).
- Redirect targets are expanded (`> $HOME/x` created a file literally named
  `$HOME/x`).
- `bash -c` fallback now syncs the working directory and exported variables
  back into ocash: `cd ~`, `cd $(...)`, `export X=$(...)` and
  `source ~/...` had no effect before.
- Aliases are resolved before builtin dispatch, so `alias ..='cd ..'` changes
  ocash's own cwd instead of a forked child's. Aliases are also expanded
  before handing a line to bash, and alias values with quotes are tokenised
  properly.
- `$?` reflects the last command in every path (native, bash fallback,
  `time`); previously it was not expanded natively and bash always saw 0.
  The self-correction prompt no longer fires on a stale exit code.
- Failing redirects (`cat < missing`, `echo x > /no/dir/f`) print a clean
  error and return 1 instead of a raw `Unix.Unix_error` exception; builtin
  redirects already applied are rolled back.
- `cmd &` with an unknown command no longer prints the error twice and leaves
  a phantom job.
- Exit status of signal-killed processes is `128 + signal` (was always 130).
- AI self-corrections are run through the full line evaluator, so fixes using
  `&&`, `;` or `$(...)` are no longer silently dropped.
- `source` / `~/.ocashrc` lines go through the same evaluator as typed
  lines: lines with `&&`, `$(...)`, `~` or globs used to be dropped silently
  or run without tilde expansion. The rc path is quoted.

### Added
- `cd -`, `PWD`/`OLDPWD` maintenance, `unset`, `echo -n`, `$$`.
- Finished background jobs are reported before the next prompt.
- 26 new tests (74 total).

## [0.0.1] - 2026-05-14

First tagged release of `ocash`, an OCaml-native interactive shell with embedded
AI assistance, hybrid bash compatibility, and an experimental MirageOS unikernel
backend.

### Added

#### Shell core
- Initial OCaml shell with builtin Ansible-style commands and local AI integration (`15a0359`).
- Embedded OCaml compiler: toploop plus `compile`/`build` builtins for evaluating and producing native binaries from inside the shell (`745e1a3`).
- Hybrid bash compatibility: when ocash encounters non-native constructs (`if`, `for`, `while`, `$()`, process substitution, etc.) it transparently falls back to `bash -c` (`e8a4422`).
- Non-TTY mode for scripting and CI pipelines (`adf098b`).
- POSIX signal handling with full job control: `Ctrl-C`, `jobs`, `fg`, `bg`, and background `&` operator (`f264715`).
- User configuration: aliases, `time` builtin, `~/.ocashrc` startup file, and a git-status segment in the prompt (`030304e`).
- `fatbin` packaging: static profile and packaging script to produce a self-contained binary (`479a9eb`).
- Distribution targets: opam package, Docker image, and Homebrew formula (`e3cc38a`).
- Alcotest unit-test suite, GitHub Actions CI workflow, and man pages (`0b3f8bd`).

#### AI integration
- Bundled Qwen2.5-OCamler GGUF model fetched via Git LFS, plus `.gitattributes` LFS config for `*.gguf` and `models/` (`3cfc351`, `5575810`, `bceac36`).
- End-to-end verified AI pipeline with associated fixes (`eae9965`).
- Multi-backend AI selector via `OCASH_AI_BACKEND`: local `llama-server`, Claude CLI, Codex CLI, Anthropic API, OpenAI API (`e6b75ac`).
- `ç` suffix mode: append `ç` to a line to ask the AI with command-history context (`e6b75ac`).
- AI-driven Tab autocomplete inside lambda-term (`3926d2f`).
- Fish/zsh-style inline ghost-text autocomplete suggestions (`dcda78e`).
- Live ghost-text redraw and `Ctrl-R` fuzzy history picker (`d61bf81`).
- Persistent shell history with fuzzy search, multi-turn AI conversations, and self-correction loop (`bb50264`).
- `/metrics` Prometheus endpoint, streaming AI responses, and `ml:` self-correct mode (`f130d8c`).
- Streaming Anthropic backend with persistent multi-turn state (`7a234e2`).
- RAG context-aware prompting that pulls relevant local context into AI queries (`e3cc38a`).
- `habla:` natural-language-to-shell mode with confirmation before execution (covered by the multi-backend work above).

#### Unikernel / MirageOS
- `ocash-ai-unikernel` Phase 1: standalone Linux binary that JIT-compiles natural-language requests into shell commands (`9ea8403`).
- MirageOS Phase 2 scaffolding plus a blocker document describing remaining work (`5c43927`).

### Changed
- Friendlier error message in model-download script when the network is blocked by a firewall (`d567459`).
- `bin/dune` switched to the plural `executables`/`names` form so tests are easier to add later (`5dcc6f2`).

### Fixed
- Project now compiles and runs on OCaml 4.14 with dune 3.14 (`3b6cd2a`).
- Pipes were broken because builtins ignored the stdin/stdout file descriptors passed in by the pipeline; quoting in variable assignments was also incorrect (`845ed83`).
- Sandbox AST in the unikernel rejected `Some`/`None`/`Ok`/`Error` constructors, causing every handler to fail (`75ef59c`).
- `SIGINT` killed ocash in non-TTY mode due to an uncaught `Sys_error` from `input_line` (`cba8c9a`).

### Security
- Unikernel handler validation via an `Ast_iterator` whitelist: `Sys`, `Unix`, `Obj`, and `exit` are blocked from user-supplied OCaml fragments (`5c43927`).

### Misc
- Ignore `.claude/` worktrees and local settings (`ce8bb12`).

[Unreleased]: https://github.com/ocash/ocash/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/ocash/ocash/releases/tag/v0.0.1
