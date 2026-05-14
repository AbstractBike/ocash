# ocash — Shell interactiva en OCaml con AI + Ansible

Shell Unix escrita en OCaml con tres superpoderes:
1. Integracion del modelo Qwen2.5-OCamler-1.5B para comandos en lenguaje natural.
2. Biblioteca/builtin **Ansible** integrado (`ansible playbook ...`, `ansible ping all`).
3. Pipes, redirects, expansion de variables, history, completion.

## Quickstart

```bash
# 1. Setup y compilar
bash scripts/setup.sh

# 2. Descargar modelo AI (~986 MB)
bash scripts/download_model.sh

# 3. Iniciar servidor AI (en otra terminal)
llama-server -m ~/.local/share/ocash/model.gguf \
  --port 8080 --ctx-size 4096 -ngl 99

# 4. Lanzar la shell
./_build/default/bin/main.exe
```

## Uso del modo AI

Antepon `habla:`, `ai:`, `?:`, `haz:`, `make:` o `di:`:

```
user [AI] ~/proyecto $ habla: cuantas lineas de OCaml tengo
> find . -name "*.ml" | xargs wc -l | tail -1
¿ejecutar? [S/n/e] s
```

Respuestas: `s` ejecuta, `n` cancela, `e` permite editar antes de ejecutar.

## Builtin Ansible

`ocash` integra un wrapper sobre el CLI de Ansible. Ejemplos:

```
ansible playbook deploy.yml --limit web --tags db -e env=prod
ansible ping all
ansible run web shell "uptime"
ansible hosts web
ansible inventory
ansible help
```

Variable de entorno: `OCASH_ANSIBLE_INVENTORY=/path/to/hosts.ini`.

Tambien funciona en modo AI:

```
habla: ejecutar playbook site.yml en hosts de produccion
> ansible playbook site.yml --limit prod
```

## Compatibilidad con bash

`ocash` parsea nativamente un subset (pipes, redirects, assigns simples,
expansión de `$VAR`/`${VAR}`). Para cualquier construcción fuera de ese
subset (control flow, `$()`, `&&`/`||`/`;`, glob, tilde, `[[ ]]`,
heredocs, brace expansion, funciones, case) delega a `bash -c`
automáticamente. Compatibilidad efectiva: 100%.

```
user $ for i in 1 2 3; do echo $i; done    # → bash -c
user $ if [ -f foo ]; then echo si; fi     # → bash -c
user $ ls *.ml | head -3                   # → bash -c (glob)
user $ echo $(date +%Y)                    # → bash -c (cmd sub)
user $ ls -la /tmp                         # → nativo (rápido)
user $ MY=hola; bash -c 'echo $MY'         # MY se sincroniza a env
```

Lo nativo es más rápido (sin fork+exec de bash); el fallback se
activa solo cuando es necesario.

## ocash-ai-unikernel (JIT de NL→shell)

`unikernel/` contiene un servidor HTTP que **compila handlers OCaml
en runtime** generados por el LLM. La primera vez que llega una query
nueva se invoca al LLM para producir un handler `string -> string option`,
se compila vía `compiler-libs.toplevel`, se cachea, y se persiste en
`~/.ocash/handlers/h_NNN.ml`. Queries similares posteriores hit el cache
en microsegundos sin tocar el LLM.

```bash
# Arquitectura: ocash → unikernel(8081, JIT) → llama-server(8080, LLM)
dune build unikernel/uni.exe
llama-server -m models/model.gguf --port 8080 &
PORT=8081 UPSTREAM_LLM=http://localhost:8080 \
  ./_build/default/unikernel/uni.exe &
OCASH_AI_URL=http://localhost:8081 ./_build/default/bin/main.exe
```

Ver `unikernel/README.md` para detalles y plan de port a MirageOS.

## OCaml embebido

`ocash` lleva el compilador OCaml dentro (`compiler-libs.toplevel` +
`ocamlrun` enlazado en el ejecutable). Evalúa expresiones in-process
sin invocar `ocaml` externo:

```
user [AI] ~/proyecto $ ml: List.map succ [1;2;3]
- : int list = [2; 3; 4]

user [AI] ~/proyecto $ ml: let cube x = x * x * x ;; cube 5
val cube : int -> int = <fun>
- : int = 125
```

Builtin `ocaml` para compilar archivos:

```
ocaml eval "Printf.printf %d (1+1)"
ocaml use foo.ml                       # equivalente a #use
ocaml compile foo.ml                   # bytecode .cmo (in-process)
ocaml build foo.ml -p lwt,cohttp -o app   # binario nativo vía ocamlfind
ocaml help
```

## Fatbin (binario único distribuible)

```bash
# Genera dist/ con binario estático + (opcional) llama-server + modelo
bash scripts/build_fatbin.sh

# Lanza todo desde el bundle
./dist/launch.sh

# Empaquetar para distribuir
tar czf ocash-fatbin.tar.gz -C dist .
```

El binario es bytecode + `ocamlrun` embebido + stdlib + `compiler-libs`
para el toploop. Pesa ~6 MB y solo depende de `libc`/`libssl`/`libev`
del sistema (típicamente presentes en cualquier Linux).

Para 100% estático sin libs de sistema: musl + libssl/libev estáticas
(complicado; fuera del scope por defecto).

Para link 100% estático: usa un switch opam con musl + flambda
(`opam switch create musl 4.14.1+musl+static`) y `apt install libev-dev`.

## Variables de entorno

| Variable | Default | Descripcion |
|---|---|---|
| `OCASH_AI_URL` | `http://localhost:8080` | Endpoint del llama-server |
| `OCASH_ANSIBLE_INVENTORY` | (ninguno) | Inventory por defecto para el builtin |

## Arquitectura

```
bin/main.ml         REPL principal
lib/ast.ml          AST de la shell
lib/parser.ml       Parser Angstrom (pipes, redirects, assigns)
lib/eval.ml         Evaluador Lwt (fork/exec, redirects, builtins)
lib/ansible.ml      Wrapper Ansible CLI
lib/ocaml_eval.ml   Toploop OCaml embebido + compile/build
lib/ai.ml           Cliente HTTP llama-server
lib/completion.ml   Completion de paths y comandos
lib/readline.ml     UI lambda-term + prompt + parsing NL
```

