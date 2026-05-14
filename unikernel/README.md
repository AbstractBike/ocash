# ocash-ai-unikernel (Fase 1: Linux binary)

Servidor HTTP **JIT** que compila handlers OCaml en runtime.

## Arquitectura

```
ocash (puerto X)
  │
  ▼
unikernel :8081
  ├── 1. dispatch → cache (List de string→string option compilados)
  │   └─ HIT  → handler aplica regla OCaml, retorna en µs (offline)
  │
  └── 2. MISS → LLM upstream :8080 (llama-server + Qwen2.5-OCamler)
                Prompt: "genera handler OCaml para esta intención"
                ├── LLM responde código OCaml
                ├── Toploop.execute_phrase compila in-process
                ├── handler registrado vía Uni.register
                ├── persistido en ~/.ocash/handlers/h_NNN.ml
                └── handler aplicado → comando shell
```

Tras N queries el cache cubre los patrones comunes; el LLM solo se
invoca para intenciones nuevas. Los `.ml` persistidos sobreviven
reinicios (se recompilan al arranque).

## Quickstart

```bash
# 1. Compilar
dune build unikernel/uni.exe

# 2. Arrancar llama-server con el modelo (LLM upstream)
llama-server -m models/model.gguf --port 8080 --ctx-size 2048 &

# 3. Arrancar el unikernel JIT
PORT=8081 UPSTREAM_LLM=http://localhost:8080 \
  ./_build/default/unikernel/uni.exe &

# 4. Apuntar ocash al unikernel (NO al llama-server directo)
OCASH_AI_URL=http://localhost:8081 ./_build/default/bin/main.exe
```

## API

| Endpoint | Método | Body | Respuesta |
|---|---|---|---|
| `/health` | GET | - | `ok` |
| `/stats` | GET | - | `handlers cached: N` |
| `/v1/chat/completions` | POST | OpenAI chat format | OpenAI chat format con shell command |

## Handlers generados por el LLM

Ejemplo (`~/.ocash/handlers/h_000.ml`):

```ocaml
let handler q =
  let q = String.lowercase_ascii q in
  let words = String.split_on_char ' ' q in
  let starts = List.exists (fun w ->
    w = "lista" || w = "muestra" || w = "enumera") words in
  if not starts then None
  else
    let n = List.find_map (fun w -> int_of_string_opt w) words in
    let ext = List.find_map (fun w ->
      if String.length w > 1 && w.[0] = '.' then
        Some (String.sub w 1 (String.length w - 1))
      else None) words in
    let dir = (* ... *) in
    match ext with
    | None -> None
    | Some e ->
        let head = match n with
          | Some k -> Printf.sprintf " | head -%d" k
          | _ -> "" in
        Some (Printf.sprintf "find %s -name \"*.%s\"%s" dir e head)
let () = Uni.register "lista-archivos-ext" handler
```

El handler **rechaza** queries fuera de su patrón devolviendo `None`,
lo que permite que el dispatch pruebe el siguiente handler. Pattern
matching y composición naturales gracias a OCaml.

## Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `PORT` | `8081` | Puerto del servidor unikernel |
| `UPSTREAM_LLM` | `http://localhost:8080` | URL del llama-server |
| `OCASH_HANDLERS_DIR` | `$HOME/.ocash/handlers` | Persistencia de handlers |

## Estado actual / próximos pasos

- ✅ HTTP server cohttp-lwt-unix compatible OpenAI
- ✅ Cache in-memory de handlers compilados
- ✅ JIT vía `compiler-libs.toplevel`
- ✅ Persistencia en `~/.ocash/handlers/`
- ✅ Recarga de handlers al arranque
- ✅ Integrado con ocash existente
- ⏳ **Fase 2 (futuro): port a MirageOS** (Solo5 hvt o spt) para
  bare-metal/KVM. Requiere reemplazar:
  - `cohttp-lwt-unix` → `cohttp-mirage`
  - `Unix.{mkdir,open,read}` → `Mirage_kv`
  - Persistencia → bloque virtio o KV store
  - Toploop con Dynlink: ⚠️ no estándar en Mirage; se necesita
    cargar handlers como `cmxs` o usar el AST interpretado.

## Limitaciones conocidas

- La calidad de los handlers depende del LLM upstream. Qwen2.5-1.5B
  a veces produce handlers con bugs (ej. usa la query como path en
  `find` en vez del directorio correcto).
- Los handlers se ejecutan en el mismo proceso del unikernel: un
  handler malicioso o con bug podría tirar el server. Sandboxing
  a futuro.
- El cache es lineal (List.find_map); para >>1000 handlers se debería
  indexar.
