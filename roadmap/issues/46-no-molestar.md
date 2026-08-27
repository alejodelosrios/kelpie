title: No-molestar: kelpie respeta el silencio de Omarchy; opción explícita para que los bloqueos lo salten
labels: type:feat,area:omarchy
milestone: M5 — Integración Omarchy
---
## Contexto
El Spike E (#6) verificó que `--app-name omarchy-action` salta el DND y que con `--app-name kelpie`
no. La decisión por defecto: respetar al usuario. Depende de #18.

## Alcance
Entra: preferencia "Los agentes bloqueados saltan No molestar" (default off) que, solo para
`blocked`, cambia `--app-name` a `omarchy-action`; nota en la preferencia de que eso también marca la
toast como efímera; documentación en README.
No entra: leer el estado de DND desde kelpie, colas de notificaciones pospuestas.

## Criterios de aceptación
- [ ] Con DND activo (`omarchy toggle notification silencing`) y la opción off, ni bloqueado ni terminado muestran toast; el sidebar sí cambia.
- [ ] Con la opción on, bloqueado sí aparece y terminado no.
- [ ] Restaurado el estado de DND al terminar la prueba.

## Referencias
- `/usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js:34-43`.

## Skills
`omarchy-app`.
