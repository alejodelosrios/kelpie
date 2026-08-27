title: Spike D — hablar con el socket de herdr: `ping` (protocol ≥ 20), `session.snapshot`, `agent.list` y un stream de eventos
labels: type:spike,area:rpc
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Gate de M0. Verifica desde Zig el contrato real del API NDJSON de herdr 0.8.2 (protocol 20):
una petición por conexión, `id` string, `params` obligatorio, `events.subscribe` persistente.
Depende de #1.

## Alcance
Entra: `kelpie --herdr-probe` (o test gated por `HERDR_ENV=1`) que, contra `~/.config/herdr/herdr.sock`
(o `HERDR_SOCKET_PATH`): (1) envía `{"id":"1","method":"ping","params":{}}\n`, lee una línea, valida
`result.type == "pong"` y `result.protocol >= 20`; (2) en conexión nueva, `session.snapshot` y
cuenta workspaces/tabs/panes/agents; (3) `agent.list` e imprime `pane_id`, `agent`, `agent_status`
por agente; (4) abre una conexión persistente, envía `events.subscribe` con `{"subscriptions":[{"type":…}]}`
para los tipos sin parámetros del schema, lee el ack `{"type":"subscription_started"}` y vuelca las
siguientes 5 líneas de eventos; (5) demuestra los errores: `id` numérico y sin `params` → `error.code
== "invalid_request"`. Solo métodos de lectura.
No entra: tipos completos (#9), reconexión (#10), autostart (#11).

## Criterios de aceptación
- [ ] Salida del probe pegada en el issue con `protocol` real y conteos del snapshot.
- [ ] Un segundo request en la misma conexión falla con EPIPE/EOF (documenta que el servidor cierra tras una petición no-suscripción).
- [ ] Los 5 eventos volcados incluyen al menos un `pane_updated` con `agent_status` al interactuar con un agente.
- [ ] Los cinco valores de `AgentStatus` (`idle working blocked done unknown`) quedan anotados en la skill/README del módulo `herdr`.
- [ ] `herdr api schema --json > src/herdr/testdata/herdr-api.schema.json` vendorizado (255 KB) con `scripts/update-schema.sh`.

## Referencias
- `herdr api schema --json` (schema local, protocol 20); rama `master` del repo: `docs/next/api/herdr-api.schema.json` (protocol 21, mismos 91 métodos).
- Docs: `https://herdr.dev/llms.txt` → `socket-api.mdx` ("Send one request per line… Event subscriptions keep the connection open").
- Envelope: `{id: string, method, params}`; éxito `{id, result{type,…}}`; error `{id, error{code,message}}`.

## Skills
`herdr` (requiere `HERDR_ENV=1`), `zig-libghostty`.
