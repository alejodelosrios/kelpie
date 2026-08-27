title: Selección (`Selection`/`SelectionGesture`) y portapapeles Wayland
labels: type:feat,area:vt,area:ui
milestone: M2 — Terminal embebido
---
## Contexto
La lógica de selección (por celda, palabra, línea, rectangular) ya está en `ghostty-vt`; kelpie
aporta el gesto y el portapapeles. Depende de #24.

## Alcance
Entra: `SelectionGesture` alimentado por press/drag/release y doble/triple click; pintado del rango
seleccionado con `--term-selection-bg/fg` (#26) como capa sobre las filas; `Ctrl+Shift+C` copia al
portapapeles (`gdk.Clipboard` del widget), selección → primary clipboard automáticamente; botón
central pega desde primary; `Shift+drag` fuerza selección aunque haya modo ratón; opción
"copiar al seleccionar".
No entra: búsqueda en el buffer (Oniguruma no está en el módulo Zig), selección de URLs.

## Criterios de aceptación
- [ ] Arrastrar selecciona; doble click selecciona palabra; triple, línea; `Ctrl+Alt+drag` rectangular.
- [ ] Lo copiado en kelpie se pega en Ghostty y viceversa (`wl-paste` lo confirma).
- [ ] La selección sobrevive al scroll del viewport y se limpia al escribir.
- [ ] Caracteres anchos y emoji se copian completos (sin medias celdas).
- [ ] Test: dado un `Screen` con texto conocido, seleccionar (0,0)-(0,4) devuelve exactamente `hola `.

## Referencias
- `src/lib_vt.zig` (`Selection`, `SelectionGesture`), `include/ghostty/vt/selection.h` (contrato documentado).
- context7: GTK4 `GdkClipboard`, `gtk_widget_get_primary_clipboard`.

## Skills
`zig-libghostty`, `context7`.
