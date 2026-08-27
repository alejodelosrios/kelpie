title: Archivo de estado `$XDG_STATE_HOME/kelpie/status.json` escrito atómicamente en cada cambio
labels: type:feat,area:omarchy
milestone: M5 — Integración Omarchy
---
## Contexto
Fuente de datos del plugin de barra (#41) y de cualquier script del usuario. Un archivo, escritura
atómica, formato estable. Depende de #12.

## Alcance
Entra: en cada cambio del store de agentes, escribir `{ "version": 1, "updated_at": <unix>,
"blocked": [ { "device": id, "device_name", "pane": id, "title", "agent" } ], "counts": { "blocked",
"done", "working", "idle" } }` a `status.json.tmp` + `rename` (atómico); borrar el archivo al salir
limpio (y en SIGTERM); coalescer ráfagas (≤ 4 escrituras/s).
No entra: historial, sockets, D-Bus.

## Criterios de aceptación
- [ ] `inotifywait -m ~/.local/state/kelpie/` muestra `MOVED_TO status.json` (nunca `MODIFY` parcial) al cambiar un agente.
- [ ] Un lector que lee mientras kelpie escribe nunca ve JSON truncado (test: 1000 escrituras concurrentes con un lector que parsea).
- [ ] Al cerrar kelpie el archivo desaparece; tras un crash simulado (SIGKILL) el siguiente arranque lo sobrescribe.
- [ ] El formato está documentado en `docs/status-json.md` con ejemplo.

## Skills
`zig-libghostty`, `omarchy-app`.
