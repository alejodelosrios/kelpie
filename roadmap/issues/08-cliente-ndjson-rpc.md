title: Cliente NDJSON-RPC sobre socket Unix: una conexión por petición, timeout, errores tipados y test con servidor falso
labels: type:feat,area:rpc
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Primer ladrillo de M1. herdr cierra la conexión tras una petición (verificado en #5), así que el
cliente es deliberadamente simple: conectar, escribir una línea, leer una línea, cerrar.
Depende de #7.

## Alcance
Entra: `src/herdr/Rpc.zig`: `request(gpa, socket_path, method, params: anytype) !Response` con `id`
string monotónico, `params` siempre presente (objeto vacío por defecto), timeout de 15 s en lectura,
lectura por trozos de 64 KiB con buffer de arrastre hasta `\n`, mapeo de `{code,message}` a
`error.HerdrRpc` + struct `RpcError` (códigos conocidos: `invalid_request invalid_params agent_blocked
agent_not_ready pane_not_found invalid_target ui_busy protocol_mismatch …`), resolución de ruta:
`HERDR_SOCKET_PATH` → `$XDG_CONFIG_HOME/herdr/herdr.sock` → `~/.config/herdr/herdr.sock`;
`FakeServer` de test (socket Unix en hilo) que responde ping, devuelve error, cierra sin responder
y responde en dos fragmentos.
No entra: tipos de dominio (#9), eventos (#10), autostart (#11), multiplexación por `id`.

## Criterios de aceptación
- [ ] `request(.ping)` contra herdr real devuelve `result.type == "pong"` (test gated por `HERDR_ENV=1`).
- [ ] Tests con `FakeServer`: respuesta partida en 2 `write` se ensambla; error → `error.HerdrRpc` con `code`; cierre sin respuesta → `error.EndOfStream`; sin respuesta en 15 s → `error.Timeout` (usar timeout corto inyectable).
- [ ] Ninguna petición reutiliza conexión; `strace -e connect` muestra un `connect()` por request.
- [ ] `id` es string en el JSON emitido (test que inspecciona la línea).
- [ ] Sin fugas con `std.testing.allocator`.

## Referencias
- #5 (contrato observado), `socket-api.mdx` vía `https://herdr.dev/llms.txt`.
- `std.net` / `std.posix` (AF_UNIX, `sockaddr_un` 108 bytes: rutas largas fallan; la ruta por defecto cabe).

## Skills
`zig-libghostty`, `herdr`.
