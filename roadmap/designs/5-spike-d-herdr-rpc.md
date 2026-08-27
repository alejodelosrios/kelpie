# Diseño — #5 Spike D — hablar con el socket de herdr

> Aprobado por: Manuel Alejandro Ramirez · 2026-08-27 · rama `feature/5-spike-d-herdr-rpc`

## Spec

Un binario auxiliar Zig puro, `kelpie --herdr-probe`, que habla NDJSON-RPC crudo contra el socket
Unix de herdr (`$HERDR_SOCKET_PATH` o `~/.config/herdr/herdr.sock`) usando solo `std.Io.net` +
`std.json` — sin librerías nuevas — y demuestra en vivo los cinco puntos del contrato del issue:
`ping`, `session.snapshot`, `agent.list`, un `events.subscribe` persistente, y los dos casos de
error. El comando queda gateado tras `HERDR_ENV=1` (igual que la skill `herdr`): si la env var no
está, imprime que no corre fuera de una sesión Herdr y sale sin tocar el socket.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/herdr/client.zig` — nuevo. Cliente NDJSON mínimo: abrir conexión, escribir una línea de
  request, leer una línea de response, cerrar.
- `src/herdr/probe.zig` — nuevo. Las cinco demostraciones del issue, cada una imprime su resultado
  a stdout en texto plano legible por humano (esto es un spike, no un parser de producción).
- `src/herdr/testdata/herdr-api.schema.json` — nuevo, vendorizado vía `herdr api schema --json`
  (255 KB, protocol 20).
- `scripts/update-schema.sh` — nuevo. Un `herdr api schema --json > src/herdr/testdata/herdr-api.schema.json`
  con guard de `HERDR_ENV`/binario presente; nada más.
- `src/main.zig` (hotspot, dueño `core-builder`) — añade el flag `--herdr-probe` que llama a
  `herdr.probe.run`.
- `build.zig` (hotspot, dueño `core-builder`) — añade `src/herdr/` al módulo raíz si hace falta un
  import explícito (no se anticipa nuevo `b.createModule`, es el mismo `exe_mod`).
- `.claude/skills/herdr/` — anota los 5 valores de `AgentStatus` (`idle working blocked done
  unknown`) y el contrato de "una petición por conexión, salvo `events.subscribe`".

**No entra** (copiado del issue):
- Tipos completos de eventos del schema (#9).
- Reconexión automática tras el cierre del servidor (#10).
- Autostart del servidor herdr (#11).
- Métodos de escritura del API (`agent.prompt`, `pane.run`, etc.) — solo lectura.

Recorte YAGNI: sin pool de conexiones, sin reintentos, sin abstracción de "cliente RPC genérico"
reutilizable — es un probe de un solo uso que demuestra el mecanismo; #9/#10/#11 son quienes deciden
si eso se convierte en librería real.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Zig stdlib verificado contra el toolchain instalado
(`/usr/lib/zig/std`, zig 0.16.0 — fuente de verdad #2 del repo). Contrato NDJSON de herdr verificado
en vivo contra el socket real (`~/.config/herdr/herdr.sock`, servidor `0.8.2`/protocol 20) el
2026-08-27, más el schema vendorizado (`herdr api schema --json`).

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `UnixAddress.init(path)` — falla con `error.NameTooLong` si excede 108 bytes | `/usr/lib/zig/std/Io/net.zig:848` | ✅ |
| `UnixAddress.connect(io) ConnectError!Stream` | `/usr/lib/zig/std/Io/net.zig:908` | ✅ |
| `Stream.reader(io, buffer) Reader` / `Stream.writer(io, buffer) Writer` | `/usr/lib/zig/std/Io/net.zig:1393,1397` | ✅ |
| `Stream.close(io)` | `/usr/lib/zig/std/Io/net.zig:1248` | ✅ |
| `Io.Reader.takeDelimiterExclusive(r, '\n') DelimiterError![]u8` — una línea NDJSON sin el `\n` | `/usr/lib/zig/std/Io/Reader.zig:872` | ✅ |
| `std.json.Stringify.value(v, options, writer) Error!void` — serializa el request struct directo al `Io.Writer` de la conexión | `/usr/lib/zig/std/json/Stringify.zig:573` | ✅ |
| `std.json.parseFromSlice(T, allocator, slice, options) Parsed(T)` — parsea la línea de respuesta | `/usr/lib/zig/std/json/static.zig:73` | ✅ |
| Envelope de éxito: `{"id":"1","result":{"type":"pong","version":"0.8.2","protocol":20,"capabilities":{...}}}` | sonda en vivo, `ping` sobre socket real | ✅ |
| Una petición no-suscripción por conexión: el 2º `sendall` en la misma conexión revienta con `BrokenPipeError`/EPIPE — el servidor ya cerró tras responder | sonda en vivo, dos requests seguidas sobre la misma conexión | ✅ |
| `session.snapshot` → `result.snapshot.workspaces[]` con `pane_count`/`tab_count` por workspace | sonda en vivo, `session.snapshot` sobre socket real | ✅ |
| `agent.list` → `result.agents[]` con `pane_id`, `agent`, `agent_status`, `agent_session` | sonda en vivo, `agent.list` sobre socket real | ✅ |
| `id` numérico → `{"id":"","error":{"code":"invalid_request","message":"invalid type: integer \`1\`, expected a string..."}}` | sonda en vivo, request con `"id":1` | ✅ |
| `params` ausente → `{"id":"","error":{"code":"invalid_request","message":"missing field \`params\`..."}}` | sonda en vivo, request sin campo `params` | ✅ |
| `events.subscribe` ack: `{"id":"1","result":{"type":"subscription_started"}}`, luego eventos `{"data":{"pane":{...}}}`/`{"data":{"layout":{...}}}` en líneas siguientes | sonda en vivo, `events.subscribe` con `subscriptions:[{"type":"pane.updated"},{"type":"layout.updated"}]` | ✅ |
| `AgentStatus` enum: `idle \| working \| blocked \| done \| unknown` | `herdr api schema --json` → `schemas.request.$defs.AgentStatus.enum` | ✅ |
| Tipos de suscripción sin parámetros propios (solo `{"type": "..."}`, `required:["type"]`): todos los `workspace.*`, `worktree.*`, `tab.*`, y de `pane.*` los que no son `output_matched`/`agent_status_changed`/`scroll_changed` (esos exigen `pane_id`), más `layout.updated` | `herdr api schema --json` → `schemas.request.$defs.Subscription.oneOf` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: ping responde pong con protocol >= 20
Dado el socket de herdr vivo en $HERDR_SOCKET_PATH
Cuando el probe envía {"id":"1","method":"ping","params":{}} y lee una línea
Entonces result.type es "pong"
Y result.protocol es >= 20

Escenario: session.snapshot cuenta workspaces, tabs, panes y agentes
Dado una conexión nueva al socket de herdr
Cuando el probe envía {"id":"1","method":"session.snapshot","params":{}}
Entonces el probe imprime el conteo de workspaces, tabs, panes y agentes activos del snapshot

Escenario: agent.list imprime pane_id, agent y agent_status por agente
Dado una conexión nueva al socket de herdr
Cuando el probe envía {"id":"1","method":"agent.list","params":{}}
Entonces el probe imprime una línea por agente con su pane_id, agent y agent_status

Escenario: events.subscribe abre un stream persistente y captura un pane_updated con agent_status
Dado una conexión persistente al socket de herdr
Cuando el probe envía events.subscribe con las subscriptions sin parámetros del schema
Entonces el probe lee el ack {"type":"subscription_started"}
Y vuelca las siguientes 5 líneas de eventos crudas
Y al interactuar con un agente durante la captura, al menos un evento de pane trae un agent_status

Escenario: un id no-string es un invalid_request
Dado el socket de herdr vivo
Cuando el probe envía un request con "id":1 (numérico)
Entonces la respuesta trae error.code == "invalid_request"

Escenario: params ausente es un invalid_request
Dado el socket de herdr vivo
Cuando el probe envía un request sin el campo "params"
Entonces la respuesta trae error.code == "invalid_request"

Escenario: una segunda petición no-suscripción en la misma conexión falla
Dado una conexión ya usada para una petición no-suscripción
Cuando el probe intenta enviar una segunda petición sobre la misma conexión
Entonces la escritura o lectura falla con EPIPE/EOF
Y el probe lo reporta como comportamiento esperado del servidor, no como error del probe
```

## Riesgos y preguntas abiertas

- El servidor cierra la conexión tras responder a una petición no-suscripción; el `write` del
  segundo intento puede fallar con `error.BrokenPipe`/`ConnectionResetByPeer` o el `read` puede
  devolver `error.EndOfStream`, dependiendo de timing del kernel. El probe debe tratar ambos como
  éxito del escenario (confirma el cierre), no solo uno — no se pudo fijar cuál ocurre de forma
  determinista desde una sonda externa.
- No hay garantía de que un `pane_updated` con `agent_status` llegue dentro de las primeras 5 líneas
  de eventos si nadie interactúa con un agente durante la captura del probe; el criterio de
  aceptación #3 requiere interacción activa (`herdr agent.list`/uso normal de un pane) mientras el
  probe está suscrito. Esto lo ejecuta el humano en QA, no es automatizable sin control externo del
  entorno Herdr.
