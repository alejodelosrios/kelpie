title: Spike B — ventana GTK4 vía zig-gobject y rejilla de texto Pango/GSK a ≥60 fps en Wayland
labels: type:spike,area:ui,area:render,risk:high
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Gate de M0. Decide el renderer del terminal (ADR-0001 §4): si un widget GTK4 que dibuja una rejilla
de 200×60 celdas monoespaciadas con Pango en su vfunc `snapshot` sostiene 60 fps redibujando TODO
(peor caso), M2 no necesita FreeType/HarfBuzz/atlas/GL propios. Si no, plan B: `GtkGLArea` +
renderer GL. Depende de #1.

## Alcance
Entra: dependencia `gobject` (misma tarball y hash que Ghostty), mapeo de imports idéntico a
`SharedDeps.zig:713-731`, una `adw.Application` con `application-id = io.github.alejodelosrios.kelpie`,
un widget propio cuyo `snapshot` pinta 200×60 celdas con texto aleatorio, colores de fondo por celda
y atributos (bold, underline) usando `pango1` (layout o glyph string con avances forzados al ancho
de celda) y nodos GSK; un contador de fps en stderr; y una segunda ventana con `gtk.GLArea`
limpiando a un color (comprobación del plan B). Deps del CI: `gtk4 libadwaita pango`.
No entra: `ghostty-vt`, PTY, entrada de teclado, CSS de tema.

## Criterios de aceptación
- [ ] La ventana abre en Hyprland/Wayland con el renderer por defecto de GTK 4.22 y también con `GSK_RENDERER=ngl`; se anota qué pasa con `GSK_RENDERER=vulkan`.
- [ ] Redibujando las 12.000 celdas cada frame durante 10 s: media ≥ 60 fps y sin frame > 33 ms, medido con `GDK_DEBUG=frames` o un contador propio. Se pegan los números en el issue.
- [ ] Los glifos caen exactamente en su columna: con avances forzados a `cell_width`, una línea de 200 `M` y una de 200 `i` terminan en el mismo píxel.
- [ ] Ligaduras de JetBrains Mono (`->`, `!=`) se muestran cuando el texto es contiguo en un mismo run.
- [ ] `gtk.GLArea` crea contexto y limpia a un color (plan B viable).
- [ ] Veredicto escrito en el issue: "Pango/GSK" o "plan B GL", con referencia a la tabla de aborto del ADR-0001.

## Referencias
- `src/build/SharedDeps.zig:713-731` (imports gobject), `src/apprt/gtk/class/surface.zig:3893-3898` y `3408-3424` (GLArea), `src/apprt/gtk/class.zig` (subclases).
- Tarball gobject: `https://deps.files.ghostty.org/gobject-2026-07-28-36-1.tar.zst`, hash `gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`.
- context7: GTK4 `GtkWidgetClass.snapshot`, `gtk_snapshot_append_layout`, `PangoGlyphString`/`PangoGlyphGeometry.width`, `GdkFrameClock`.

## Skills
`zig-libghostty`, `context7`.
