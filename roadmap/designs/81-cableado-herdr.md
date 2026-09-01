# Diseño — #81 Cableado en vivo: herdr → Store → sidebar

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-09-01

## Spec

El dueño que junta piezas que ya existen y están probadas por separado. `src/ui/herdr_link.zig`
(nuevo) posee un `EventsClient` (#10), su `Dispatcher` real contra la main loop de GLib, y las
callbacks que mutan el `Store` (#12) **siempre desde el hilo de UI**. `app_shell.zig` lo arranca al
activar la ventana y lo para al cerrar la aplicación.

**Archivos que se tocan**, en dos tramos secuenciados (core primero, verificar, commitear, luego ui):

*Tramo 1 — `core-builder` (`src/herdr/`, `src/model/`):*
- `src/herdr/Events.zig` — `Dispatcher.invokeFn` pasa a poder fallar (§Dispatcher).
- `src/model/Store.zig` — `pane_agent_status_changed` deja de borrar campos que el evento no trae.

*Tramo 2 — `ui-builder` (`src/ui/`):*
- `src/ui/herdr_link.zig` — **nuevo**: `GlibDispatcher`, ciclo de vida, callbacks al Store.
- `src/ui/app_shell.zig` — guarda `io`/`environ`, arranca el link en `onActivate`, lo para en
  `shutdown`, y el estado vacío dice por qué no hay agentes.
- `src/main.zig` — una línea: `_ = herdr_link;` en el bloque `test {}`.

**No entra:**
- **La petición inicial de `session.snapshot` por separado.** Recorte grande y verificado en el
  código: `EventsClient.runOnce` ya hace connect → subscribe → ack → **`resync()`**
  (`Events.zig:151-167`), y `resync()` (`Events.zig:167-192`) pide `session.snapshot` y lo entrega
  por el mismo `Dispatcher`. Arrancar el `EventsClient` **es** el bootstrap del snapshot; una
  petición aparte duplicaría el trabajo y abriría una carrera con el primer `resync`.
- Reintentos configurables: el backoff 1 s → 30 s ya vive en `Events.zig:123-131`.
- Dispositivos remotos por SSH (#29–#33), persistencia, y la UI fina de diagnóstico (#32).
- Botón "Reconectar" (`LocalServer.Mode.force` existe para eso, pero es UI que nadie pidió aquí).
- Los tres tipos de evento que `Events.zig:68-78` excluye a propósito de la suscripción.

## El Dispatcher: por qué la costura tiene que poder fallar

**Corrección del gate (2026-09-01):** el diseño decía `glib.MainContext.invoke`. Lo desmintió
el test del hilo del propio `herdr_link.zig`: `MainContext.invoke` ejecuta la función **en
línea** cuando el hilo que llama puede adquirir el contexto, y sin main loop dueña puede
— la tarea corrió en el hilo trabajador (`expected 1949260, found 1949264`). En producción
GTK posee el contexto y probablemente nunca habría ocurrido, pero eso dejaba la garantía
central de este issue apoyada en un razonamiento sobre quién posee qué y cuándo, en vez de
sobre el mecanismo. Se usa **`glib.idleAddOnce`**: una fuente idle siempre se encola y la
drena la loop, nunca el llamador. Coste declarado: en tests, quien encola tiene que drenar.

`glib.idleAddOnce` (`glib2.zig:20815`) acepta **un** `user_data`, y `Dispatcher.invoke`
entrega **dos** punteros (`task` y `task_ctx`). Empaquetarlos exige alocar una caja, y esa alocación
puede fallar. Hoy `invokeFn` no puede fallar (`Events.zig:14-21`), así que si la caja no se puede
alocar **no hay forma de liberar `task_ctx`**: lo creó `Events.zig` con `gpa.create` y solo su
trampolín sabe destruirlo (`Events.zig:205-217`).

Dejarlo como fuga bajo OOM sería la **sexta** aparición en este repo de "una asignación que muere
antes de llegar a su dueño" (`Connection.open`, `openLive`, `request()`, los literales de `Row`, el
buffer de `Group`). Se elimina el modo de fallo en vez de documentarlo:

```zig
// Events.zig
invokeFn: *const fn (ptr: *anyopaque, task: ..., task_ctx: *anyopaque) anyerror!void,
pub fn invoke(self: Dispatcher, task: ..., task_ctx: *anyopaque) !void { ... }
```

Los dos llamadores están a la vista y ya tienen su `errdefer` al lado — `resync()` (`Events.zig:191`)
y `deliverEvent()` (`Events.zig:201`); cada uno pasa a `catch` liberando `parsed` y el `ctx`.
`resync()` ya trata así el fallo de `gpa.create` justo encima (`Events.zig:186-189`): es el mismo
patrón, no uno nuevo.

Implementación en `herdr_link.zig`:

```zig
const Box = struct { gpa: std.mem.Allocator, task: *const fn (*anyopaque) void, ctx: *anyopaque };

fn invokeImpl(ptr: *anyopaque, task: ..., task_ctx: *anyopaque) anyerror!void {
    const self: *GlibDispatcher = @ptrCast(@alignCast(ptr));
    const box = try self.gpa.create(Box);            // el `try` es el punto del cambio
    box.* = .{ .gpa = self.gpa, .task = task, .ctx = task_ctx };
    glib.MainContext.invoke(null, &trampoline, box); // null = main context por defecto, el de GTK
}

fn trampoline(data: ?*anyopaque) callconv(.c) c_int {
    const box: *Box = @ptrCast(@alignCast(data.?));
    box.task(box.ctx);
    box.gpa.destroy(box);
    return 0; // G_SOURCE_REMOVE: la fuente no se repite
}
```

**Asíncrono y sin bloquear, a propósito.** Una variante bloqueante (caja en pila + semáforo) se
descartó por deadlock real, no teórico: `EventsClient.stop()` (`Events.zig:112-121`) hace `join()`
del hilo lector, y se llama **desde el hilo de UI**; si el lector estuviera esperando a que la main
loop procese su tarea mientras la main loop espera el `join`, se abrazan. El asíncrono no puede
deadlockear y la propiedad de memoria ya la resolvió #10 poniendo el ctx en heap.

## Ciclo de vida y el hilo de arranque

`LocalServer.ensureRunning` (`LocalServer.zig:204`) puede tardar **hasta ~10 s** (ventana de
lanzamiento, `LocalServer.zig:71`). Correrlo en el hilo de UI cuelga la ventana, que es exactamente
lo que el criterio 2 prohíbe. Va en un hilo de arranque de vida corta:

```
onActivate ──> herdr_link.start(app)
                 │  resuelve socket (client.zig:64) en un buffer que vive en el link
                 └─ std.Thread.spawn(startupThread)
                        ensureRunning(io, gpa, environ, socket, .auto, ever_connected=false,
                                      spawnHerdrServer, readHerdrStatus)
                        ├─ dispatcher.invoke(publishStatus, ...) ── UI: texto del estado vacío
                        └─ EventsClient.start()  ── su propio hilo: connect→subscribe→resync→eventos

shutdown (gio.Application, gio2.zig:896) ──> herdr_link.stop()
                 join del hilo de arranque, luego EventsClient.stop() (que hace shutdown+join)
```

`on_event` → `Store.applyEvent`; `on_resynced` → `Store.applySnapshot`. Las dos corren **en el hilo
de UI por construcción**, porque el único camino hasta ellas pasa por el trampolín de arriba. El
sidebar se refresca solo: ya es `ChangeObserver` del `Store` desde #16.

**Errores del Store no matan la sesión**: `applyEvent`/`applySnapshot` devuelven `!void`; se
loguean con `std.log.err` y se sigue. Nada de `catch unreachable` (regla del repo).

## El borrado de campos del Store

`Store.zig:287-289` llama `updateOptionalField` con lo que traiga el evento, y
`updateOptionalField` (`Store.zig:700-704`) duplica `null`, libera lo que había y deja el campo en
`null` **sin condición**. Un `pane_agent_status_changed` que solo traiga el status borra `agent`,
`display_agent` y `title`, y `displayTitle()` cae al `pane_id`: la fila del usuario se degrada de
`claude` a `pane-0` justo al bloquearse — en el momento de máxima atención. Observado en vivo por el
auditor de #16 con el binario instrumentado; es la fila de `CONCERNS.md` que apunta a este issue.

Arreglo: **`null` significa "el evento no trae este campo", no "ponlo a null"**. Los payloads del
Store ya declaran estos campos como `?[]const u8`, así que un evento que quiera borrar de verdad no
tiene hoy forma de expresarlo — y no la necesita: el borrado real llega por `applySnapshot`.
`updateOptionalField` pasa a ignorar el `null` y solo actualizar cuando hay valor.

## Firmas de API que se van a usar

Verificadas por el PM con `sed -n '<línea>p' <archivo>`, **una línea por invocación** (`sed` imprime
en orden de archivo, no de argumentos — `lessons-learned.md`, Ola 3 M1).

`$GOB = /home/alejodelosrios/.cache/ghostty-build/src/zig-global-cache/p/gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3/`

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `glib.idleAddOnce(function: glib.SourceOnceFunc, data: ?*anyopaque) c_uint` | `$GOB/src/glib2/glib2.zig:20815` | ✅ |
| `glib.SourceOnceFunc = *const fn (?*anyopaque) callconv(.c) void` | `$GOB/src/glib2/glib2.zig:25660` | ✅ |
| `glib.MainContext.iteration(context: ?*MainContext, may_block: c_int) c_int` (solo en tests, para drenar) | `$GOB/src/glib2/glib2.zig:5311` | ✅ |
| `gio.Application.signals.shutdown` | `$GOB/src/gio2/gio2.zig:896` | ✅ |
| `client.resolveSocketPath(environ, buf: *[std.fs.max_path_bytes]u8) ![]const u8` | `src/herdr/client.zig:64` | ✅ |
| `LocalServer.ensureRunning(io, gpa, environ, socket_path, mode, ever_connected, launch, status_reader) !Status` | `src/herdr/LocalServer.zig:204` | ✅ |
| `LocalServer.spawnHerdrServer(io, environ, socket_path) !void` (el `Launcher` real) | `src/herdr/LocalServer.zig:81` | ✅ |
| `LocalServer.readHerdrStatus(io, gpa, environ) ?ServerCompat` (el `StatusReader` real) | `src/herdr/LocalServer.zig:146` | ✅ |
| `LocalServer.Mode` / `Kind` / `Status` | `src/herdr/LocalServer.zig:17` / `:23` / `:40` | ✅ |
| `Events.EventsClient` (campos: `gpa,io,socket_path,dispatcher,sleeper,on_event,on_resynced,callback_ctx`) | `src/herdr/Events.zig:84` | ✅ |
| `Events.EventsClient.start(self) !void` / `stop(self) void` | `src/herdr/Events.zig:105` / `:112` | ✅ |
| `Events.Dispatcher{ ptr, invokeFn }` — **la costura que este issue cambia a fallible** | `src/herdr/Events.zig:14` | ✅ |
| `Events.IoSleeper{ io, stopping }` / `.sleeper(self) Sleeper` | `src/herdr/Events.zig:42` / `:46` | ✅ |
| `Store.applySnapshot(self, snapshot: types.SessionSnapshot) !void` | `src/model/Store.zig:171` | ✅ |
| `Store.applyEvent(self, envelope: types.EventEnvelope) !void` | `src/model/Store.zig:238` | ✅ |
| `Store.updateOptionalField(gpa, field: *?[]const u8, new_val: ?[]const u8) !void` — **la que se arregla** | `src/model/Store.zig:700` | ✅ |
| `types.SessionSnapshot` | `src/herdr/types.zig:119` | ✅ |
| `EventsClient.resync()` ya pide `session.snapshot` — por eso NO se pide aparte | `src/herdr/Events.zig:167` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: con herdr corriendo, el sidebar muestra agentes reales sin flags
  Dado un herdr con al menos un agente
  Cuando se lanza kelpie sin ningún flag
  Entonces el sidebar deja de estar vacío
  Y los agentes que muestra son los de la sesión real de herdr

Escenario: sin herdr, la UI no se cuelga ni panica
  Dado que no hay ningún herdr corriendo
  Cuando se lanza kelpie
  Entonces la ventana responde durante todo el arranque
  Y o bien herdr se lanza y aparecen sus agentes, o el estado vacío dice por qué no hay ninguno
  Y el proceso no panica en ningún caso

Escenario: un bloqueo se ve sin tocar kelpie
  Dado kelpie corriendo con el sidebar poblado
  Cuando un agente pasa a blocked en herdr
  Entonces el sidebar lo muestra bloqueado y en primer lugar en menos de 500 ms

Escenario: el título del agente sobrevive al cambio de estado
  Dado un agente cuyo título visible es "claude"
  Cuando llega un pane_agent_status_changed que solo trae el status
  Entonces el título sigue siendo "claude"
  Y no cae al pane_id

Escenario: reconectar repuebla sin reiniciar kelpie
  Dado kelpie corriendo con el sidebar poblado
  Cuando se mata el servidor de herdr y se vuelve a levantar
  Entonces el sidebar se repuebla solo por on_resynced
  Y no hizo falta reiniciar kelpie

Escenario: ninguna mutación del Store ocurre en el hilo lector
  Dado un GlibDispatcher real y un EventsClient con un servidor falso
  Cuando llega un evento por el hilo lector
  Entonces la callback que muta el Store corre en el hilo de la main loop
  Y el id de hilo observado dentro de la callback no es el del hilo lector

Escenario: la costura de dispatch libera el evento cuando no puede encolarlo
  Dado un Dispatcher cuya alocación falla
  Cuando el hilo lector entrega un evento
  Entonces no se filtra ni el envelope parseado ni su contexto
  Y el EventsClient sigue vivo para el siguiente evento

Escenario: cerrar la ventana para los hilos
  Dado kelpie con el link arrancado
  Cuando se cierra la aplicación
  Entonces el hilo de arranque y el hilo lector terminan con join
  Y no queda memoria sin liberar bajo std.testing.allocator en los tests de la costura
```

## Obligaciones que bajan del ledger a este diseño

Regla nueva de la Ola C: leer `lessons-learned.md` no cuenta como cumplirlo. Filas vigentes que
tocan este issue, convertidas en algo verificable **aquí**:

1. **`#17` · contrato oculto en líneas preexistentes.** `gio.Application.run` ya se llama con
   `handles_command_line`, y ahora habrá hilos vivos: el `shutdown` de GApplication puede llegar por
   caminos que el diff no toca. **Obligación**: el Apply declara explícitamente por qué caminos se
   llega a `stop()` y QA prueba al menos el cierre normal de ventana.
2. **`#5`/`#8`/#16 · asignación que muere antes de llegar a su dueño (5 apariciones).**
   **Obligación**: la costura `!void` de arriba, más un escenario Gherkin dedicado (el séptimo).
3. **Test que no discrimina (4 apariciones).** **Obligación**: el escenario del hilo compara ids de
   hilo reales; un test que solo compruebe "la callback corrió" pasaría también con un dispatcher
   síncrono, que es justo el bug. QA lo sabotea sustituyendo el `GlibDispatcher` por uno directo y
   confirma rojo.
4. **`#12` · gate mecánico verde sobre un camino que ningún test ejercita**, y el **gate de
   ejecución real** de la Ola C. **Obligación**: este issue **no se cierra sin correr el binario
   contra un herdr de verdad**, capturar y mirar. Lo corre el PM.

## Riesgos y preguntas abiertas

- **Riesgo principal, y es de concurrencia**: `EventsClient.stop()` se llama desde el hilo de UI y
  hace `join`. Si algo en el camino de parada acaba esperando a la main loop, se abraza. El diseño
  lo evita con un dispatcher asíncrono, pero es lo primero que el auditor debe atacar.
- **`ever_connected` se pasa `false` siempre** en este issue: no hay persistencia de sesión ni botón
  de reconectar (`Mode.force`), así que no hay estado previo que consultar. Cuando exista #32 o el
  botón, ese parámetro deja de ser constante.
- **Hueco declarado, no supuesto**: no se verificó en la fuente qué hace GLib si
  `g_main_context_invoke` se llama **después** de que la main loop haya terminado (cierre de la app
  con un evento en vuelo). El diseño ordena la parada para que no ocurra —`stop()` antes de que la
  loop muera— pero si el auditor encuentra un camino en que sí ocurre, es un hallazgo legítimo y no
  está resuelto aquí.
- **No se verificó** si `readHerdrStatus` puede tardar lo suficiente como para dominar el arranque;
  vive dentro del hilo de arranque, así que no bloquea la UI, pero podría retrasar el primer
  `EventsClient.start()`. Medible en el gate de ejecución real.
