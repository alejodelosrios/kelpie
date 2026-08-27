title: Entrada: teclado (`input.encodeKey`), ratón (`encodeMouse`), paste con brackets, foco e IME
labels: type:feat,area:vt,area:ui
milestone: M2 — Terminal embebido
---
## Contexto
El terminal debe hablar el protocolo que los programas esperan (incluido el protocolo de teclado
kitty si la app lo pide). Los codificadores vienen de `ghostty-vt`; kelpie solo traduce eventos GDK.
Depende de #23.

## Alcance
Entra: `gtk.EventControllerKey` → traducción de keyval/modificadores GDK a `input.KeyEvent` →
`input.encodeKey` con las opciones derivadas de los modos del terminal → escribir al PTY;
`gtk.IMMulticontext` para teclas muertas y composición (teclado latam: `ñ`, `á`, `¿`);
`gtk.GestureClick` + `EventControllerMotion` + `EventControllerScroll` → `input.encodeMouse` cuando
el modo de reporte de ratón está activo, si no, scroll del viewport; paste (`Ctrl+Shift+V`, botón
central) → `input.isSafePaste` (diálogo de confirmación si no es seguro) → `input.encodePaste`
(brackets según modo); `input.encodeFocus` en focus in/out si el modo está activo.
No entra: keybindings configurables, selección (#25).

## Criterios de aceptación
- [ ] En `bash`: flechas, `Home/End`, `Ctrl+flecha`, `Alt+b`, `F1-F12`, `Shift+Tab` producen las secuencias esperadas (comprobadas con `cat -v` / `showkey -a`).
- [ ] Con teclado latam, `´`+`a` produce `á` y `~`+`n` produce `ñ` vía IME; `AltGr+q` produce `@`.
- [ ] En `vim` con `set mouse=a`, el click mueve el cursor y la rueda hace scroll; sin modo ratón, la rueda desplaza el scrollback.
- [ ] Pegar texto con `\n` embebido pide confirmación cuando no hay bracketed paste; con bracketed paste se envuelve en `ESC[200~ … ESC[201~`.
- [ ] `kitty +kitten show-key -m kitty` (o `herdr`) recibe eventos con el protocolo kitty cuando lo solicita.
- [ ] Test unitario de la traducción GDK → `KeyEvent` para 10 teclas representativas.

## Referencias
- `src/lib_vt.zig:118-156` (`input.*`), `src/apprt/gtk/key.zig`, `src/apprt/gtk/class/surface.zig` (controladores y IM).
- context7: GTK4 `GtkEventControllerKey`, `GtkIMContext`, `GtkEventControllerScroll`.

## Skills
`zig-libghostty`, `context7`.
