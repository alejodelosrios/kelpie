title: Spike C — alimentar bytes con SGR y CSI a `Terminal` y volcar filas vía RenderState
labels: type:spike,area:vt
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Gate de M0. Prueba el núcleo entero sin UI: parser → pantalla → render state → filas sucias.
Es el mismo flujo que usará el widget en M2. Depende de #2.

## Alcance
Entra: un ejecutable/test que crea un `Terminal` 40×5, le escribe un stream fijo con texto,
`ESC[1;31m` (SGR bold+rojo), `ESC[2;3H` (CUP) y `ESC[K` (EL), actualiza el render state e imprime
cada fila sucia a stdout como texto plano más un marcador por celda con estilo. Segunda pasada sin
escribir nada: debe informar 0 filas sucias tras `clean`.
No entra: PTY, hilos, GTK.

## Criterios de aceptación
- [ ] La salida coincide byte a byte con un `expected.txt` guardado en `src/testdata/` (test con `std.testing.expectEqualStrings`).
- [ ] La celda (fila 2, col 3) reporta bold + fg rojo de la paleta.
- [ ] Tras `clean()`, un nuevo `update` sin entrada devuelve 0 filas por el iterador de sucias; tras escribir una letra, exactamente 1.
- [ ] Se usan los nombres reales de `src/terminal/render.zig`/`lib_vt.zig` del commit pinneado (anotarlos en el issue para la skill).

## Referencias
- `include/ghostty/vt/render.h:23-72` (contrato de dos fases y dos capas de dirty) y `:605-612` (iterador).
- `example/zig-vt/src/main.zig`, `example/zig-vt-stream/`.
- `src/lib_vt.zig` (`Terminal`, `RenderState`, `Stream`, `Parser`).

## Skills
`zig-libghostty`.
