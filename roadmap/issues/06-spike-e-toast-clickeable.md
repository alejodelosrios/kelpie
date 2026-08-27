title: Spike E — toast de Omarchy con `--exec` clickeable: argv ejecutado, `-r`/`-p`, `dismiss`, no-molestar
labels: type:spike,area:omarchy,risk:high
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Gate de M0. El requisito 2 del proyecto (notificación clickeable que enfoca al agente) depende
enteramente del hint `omarchy-exec-argv` de Quickshell. Se verifica el día uno, desde un script,
antes de escribir una línea de Zig para notificaciones. Depende de #1.

## Alcance
Entra: un script `scripts/spike-e.sh` que ejercita `omarchy notification send` con `--app-name kelpie`,
`-g`, `-u`, `-p`, `-r`, `--exec` (argv que escribe sus argumentos en un archivo temporal, con un
argumento que contiene espacios y otro que empieza por `$(`), `omarchy notification dismiss`, y el
comportamiento con `omarchy toggle notification silencing` activado y desactivado (dejarlo como
estaba al terminar). Resultados anotados en el issue.
No entra: código Zig; decidir el diseño de la notificación (eso es #18).

## Criterios de aceptación
- [ ] Al hacer click en la toast, el archivo temporal contiene los argumentos **literales**: el que tiene espacios llega como uno solo y `$(id)` llega sin expandir.
- [ ] `-p` imprime un id numérico; reenviar con `-r <id>` reemplaza la toast en vez de apilarla.
- [ ] `omarchy notification dismiss "<substring>"` retira la toast visible y devuelve `ok`.
- [ ] Con no-molestar activo y `--app-name kelpie`, la toast NO aparece; con el `--app-name` por defecto (`omarchy-action`) sí. Decisión anotada: kelpie respeta DND (usa su nombre).
- [ ] `-g` muestra el glifo Nerd Font en la toast; `-u critical` y `normal` se distinguen visualmente.
- [ ] La toast sigue siendo clickeable tras `omarchy restart shell` (la acción es dato, no callback).

## Referencias
- `/usr/share/omarchy/bin/omarchy-notification-send` (flags: 60-78; `--exec`: 117-137, 176-179).
- `/usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js:34-38` (DND), `:60-93` (exec argv).
- `/usr/share/omarchy/shell/Commons/Util.qml:57-64` (`execArgv`).

## Skills
`omarchy-app`, `omarchy`.
