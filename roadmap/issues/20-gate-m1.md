title: Gate M1 — v0.1 usable a diario en el dispositivo local
labels: type:docs
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Checklist de cierre de M1. Depende de #8–#19.

## Criterios de aceptación (una semana de uso real)
- [ ] kelpie arranca con herdr parado (autostart), con herdr vivo y tras `herdr server stop` (sin reinicio indebido).
- [ ] 5 agentes reales durante 5 días: cada bloqueo produjo una toast clickeable que enfocó al agente correcto; `done` no molestó con el pane a la vista.
- [ ] `omarchy theme set` ×3 con kelpie abierta: retematizado en vivo sin restos.
- [ ] Attach externo desde el sidebar y or-focus al re-clickear.
- [ ] `coredumpctl list kelpie` vacío; RSS < 150 MB tras 5 días.
- [ ] Etiqueta `v0.1.0` y CHANGELOG inicial.

## Skills
`diagnose-crash`.
