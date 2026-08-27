title: TerminalView: widget GTK4 que dibuja solo filas sucias del RenderState con Pango/GSK
labels: type:feat,area:render,area:vt,risk:high
milestone: M2 — Terminal embebido
---
## Contexto
Núcleo de M2. Convierte el veredicto del Spike B (#3) y el flujo del Spike C (#4) en el widget
real. Un `Terminal` + `RenderState` protegidos por un mutex; el hilo de UI pinta en `snapshot`.
Depende de #7 (gate), #3, #4.

## Alcance
Entra: `src/terminal/TerminalView.zig` como subclase de `gtk.Widget` que posee el terminal, el
render state y el mutex; método `feed(bytes)` (llamado desde el hilo lector de #23) que escribe al
terminal bajo lock y solicita redibujo en el hilo de UI (`glib` idle/invoke → `queue_draw`); vfunc
`snapshot` que hace `begin_update` bajo lock, `end_update` fuera, itera **solo filas sucias**,
reconstruye el nodo GSK de cada fila sucia (caché de nodos por fila) y termina con `clean()`;
fondo por celda, texto por runs de estilo igual con avances forzados al ancho de celda, bold/italic/
underline/strikethrough/inverse, caracteres anchos (2 celdas) y cursor bloque básico; `resize` del
widget → `Terminal.resize` con las dimensiones de rejilla derivadas de #22.
No entra: PTY (#23), entrada (#24), selección (#25), estilos de cursor y paleta del tema (#26), imágenes.

## Criterios de aceptación
- [ ] Con 1 fila cambiada entre frames, un contador interno reporta exactamente 1 nodo reconstruido; con `full` dirty, todos.
- [ ] Alimentando 1 MB de texto en trozos de 64 KiB a 60 Hz (test harness sin PTY), el widget mantiene ≥ 60 fps en una rejilla 200×60 y no pinta desde el hilo que alimenta.
- [ ] Tras cada frame se llama `clean()`; un frame sin cambios no reconstruye ningún nodo.
- [ ] Redimensionar la ventana cambia cols/filas del terminal y `stty size` (cuando exista PTY) coincide con la rejilla visible.
- [ ] Sin `unreachable` ni `catch unreachable` en el camino de render; los errores se registran con `std.log`.
- [ ] `zig build test` incluye un test que alimenta SGR + texto y comprueba filas sucias antes/después de `clean()`.

## Referencias
- `include/ghostty/vt/render.h:23-72` (dos fases, dos capas), `:605-612` (iterador de sucias).
- `src/apprt/gtk/class/surface.zig:827` (queueRender), `App.zig:23` (no dibujar desde otro hilo).
- Spike B (#3): código del renderer Pango/GSK y sus números.
- context7: GTK4 `gtk_snapshot_append_layout` / `gsk_text_node_new`, `GtkWidgetClass.snapshot`, `g_main_context_invoke`.

## Skills
`zig-libghostty`, `context7`.
