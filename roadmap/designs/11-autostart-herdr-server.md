# Diseño — #11 Autostart del `herdr server` local solo si nunca estuvo: sonda por `connect()`, socket ambiguo re-probado, proceso no poseído

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-30

## Spec

`src/herdr/LocalServer.zig` nuevo: `ensureRunning()` decide, mediante `connect()` (nunca `fileExists`),
si el `herdr server` local está vivo, y lo lanza como proceso huérfano no poseído solo cuando nunca
estuvo vivo en este proceso.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/herdr/LocalServer.zig` — nuevo módulo completo (lógica + tests).
- `build.zig` — **solo apéndice al final** (patrón `theme_css_mod`, líneas 83-91): módulo de test
  propio para `LocalServer.zig`, sin tocar ninguna línea existente. `src/main.zig` está arrendado a
  #17 esta ola — este módulo no lo importa ni lo toca; su consumidor futuro (#17) lo conectará en su
  propio PR.

**No entra** (del issue + recorte YAGNI):
- Arrancar servidores remotos, gestionar `herdr update` (explícito en el issue).
- **Corrección de scope (orquestador del fleet, wA:p1, en FASE 4):** el recorte original descartaba
  `herdr status --json` entero. Se mantiene el recorte para `running`/`stopped` — ahí `connect()` es
  la autoridad y es el punto central del issue, un segundo camino de lectura sería fuente de verdad
  duplicada. Pero **`compatible`/`restart_needed` no salen de `connect()`**: un servidor con
  protocolo incompatible acepta la conexión TCP/Unix igual (el rechazo de protocolo es a nivel
  NDJSON-RPC, no a nivel socket) — ninguna otra ruta da ese dato, y el criterio de aceptación de #19
  depende de él. `ensureRunning` sí lee esos dos campos de `herdr status --json` cuando el servidor
  resulta alcanzable (`.connected`/`.launched`), vía `std.process.run` (ver tabla de citas).
- Wiring del botón "Reconectar" en la UI y la llamada real a `ensureRunning` desde `app_shell.zig`
  — eso es `src/ui/`, terreno de #17, y `main.zig` está arrendado. Este issue expone el `Mode.force`
  que ese wiring necesitará; conectar el botón es su PR, no el mío.
- Reaping/zombie-reaping del proceso lanzado — señalado en "Riesgos", no resuelto aquí: el issue
  pide explícitamente "proceso no poseído (no se mata al salir)", que es precisamente no llamar
  `wait()`/`kill()` sobre él.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Fuente: el toolchain instalado (`zig version` → `0.16.0`,
`/usr/lib/zig/std`) — es la fuente de verdad #2 de `CLAUDE.md`; este módulo no toca `ghostty-vt` así
que el mirror pinneado no aplica aquí. Todas verificadas con `sed -n '<línea>p'`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `net.UnixAddress.init(path)` | `/usr/lib/zig/std/Io/net.zig:848` | ✅ |
| `net.UnixAddress.connect(ua, io) ConnectError!Stream` | `/usr/lib/zig/std/Io/net.zig:908` | ✅ |
| `Stream.close(s: *const Stream, io: Io) void` | `/usr/lib/zig/std/Io/net.zig:1248` | ✅ |
| Mapeo real de errno en la ruta AF_UNIX — **no** el `ConnectError` set declarado en `net.zig:891-906` (ese incluye `ConnectionRefused`, que este camino nunca produce) | `/usr/lib/zig/std/Io/Threaded.zig:11947-11987` (`posixConnectUnix`) | ✅ — ver "Riesgos", es el hallazgo central del diseño |
| `Io.sleep(io: Io, duration: Duration, clock: Clock) Cancelable!void` | `/usr/lib/zig/std/Io.zig:2397` | ✅ |
| `Io.Duration.fromMilliseconds(x: i64) Duration` | `/usr/lib/zig/std/Io.zig:982` | ✅ |
| `std.process.spawn(io: Io, options: SpawnOptions) SpawnError!Child` | `/usr/lib/zig/std/process.zig:442` | ✅ |
| `SpawnOptions{ argv, stdin: StdIo, stdout: StdIo, stderr: StdIo, environ_map: ?*const Environ.Map }` | `/usr/lib/zig/std/process.zig:360-435` | ✅ |
| `StdIo.file: File` / `StdIo.ignore` (union variants) | `/usr/lib/zig/std/process.zig:408-434` | ✅ |
| Fork/dup2 no cierra el fd del padre para `.file` — el llamador debe cerrarlo tras `spawn()` | `/usr/lib/zig/std/Io/Threaded.zig:14900-15095` (`spawnPosix`, `setUpChildIo`, solo `.pipe` se cierra en el padre) | ✅ |
| `Dir.cwd().createDirPath(io, sub_path) CreateDirPathError!void` (recursivo, éxito si ya existe) | `/usr/lib/zig/std/Io/Dir.zig:843` | ✅ |
| `createFileAbsolute(io, absolute_path, flags) File.OpenError!File` | `/usr/lib/zig/std/Io/Dir.zig:642` | ✅ |
| `Environ.Map.get(self: Map, key) ?[]const u8` (recibido por valor, mismo patrón que `client.resolveSocketPath`) | `/usr/lib/zig/std/process/Environ.zig:285`, convención en `src/herdr/client.zig:64-68` | ✅ |
| `Io.Timestamp.now(io, clock) Timestamp` (para el sufijo único del log) | `/usr/lib/zig/std/Io.zig:909` | ✅ |
| `FakeServer` sobre socket Unix real en un hilo, para tests deterministas sin depender del binario `herdr` | patrón ya existente, `src/herdr/client.zig:601-616` (`startFakeServer`) | ✅ (reutilizado como referencia de estilo, no importado) |
| `std.process.run(gpa, io, options: RunOptions) RunError!RunResult` — captura stdout/stderr de `herdr status --json`, esperando a que termine | `/usr/lib/zig/std/process.zig:496` | ✅ |
| `RunOptions{ argv, environ_map, ... }` / `RunResult{ term, stdout, stderr }` (caller-owned, hay que `gpa.free`) | `/usr/lib/zig/std/process.zig:458-492` | ✅ |
| `json.parseFromSlice(T, gpa, slice, .{ .ignore_unknown_fields = true })` sobre un struct propio `{ server: struct { compatible: bool, restart_needed: bool } }` — mismo patrón que usa `types.zig` para el resto del API de herdr | `src/herdr/client.zig:200` (uso ya existente en este repo) | ✅ |

## Diseño de la API

```zig
pub const Mode = enum { auto, force }; // force = "Reconectar" de la UI, ignora la guardia

pub const Kind = enum {
    connected,             // ya estaba vivo (connect() aceptó a la primera)
    launched,               // lo lanzamos y aceptó dentro de los 10s
    launch_timed_out,       // lo lanzamos pero no aceptó a tiempo
    stopped_no_autostart,    // confirmado muerto, ever_connected==true, mode==.auto: no se relanza
};

/// `compatible`/`restart_needed` solo se rellenan cuando `kind` implica un
/// servidor alcanzable (`.connected`/`.launched`) — para `.launch_timed_out`
/// y `.stopped_no_autostart` no hay a quién preguntarle, quedan `null`. Si
/// `herdr status --json` falla o no parsea con el servidor ya alcanzable
/// (proceso no encontrado, JSON inesperado), también quedan `null`: un dato
/// de compatibilidad que no se pudo leer no es un motivo para que
/// `ensureRunning` falle — el servidor sigue corriendo igual.
pub const Status = struct {
    kind: Kind,
    compatible: ?bool = null,
    restart_needed: ?bool = null,
};

/// Inyectado para hacer testeable el lanzamiento sin el binario `herdr` real:
/// recibe `socket_path` porque un launcher de test necesita saber dónde
/// levantar su `FakeServer`; recibe `environ` porque el launcher real lo usa
/// para `$SHELL` y `$XDG_STATE_HOME`, no para resolver el socket (ese lo
/// resuelve `herdr` mismo).
pub const Launcher = *const fn (io: Io, environ: Environ.Map, socket_path: []const u8) anyerror!void;

/// Lanzador real: `$SHELL -lc 'exec herdr server'`, stdout/stderr a un
/// archivo único en `$XDG_STATE_HOME/kelpie/` (o `$HOME/.local/state/kelpie/`
/// si no está seteado), proceso no poseído (no se guarda el `Child`, nunca se
/// llama `wait`/`kill`).
pub fn spawnHerdrServer(io: Io, environ: Environ.Map, socket_path: []const u8) !void;

pub const ServerCompat = struct { compatible: bool, restart_needed: bool };

/// Inyectado por la misma razón que `Launcher`: el binario `herdr` real no
/// está garantizado en CI/sandbox. `null` de retorno (no error) significa
/// "no se pudo leer" y es indistinguible, para `ensureRunning`, de un
/// `herdr status --json` que falló — en ambos casos `Status.compatible`/
/// `.restart_needed` quedan `null`.
pub const StatusReader = *const fn (io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat;

/// Lector real: `std.process.run(gpa, io, .{.argv = &.{"herdr","status","--json"}, ...})`,
/// parsea `{"server":{"compatible":bool,"restart_needed":bool}}` del stdout. Cualquier fallo
/// (spawn, término no-cero, JSON que no parsea) se traga y devuelve `null` — nunca propaga error.
pub fn readHerdrStatus(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat;

pub fn ensureRunning(
    io: Io,
    gpa: std.mem.Allocator,
    environ: Environ.Map,
    socket_path: []const u8,
    mode: Mode,
    ever_connected: bool,
    launch: Launcher,
    status_reader: StatusReader,
) !Status;
```

Lógica de `ensureRunning` (los tres casos + guardia del issue, en orden):

1. `tryConnect` una vez. Si acepta → `.connected` (cierra la conexión de sonda de inmediato).
2. Si falla con `error.FileNotFound` → nunca arrancó, va directo al paso 4 (sin la ventana de
   reintento de 1s: no hay ambigüedad que resolver, el archivo no existe).
3. Cualquier otro error (incluido `error.Unexpected`, que es lo que realmente produce un socket
   viejo sin listener — ver "Riesgos") → ambiguo: reintenta `tryConnect` cada 50ms durante 1s. Si
   algún intento acepta → `.connected`. Si los 20 intentos fallan → confirmado muerto, sigue al
   paso 4.
4. Guardia: si `mode == .auto` y `ever_connected == true` → `.stopped_no_autostart`, no se lanza
   nada. (`mode == .force`, el camino del botón "Reconectar", ignora la guardia.)
5. `launch(io, environ, socket_path)`. Luego reintenta `tryConnect` cada 50ms durante 10s. Acepta
   dentro de la ventana → `.launched`; si no → `.launch_timed_out`. Un `Child` con salida no-cero no
   se trata como fallo (no se inspecciona: no se guarda el `Child`) — lo único que importa es si el
   socket llegó a aceptar.
6. Si el `Kind` resultante es `.connected` o `.launched`: `status_reader(io, gpa, environ)`. `null`
   → los dos campos quedan `null`; `ServerCompat` → se copian a `Status.compatible`/`.restart_needed`.
   Nunca cambia el `Kind` ya decidido por `connect()` — este paso es puramente informativo.

`ever_connected` es responsabilidad del llamador (vive en `app_shell.zig`/#17: es estado de sesión de
proceso, `ensureRunning` es sin estado entre llamadas — ninguna de las dos cosas es terreno de este
módulo).

## Escenarios (Gherkin)

```gherkin
Escenario: Sin herdr.sock, kelpie arranca el servidor y conecta
  Dado que socket_path no existe en el filesystem
  Cuando ensureRunning corre con mode=.auto y ever_connected=false, y el launcher inyectado
    levanta un FakeServer real en socket_path dentro de la ventana de 10s
  Entonces ensureRunning devuelve Status{.kind = .launched, ...}
  Y el launcher fue invocado exactamente una vez

Escenario: compatible/restart_needed se leen vía el StatusReader inyectado cuando el servidor responde
  Dado un servidor alcanzable (Kind .connected o .launched) y un StatusReader de test que devuelve
    ServerCompat{.compatible = false, .restart_needed = true}
  Cuando ensureRunning termina de resolver el Kind
  Entonces Status.compatible == false y Status.restart_needed == true

Escenario: un StatusReader que devuelve null no cambia el Kind ya resuelto
  Dado un servidor alcanzable y un StatusReader de test que siempre devuelve null
  Cuando ensureRunning corre
  Entonces Status.kind es el mismo que sin el StatusReader (.connected/.launched según el caso)
  Y Status.compatible == null y Status.restart_needed == null

Escenario: el StatusReader nunca se invoca si el servidor no es alcanzable
  Dado mode=.auto, ever_connected=true y el socket muerto (confirmado tras el reintento de 1s)
  Cuando ensureRunning corre
  Entonces devuelve Status{.kind = .stopped_no_autostart, .compatible = null, .restart_needed = null}
  Y el StatusReader de test (que registra si fue llamado) nunca fue invocado

Escenario: Socket muerto (bind-then-kill), kelpie espera ~1s y arranca
  Dado un archivo de socket en socket_path creado con un listener que se cerró sin aceptar
    (net.UnixAddress.listen + server.deinit inmediato, sin accept — reproduce el ECONNREFUSED
    de un servidor muerto)
  Cuando ensureRunning corre con mode=.auto y ever_connected=false
  Entonces el tiempo transcurrido antes de invocar el launcher es >= 1000ms (a las 20 reintentos
    de 50ms) y < 2000ms (no se pasó de la ventana)
  Y el launcher fue invocado

Escenario: herdr server stop con kelpie abierto, no reinicia solo, "Reconectar" sí
  Dado el mismo socket muerto del escenario anterior y ever_connected=true
  Cuando ensureRunning corre con mode=.auto
  Entonces devuelve .stopped_no_autostart y el launcher NUNCA fue invocado
  Cuando ensureRunning corre después con mode=.force (mismo socket, mismo ever_connected=true)
  Entonces invoca el launcher y puede llegar a .launched

Escenario: PATH de login en los panes del servidor arrancado por kelpie
  (criterio manual — no automatizable desde un test Zig: requiere el `herdr server` real y un pane
  real. QA lo ejecuta a mano: levantar con kelpie, abrir un pane, `echo $PATH`, comparar contra un
  shell de login (`$SHELL -lc 'echo $PATH'`). Ver "Riesgos".)
```

Los escenarios automatizables (todos salvo el de PATH de login) se implementan como tests Zig con
`FakeServer`/sockets reales en `/tmp` y `Launcher`/`StatusReader` de test, mismo patrón que
`client.zig` — no contra el `herdr` real, así que corren en CI sin él.

## Riesgos y preguntas abiertas

- **Hallazgo central, no una suposición**: contra lo que el propio `ConnectError` de
  `net.UnixAddress` sugiere (declara `ConnectionRefused` en su set, `net.zig:891-906`), la
  implementación real para sockets Unix (`posixConnectUnix`, `Threaded.zig:11947-11987`) **no tiene
  una rama para `ECONNREFUSED`** — cae en el `else` genérico y sale como `error.Unexpected`
  (`posix.unexpectedErrno`, que solo hace `debug.print` + stack trace en modo debug si
  `unexpected_error_tracing` está activo, **nunca panic** — verificado en
  `/usr/lib/zig/std/posix.zig:1669-1675`). Por eso el paso 3 de la lógica atrapa "cualquier error
  que no sea `FileNotFound`" en vez de matchear `error.ConnectionRefused` explícitamente: un diseño
  que hiciera lo segundo nunca dispararía el reintento de 1s contra un socket muerto real.
- **`errnoBug` en vez de un error catcheable, para `NOTSOCK`/`BADF`/etc.** (`Threaded.zig:11977-11983`):
  si `socket_path` apuntara a un archivo que existe pero no es un socket AF_UNIX, `connect()` haría
  `panic` en modo debug (`errnoBug`, `Threaded.zig:14054-14056`). No debería ocurrir en el flujo
  normal (herdr siempre crea un socket real en esa ruta cuando la crea), así que se deja como hueco
  declarado, no como caso manejado: si algún día un fallo distinto deja un archivo regular en esa
  ruta, `ensureRunning` puede *panic*-ear en vez de devolver un error. No es el `unreachable`/`catch
  unreachable` que ADR-0001/#21 prohíben en código propio (es interno a la stdlib), pero el efecto —
  matar la sesión — es el mismo. Documentado como riesgo, no resuelto: resolverlo requeriría un
  `statFile` previo solo para este caso de borde hipotético, que es código extra para algo que nunca
  se ha observado.
- **El proceso lanzado puede quedar zombie** si `herdr server` termina mientras kelpie sigue vivo:
  el issue pide explícitamente "no poseído (no se mata al salir)", que se traduce a nunca guardar el
  `Child` ni llamar `wait()`/`kill()` sobre él — la contrapartida inevitable de eso en POSIX es que,
  si el hijo termina antes que kelpie, queda zombie hasta que kelpie mismo termine (momento en el que
  se reparenta a init y se cosecha solo). Aceptado como el comportamiento que el propio issue pide;
  no se resuelve con un hilo "reaper" porque eso es exactamente la propiedad ("no poseído") que el
  criterio de aceptación pide que NO tenga.
- **El criterio de PATH de login no es verificable por un test Zig**: requiere el binario `herdr`
  real y un pane real de Herdr corriendo. Queda como paso manual de QA (FASE 6 del flow), no como
  test automatizado — declarado aquí para que QA no lo redescubra como "falta cobertura".
- **`readHerdrStatus` (el `StatusReader` real) no tiene test automatizado contra el `herdr` real**,
  igual que el `Launcher` real (`spawnHerdrServer`) — mismo motivo: CI/sandbox no garantiza el
  binario. La cobertura automatizada es sobre la lógica de `ensureRunning` con un `StatusReader` de
  test; que `herdr status --json` real produzca exactamente `{"server":{"compatible":...,
  "restart_needed":...}}` lo verifica QA a mano en la misma sesión donde valida PATH de login (ya
  hay una sesión real con `herdr` vivo para ese criterio, es el mismo paso). Si el schema real de
  `herdr status --json` no coincidiera, `readHerdrStatus` lo trata como "no parsea" → `null` — no
  hay riesgo de panic ni de bloquear `ensureRunning`, solo de perder el dato de compatibilidad.
- **Filename único del log**: se usa `Io.Timestamp.now(io, .awake).nanoseconds` como sufijo. No hay
  garantía teórica de unicidad entre dos arranques en el mismo nanosegundo (imposible en la práctica
  para este flujo, que ocurre como mucho una vez por arranque de kelpie), así que no se le añade PID
  ni un contador — sería código extra para una colisión que no puede pasar aquí.
