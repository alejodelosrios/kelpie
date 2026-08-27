# Diseño — #2 Spike A — consumir `ghostty-vt` como módulo Zig e imprimir su versión

> Aprobado por: Manuel Alejandro Ramirez · 2026-08-27 · rama `chore/2-spike-a-ghostty-vt`

## Spec

Añadir `ghostty` como dependencia lazy pinneada al commit `15ff186f65ca0bdbd1fa397ab03908d59de16463`,
importar el módulo Zig `ghostty-vt` en `src/main.zig`, crear un `Terminal` de 80×24 con la flag
`--vt-info` e imprimir sus dimensiones. CI corre `zig build --fetch` para materializar la dependencia.

**Archivos que se tocan:**
- `build.zig.zon` — nueva entrada `.dependencies.ghostty` (`.lazy = true`, hash de `zig fetch --save`).
- `build.zig` — bloque `b.lazyDependency("ghostty", .{})` que importa `ghostty-vt` al `exe_mod`.
- `src/main.zig` — con `--vt-info`: crea/destruye un `Terminal` de 80×24 e imprime `cols`×`rows`;
  sin la flag, mantiene el comportamiento actual (`name version`). Un `test` crea/destruye un
  `Terminal` con `std.testing.allocator`.
- `.github/workflows/ci.yml` — paso `zig build --fetch` antes de `zig build --summary all`.

**No entra:** PTY, render real, GTK, API C ni headers de ghostty-vt. Sin flags de simd (queda
activado, valor por defecto de `lazyDependency`).

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `b.lazyDependency("ghostty", .{})` + `dep.module("ghostty-vt")` | `~/.cache/ghostty-build/src/ghostty/example/zig-vt/build.zig:19-29` | ✅ |
| `ghostty_vt.Terminal.init(io_impl: std.Io, alloc: Allocator, opts: Options) !Terminal` | `~/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:311-314` | ✅ |
| `Terminal.deinit(self: *Terminal, alloc: Allocator) void` | `~/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:356` | ✅ |
| `Terminal.rows: size.CellCountInt` (`u16`) / `Terminal.cols: size.CellCountInt` | `~/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:59-60`, `size.zig:22` | ✅ |
| `Options.cols: size.CellCountInt` / `Options.rows: size.CellCountInt` (los que recibe `init`) | `~/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:267-268` | ✅ |
| `pub const Terminal = terminal.Terminal;` (re-export público) | `~/.cache/ghostty-build/src/ghostty/src/lib_vt.zig:93` | ✅ |
| `init.io`, `init.gpa` en `std.process.Init` (patrón del ejemplo oficial) | `~/.cache/ghostty-build/src/ghostty/example/zig-vt/src/main.zig:1-20` | ✅ |
| `minimum_zig_version = "0.16.0"` del propio Ghostty (compatible con kelpie) | `~/.cache/ghostty-build/src/ghostty/build.zig.zon:6` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: build.zig.zon declara la dependencia ghostty pinneada y lazy
  Dado el repo en la rama chore/2-spike-a-ghostty-vt
  Cuando se ejecuta `zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/15ff186f65ca0bdbd1fa397ab03908d59de16463.tar.gz`
  Entonces build.zig.zon tiene una entrada `.ghostty` con `.url`, `.hash` calculado, y `.lazy = true`

Escenario: build.zig importa ghostty-vt solo si la dependencia lazy se materializa
  Dado build.zig.zon con la dependencia ghostty declarada
  Cuando se lee build.zig
  Entonces existe un bloque `if (b.lazyDependency("ghostty", .{})) |dep| exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"))`
  Y es una copia literal del patrón en example/zig-vt/build.zig

Escenario: el binario imprime datos del módulo ghostty-vt con --vt-info
  Dado el binario compilado en Debug o ReleaseSafe
  Cuando se ejecuta `zig-out/bin/kelpie --vt-info`
  Entonces se imprime una línea con las dimensiones 80x24 provenientes de un ghostty_vt.Terminal real
  Y el proceso termina con código 0

Escenario: zig build compila sin warnings propios en Debug y ReleaseSafe
  Dado el repo con la dependencia ghostty añadida
  Cuando se ejecuta `zig build -Doptimize=Debug` y `zig build -Doptimize=ReleaseSafe`
  Entonces ambos compilan sin error y sin warnings originados en código de kelpie

Escenario: un test construye y destruye un Terminal sin fugas
  Dado el archivo src/main.zig con un bloque `test`
  Cuando se ejecuta `zig build test --summary all`
  Entonces el test crea un ghostty_vt.Terminal con std.testing.allocator, lo destruye con deinit,
    y std.testing.allocator no reporta memoria sin liberar

Escenario: CI verde con la dependencia lazy fetcheada en el contenedor
  Dado el workflow .github/workflows/ci.yml
  Cuando corre en el runner archlinux:latest
  Entonces un paso `zig build --fetch` descarga la tarball pinneada antes de `zig build --summary all`
  Y el job build termina en verde
```

## Riesgos y preguntas abiertas

- El hash de `.ghostty` en `build.zig.zon` no se puede citar de una fuente estática: lo calcula
  `zig fetch --save` en el momento del Apply, contra la red. Si el runner de CI no tiene salida a
  `github.com`, el fetch falla — no hay mitigación en este spike, es la condición de éxito/fracaso
  que el propio issue pide medir (M0 es un gate).
- Tiempo de compilación limpio y tamaño del binario se anotan en el issue **después** de correr
  `zig build` — no se pueden citar de antemano.
