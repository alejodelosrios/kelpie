# `src/herdr/` — cliente NDJSON-RPC de herdr

Cliente mínimo (`client.zig`) y probe de demostración (`probe.zig`, `kelpie --herdr-probe`) que
hablan el protocolo NDJSON de [herdr](https://github.com/herdrdev/herdr) sobre su socket Unix
(`$HERDR_SOCKET_PATH` o `~/.config/herdr/herdr.sock`). Ver `roadmap/designs/5-spike-d-herdr-rpc.md`
para la spec completa.

## `AgentStatus`

El campo `agent_status` de `agent.list` y de los eventos `pane.updated` toma uno de cinco valores
(`herdr api schema --json` → `schemas.request.$defs.AgentStatus.enum`):

- `idle` — el agente no está corriendo nada.
- `working` — el agente está procesando.
- `blocked` — el agente espera input del usuario.
- `done` — el agente terminó su tarea.
- `unknown` — herdr no pudo determinar el estado.

## Una petición por conexión

Salvo `events.subscribe`, el servidor de herdr **cierra la conexión después de responder a
cualquier método**. Cada demo en `probe.zig` abre una conexión nueva por request; reusar una
conexión para una segunda petición no-suscripción falla con `error.BrokenPipe`/`WriteFailed` al
escribir, o `error.EndOfStream` al leer, dependiendo del timing del kernel — ambos son el cierre
esperado del servidor, no un bug del cliente.

`events.subscribe` es la única excepción: es un stream persistente que se mantiene abierto y va
emitiendo líneas NDJSON de eventos mientras la conexión siga viva.

## `request()` — una petición de un tiro

`request(gpa, io, socket_path, method, params, read_timeout_ms, rpc_err)` abre una `Connection`
nueva, envía `method`/`params`, lee una línea de respuesta y cierra — el patrón de "una conexión
por petición" de arriba, hecho función. `rpc_err.*` se resetea a `null` al entrar; si herdr responde
con un error de protocolo (`{"error":{code,message}}`), `request` devuelve `error.HerdrRpc` y deja
el detalle en `rpc_err.*` (el llamador lo libera con `.deinit(gpa)` solo si no es `null`). En el
camino feliz el llamador es dueño del `Response` devuelto y debe `.deinit()` lo.

`read_timeout_ms` es inyectable (usa `default_read_timeout_ms` = 15 s si no hace falta uno corto).
Se implementa con un hilo watchdog, no `SO_RCVTIMEO`: en Linux un `read()`/`readv()` bloqueante
que expira por `SO_RCVTIMEO` entrega `EAGAIN`, no `ETIMEDOUT`, y el backend `Threaded` de `std.Io`
trata `EAGAIN` sobre un socket bloqueante como "programmer bug" y aborta el proceso — ver
`roadmap/designs/8-cliente-rpc.md`, sección "Decisión de diseño (revisión 2)". El watchdog duerme
`read_timeout_ms` y, si la lectura no terminó, hace `Stream.shutdown(io, .recv)` sobre el socket:
un `shutdown(SHUT_RD)` estándar de POSIX hace que la lectura bloqueada en el otro hilo retorne EOF
de inmediato, que se traduce a `error.Timeout` en `request()`.

## `RpcErrorCode`

Códigos de error de protocolo que herdr puede devolver en `{"error":{"code": ...}}`:
`invalid_request`, `invalid_params`, `agent_blocked`, `agent_not_ready`, `pane_not_found`,
`invalid_target`, `ui_busy`, `protocol_mismatch`, y `unknown` para cualquier código que este cliente
no reconozca todavía (el mensaje crudo sigue disponible en `RpcError.message`).

## `resolveSocketPath` — tres escalones

1. `HERDR_SOCKET_PATH`, verbatim, si está puesto.
2. `$XDG_CONFIG_HOME/herdr/herdr.sock`, si `XDG_CONFIG_HOME` está puesto.
3. `$HOME/.config/herdr/herdr.sock`, como último recurso.

## `Events.zig` — suscripción persistente con reconexión

`EventsClient` (`Events.zig`) mantiene un `events.subscribe` abierto en su propio hilo
(`std.Thread.spawn`) y entrega cada `EventEnvelope` y cada re-`session.snapshot` de reconexión a
través de `on_event`/`on_resynced`. Ver `roadmap/designs/10-eventos-reconexion.md` para la spec y
los escenarios Gherkin completos.

### `Dispatcher` y `Sleeper` — las dos costuras inyectables

`EventsClient` nunca llama a `on_event`/`on_resynced` directamente desde su hilo lector: siempre
pasa por `dispatcher.invoke(task, task_ctx)`. Producción envuelve `glib.MainContext.invoke` — ese
binding vive en un issue de UI futuro; `Events.zig` no importa `gobject` (decisión de diseño
tomada con el orquestador, ver el diseño). `Sleeper.sleep(ms)` reemplaza `Io.sleep` en el ciclo de
backoff; `IoSleeper` es la implementación de producción, respaldada en `Io.sleep` real. Los tests
inyectan dobles que graban sin bloquear, lo que hace el backoff y el aislamiento de hilo
verificables sin relojes reales.

### Contrato de reconexión

Ante EOF o error de lectura, `EventsClient` cierra la conexión y reconecta con backoff
`1,2,4,8,16,30,30…` segundos (tope 30 s). El backoff se resetea a 1 s en cuanto llega el ack
`subscription_started` de una nueva suscripción — sin esperar a que el ciclo entero tenga éxito.
Cada reconexión exitosa dispara un `session.snapshot` fresco (conexión aparte, one-shot) antes de
volver a leer eventos, para que el consumidor pueda resincronizar su estado sin perder eventos
intermedios. `stop()` es limpio: usa `stream.shutdown(io, .recv)` (mismo mecanismo que el
`Watchdog` de `client.zig:130-156`) para desbloquear una lectura en curso, y hace `Thread.join()`.
