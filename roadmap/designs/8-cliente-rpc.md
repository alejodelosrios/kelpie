# Diseño — #8 Cliente NDJSON-RPC sobre socket Unix: una conexión por petición, timeout, errores tipados y test con servidor falso

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-28

## Spec

Extiende `src/herdr/client.zig` (ya trae `Connection.open/close/sendRequest` y
`resolveSocketPath` de #5) con una función `request()` de un tiro, timeout de lectura inyectable,
errores tipados, el escalón `XDG_CONFIG_HOME` que le falta a `resolveSocketPath`, y un `FakeServer`
de test.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/herdr/client.zig` — todo lo de abajo.
- `src/herdr/README.md` — documentar `request()`, `RpcError` y el tercer escalón de
  `resolveSocketPath`.

**No entra:**
- Tipos de dominio (#9), eventos (#10), autostart (#11), multiplexación por `id`.
- La "lectura por trozos de 64 KiB con buffer de arrastre" original — recortada por YAGNI en el
  propio issue: `net.Stream.Reader` + `takeDelimiterExclusive` ya lo hacen.
- No se toca `src/main.zig`: su `test {}` (línea 76, `_ = herdr_probe;`) ya arrastra los tests de
  `client.zig` porque `probe.zig` importa `client.zig`. Se confirma en FASE 4 añadiendo un test que
  falle a propósito y viendo `zig build test` ponerse rojo, luego retirándolo — no es una firma que
  haga falta citar, es un comportamiento del test runner que se verifica ejecutándolo.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Todas verificadas con `sed -n '<línea>p' <archivo>` contra el std
instalado (`zig 0.16.0`, `/usr/lib/zig/std/`) y contra el propio `client.zig`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `Connection.open(self, io, socket_path) !void` | `src/herdr/client.zig:28` | ✅ |
| `Connection.close(self) void` | `src/herdr/client.zig:39` | ✅ |
| `Connection.sendRequest(self, request: anytype) ![]u8` | `src/herdr/client.zig:45` | ✅ |
| `resolveSocketPath(environ: std.process.Environ.Map, buf) ![]const u8` | `src/herdr/client.zig:64-65` | ✅ |
| `environ.get("HOME") orelse return error.HomeNotSet` (patrón a replicar para `XDG_CONFIG_HOME`) | `src/herdr/client.zig:70` | ✅ |
| `net.Stream.Reader.Error` incluye `Timeout` como variante directa | `/usr/lib/zig/std/Io/net.zig:1263-1270` | ✅ |
| `netReadPosix`: `.TIMEDOUT => return error.Timeout` (dos ramas, wasi y posix genérico) | `/usr/lib/zig/std/Io/Threaded.zig:12593` y `:12625` | ✅ |
| `posix.setsockopt(fd: socket_t, level: i32, optname: u32, opt: []const u8) SetSockOptError!void` | `/usr/lib/zig/std/posix.zig:1073` | ✅ |
| `posix.SOL = system.SOL` / `posix.SO = system.SO` | `/usr/lib/zig/std/posix.zig:123` y `:125` | ✅ |
| `SO.RCVTIMEO = 18` (rama genérica no-mips, aplica a x86_64-linux-gnu) | `/usr/lib/zig/std/os/linux.zig:4407` | ✅ |
| `posix.timeval = system.timeval` → `extern struct { sec: isize, usec: i64 }` | `/usr/lib/zig/std/posix.zig:191` y `/usr/lib/zig/std/os/linux.zig:8680-8683` | ✅ |
| `net.Socket.Handle = std.posix.fd_t` (campo `stream.socket.handle`) | `/usr/lib/zig/std/Io/net.zig:1077` y `:1053` | ✅ |
| `UnixAddress.init(p) InitError!UnixAddress` | `/usr/lib/zig/std/Io/net.zig:848` | ✅ |
| `UnixAddress.listen(ua, io, options) ListenError!Server` | `/usr/lib/zig/std/Io/net.zig:880` | ✅ |
| `Server.accept(s, io) AcceptError!Stream` | `/usr/lib/zig/std/Io/net.zig:1442` | ✅ |
| `Server.deinit(s, io) void` (cierra el socket) | `/usr/lib/zig/std/Io/net.zig:1406` | ✅ |
| `std.Io.Dir.deleteFileAbsolute(io, absolute_path) DeleteFileError!void` | `/usr/lib/zig/std/Io/Dir.zig:1008` | ✅ |
| `std.Thread.spawn(config: SpawnConfig, function, args) SpawnError!Thread` | `/usr/lib/zig/std/Thread.zig:344` | ✅ |
| `std.meta.stringToEnum(comptime T, str) ?T` | `/usr/lib/zig/std/meta.zig:18` | ✅ |
| `json.parseFromSlice` / `json.Stringify.value` | `/usr/lib/zig/std/json/static.zig:73` y `/usr/lib/zig/std/json/Stringify.zig:573` | ✅ (ya en uso en `client.zig`) |
| `std.atomic.Value(T).init` / `.fetchAdd` | `/usr/lib/zig/std/atomic.zig:16` y `:52` | ✅ |

## Decisión de diseño: timeout con `SO_RCVTIMEO`, no un reloj inyectado

`std.Io.net.Stream` no expone ninguna variante con timeout para lecturas (`receiveTimeout` solo
existe en `Socket` para datagramas, `net.zig:1164` — no aplica a `Stream`, que es lo que usa
`Connection`). `netReadPosix` (`Threaded.zig:12552-12629`) llama a `readv` crudo y solo traduce
`ETIMEDOUT` si el socket ya tiene `SO_RCVTIMEO` puesto vía `setsockopt` — no hay ningún parámetro de
`Io.Timeout` que llegue hasta ahí para una `Stream`.

Alternativa considerada: pasar un deadline/reloj inyectado y correr un hilo o `select` en paralelo
para abortar la lectura. Se descarta por YAGNI — es más código (un hilo o un mecanismo de
cancelación nuevo) para lograr exactamente lo mismo que ya ofrece el kernel: `setsockopt` con
`SO_RCVTIMEO` es 4 líneas, reusa el `error.Timeout` que `Stream.Reader.Error` ya declara
(`net.zig:1263-1270`), y cumple el criterio de aceptación tal cual está escrito ("timeout corto
inyectable" para que el test no duerma de verdad: en el test se pasa `read_timeout_ms` pequeño, p.ej.
50, y `FakeServer` simplemente no responde).

```zig
fn setReadTimeout(handle: net.Socket.Handle, ms: u32) std.posix.SetSockOptError!void {
    const tv: std.posix.timeval = .{
        .sec = @intCast(ms / 1000),
        .usec = @as(i64, @intCast(ms % 1000)) * 1000,
    };
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}
```

Se aplica sobre `conn.stream.socket.handle` justo después de `Connection.open`, antes de
`sendRequest`. Solo afecta lecturas (`RCVTIMEO`), que es lo único que el criterio pide cronometrar.

## API nueva en `client.zig`

```zig
pub const default_read_timeout_ms: u32 = 15_000;

pub const RpcErrorCode = enum {
    invalid_request,
    invalid_params,
    agent_blocked,
    agent_not_ready,
    pane_not_found,
    invalid_target,
    ui_busy,
    protocol_mismatch,
    unknown, // código no reconocido — no rechazamos, dejamos ver el mensaje crudo
};

pub const RpcError = struct {
    code: RpcErrorCode,
    message: []u8, // gpa-owned, el llamador libera con `.deinit(gpa)`

    pub fn deinit(self: RpcError, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
    }
};

pub const Response = json.Parsed(json.Value);

/// Un tiro sobre `Connection`: abre, envía, lee una línea, cierra.
/// `params` va siempre en el JSON emitido, aunque sea `.{}`.
/// En error de protocolo (`{"error":{code,message}}`) devuelve `error.HerdrRpc`
/// y deja el detalle en `rpc_err.*` — el llamador lo libera con `.deinit(gpa)`
/// solo si `rpc_err.* != null`.
pub fn request(
    gpa: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    method: []const u8,
    params: anytype,
    read_timeout_ms: u32,
    rpc_err: *?RpcError,
) !Response
```

Nota sobre la firma del issue (`request(gpa, socket_path, method, params) !Response`): el prosa del
issue omite `io` (imprescindible — `Connection.open` lo exige, `client.zig:28`), `read_timeout_ms`
(el propio issue lo pide "inyectable", que solo puede ser un parámetro) y `rpc_err` (Zig no tiene
payload en `error.HerdrRpc`; el patrón `campo `.err`` ya vive en este archivo para `Writer`/`Reader` —
aquí es un out-param en vez de un campo porque `request` no tiene una instancia persistente).

Cuerpo, en trazo grueso:

```zig
pub fn request(gpa, io, socket_path, method, params, read_timeout_ms, rpc_err) !Response {
    rpc_err.* = null;

    var conn: Connection = undefined; // dirección final antes de open (client.zig:22-24)
    try conn.open(io, socket_path);
    defer conn.close();

    try setReadTimeout(conn.stream.socket.handle, read_timeout_ms);

    var id_buf: [20]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{next_id.fetchAdd(1, .monotonic)}) catch unreachable;

    const line = conn.sendRequest(.{ .id = id, .method = method, .params = params }) catch |err| {
        if (err == error.ReadFailed) {
            if (conn.reader.err) |real| if (real == error.Timeout) return error.Timeout;
        }
        return err;
    };

    const parsed = try json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true });

    if (parsed.value.object.get("error")) |err_obj| {
        const code_str = (err_obj.object.get("code") orelse return error.UnexpectedResponse).string;
        const msg = (err_obj.object.get("message") orelse return error.UnexpectedResponse).string;
        rpc_err.* = .{
            .code = std.meta.stringToEnum(RpcErrorCode, code_str) orelse .unknown,
            .message = try gpa.dupe(u8, msg),
        };
        parsed.deinit();
        return error.HerdrRpc;
    }

    return parsed;
}

var next_id: std.atomic.Value(u64) = .init(1);
```

`resolveSocketPath` gana el escalón `XDG_CONFIG_HOME` entre `HERDR_SOCKET_PATH` y `HOME` (mismo
patrón de `client.zig:70`, verificado — nada nuevo que citar):

```zig
if (environ.get("HERDR_SOCKET_PATH")) |p| return p;
if (environ.get("XDG_CONFIG_HOME")) |xdg| { /* xdg + "/herdr/herdr.sock" */ }
const home = environ.get("HOME") orelse return error.HomeNotSet; // fallback existente
```

## `FakeServer` de test

Socket Unix real en un hilo (`std.Thread.spawn`), escucha en una ruta bajo `/tmp` derivada de
`std.testing.tmpDir` o de un nombre único con el PID (para no chocar entre corridas en paralelo),
acepta una conexión, y según el escenario:
- responde `{"result":{"type":"pong"}}` en un solo `write` (ping feliz).
- responde el mismo JSON partido en dos `write()` separados con una pausa corta entre medio, para
  el escenario "se ensambla en 2 fragmentos" — usa `net.Stream.writer` normal, sin flush entre
  ambos si hace falta forzar el corte, o dos `stream.writer(...).interface.writeAll` + `flush`
  consecutivos sobre el mismo `Stream` (no hay reconexión).
- responde `{"error":{"code":"invalid_params","message":"..."}}`.
- acepta la conexión y la cierra sin escribir nada (`stream.close(io)` inmediato) — cubre
  `error.EndOfStream`.
- acepta la conexión y no responde nunca (bloquea el hilo en un `sleep` largo o simplemente no
  llama a `write`) — cubre `error.Timeout` con `read_timeout_ms` corto (p.ej. 50 ms) pasado por el
  test, no el timeout real de 15 s.

Limpieza: `Server.deinit(io)` + `std.Io.Dir.deleteFileAbsolute(io, path)` en un `defer` del test
(el socket Unix deja un inodo en el filesystem que `deinit`/`close` no borra).

## Escenarios (Gherkin)

```gherkin
Escenario: ping contra herdr real (gated HERDR_ENV=1)
Dado un `HERDR_ENV=1` real con socket vivo
Cuando se llama `request(gpa, io, socket_path, "ping", .{}, default_read_timeout_ms, &rpc_err)`
Entonces la respuesta parseada tiene `result.type == "pong"`
Y `rpc_err.*` sigue siendo `null`

Escenario: respuesta partida en 2 writes se ensambla
Dado un `FakeServer` que escribe la respuesta de ping en dos `write()` separados
Cuando se llama `request(...)` contra su socket
Entonces la línea NDJSON completa se parsea sin error
Y el `result.type` es `"pong"`

Escenario: error de protocolo mapea a error.HerdrRpc
Dado un `FakeServer` que responde `{"error":{"code":"invalid_params","message":"falta X"}}`
Cuando se llama `request(...)`
Entonces la llamada devuelve `error.HerdrRpc`
Y `rpc_err.*.?.code == .invalid_params`
Y `rpc_err.*.?.message` contiene `"falta X"`

Escenario: cierre sin responder
Dado un `FakeServer` que acepta y cierra sin escribir nada
Cuando se llama `request(...)`
Entonces la llamada devuelve `error.EndOfStream`

Escenario: sin respuesta en el timeout inyectado
Dado un `FakeServer` que acepta y nunca responde
Cuando se llama `request(...)` con `read_timeout_ms = 50`
Entonces la llamada devuelve `error.Timeout`
Y el test termina en milisegundos, no en 15 s reales

Escenario: una conexión por petición
Dado dos llamadas sucesivas a `request(.ping)` contra herdr real
Cuando se observa con `strace -e connect` (QA lo corre manualmente en la sesión Wayland)
Entonces aparece un `connect()` por request, nunca uno reusado

Escenario: id es string en el JSON emitido
Dado una llamada a `request(...)`
Cuando se inspecciona (vía `FakeServer` capturando lo recibido, o releyendo `conn.sendRequest`)
   la línea NDJSON enviada
Entonces el campo `"id"` aparece entre comillas (string), nunca como número desnudo

Escenario: resolveSocketPath cubre los tres escalones
Dado un `environ` con solo `HERDR_SOCKET_PATH` puesto
Cuando se llama `resolveSocketPath`
Entonces devuelve ese valor verbatim
Dado un `environ` con `XDG_CONFIG_HOME` puesto y sin `HERDR_SOCKET_PATH`
Cuando se llama `resolveSocketPath`
Entonces devuelve `$XDG_CONFIG_HOME/herdr/herdr.sock`
Dado un `environ` con solo `HOME` puesto
Cuando se llama `resolveSocketPath`
Entonces devuelve `$HOME/.config/herdr/herdr.sock`

Escenario: guard de regresión de memoria cubre el camino nuevo
Dado una `Connection` local abierta contra `FakeServer` dentro de `request()`
Cuando se compara `@intFromPtr(&conn.read_buf)` contra `@intFromPtr(conn.reader.interface.buffer.ptr)`
   justo antes de que `request()` cierre la conexión (vía un hook de test o repitiendo el patrón
   existente de `openLive`)
Entonces las direcciones coinciden — `conn` nunca se copió fuera de su dirección final

Escenario: sin fugas
Dado cualquiera de los escenarios anteriores corrido bajo `std.testing.allocator`
Cuando el test termina
Entonces no hay fugas reportadas (incluye liberar `rpc_err.*.message` y el `Response` con
   `.deinit(gpa)` en el camino feliz)
```

## Riesgos y preguntas abiertas

- `RpcErrorCode` como enum cerrado con variante `.unknown`: si herdr agrega un código nuevo, el
  cliente no rompe (cae a `.unknown`), pero el mensaje crudo sigue disponible en
  `RpcError.message` — no hace falta que el enum liste todos los códigos posibles del servidor.
- El escenario de "responder en 2 fragmentos" en `FakeServer` depende de que el segundo `write` no
  se junte con el primero a nivel de kernel (buffer local de socket puede coalescer). Si en la
  práctica siempre llegan juntos, el test no prueba lo que dice — mitigación: forzar el corte
  metiendo el primer fragmento, haciendo un `flush()` explícito, y una pausa de pocos ms antes del
  segundo `write`, no confiar en que dos `writeAll` sin pausa produzcan dos `read()` del lado
  cliente.
