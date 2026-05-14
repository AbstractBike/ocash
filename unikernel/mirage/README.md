# ocash-ai-unikernel Fase 2 — MirageOS / Solo5

Scaffolding del port a MirageOS. **NO ESTÁ FUNCIONAL.** Este README documenta
los blockers técnicos descubiertos durante el port y propone alternativas.

## Estado

- `config.ml` — Mirage DSL (KV, stack TCP/IP, HTTP server, http-mirage-client).
  Necesita `mirage configure -t hvt|spt|unix` + `make depend` + `dune build`.
- `unikernel.ml` — main module. Carga handlers desde KV, expone
  `/v1/chat/completions`, `/metrics`, `/health`. **Stub** sobre el LLM client
  (http-mirage-client falta).
- No hay `dune` file aquí porque `mirage configure` lo genera.

## Blocker técnico principal: Toploop + Dynlink en Solo5

El unikernel Fase 1 (`unikernel/uni.ml`) usa `Toploop.execute_phrase` y
`compiler-libs.toplevel` para JIT-compilar el OCaml que devuelve el LLM, y
linkar el resultado vía `Dynlink`. Esto **no funciona** sobre Solo5 porque:

1. **`Dynlink` requiere un loader del SO.** En Solo5/hvt no hay `dlopen`, no
   hay ELF loader, no hay tabla de símbolos runtime. Tampoco hay un mecanismo
   estándar de carga de `.cmxs`. El paquete `dynlink` para Mirage existe pero
   solo soporta el target `unix` (donde hay loader nativo); en `hvt`/`spt`/`xen`
   el módulo está stubbed o ausente.
2. **`compiler-libs.toplevel` tira de Unix, threads y parsing-trees grandes.**
   Aunque el bytecode toplevel podría teóricamente correr (Mirage tiene un
   target bytecode), `compiler-libs` referencia `Sys.command`, `Unix.fork`,
   acceso a FS para `.cmi` paths. Cualquier intento de linkado falla con
   "module not found: Unix" o similar.
3. **No hay filesystem ni `Sys.executable_name`.** El código actual usa
   `Sys.executable_name`, `Sys.readdir`, `Sys.getenv` extensivamente; en
   Mirage debe migrar a `Mirage_kv` + `Key_gen`. Esto sí es mecánico.

### Alternativas evaluadas

| Opción | Viable | Coste | Pérdida |
|---|---|---|---|
| A. Precompilar handlers en build-time, embeber como módulos OCaml | Sí | bajo (PPX que lea `handlers/*.ml`) | pierdes el "JIT en runtime"; nuevos handlers requieren rebuild |
| B. Dynlink experimental sobre Mirage target `unix` | Parcial | medio | no es un verdadero unikernel (sigue siendo Linux process) |
| C. `Dynlink` sobre Solo5 con un loader custom de `.cmxs` | No (al hoy de mayo 2026) | altísimo | requeriría port del runtime dinámico de OCaml a Solo5; trabajo de meses |
| D. Mover la compilación al host: dos-tier, host JIT + envío del `.cmo` al unikernel via red | Sí | medio-alto | añade un host trusted; el unikernel deja de ser self-contained |
| E. Sustituir Toploop por un mini-DSL interpretado (no OCaml puro) | Sí | medio | LLM ya no genera OCaml; replantear prompt |

**Recomendación**: Opción **A** para Fase 2 (entregable, predecible). Reservar
**E** o **D** para Fase 3 si se quiere recuperar la dinamicidad.

## API de MirageOS que se necesitaría / falta

- `http-mirage-client` v0.0.5+ — para llamadas HTTP salientes al LLM.
  Requiere `happy-eyeballs-mirage`, `ca-certs-nss`, `dns-client-mirage`.
- `cohttp-mirage` — server side; OK, estable.
- `mirage-kv-mem` o `mirage-kv-unix` — para los handlers embebidos.
- `mirage-runtime` >= 4.5.0 — para `Key_gen` y `Mirage_runtime.argv`.
- **NO** existe (y este es el blocker): `mirage-dynlink` o equivalente que
  permita cargar bytecode/cmxs en runtime sobre Solo5.

## Para continuar

1. Decidir opción A: implementar un PPX o script de build que lea
   `~/.ocash/handlers/*.ml`, los valide con el sandbox AST ya implementado en
   Fase 1 (`Sandbox.validate_phrase`), y los compile como módulos OCaml
   normales linkados en `unikernel.ml`.
2. Implementar `llm_generate` real con `http-mirage-client`.
3. Reemplazar `Yojson.Basic.from_string` por algo que no asuma stdlib (Yojson
   funciona en Mirage pero hay que verificar).
4. `mirage configure -t hvt && make depend && dune build` en un entorno con
   `opam` + paquetes Mirage instalados (no disponible en este worktree).
