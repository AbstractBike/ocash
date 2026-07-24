# Changelog

All notable changes to **ocash** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- AI backends `gemini` (Google Gemini, OpenAI-compat endpoint) and `mistral`
  (Mistral API), selected with `OCASH_AI_BACKEND`; keys via `GEMINI_API_KEY` /
  `MISTRAL_API_KEY`, model override via `OCASH_AI_MODEL`.

### Fixed
- The `openai` backend now sends the required `model` field (default
  `gpt-4o-mini`); previously requests to the real OpenAI API were rejected.

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
