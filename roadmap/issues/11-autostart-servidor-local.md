title: Autostart del `herdr server` local solo si nunca estuvo: sonda por `connect()`, socket ambiguo re-probado, proceso no poseído
labels: type:feat,area:rpc
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Un arranque en frío debe conectar, no decir "no hay servidor". Pero reiniciar un servidor que el
usuario paró a propósito (o que `herdr update` está reemplazando) es peor que no arrancarlo.
Depende de #8.

## Alcance
Entra: `src/herdr/LocalServer.zig` con `ensureRunning(socket_path)`: (1) si `connect()` acepta →
corriendo (nunca `fileExists` como prueba de vida: herdr crea el archivo decenas de ms antes de
aceptar y un servidor muerto lo deja atrás); (2) si el archivo no existe → nunca arrancó → lanzar;
(3) si existe pero rechaza → ambiguo: re-probar 1 s cada 50 ms antes de declararlo obsoleto (un
servidor sano con la cola llena también rechaza, y `herdr server` reacciona a un socket rechazado
borrándolo y ocupándolo: dejaría al servidor vivo huérfano con todos los panes). Lanzar =
`$SHELL -lc 'exec herdr server'` (PATH de login para que los panes encuentren `claude`/`codex`),
stdout/err a un archivo único en `$XDG_STATE_HOME/kelpie/`, proceso **no poseído** (no se mata al
salir). Esperar ≤ 10 s a que el socket acepte; salida no-cero del hijo no es fallo si otro ganó el
bind. Guardia: autostart solo si en este proceso nunca se conectó antes (`everConnected == false`).
Mensajes de estado desde `herdr status --json` (`server.running/compatible/restart_needed`).
No entra: arrancar servidores remotos, gestionar `herdr update`.

## Criterios de aceptación
- [ ] Sin `herdr.sock`: kelpie arranca el servidor y conecta en < 3 s; `pgrep -f 'herdr server'` sigue vivo tras cerrar kelpie.
- [ ] Con un archivo de socket muerto (crear uno con `python3 -c 'import socket;…bind…'` y matar): kelpie espera ~1 s y arranca.
- [ ] `herdr server stop` con kelpie abierto: kelpie muestra "servidor detenido" y **no** lo reinicia; "Reconectar" en la UI sí.
- [ ] Los panes del servidor arrancado por kelpie tienen el mismo `PATH` que un shell de login (`echo $PATH` en un pane).
- [ ] Tests con sockets falsos para los tres estados y para el guardia `everConnected`.

## Referencias
- Referencia de comportamiento (no copiar): `Packages/HerdrKit/Sources/HerdrKit/LocalServer.swift:51-100` del fork de herdrm.
- `herdr server --help`, `herdr status --json`.

## Skills
`zig-libghostty`, `herdr`.
