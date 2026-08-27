title: Sidebar por urgencia: espacios y agentes, glifos de estado (idle no dibuja nada), filas de 28/30 px y hairlines
labels: type:feat,area:ui
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Valor #1 del proyecto y la clave estética de herdrm: la interfaz solo grita cuando hay algo que
atender. Depende de #12, #13, #14.

## Alcance
Entra: `gtk.ListView` con `gio.ListStore` alimentado por el Store: sección por dispositivo (solo
`local` en M1), dentro espacios (workspaces) como filas de 30 px con su `agent_status` agregado, y
agentes como filas de 28 px ordenadas por urgencia; `AgentStatusGlyph` widget compartido:
`working` = spinner de 12 px (rotación lineal 0.9 s, color `--status-working`), `blocked` = círculo
con exclamación Nerd Font a 11 px semibold `--status-blocked`, `done` = check a 10.5 px bold
`--status-done`, `idle`/`unknown` = **nada**; título 13 medium `--text-1`, subtítulo 11.5 `--text-2`
(agente · cwd corto); selección con `--item-wash-selected`; hover `--item-wash`; separadores
hairline 1 px; click selecciona y dispara `focusAgent` (consumido por #19 y luego #27).
No entra: drag & drop de espacios, renombrar, menús contextuales, dispositivos remotos (#34).

## Criterios de aceptación
- [ ] Con 4 agentes idle el sidebar no muestra ningún glifo ni animación; al bloquearse uno sube al primer lugar con el glifo en < 200 ms.
- [ ] Alturas medidas con el inspector GTK: agentes 28 px, espacios 30 px, cabecera 42 px, separadores 1 px.
- [ ] El spinner solo existe mientras el estado es `working` (no hay widget oculto girando).
- [ ] Colores exclusivamente por `var(--…)` (inspector: sin valores literales en las reglas de kelpie).
- [ ] 200 agentes: scroll fluido (ListView recicla filas).

## Referencias
- Skill `omarchy-app` §mapeo y métricas; `Theme.swift:64-92` del fork (regla del glifo, sin copiar código).
- context7: GTK4 `GtkListView`, `GtkSignalListItemFactory`, `GtkSectionModel`.

## Skills
`omarchy-app`, `context7`.
