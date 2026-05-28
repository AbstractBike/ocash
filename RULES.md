# Reglas del Proyecto — Nodo de Malla (Mesh Node)

> Documento normativo. Define **qué es** el proyecto, **cómo se estructura** y
> **qué está permitido / prohibido**. Usa RFC 2119 en español:
> **DEBE** / **NO DEBE** (obligatorio), **DEBERÍA** (recomendado fuerte),
> **PUEDE** (opcional).

---

## 0. Filosofía (los cinco invariantes)

El proyecto se sostiene sobre cinco ideas. Si una decisión las contradice, la
decisión está mal, no el invariante.

1. **Un nodo es una carpeta.** La carpeta *es* a la vez el repositorio, el
   estado, la configuración y la unidad de despliegue. No hay "estado oculto"
   fuera de ella.
2. **El estado converge por commits.** Todo cambio observable del nodo es un
   *commit* en el VCS. La replicación entre máquinas no es un sistema aparte:
   es la sincronización (`sync`) del propio VCS. La malla *es* el grafo de
   sincronización.
3. **Lo que corre es inmutable.** El código de negocio se compila a
   **unikernels** y se ejecuta con **urunc**. No se parchea en caliente: se
   reconstruye un artefacto nuevo, se commitea y se redepliega.
4. **OCaml de punta a punta.** El lenguaje del nodo, de las apps y de las
   herramientas es OCaml. Cualquier otro lenguaje es la excepción y DEBE
   justificarse.
5. **Observar antes que adivinar.** Métricas, logs y trazas viven en
   **GreptimeDB**; las operaciones de larga duración y multi-paso viven en
   **Restate** con garantías de durabilidad. Nada crítico se hace "a ciegas"
   ni "best-effort".

---

## 1. Topología y modelo del nodo

### 1.1 Definición

Un **nodo lógico** es una unidad de cómputo identificable que puede existir,
simultáneamente, como **réplica** en varias máquinas físicas o virtuales.
Concretamente, un nodo es:

```
<node-id>/                  ← la carpeta = el nodo = el repositorio Fossil
```

- El **id del nodo** (`node-id`) es estable durante toda la vida del nodo y
  NO DEBE reutilizarse para otro propósito.
- Una **réplica** es una copia del nodo en una máquina concreta. Todas las
  réplicas de un nodo comparten `node-id` pero tienen un **replica-id** único
  (host + montaje). El `replica-id` se deriva, no se versiona.
- "El nodo está en varias máquinas" significa: *N* réplicas del **mismo**
  repositorio Fossil, sincronizándose entre sí. La verdad del nodo es la
  convergencia de esas réplicas, no ninguna copia individual.

### 1.2 Convención visible / oculto

La carpeta del nodo se divide en dos clases, y **la clase decide si la entrada
lleva punto**:

- **Contenido autoral → visible** (sin punto). Es lo que una persona escribe y
  lee: las apps, los workflows, los esquemas, los manifiestos de despliegue y el
  manifiesto del nodo. Es la "superficie" del nodo.
- **Infraestructura del sistema → oculta** (prefijo `.`). Es la maquinaria que
  gestionan el VCS, la malla y el runtime: el repositorio Fossil, los secretos,
  el estado de runtime y los artefactos compilados. Una persona casi nunca la
  edita a mano.

> **Regla 1.2.a (la regla del punto)** — Toda carpeta de *sistema* DEBE empezar
> por `.`; toda carpeta de *contenido autoral* NO DEBE llevar punto. Si dudas de
> en qué clase cae algo nuevo: ¿lo edita un humano para hacer su trabajo? →
> visible. ¿Lo gestiona la maquinaria? → oculto.

### 1.3 Layout canónico de la carpeta del nodo

Todo nodo DEBE seguir este esqueleto. Las rutas marcadas con `(VCS)` se
versionan; las marcadas con `(local)` van al `.fossil-settings/ignore-glob` y
**no** cruzan la malla.

```
<node-id>/
│   ── contenido autoral (VISIBLE) ──
├── node.toml              (VCS)   Identidad y declaración del nodo (ver §1.4)
├── apps/                  (VCS)   Código OCaml de las apps (una carpeta por app)
│   └── <app>/
│       ├── dune-project
│       ├── lib/
│       ├── bin/
│       └── config.ml              Config MirageOS del unikernel (§4)
├── workflows/             (VCS)   Servicios Restate en OCaml (§6)
├── schema/                (VCS)   Esquemas de tablas GreptimeDB (§5)
├── deploy/                (VCS)   Manifiestos urunc / OCI, perfiles de recursos (§4)
│
│   ── infraestructura del sistema (OCULTO, ".") ──
├── .fossil/               (local) El repositorio Fossil en sí (archivo SQLite)
├── .fossil-settings/      (VCS)   ignore-glob, crlf, etc.
├── .mesh/                 (VCS)   Topología de la malla: peers declarados (§2.4)
│   └── peers/
├── .secrets/              (local) Material sensible — NUNCA al VCS (§7.3)
├── .state/                (local) Datos efímeros de runtime, sockets, PIDs
└── .var/                  (local) Artefactos compilados (.hvt/.spt, imágenes OCI)
```

**Nota** — `node.toml` es la única *raíz* que, siendo "de sistema" en espíritu,
se mantiene **visible**: es el manifiesto que un humano edita para declarar el
nodo (§1.4). Es la excepción consciente a la regla del punto, no un descuido.

**Regla 1.3.a** — Si algo no entra en este árbol, primero se decide *dónde* y
*en qué clase* (§1.2) encaja; no se inventa una carpeta nueva fuera del esquema
sin actualizar este documento.

### 1.4 `node.toml` (manifiesto del nodo)

Cada nodo DEBE tener un `node.toml` versionado. Es el único punto de verdad de
la identidad y la composición del nodo.

```toml
[node]
id        = "edge-eu-west-01"      # node-id estable
role      = "edge"                 # edge | core | gateway | observer
created   = "2026-05-28"

[mesh]
autosync  = true                   # ver §2.3
project   = "https://fossil.example.org/mesh"   # repositorio raíz/ancla

[apps]
enabled   = ["ingest", "router"]   # apps que este nodo arranca

[runtime]
engine    = "urunc"
monitor   = "qemu"                 # o "solo5-hvt", "firecracker", ...

[telemetry]
greptime  = "greptime://obs.example.org:4000"

[durable]
restate   = "http://restate.example.org:8080"
```

---

## 2. Sincronización y control de versiones — Fossil (Sync Mesh)

El VCS es **Fossil** (de D. Richard Hipp, el mismo autor de SQLite). Se elige
porque: (a) un repositorio es *un solo archivo SQLite*, lo que encaja con
"un nodo = una carpeta"; (b) trae `sync` / `autosync` nativos; (c) es
distribuido y reconstruye su estado por *artifacts* inmutables.

### 2.1 Modelo mental

- El "Sync Mesh" **no es** una pieza de software adicional: es el `fossil sync`
  de cada réplica apuntando a uno o varios peers. La malla emerge del grafo de
  estos enlaces.
- Cada **commit** es la unidad atómica de cambio del nodo. Propagar un cambio a
  la malla = `fossil commit` (con autosync) o `fossil push/pull`.
- Convergencia: Fossil sincroniza *artifacts* idempotentes; dos réplicas que
  intercambian los mismos commits convergen al mismo estado. La malla es,
  efectivamente, **eventualmente consistente** a nivel de repositorio.

### 2.2 Reglas de commit

- **2.2.a** Un commit DEBE dejar el nodo en estado válido (compila, tests de la
  app tocada en verde). No se commitea trabajo a medias en `trunk`.
- **2.2.b** Mensaje de commit: primera línea ≤ 72 chars, en imperativo, con
  *scope* entre corchetes del subsistema afectado:
  `[ingest] añade backpressure por watermark`. Scopes válidos:
  `node`, `<app>`, `workflows`, `schema`, `deploy`, `peers`, `mesh`, `docs`.
- **2.2.c** Cambios de identidad (`node.toml [node]`) van en commits aislados,
  sin mezclar con código.
- **2.2.d** Artefactos compilados (`.var/`, unikernels) **NO** se commitean: se
  reconstruyen de forma reproducible (§4.3). Lo versionado es la *fuente* y el
  *manifiesto de build*, no el binario.

### 2.3 Autosync y ramas

- **2.3.a** `autosync` DEBE estar **activo** en réplicas de rol `edge` y
  `gateway` (escriben y propagan de inmediato). PUEDE estar diferido en réplicas
  `observer` (solo lectura analítica).
- **2.3.b** El tronco compartido de la malla es `trunk`. El trabajo experimental
  va en ramas con prefijo de réplica: `wip/<replica-id>/<tema>`.
- **2.3.c** Una réplica **NO DEBE** forzar (`--force`) un sync que reescriba
  historia de la malla. La historia Fossil es *append-only* por diseño;
  respetarlo es obligatorio.

### 2.4 Peers de la malla (`peers/`)

- La topología de la malla se **declara**, no se descubre mágicamente. Cada
  réplica lista sus peers en `.mesh/peers/<replica-id>.toml`.
- **2.4.a** La malla DEBERÍA tener al menos un peer *ancla* (rol `core`) con
  alta disponibilidad, para que las réplicas `edge` converjan aunque no se vean
  entre sí.
- **2.4.b** Añadir/quitar un peer es un commit (queda auditado en la historia).
  `.mesh/peers/` se versiona; el repositorio Fossil en sí (`.fossil/`) es local
  a cada réplica y no se versiona dentro de sí mismo.

### 2.5 Resolución de conflictos

- **2.5.a** Conflictos de *contenido* (mismo fichero, ediciones divergentes) se
  resuelven con `fossil merge` y un commit de merge explícito. NO se "aplastan"
  cambios de otra réplica sin merge.
- **2.5.b** El estado de runtime que pueda divergir entre máquinas **NO** se
  versiona (va en `.state/`, `local`). Si dos réplicas deben coordinar estado
  vivo (no solo configuración), eso es responsabilidad de **Restate** (§6), no
  del VCS.

---

## 3. Lenguaje y código — OCaml

### 3.1 Estructura y build

- **3.1.a** Toda app y herramienta se construye con **dune** (`dune-project`
  con `(lang dune 3.12)` o superior). Un único `dune-project` por app.
- **3.1.b** El código se separa en `lib/` (lógica, testeable) y `bin/` o
  `config.ml` (punto de entrada / unikernel). La lógica de negocio NO DEBE vivir
  en el punto de entrada.
- **3.1.c** Dependencias declaradas en el `.opam` de la app; nada de depender de
  binarios del sistema no declarados.

### 3.2 Estilo

- **3.2.a** Formato con `ocamlformat` (config `.ocamlformat` versionada en la
  raíz del nodo). CI rechaza diffs sin formatear.
- **3.2.b** Warnings tratados como errores en build de release
  (`--profile release`); en `dev` se permiten para iterar.
- **3.2.c** Errores: usar `result`/`Result.t` para fallos esperables; las
  excepciones se reservan para invariantes rotos (bugs), no para flujo de
  control normal.
- **3.2.d** Concurrencia: un solo modelo por app (Lwt **o** Eio, no mezclar).
  Eio DEBERÍA preferirse en código nuevo sobre OCaml ≥ 5.

### 3.3 Tests

- **3.3.a** Cada `lib/` DEBE tener tests (`alcotest`/`qcheck`). La regla 2.2.a
  (commit válido) se apoya en esto.
- **3.3.b** La lógica de un workflow Restate DEBE ser testeable de forma
  determinista *sin* la red (las llamadas externas se inyectan).

---

## 4. Apps y empaquetado — Unikernels + urunc

> "Las apps se envuelven en unikernels": cada app de negocio compila a una
> imagen unikernel (MirageOS sobre OCaml) y se ejecuta como contenedor OCI con
> **urunc**.

### 4.1 Unikernel por app

- **4.1.a** Cada app en `apps/<app>/` DEBE producir **un** unikernel mediante
  MirageOS (`config.ml` define los *devices*: red, almacenamiento, KV, reloj).
- **4.1.b** El unikernel NO DEBE asumir un sistema operativo host completo: sin
  shell, sin `fork/exec`, sin acceso al filesystem del host fuera de los
  *block/KV devices* declarados. Toda capacidad se inyecta vía MirageOS.
- **4.1.c** Una app = un propósito. Si necesita "otro proceso al lado", eso es
  **otra app / otro unikernel**, coordinados por la malla o por Restate.

### 4.2 Ejecución con urunc

- **4.2.a** Los unikernels se empaquetan como **imágenes OCI** y se corren con
  **urunc** (runtime que ejecuta unikernels como contenedores bajo
  containerd/OCI). Los manifiestos viven en `deploy/`.
- **4.2.b** El monitor (`qemu`, `solo5-hvt`, `firecracker`…) se fija en
  `node.toml [runtime].monitor` y se refleja en las anotaciones OCI que urunc
  espera. No se hardcodea en el código de la app.
- **4.2.c** Límites de CPU/memoria/red se declaran en `deploy/<app>.yaml`. Un
  unikernel sin perfil de recursos NO DEBE desplegarse.

### 4.3 Builds reproducibles

- **4.3.a** El build es función pura de `(fuente @ commit, lockfile opam,
  toolchain)`. Mismo commit ⇒ misma imagen. Por eso §2.2.d prohíbe versionar el
  binario: se regenera.
- **4.3.b** Cada imagen OCI DEBE etiquetarse con el **hash del commit Fossil**
  del que salió (`org.opencontainers.image.revision`). Trazabilidad imagen↔commit
  es obligatoria.

---

## 5. Datos y observabilidad — GreptimeDB

> GreptimeDB es la base de datos unificada de métricas + logs + trazas del nodo.

- **5.1** **Toda** la telemetría del nodo (métricas de apps, logs estructurados,
  trazas) va a GreptimeDB vía el endpoint de `node.toml [telemetry].greptime`.
  No se escriben logs "sueltos" a ficheros como fuente de verdad.
- **5.2** Los esquemas de tabla se versionan en `schema/` (DDL en SQL). Cambiar
  un esquema es un commit (regla 2.2) y DEBE ser *aditivo* / compatible hacia
  atrás siempre que sea posible (las réplicas viejas siguen escribiendo).
- **5.3** Toda serie temporal DEBE etiquetarse con `node_id` y `replica_id`,
  para poder distinguir contribuciones de cada réplica de la malla.
- **5.4** GreptimeDB es para **observación y analítica**, NO para el estado
  operativo del nodo (ese vive en el VCS) ni para coordinación durable (esa vive
  en Restate). No se abuse de él como cola ni como store transaccional.
- **5.5** Retención y *downsampling* se declaran junto al esquema; ninguna tabla
  crece sin política de retención.

---

## 6. Orquestación y durabilidad — Restate

> Restate da ejecución durable: workflows/servicios con reintentos, estado
> persistente y semántica *exactly-once* a nivel de invocación.

- **6.1** Cualquier operación que sea **multi-paso, de larga duración o que
  cruce nodos/réplicas** DEBE implementarse como servicio/workflow Restate en
  `workflows/`, no como script imperativo suelto. Ejemplos: desplegar una nueva
  versión de unikernel en la malla, una saga de migración de esquema,
  coordinación entre apps.
- **6.2** Los handlers Restate DEBEN ser **idempotentes**: el mismo `idempotency
  key` no produce efectos duplicados. Los efectos externos (llamar a otra app,
  escribir a GreptimeDB) se hacen vía las primitivas de Restate (`ctx.run`,
  *durable steps*) para que sobrevivan a reinicios.
- **6.3** El estado de coordinación vivo entre réplicas (§2.5.b) es estado de
  Restate, no del VCS. El VCS guarda *qué se quiere*; Restate ejecuta *cómo se
  llega* de forma durable.
- **6.4** Fallos: un workflow agota reintentos → emite un evento de telemetría a
  GreptimeDB y queda en estado *failed* inspeccionable. No se "traga" el error
  en silencio.
- **6.5** Endpoint de Restate en `node.toml [durable].restate`. Los workflows se
  testean en local con el runtime de Restate antes de commitear (regla 3.3.b).

---

## 7. Seguridad y aislamiento

- **7.1 Aislamiento por diseño.** El modelo de ejecución (unikernel + urunc +
  monitor de hardware) es la primera línea de defensa: superficie mínima, sin
  shell, sin syscalls de host innecesarios.
- **7.2 Mínimo privilegio.** Cada unikernel solo recibe los *devices* que
  declara su `config.ml`. Nada de "por si acaso".
- **7.3 Secretos.** El material sensible vive en `.secrets/` (rol `local`,
  ignorado por Fossil) y **NUNCA** cruza la malla por el VCS. Los unikernels lo
  reciben en arranque por el mecanismo del runtime (variables OCI / KV cifrado),
  no embebido en la imagen.
- **7.4 Integridad de la malla.** Los enlaces `fossil sync` DEBEN ir sobre canal
  autenticado (HTTPS + credenciales por réplica). Un peer no autenticado NO se
  añade a `peers/`.
- **7.5 Auditoría.** Como todo cambio operativo es un commit Fossil firmado por
  una réplica, la historia del repositorio *es* el registro de auditoría. No se
  reescribe (regla 2.3.c).

---

## 8. Convenciones transversales

### 8.1 Nombres

- `node-id`, `app`, scopes de commit: `kebab-case` o minúsculas, sin espacios.
- Tablas GreptimeDB: `snake_case`, prefijo por app (`ingest_latency`).
- Servicios Restate: `PascalCase` para el servicio, `camelCase` para handlers.

### 8.2 CI

- CI DEBE, como mínimo: `ocamlformat --check`, `dune build --profile release`,
  `dune runtest`, build del unikernel (al menos `solo5-hvt`) y validación de los
  manifiestos `deploy/`.
- Un commit que rompe CI bloquea el `trunk` de la malla hasta arreglarse.

### 8.3 Documentación

- Cambios que afecten a estas reglas (layout, stack, invariantes) se reflejan en
  **este** documento *en el mismo commit*. El documento no puede quedar desfasado
  respecto al árbol real del nodo.

---

## 9. Ciclo de vida de un cambio (resumen operativo)

```
1. Editas fuente OCaml en apps/<app>/  (o workflows/, schema/, deploy/…).
2. dune build + dune runtest en verde.                         (§3.3)
3. fossil commit  → autosync propaga el commit a la malla.     (§2.2, §2.3)
4. CI reconstruye el unikernel de forma reproducible.          (§4.3)
5. La imagen OCI (etiquetada con el hash del commit) se publica.
6. Un workflow Restate orquesta el redespliegue por la malla.  (§6.1)
7. urunc arranca el nuevo unikernel; el viejo se retira.       (§4.2)
8. GreptimeDB recibe métricas/trazas del nuevo despliegue.     (§5)
```

Si en cualquier punto algo falla, el invariante #2 garantiza el rollback: se
vuelve a un commit anterior y la malla converge a él.

---

## Apéndice A — El stack de un vistazo

| Capa                      | Tecnología   | Rol en el proyecto                                   |
|---------------------------|--------------|------------------------------------------------------|
| Identidad / replicación   | **Fossil**   | Un nodo = un repo; la malla es el grafo de `sync`    |
| Lenguaje                  | **OCaml**    | Apps, workflows y herramientas                       |
| Empaquetado de apps       | **Unikernel**| MirageOS: una imagen mínima e inmutable por app      |
| Runtime                   | **urunc**    | Ejecuta los unikernels como contenedores OCI         |
| Observabilidad            | **GreptimeDB**| Métricas + logs + trazas unificados                 |
| Durabilidad / orquestación| **Restate**  | Workflows multi-paso, idempotentes y *exactly-once*  |

## Apéndice B — Diagrama de la malla

```
        Máquina A                     Máquina B                    Máquina C
   ┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐
   │ <node-id>/       │         │ <node-id>/       │         │ <node-id>/       │
   │  ├ node.toml     │         │  ├ node.toml     │         │  ├ node.toml     │
   │  ├ apps/ (OCaml)─┼─visible │  ├ apps/         │         │  ├ apps/         │
   │  ├ workflows/    │         │  ├ workflows/    │         │  ├ workflows/    │
   │  ├ deploy/       │         │  ├ deploy/       │         │  ├ deploy/       │
   │  ├ .fossil/     ─┼─oculto  │  ├ .fossil/      │         │  ├ .fossil/      │
   │  ├ .mesh/peers/  │         │  ├ .mesh/peers/  │         │  ├ .mesh/peers/  │
   │  └ .state/ .var/ │         │  └ .state/ .var/ │         │  └ .state/ .var/ │
   └───────┬──────────┘         └────────┬─────────┘         └────────┬─────────┘
           │  fossil sync (commits)      │                            │
           └───────────────┬─────────────┴──────────────┬─────────────┘
                           │      SYNC MESH (Fossil)     │
                           ▼                             ▼
                  ┌──────────────────┐         ┌──────────────────┐
                  │   urunc + monitor│         │   urunc + monitor│
                  │  ┌────┐  ┌────┐  │         │  ┌────┐  ┌────┐  │
                  │  │uni │  │uni │  │  apps →  │  │uni │  │uni │  │
                  │  └─┬──┘  └─┬──┘  │ unikernel│  └─┬──┘  └─┬──┘  │
                  └────┼───────┼─────┘         └────┼───────┼─────┘
                       │       │                    │       │
              métricas ▼       ▼ durable    métricas ▼       ▼ durable
                  ┌─────────────┐  ┌─────────────┐
                  │ GreptimeDB  │  │   Restate   │
                  └─────────────┘  └─────────────┘
```
