title: Tipos del subconjunto usado del API de herdr, validados contra el schema vendorizado en `zig build test`
labels: type:feat,area:rpc
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
El schema tiene 91 métodos; kelpie usa ~12. Generar 91 tipos es trabajo muerto; escribirlos a mano
sin control es inventar el protocolo. Solución: tipos a mano del subconjunto + un test que los
contrasta con `herdr-api.schema.json`. Depende de #8.

## Alcance
Entra: `src/herdr/types.zig`: `AgentStatus = enum { idle, working, blocked, done, unknown }` con
fallback a `unknown` para valores desconocidos; `Pong {version, protocol, capabilities?}`;
`AgentInfo {pane_id, tab_id, workspace_id, terminal_id, agent_status, focused, revision, agent?,
display_agent?, name?, title?, cwd?, terminal_title?, terminal_title_stripped?, state_change_seq?}`;
`PaneInfo`, `TabInfo`, `WorkspaceInfo` (con su `agent_status` agregado), `SessionSnapshot`,
eventos `pane_updated pane_created pane_closed pane_agent_status_changed workspace_created
workspace_closed workspace_renamed tab_*` con `{event, data}`; parseo con `std.json` e
`ignore_unknown_fields = true`; test que carga `testdata/herdr-api.schema.json`, localiza cada
`$defs` usado y afirma que (a) todo campo `required` del schema existe en nuestro struct, (b) los
valores del enum `AgentStatus` coinciden exactamente, (c) los nombres de método/evento que usamos
existen en `request.oneOf` / `EventKind`.
No entra: generador de código, cobertura de los 91 métodos.

## Criterios de aceptación
- [ ] `zig build test` falla si se renombra un campo requerido de `AgentInfo` en el schema (probar mutando una copia).
- [ ] Un `agent_status` futuro (`"paused"`) decodifica a `.unknown` sin error.
- [ ] Campos opcionales ausentes (observado: `name/title/display_agent/state_labels`) quedan `null`, no fallan.
- [ ] `scripts/update-schema.sh` regenera `testdata/` con `herdr api schema --json` y el test sigue verde con protocol 20 y 21.

## Referencias
- Schema: `schemas.request.oneOf[91]`, `schemas.event.$defs.EventKind`, `schemas.success_response.$defs.{AgentInfo,PaneInfo,SessionSnapshot,Pong}`.
- `std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true })`.

## Skills
`zig-libghostty`, `herdr`.
