title: Notificaciones por `omarchy notification send`: bloqueado (critical) y terminado (normal) con `--exec kelpie focus`, `-r`/`-p`, `-g` y `dismiss`
labels: type:feat,area:omarchy
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Valor #2 del proyecto. La forma exacta la fijó el Spike E (#6). Depende de #6, #12, #17.

## Alcance
Entra: `src/omarchy/Notify.zig` suscrito a `onTransition` del Store: `* → blocked` y `* → done`
(omitir `done` si ese pane está enfocado en kelpie con la ventana activa); argv construido como
array, sin shell: `omarchy notification send --app-name kelpie -g <glifo> -u critical|normal -p
[-r <id>] "<título> · <agente>" "<agente> needs your input · <espacio> · <dispositivo>" --exec kelpie
focus <device-id>/<pane-id>`; id numérico devuelto por `-p` guardado por `(device, pane)` y reusado
con `-r` (nunca se apilan toasts del mismo agente); al enfocar un agente,
`omarchy notification dismiss "<título> · <agente>"`; glifos Nerd Font: bloqueado `󰀦`, terminado `󰄬`;
preferencias: activar/desactivar por estado.
No entra: sonido propio (lo decide el shell), DND (#46), libnotify.

## Criterios de aceptación
- [ ] Bloquear un agente (`herdr agent prompt` que pida confirmación) → toast critical en < 500 ms; click → kelpie al frente con ese agente enfocado (vía #17); la toast desaparece (`dismiss`).
- [ ] Dos bloqueos seguidos del mismo agente → una sola toast (reemplazada, id reutilizado).
- [ ] Título con `$(id)`, comillas y `--` llega literal a la toast y al argv del `--exec` (inyección imposible por construcción: `std.process.Child` con argv).
- [ ] `done` del pane que estoy mirando no notifica; `done` de otro sí, con `-u normal`.
- [ ] Test unitario de la construcción del argv (con y sin `-r`) y del mapa de ids.

## Referencias
- Skill `omarchy-app` §2; `/usr/share/omarchy/bin/omarchy-notification-send` (flags 60-78, `--exec` 117-137, hint 176-179).
- Referencia de comportamiento (no copiar): `NotificationManager.swift` del fork (qué estados notifican y textos).

## Skills
`omarchy-app`, `omarchy`.
