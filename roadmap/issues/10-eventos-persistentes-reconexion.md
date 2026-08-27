title: Suscripción a eventos persistente con reconexión (1 s → 30 s) y re-`session.snapshot` al reconectar
labels: type:feat,area:rpc
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
El sidebar y las notificaciones viven de los eventos. El contrato documentado por herdr: bootstrap
con `session.snapshot`, suscribirse en una conexión larga, actualizar la caché con eventos y
**re-snapshot tras cada reconexión**. Depende de #8, #9.

## Alcance
Entra: `src/herdr/Events.zig`: hilo que abre conexión, envía `events.subscribe` con los tipos sin
parámetros del schema (lista en código, verificada por el test de #9), espera el ack
`subscription_started`, entrega cada evento decodificado a un callback en el hilo de UI
(`glib.MainContext` invoke), y al EOF/error reintenta con backoff 1, 2, 4, 8, 16, 30, 30… s (reset al
recibir el ack); tras cada reconexión emite `resynced(snapshot)` con un `session.snapshot` nuevo;
`stop()` limpio (cierra el fd, join).
No entra: suscripciones parametrizadas (`pane.output_matched`, `pane.scroll_changed`), persistencia.

## Criterios de aceptación
- [ ] Con herdr vivo, cambiar el estado de un agente produce un `pane_updated` en el callback en < 200 ms.
- [ ] `herdr server stop` + `herdr` de nuevo: el log muestra la secuencia de backoff y, al volver, un `resynced` con el snapshot completo; el sidebar queda correcto sin reiniciar kelpie.
- [ ] `FakeServer` en test: emite ack + 3 eventos + cierra → el cliente reconecta y el contador de intentos sigue la secuencia (test del backoff sin dormir de verdad: reloj inyectable).
- [ ] Ningún callback se ejecuta fuera del hilo de UI (assert en debug con `glib.MainContext.isOwner`).

## Referencias
- `socket-api.mdx` §session.snapshot (contrato de reconexión); ack observado en #5.
- herdrm: los tres tipos pane-scoped se excluyen a propósito; los cambios de estado llegan globalmente por `pane_updated`.

## Skills
`zig-libghostty`, `herdr`.
