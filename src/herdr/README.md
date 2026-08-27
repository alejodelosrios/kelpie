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
