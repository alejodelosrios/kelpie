title: Spike A — consumir `ghostty-vt` como módulo Zig e imprimir su versión
labels: type:spike,area:vt,risk:high
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Gate de M0. Todo el terminal depende de que la dependencia `ghostty` compile con Zig 0.16 en el
commit pinneado y de que el módulo Zig `ghostty-vt` sea importable. Depende de #1.

## Alcance
Entra: añadir la dependencia `ghostty` (`.lazy = true`) pinneada al commit
`15ff186f65ca0bdbd1fa397ab03908d59de16463`, importar `ghostty-vt` en `src/main.zig` y, con
`--vt-info` (o similar), imprimir algo que provenga del módulo (p. ej. crear un `Terminal` de
80×24 y volcar sus dimensiones). Actualizar el CI para que `zig build --fetch` funcione.
No entra: PTY, render, GTK. No se toca la API C ni los headers.

## Criterios de aceptación
- [ ] `build.zig.zon` tiene `.ghostty = .{ .url = "https://github.com/ghostty-org/ghostty/archive/<commit>.tar.gz", .hash = <calculado con zig fetch --save>, .lazy = true }`.
- [ ] `build.zig` replica literalmente `example/zig-vt/build.zig`: `if (b.lazyDependency("ghostty", .{})) |dep| exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));`.
- [ ] `zig build` compila en Debug y ReleaseSafe sin warnings propios; el binario imprime datos que provienen del módulo.
- [ ] Un `test` construye y destruye un `Terminal` con `std.testing.allocator` sin fugas.
- [ ] CI verde con la dependencia (fetch en el contenedor).
- [ ] Anotado en el issue: tiempo de compilación limpio y tamaño del binario.

## Referencias
- `example/zig-vt/{build.zig,build.zig.zon,src/main.zig}` del commit pinneado (mirror local: `~/.cache/ghostty-build/src/ghostty/`).
- `src/lib_vt.zig` (fachada pública; nota de inestabilidad en líneas 1-9).
- `src/build/GhosttyZig.zig` (cómo se genera el módulo; Oniguruma deshabilitado).

## Skills
`zig-libghostty`.
