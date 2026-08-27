title: Instancia única con GApplication: `kelpie focus <device>/<pane>`, `reload-theme`, `reload-font` llegan a la instancia primaria
labels: type:feat,area:ui
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
El `--exec` de la notificación (#18), el plugin de barra (#41) y los hooks (#45) necesitan mandar
órdenes a la kelpie que ya está abierta. GApplication ya resuelve instancia única y reenvío de
argv por D-Bus: no se escribe IPC propia. Depende de #13.

## Alcance
Entra: flag `G_APPLICATION_HANDLES_COMMAND_LINE`; handler `command-line` que parsea
`focus <device-id>/<pane-id>`, `reload-theme`, `reload-font` y sin argumentos = `activate`
(presentar ventana); si no hay instancia, la misma invocación arranca kelpie y aplica la orden tras
el primer snapshot; subcomandos locales que **no** deben viajar a la primaria (`--version`, `setup`,
`askpass`, `--herdr-probe`) se despachan antes de `run` mirando `argv[1]`; `focus` selecciona el
agente en el sidebar, lo enfoca (#19/#27) y presenta la ventana (`gtk.Window.present`).
No entra: `gapplication` CLI como interfaz pública, acciones D-Bus con parámetros.

## Criterios de aceptación
- [ ] Con kelpie abierta, `kelpie focus local/<pane>` vuelve en < 100 ms con exit 0 y la primera instancia selecciona y presenta.
- [ ] Sin kelpie abierta, el mismo comando la abre y enfoca el agente tras cargar.
- [ ] `kelpie focus local/inexistente` → exit 1 y mensaje en stderr de la **segunda** instancia.
- [ ] `kelpie --version` y `kelpie setup --dry-run` funcionan sin que exista D-Bus de sesión (`dbus-run-session` no necesario) y sin activar la primaria.
- [ ] Test unitario del parser de argumentos.

## Referencias
- context7: GIO `GApplication::command-line`, `g_application_command_line_get_arguments`, `G_APPLICATION_HANDLES_COMMAND_LINE`, `g_application_command_line_set_exit_status`.
- Ghostty `src/apprt/gtk/application.zig` (uso de `gio.Application`).

## Skills
`zig-libghostty`, `context7`.
