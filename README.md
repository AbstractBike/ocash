# ocash — interactive OCaml shell with AI, Ansible & a JIT unikernel

[![OCaml](https://img.shields.io/badge/OCaml-%E2%89%A5%204.14-orange.svg)](#building-from-source)
[![Tests](https://img.shields.io/badge/tests-48%20passing-brightgreen.svg)](#testing)

`ocash` is a Unix shell written in OCaml that aims to be a drop-in interactive
replacement for `bash`: it parses pipes, redirects, assignments and a wide set
of builtins natively, and transparently falls back to `bash -c` for anything
else (control flow, command substitution, globs, heredocs). On top of that it
ships an AI assistant with five interchangeable backends, an embedded OCaml
toploop, an `ansible` builtin, and a companion JIT "unikernel" that compiles
OCaml handlers on the fly. The goal is a shell that feels like `bash` when you
want it to, like `ocaml` when you need it to, and like `fish` (ghost-text,
Ctrl-R fuzzy picker) while you type.

## Demo

```text
$ ocash

  ╔═══════════════════════════╗
  ║   ocash — OCaml Shell     ║
  ║   + AI (multi-backend)    ║
  ║   + Ansible builtin       ║
  ║   + OCaml toploop (ml:)   ║
  ╚═══════════════════════════╝
  habla: <text>    -> AI mode
  <text> ç         -> AI with history context
  ml:    <expr>    -> evaluate OCaml in the embedded toploop
  ansible help     -> Ansible builtin help
  ocaml help       -> OCaml compiler builtin help

  ✓ AI activa [local (llama-server) @ http://localhost:8080]

user [AI] ~/ocash (main) {14} $ habla: cuántas líneas de OCaml tengo
  -> find . -name "*.ml" -not -path "./_build/*" | xargs wc -l | tail -1     # cyan
  ¿ejecutar? [S/n/e] s
  3214 total

user [AI] ~/ocash (main) {14} $ ml: List.map (fun x -> x * x) [1;2;3;4]
- : int list = [1; 4; 9; 16]

user [AI] ~/ocash (main) {14} $ ansible ping web
  ocash[ansible]: ping -> web
  web01 | SUCCESS => { "ping": "pong" }

user [AI] ~/ocash (main*) {14} $ gst<Tab>       # ghost-text completes from history
user [AI] ~/ocash (main*) {14} $ git status     # accepted suggestion in dim grey

user [AI] ~/ocash (main*) {14} $ <Ctrl-R>git
  ┃ git
  ▶ git status
    git stash pop
    git switch main
    (Enter selects, Esc cancels)
```

## Features

### Shell

- Native parser (Angstrom) for pipes, I/O redirects (`>`, `>>`, `<`, `2>`),
  assignments with quoting, background `&`
- Automatic `bash -c` fallback for control flow (`if`, `for`, `while`, `case`),
  command substitution (`$(...)`, backticks), `&&`/`||`/`;`, heredocs, globs,
  tilde, brace expansion, parameter expansion — environment is synchronised
  both ways
- Builtins: `cd`, `exit`, `export`, `echo`, `pwd`, `history`, `hsearch`, `set`,
  `alias` / `unalias`, `source` / `.`, `jobs`, `fg`, `bg`, `ansible`, `ocaml`
- `time <cmd>` prefix that wraps the full pipeline and reports real/user/sys
- `~/.ocashrc` is sourced on startup; `~/.ocash/history` is persistent
- Prompt with `$USER`, `$cwd`, git branch + dirty marker, file count, AI badge
- Job control: `&` puts a pipeline in the background, `jobs` lists them,
  `fg %n` / `bg %n` resume them, `WUNTRACED` reports stopped processes
- Signal handling for `SIGINT` / `SIGQUIT` / `SIGTSTP`: ocash itself survives
  Ctrl-C/Ctrl-\\/Ctrl-Z, foreground children die through the TTY's default
  handlers (no `SIG_IGN` leak through `execve`)
- TTY mode uses `lambda-term`; non-TTY mode falls back to a plain stdin loop
  for scripts and CI

### AI assistant (multi-backend)

- Five backends, selected with `OCASH_AI_BACKEND`:
  - `local` — HTTP to `llama-server` (OpenAI-compatible, default)
  - `claude` — subprocess to the `claude` CLI
  - `codex` — subprocess to the `codex` CLI
  - `anthropic` — HTTPS to `api.anthropic.com`
  - `openai` — HTTPS to `api.openai.com`
- Triggers:
  - Prefixes `habla:`, `ai:`, `?:`, `haz:`, `make:`, `di:` send the rest of
    the line to the model
  - Trailing `ç` (or ` ç`) sends the line plus the last 8 history entries as
    context
- Streaming SSE for `local`, `openai`, `anthropic` (`OCASH_AI_STREAM=0` to
  disable); auto-detects OpenAI vs. Anthropic event format
- Multi-turn conversation persisted at `~/.ocash/conv.json` (trimmed to the
  last 6 turns)
- Self-correction: when a command exits non-zero or an OCaml phrase fails to
  type-check, ocash offers to ask the model for a fix and previews it before
  executing
- Optional RAG (`OCASH_RAG=1`): augments queries with the most relevant
  snippets from the current working directory using a BM25-ish tokenizer
- Confirmation flow: `[S]/n/e` lets you execute, cancel, or edit the proposal
  before running it

### Autocomplete (ghost text + Ctrl-R)

- Fish-style inline ghost text in dim grey behind the cursor: `Tab` accepts
- Suggestion source: history-prefix match first (instant, offline); falls
  back to the AI backend if no history match and a GPU is detected (or the
  backend is a fast remote one)
- Live redraw — the suggestion appears as soon as the model returns, without
  waiting for the next keystroke
- Ctrl-R opens a fzf-style inline fuzzy picker over the persistent history
  (Up/Down or Ctrl-P/Ctrl-N, Enter accepts, Esc/Ctrl-C/Ctrl-G cancels)
- `hsearch <query>` builtin prints fuzzy matches non-interactively

### Embedded OCaml

- `ml: <expr>` evaluates an OCaml phrase in-process via
  `compiler-libs.toplevel`; no external `ocaml` invocation
- `ocaml` builtin:
  - `ocaml eval "<phrase>"` — inline evaluation
  - `ocaml use foo.ml` — like `#use`
  - `ocaml compile foo.ml` — produces a `.cmo` bytecode object
  - `ocaml build foo.ml -p lwt,cohttp -o app` — links a native binary via
    `ocamlfind`
  - `ocaml help`
- Self-correction wired into `ml:` errors too: ocash will pipe the compiler's
  error message back to the AI and offer the suggested rewrite

### Ansible builtin

- `ansible playbook <file.yml> [--limit H] [--tags T1,T2] [-e K=V ...]`
- `ansible ping [hosts]`
- `ansible run <hosts> <module> [args...]` — ad-hoc execution
- `ansible hosts [pattern]`, `ansible inventory`, `ansible help`
- Picks up `OCASH_ANSIBLE_INVENTORY` automatically and forwards it as `-i`
- Wraps the real `ansible` / `ansible-playbook` / `ansible-inventory`
  binaries, so any `pip install ansible` works out of the box

### Companion unikernel — `ocash-ai-unikernel` (JIT)

- HTTP server speaking the OpenAI chat API on `:8081`; ocash points at it via
  `OCASH_AI_URL`
- On cache hit: a previously compiled OCaml handler answers in microseconds
  without contacting the LLM
- On cache miss: the upstream `llama-server` is asked to **generate** an
  OCaml handler of type `string -> string option`, the result is parsed and
  type-checked via `Toploop.execute_phrase`, registered through
  `Uni.register`, and persisted to `~/.ocash/handlers/h_NNN.ml`
- AST sandbox before evaluation: rejects any reference to `Sys`, `Unix`,
  `Stdlib`/`Pervasives`, `Toploop`, `Dynlink`, `Marshal`, `Obj`, `Mutex`,
  `Thread`, `Domain`, `Scanf`, plus identifiers like `open_in`, `open_out`,
  `exit`, `at_exit`, `read_line`; only `String`, `List`, `Printf`,
  `Filename`, `Int`, `Option`, `Char`, `Bool`, `Uni` are whitelisted. PPX
  extensions and toploop directives (`#use`, `#load`) are rejected too.
  Blocked handlers are kept as `*.banned` for audit
- Endpoints: `/v1/chat/completions`, `/health`, `/stats`, `/metrics`
  (Prometheus text exposition: queries total, cache hits/misses, LLM
  failures, handlers compiled, compile errors, cache size, uptime, last
  query latency)
- Metrics counters are persisted to `~/.ocash/metrics.txt` across restarts
- A MirageOS Fase 2 port lives in [`unikernel/mirage/`](unikernel/mirage/README.md):
  scaffolding is in place but `compiler-libs.toplevel` + `Dynlink` are not
  available on Solo5 today — that document discusses the blocker and the
  five alternatives evaluated

## Quickstart

```bash
# 1. Install system deps and OCaml libs
bash scripts/setup.sh

# 2. Pull the model from the GitHub release mirror (~940 MB)
bash scripts/download_model.sh

# 3. Start the local LLM (in another terminal)
llama-server -m ~/.local/share/ocash/model.gguf \
  --port 8080 --ctx-size 4096 -ngl 99

# 4. Launch ocash
./_build/default/bin/main.exe
```

Optional: also start the JIT unikernel and point ocash at it instead of the
raw LLM, so you benefit from the OCaml handler cache:

```bash
PORT=8081 UPSTREAM_LLM=http://localhost:8080 \
  ./_build/default/unikernel/uni.exe &
OCASH_AI_URL=http://localhost:8081 ./_build/default/bin/main.exe
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OCASH_AI_BACKEND` | `local` | Backend: `local`, `claude`, `codex`, `anthropic`, `openai` |
| `OCASH_AI_URL` | `http://localhost:8080` | Endpoint for the `local` and `openai` backends |
| `OCASH_AI_MODEL` | `claude-haiku-4-5-20251001` | Model name for the API backends |
| `OCASH_AI_STREAM` | `1` | `1`/`0` — enable SSE streaming on `local` and API backends |
| `OCASH_RAG` | (unset) | `1` to augment AI queries with snippets from the cwd |
| `ANTHROPIC_API_KEY` | (unset) | Required for `OCASH_AI_BACKEND=anthropic` |
| `OPENAI_API_KEY` | (unset) | Required for `OCASH_AI_BACKEND=openai` |
| `OCASH_ANSIBLE_INVENTORY` | (unset) | Default inventory file forwarded as `-i` to the `ansible` builtin |
| `OCASH_HANDLERS_DIR` | `~/.ocash/handlers` | Where the unikernel persists compiled handlers |
| `PORT` | `8081` | Port the unikernel listens on |
| `UPSTREAM_LLM` | `http://localhost:8080` | LLM URL the unikernel calls on cache miss |

See also [`man/ocash.1`](man/ocash.1) and
[`man/ocash-ai-unikernel.1`](man/ocash-ai-unikernel.1).

## Architecture

```
                                       ┌──────────────────────────┐
       prefix dispatcher               │   ~/.ocashrc (sourced)   │
       (habla:/ai:/ç/ml:)              │   ~/.ocash/history       │
              │                        │   ~/.ocash/conv.json     │
              ▼                        └──────────────────────────┘
   ┌──────────────────────┐                       ▲
   │     bin/main.ml      │  reads/writes ────────┘
   │  REPL + signals      │
   └──────────┬───────────┘
              │
   ┌──────────┴──────────────────────────────────────────────┐
   │                                                          │
   ▼                       ▼                                  ▼
┌──────────┐         ┌────────────┐                  ┌────────────────┐
│ lib/ast  │         │ lib/parser │ (Angstrom)       │  lib/readline  │
└────┬─────┘         └─────┬──────┘                  │  lambda-term + │
     │                     │                         │  ghost text +  │
     ▼                     ▼                         │  Ctrl-R picker │
┌────────────────┐ ┌──────────────┐                  └───────┬────────┘
│ lib/eval       │ │  lib/bash    │                          │
│ fork/exec,     │ │  fallback    │                          │ uses
│ pipes, jobs,   │ │  classifier  │                          ▼
│ aliases,       │ └──────────────┘                  ┌──────────────────┐
│ source, time   │                                   │ lib/autocomplete │
└──┬─────────────┘                                   │ history-first,   │
   │                                                 │ AI fallback      │
   ├──> lib/ansible      (Ansible CLI wrapper)       └────────┬─────────┘
   ├──> lib/ocaml_eval   (Toploop in-process)                 │
   ├──> lib/completion   (paths + builtins)                   │
   ├──> lib/history      (persistent + fuzzy)                 │
   ├──> lib/rag          (BM25 over cwd snippets)             │
   └──> lib/ai           (5 backends, SSE, multi-turn) ◄──────┘
                              │
                              ▼
                  ┌───────────────────────┐        ┌──────────────────────┐
                  │ unikernel/uni.ml      │  miss  │  llama-server :8080  │
                  │ /v1/chat/completions  │ ──────▶│  + Qwen2.5-OCamler   │
                  │ /metrics  /stats      │ ◀──────│  generates handler   │
                  │ /health               │        └──────────────────────┘
                  │                       │
                  │  Sandbox.validate ─┐  │
                  │  Toploop.execute   │  │  hit
                  │  Uni.register      │  │ ────▶ µs response
                  │  persist to        │  │
                  │  ~/.ocash/handlers │  │
                  └───────────────────────┘
```

## Building from source

```bash
opam install --deps-only .
dune build
./_build/default/bin/main.exe --version
```

Requires `ocaml >= 4.14`, `dune >= 3.12`, plus `lwt`, `lambda-term`,
`angstrom`, `cohttp-lwt-unix`, `yojson`, `conf-libev`. The toploop pulls in
`compiler-libs.toplevel`, which is part of any standard OCaml distribution.

## Packaging

- **opam**: a manifest is shipped as [`ocash.opam`](ocash.opam) — `opam pin
  add ocash .` or publish to your own opam repository.
- **Homebrew**: the formula at [`packaging/ocash.rb`](packaging/ocash.rb)
  builds both binaries and registers `ocash-ai-unikernel` as a
  launchd / systemd service (`brew tap AbstractBike/ocash && brew install
  --HEAD ocash`).
- **Docker**: the multi-stage [`Dockerfile`](Dockerfile) produces a slim
  `ubuntu:24.04` image with `ocash`, `ocash-ai-unikernel`, `ansible` and the
  required shared libs:

  ```bash
  docker build -t ocash .
  docker run -it --rm -v "$PWD:/workspace" ocash
  ```

- **Fatbin**: [`scripts/build_fatbin.sh`](scripts/build_fatbin.sh) bundles
  the ocash binary (bytecode + embedded `ocamlrun` + stdlib +
  `compiler-libs`, ~6 MB), optionally `llama-server` and the GGUF model,
  with a `launch.sh` wrapper — `tar czf ocash.tgz -C dist .` and ship it.

## Testing

The test suite is built with `alcotest` and covers 48 cases across 7
modules (parser, eval, bash classifier, history fuzzy scoring, AI
markdown stripping, autocomplete prefix logic, RAG tokenizer):

```bash
dune runtest
```

Source: [`test/test_ocash.ml`](test/test_ocash.ml).

## Roadmap

- [x] Live ghost-text redraw without waiting for a keystroke
- [x] AST sandbox for JIT handlers (whitelist + extension/directive rejection)
- [x] Prometheus `/metrics` endpoint and persistent counters on the unikernel
- [ ] MirageOS Fase 2 with build-time precompilation of handlers (Option A
      in [`unikernel/mirage/README.md`](unikernel/mirage/README.md))
- [ ] Additional AI backends (Gemini, Mistral)
- [ ] Full POSIX job control (`setpgid` / `tcsetpgrp` / SIGTTOU handling)
- [ ] Defence-in-depth sandbox for handlers (cgroup v2 + seccomp-bpf)

