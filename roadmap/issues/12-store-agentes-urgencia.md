title: Store de agentes: snapshot + eventos → lista por urgencia, transiciones de estado observables
labels: type:feat,area:ui,area:rpc
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Una sola fuente de verdad en memoria para sidebar, búsqueda, notificaciones, barra y archivo de
estado. Depende de #9, #10.

## Alcance
Entra: `src/model/Store.zig`: mapa `(device_id, pane_id) → Agent {title, agent kind, status,
workspace, tab, cwd?, revision, focused}` + espacios (workspaces) por dispositivo; `applySnapshot`,
`applyEvent` (`pane_created/updated/closed`, `pane_agent_status_changed`, `workspace_*`, `tab_*`);
orden de urgencia `blocked 0 → done 1 → working 2 → idle 3 → unknown 4`, desempate `revision`
desc; lista de observadores (`onChanged`, `onTransition(agent, from, to)`) invocados en el hilo de
UI; título visible = `title ?? terminal_title_stripped ?? agent ?? pane_id`.
No entra: persistencia, multi-dispositivo (#34 añade el device_id real; aquí `local`).

## Criterios de aceptación
- [ ] Test: snapshot con 4 agentes + `pane_updated` que pasa uno a `blocked` → primero en la lista y `onTransition(working→blocked)` disparado una vez.
- [ ] Test: `pane_closed` quita el agente; un `pane_updated` de un pane desconocido lo crea (eventos fuera de orden no rompen).
- [ ] Test: `agent_status` desconocido → `unknown`, al final de la lista.
- [ ] Sin fugas; `zig build test` verde.

## Referencias
- Regla de orden verificada en `Models.swift:16-24` del fork de herdrm (solo la regla).

## Skills
`zig-libghostty`.
