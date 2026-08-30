# Diseño — #10 Suscripción a eventos persistente con reconexión (1 s → 30 s) y re-`session.snapshot` al reconectar

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-30

## Spec

`src/herdr/Events.zig` (nuevo): hilo propio que mantiene una conexión `events.subscribe` abierta
contra herdr, entrega cada evento decodificado y cada re-`session.snapshot` a través de un
**dispatcher inyectable** (no `glib.MainContext` importado aquí — decisión de diseño tomada con el
orquestador, ver más abajo), y reconecta con backoff 1→30 s ante EOF/error, reseteando el backoff
al recibir el ack `subscription_started`.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/herdr/Events.zig` — todo lo de abajo.
- `build.zig` — registra `events_mod`/`events_tests` al final, patrón `theme_css_mod`
  (`build.zig:83-91`). No se toca ninguna otra línea de `build.zig`.
- `src/herdr/README.md` — documentar `EventsClient`, `Dispatcher`, `Sleeper` y el contrato de
  reconexión.

**No entra** (copiado del issue):
- Suscripciones parametrizadas: `pane.output_matched`, `pane.agent_status_changed`,
  `pane.scroll_changed` — los tres únicos tipos del schema con un campo requerido además de
  `type` (verificado contra `src/herdr/testdata/herdr-api.schema.json`, ver tabla de citas).
- Persistencia de eventos.
- `src/main.zig`/`src/app.zig`: nadie los toca — `#17` los tiene arrendados esta ola. `Events.zig`
  no tiene consumidor todavía; wirearlo a `app.zig` es trabajo de un issue posterior.
- La implementación real de `Dispatcher` sobre `glib.MainContext` — eso vive donde exista el main
  loop de GTK (futuro issue de UI/app.zig), no aquí. Este issue entrega la interfaz y la prueba de
  que `Events.zig` nunca llama al callback directo, solo a través del dispatcher.

## Decisión de diseño: dispatcher inyectable std-puro, no `glib.MainContext` en `Events.zig`

El issue describe la entrega como "callback en el hilo de UI (`glib.MainContext` invoke)". Se
consultó con el orquestador porque `Events.zig` vive en territorio `core-builder`
(`src/herdr/`), que hasta hoy no importa `gobject`, y uno de los criterios de aceptación pide un
test de backoff "sin dormir de verdad: reloj inyectable" — la misma lógica de inyección aplica a
la entrega de callbacks. Decisión: `Events.zig` define dos interfaces mínimas, ambas `std` puro:

```zig
pub const Dispatcher = struct {
    ptr: *anyopaque,
    invokeFn: *const fn (ptr: *anyopaque, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) void,

    pub fn invoke(self: Dispatcher, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) void {
        self.invokeFn(self.ptr, task, task_ctx);
    }
};

pub const Sleeper = struct {
    ptr: *anyopaque,
    sleepFn: *const fn (ptr: *anyopaque, ms: u32) void,

    pub fn sleep(self: Sleeper, ms: u32) void {
        self.sleepFn(self.ptr, ms);
    }
};
```

El consumidor real (un issue de UI futuro) implementa `Dispatcher.invokeFn` envolviendo
`glib.MainContext.invoke`, y ahí — no aquí — vive el `assert(glib.MainContext.isOwner(...))` en
modo debug que pide el criterio de aceptación. `Events.zig` garantiza el contrato que hace ese
assert seguro: **el callback nunca se invoca directamente desde el hilo lector**, solo a través de
`dispatcher.invoke()`. La prueba mecánica de ese contrato (sin GTK) es un `Dispatcher` de test que
graba el `std.Thread.Id` de quien llama a `invoke` y lo compara contra el `std.Thread.Id` del hilo
lector — deben ser distintos.

`Sleeper` reemplaza `Io.sleep` en el ciclo de backoff: producción usa uno respaldado en `Io.sleep`,
QA inyecta uno que registra los `ms` pedidos y retorna al instante, permitiendo verificar la
secuencia `1,2,4,8,16,30,30…` en milisegundos de test.

## Firmas de API que se van a usar

Preferencia de fuente: el propio repo primero (`client.zig`/`types.zig`, ya compilan), luego el std
instalado (`zig 0.16.0`, `/usr/lib/zig/std/`). Todas verificadas con `sed -n '<línea>p'`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `Connection` struct (`stream`,`reader`,`writer`, out-param, dirección fija) | `src/herdr/client.zig:9-27` | ✅ |
| `Connection.open(self, io, socket_path) !void` | `src/herdr/client.zig:28` | ✅ |
| `Connection.close(self) void` | `src/herdr/client.zig:39` | ✅ |
| `resolveSocketPath(environ, buf) ![]const u8` | `src/herdr/client.zig:64-65` | ✅ |
| `request(gpa, io, socket_path, method, params, read_timeout_ms, rpc_err) !Response` (usado para el `session.snapshot` de cada resync — one-shot, no reutiliza la conexión de suscripción) | `src/herdr/client.zig:170-178` | ✅ |
| `RpcError` / `RpcErrorCode` / `.deinit(gpa)` | `src/herdr/client.zig:94-116` | ✅ |
| `Response = json.Parsed(json.Value)` | `src/herdr/client.zig:118` | ✅ |
| Patrón `takeLine` (consume el `\n` inclusive, para conexión persistente reutilizada) | `src/herdr/client.zig:465-472` | ✅ (mismo patrón, se replica en `Events.zig` porque `sendRequest`/`request()` no sirven para una conexión que se mantiene abierta) |
| `conn.writer.interface.writeAll` / `.writeByte('\n')` / `.flush()` | `src/herdr/client.zig:376-380` | ✅ |
| `EventKind` enum (26 variantes, incluye `pane_agent_status_changed`) | `src/herdr/types.zig:36-63` | ✅ |
| `EventEnvelope { event: EventKind, data: json.Value }` | `src/herdr/types.zig:140-143` | ✅ |
| `SessionSnapshot` struct | `src/herdr/types.zig:119-131` | ✅ |
| Los 3 tipos pane-scoped excluidos tienen un campo propio requerido además de `type` (`pane.output_matched`: `pane_id,source,match`; `pane.agent_status_changed`: `pane_id`; `pane.scroll_changed`: `pane_id`) | `src/herdr/testdata/herdr-api.schema.json` → `schemas.request.$defs.Subscription.oneOf` (verificado por script `python3 -c "json.load(...)"`, no tiene número de línea estable — JSON generado) | ✅ |
| `json.Stringify.value(req, .{}, writer)` | `src/herdr/client.zig:50` | ✅ |
| `json.parseFromSlice(json.Value, gpa, line, .{...})` | `src/herdr/client.zig:200` | ✅ |
| `std.Thread.spawn(config, function, args) SpawnError!Thread` | `/usr/lib/zig/std/Thread.zig:344` | ✅ |
| `std.Thread.join(self) void` | `/usr/lib/zig/std/Thread.zig:370` | ✅ |
| `std.Thread.getCurrentId() Id` | `/usr/lib/zig/std/Thread.zig:279` | ✅ |
| `std.Thread.Id` (tipo, varía por OS) | `/usr/lib/zig/std/Thread.zig:262` | ✅ |
| `std.atomic.Value(T).init` / `.load` / `.store` | `/usr/lib/zig/std/atomic.zig:16` (patrón ya usado en `client.zig`'s `Watchdog`) | ✅ |
| `Stream.shutdown(s, io, how) ShutdownError!void` / `ShutdownHow` | `/usr/lib/zig/std/Io/net.zig:1252` y `:980` | ✅ (mismo mecanismo que `Watchdog` de `client.zig:130-156` para desbloquear `stop()` a mitad de una lectura) |
| `Io.sleep(io, duration, clock) Cancelable!void` | `/usr/lib/zig/std/Io.zig:2397` | ✅ (respaldo real de `Sleeper`, ya en uso en `client.zig:149`) |
| `Io.Duration.fromMilliseconds(ms) Duration` | `/usr/lib/zig/std/Io.zig:982` | ✅ |
| `std.meta.stringToEnum(comptime T, str) ?T` | `/usr/lib/zig/std/meta.zig:18` | ✅ |

## API nueva en `Events.zig`

```zig
/// Los 24 tipos suscribibles sin parámetros (schema: `Subscription.oneOf` con solo `type`
/// requerido). Excluidos a propósito: pane.output_matched, pane.agent_status_changed,
/// pane.scroll_changed — los cambios de estado de agente llegan globalmente por pane.updated.
const subscription_types = [_][]const u8{
    "workspace.created",  "workspace.updated", "workspace.metadata_updated",
    "workspace.renamed",  "workspace.moved",   "workspace.reordered",
    "workspace.closed",   "workspace.focused", "worktree.created",
    "worktree.opened",    "worktree.removed",  "tab.created",
    "tab.closed",         "tab.focused",       "tab.renamed",
    "tab.moved",          "pane.created",      "pane.closed",
    "pane.updated",       "pane.focused",      "pane.moved",
    "pane.exited",        "pane.agent_detected", "layout.updated",
};

pub const Dispatcher = struct { /* ver arriba */ };
pub const Sleeper = struct { /* ver arriba */ };

pub const EventsClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    socket_path: []const u8, // copia propia (gpa-owned) — el hilo vive más que el llamador de start()
    dispatcher: Dispatcher,
    sleeper: Sleeper,
    on_event: *const fn (ctx: *anyopaque, envelope: types.EventEnvelope) void,
    on_resynced: *const fn (ctx: *anyopaque, snapshot: types.SessionSnapshot) void,
    callback_ctx: *anyopaque,

    stopping: std.atomic.Value(bool) = .init(false),
    conn: ?Connection = null, // protegido por el propio hilo; stop() solo lee `stream` para shutdown
    thread: ?std.Thread = null,

    pub fn start(self: *EventsClient) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Limpio: marca stop, desbloquea una lectura en curso con shutdown(.recv)
    /// (mismo mecanismo que el Watchdog de client.zig), y hace join.
    pub fn stop(self: *EventsClient) void {
        self.stopping.store(true, .release);
        if (self.conn) |c| c.stream.shutdown(self.io, .recv) catch {};
        if (self.thread) |t| t.join();
    }

    fn run(self: *EventsClient) void { /* bucle de reconexión, ver más abajo */ }
};
```

Bucle de `run`, en trazo grueso (todo dentro de `while (!self.stopping.load(.acquire))`):

1. `conn.open(io, socket_path)` (mismo out-param que `request()` — dirección fija antes de `open`).
2. Envía `events.subscribe` con `subscription_types` mapeados a `.{ .type = t }` por elemento
   (mismo patrón `json.Stringify.value` que `sendRequest`, pero escrito a mano porque la conexión
   se mantiene abierta y `sendRequest`/`request()` son de un solo tiro).
3. Lee una línea con el patrón `takeLine` de `client.zig:465-472`; si el `result.type` no es
   `"subscription_started"` → tratar como error de protocolo y reconectar con backoff.
4. **Reset de backoff** al recibir el ack.
5. `request(gpa, io, socket_path, "session.snapshot", .{}, default_read_timeout_ms, &rpc_err)` en
   una conexión *aparte* (one-shot, no interfiere con la de suscripción) → decodifica
   `SessionSnapshot` → `dispatcher.invoke(resync_trampoline, ctx)`.
6. Bucle de lectura: cada línea NDJSON se parsea como `EventEnvelope` y se entrega vía
   `dispatcher.invoke(event_trampoline, ctx)` — nunca se llama `on_event`/`on_resynced`
   directamente desde este hilo.
7. Al fallar la lectura (EOF/error) o si `stopping` ya es `true`: cerrar conn, si `stopping` salir
   sin dormir; si no, `sleeper.sleep(backoff_ms)`, avanzar `backoff_ms` en la secuencia
   `1,2,4,8,16,30,30,…` (tope 30 000 ms) y volver a 1.

## Escenarios (Gherkin)

```gherkin
Escenario: pane_updated llega al callback en menos de 200 ms (manual, QA en sesión con herdr vivo)
Dado un `EventsClient` corriendo contra herdr real, suscrito y con ack recibido
Cuando cambia el estado de un agente en un pane
Entonces `on_event` recibe un `EventEnvelope{.event = .pane_updated}` en menos de 200 ms

Escenario: reconexión tras `herdr server stop` + reinicio (manual, QA en sesión real)
Dado un `EventsClient` corriendo y suscrito
Cuando se para el servidor herdr y se vuelve a levantar
Entonces el log/estado interno muestra los intentos de backoff 1,2,4,8,16,30… segundos
Y al reconectar llega un `resynced(snapshot)` con el `session.snapshot` completo
Y el sidebar (fuera de alcance de este issue, lo consume un issue posterior) quedaría correcto sin
   reiniciar kelpie — este issue entrega el contrato, no el consumidor

Escenario: FakeServer emite ack + 3 eventos + cierra → reconecta con backoff correcto (test, Sleeper inyectado)
Dado un `FakeServer` que responde el ack `subscription_started`, emite 3 líneas de evento y cierra
Cuando el `EventsClient` corre con un `Sleeper` de test que registra `ms` sin dormir de verdad
Entonces los 3 eventos se entregan vía `dispatcher.invoke` en orden
Y tras el cierre, el `Sleeper` de test registra `1000` como primer `ms` pedido
Y si el `FakeServer` vuelve a cerrar sin responder tras la reconexión, el segundo `ms` registrado es `2000`
Y un ack recibido a tiempo resetea la secuencia: una tercera reconexión exitosa vuelve a pedir `1000`, no `4000`

Escenario: ningún callback se ejecuta fuera del "hilo de UI" (test, Dispatcher de test)
Dado un `Dispatcher` de test que graba `std.Thread.getCurrentId()` en cada `invoke`
Cuando el `EventsClient` entrega eventos y un resync
Entonces el id grabado por `invoke` es siempre distinto al `std.Thread.Id` del hilo lector de `EventsClient`
Y `on_event`/`on_resynced` nunca se invocan salvo dentro del `task` que `dispatcher.invoke` recibe

Escenario: stop() limpio
Dado un `EventsClient` corriendo con una lectura bloqueada (FakeServer que no responde)
Cuando se llama `stop()`
Entonces `stream.shutdown(.recv)` desbloquea la lectura, el hilo termina, y `stop()` retorna sin
   colgarse ni dejar el hilo huérfano (verificado con `Thread.join()` retornando)

Escenario: sin fugas
Dado cualquiera de los escenarios de test anteriores corrido bajo `std.testing.allocator`
Cuando el test termina
Entonces no hay fugas — incluye el `socket_path` copiado y cada `Response`/`RpcError` del resync
```

## Riesgos y preguntas abiertas

- El criterio de aceptación literal pide `glib.MainContext.isOwner` en el assert de debug. Este
  issue no puede cumplirlo al pie de la letra porque `Events.zig` no importa `gobject` (decisión
  tomada con el orquestador). Lo que se entrega es el contrato que hace ese assert seguro cuando
  exista el `Dispatcher` real — verificado con la comparación de `std.Thread.Id` de arriba. El
  assert real con `isOwner` queda como trabajo del issue que wiree `Events.zig` a `app.zig`.
- El primer criterio ("< 200 ms", herdr real) y el de reconexión real contra `herdr server stop`
  son manuales — igual que los escenarios de ventana real de otros issues del repo, QA los ejecuta
  a mano en la sesión Wayland y los reporta, no hay test automatizado de reloj real.
- La sección "Excluidos a propósito" del schema no tiene número de línea estable (es JSON, no Zig)
  — se verificó con un script Python que carga el JSON y lista los `oneOf` con más de un campo
  requerido; queda documentado el comando en vez de una línea, por honestidad con la fuente.
