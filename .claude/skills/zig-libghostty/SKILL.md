---
name: zig-libghostty
description: Convenciones de este repo para Zig 0.16 y el módulo Zig `ghostty-vt` (terminal, render state por filas sucias, codificadores de entrada) más GTK4/libadwaita vía zig-gobject. Úsala en todo issue con `area:vt`, `area:render`, `area:pty` o `area:ui`, y siempre antes de escribir una firma de API de Zig, ghostty-vt o GTK.
---

# Zig + ghostty-vt + GTK4 en kelpie

Regla única: **ninguna firma se escribe de memoria**. Cada API se lee en la fuente pinneada antes de
usarla; si no está ahí, la duda va al issue como pregunta abierta, no al código.

## Fuentes de verdad (en este orden)

1. Ghostty pinneado, commit `15ff186f65ca0bdbd1fa397ab03908d59de16463` (1.3.2-dev, `minimum_zig_version = "0.16.0"`).
   Mirror local en la máquina de referencia: `~/.cache/ghostty-build/src/ghostty/`; en otra máquina, `git clone https://github.com/ghostty-org/ghostty && git checkout <commit>`.
   - `example/zig-vt/` — la receta oficial para consumir `ghostty-vt` desde Zig. Cópiala, no la reinventes.
   - `src/lib_vt.zig` — la fachada pública: `Terminal`, `RenderState`, `Screen`, `Selection`, `SelectionGesture`, `Parser`, `Stream`, `input.{encodeKey,encodeMouse,encodePaste,encodeFocus}`, `unicode.{codepointWidth,graphemeWidth}`, `sys`, `TinyIo`.
   - `include/ghostty/vt/render.h` — el **contrato** de filas sucias (la doc está ahí aunque usemos Zig).
   - `src/apprt/gtk/` — runtime GTK4 real de Ghostty (MIT): `class/surface.zig` (widget, GLArea en 3893-3898, render en 3408-3424), `application.zig` (SIGUSR2 1464-1467, AdwStyleManager `notify::dark` 1430-1461), `src/build/SharedDeps.zig:713-731` (mapeo de módulos gobject).
2. `zig init` del toolchain instalado y `zig build --help`: plantilla y flags de la versión real.
3. `context7` para GTK4/libadwaita/Pango cuando la duda es de API GTK, no de Zig.

## Zig 0.16 — idiomas verificados

```zig
pub fn main(init: std.process.Init) !void {          // firma nueva: recibe Init
    const io = init.io;                               // std.Io para I/O
    const arena = init.arena.allocator();             // vive lo que el proceso
    const args = try init.minimal.args.toSlice(arena);
    var buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try out.interface.print("{s}\n", .{"hola"});
    try out.interface.flush();                        // siempre flush
}
var list: std.ArrayList(u8) = .empty;                 // unmanaged: el allocator va en cada llamada
defer list.deinit(gpa);
try list.append(gpa, 42);
```

- Dependencias: `zig fetch --save=<nombre> <url.tar.gz>` calcula el hash; nunca se escribe a mano.
- `build.zig`: `b.addExecutable(.{ .name, .root_module = b.createModule(.{ .root_source_file, .target, .optimize, .imports }) })`.
- Tests: bloques `test` en el archivo + `b.addTest(.{ .root_module })`; `std.testing.allocator` detecta fugas.
- Un literal de struct con un campo falible NO es atómico: por result-location, los campos
  anteriores ya están escritos en el destino final cuando el `try` falla. Si el destino sobrevive
  al error (out-param, campo persistente), evalúa el campo falible en un local ANTES del literal.
  Tercera vez en este repo con la misma raíz: `Connection.open`, `openLive`, y `request()` (#8,
  corregido en `src/herdr/client.zig:218-222`).
- `zig fmt --check build.zig build.zig.zon src` es parte del CI: formatea antes de commitear.
- **`net.UnixAddress.connect` sobre un socket muerto NUNCA da `error.ConnectionRefused`**, aunque ese
  error esté en el `ConnectError` declarado (`net.zig:891-906`): la implementación real de la ruta
  AF_UNIX (`posixConnectUnix`, `Threaded.zig:11947-11987`) no tiene rama para `ECONNREFUSED` — cae en
  el `else` genérico y sale como `error.Unexpected` (`posix.unexpectedErrno`, nunca panic:
  `posix.zig:1669-1675`). Si necesitas distinguir "socket viejo sin listener" de "conectó", matchea
  "cualquier error que no sea `FileNotFound`", nunca `error.ConnectionRefused` explícito — un
  `socket_path` que apunta a un archivo que no es socket también da `ECONNREFUSED` (no `ENOTSOCK`:
  ese errno es sobre el fd que llama, no sobre a qué apunta la ruta), así que cae en la misma rama.
  Verificado en #11.
- **`std.process.run`'s `RunOptions.timeout` default es `.none`** (`process.zig:485`) — sin
  timeout explícito, `run()` espera para siempre a un hijo que nunca cierra sus pipes de
  stdout/stderr. Para acotarlo: `.timeout = .{ .duration = .{ .raw = .fromSeconds(n), .clock =
  .awake } }` (`Io.Timeout`/`Clock.Duration`, `Io.zig:1132-1138`/`:890-892`/`:986`); `error.Timeout`
  cae en `RunError` y el `defer child.kill(io)` interno de `run` (`process.zig:508-510`) reapea al
  hijo. Verificado en #11 (`src/herdr/LocalServer.zig`, `readHerdrStatus`).

## ghostty-vt como módulo Zig

```zig
// build.zig.zon
.ghostty = .{
    .url = "https://github.com/ghostty-org/ghostty/archive/<COMMIT>.tar.gz",
    .hash = "<lo calcula zig fetch>",
    .lazy = true,
},
// build.zig — literal de example/zig-vt/build.zig
if (b.lazyDependency("ghostty", .{})) |dep| {
    exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
}
```

- Ser dependencia activa solo el modo lib-vt (`emit-lib-vt` por defecto); nada de `-Dapp-runtime`.
- `simd` se deja activado: GTK ya nos obliga a libc.
- `Terminal` necesita un `std.Io`: pásale `init.io`; `TinyIo` es solo para embebidos sin Io.
- `sys` (punteros de función) se configura antes de tocar el terminal si hace falta decodificar PNG para Kitty graphics.
- El módulo Zig no incluye Oniguruma: sin búsqueda por regex en el buffer.
- La API es **inestable por declaración** (`src/lib_vt.zig:1-9`): cada bump del commit es un PR propio con `zig build test` verde.

### Contrato de filas sucias (verificado en #4)

`render.h:23-72` documenta el contrato, pero **sus nombres son del shim C, no de la fachada Zig**.
Lo de abajo es lo que un consumidor Zig escribe de verdad (`src/terminal/render.zig` del commit
pinneado).

1. El hilo de render **bloquea** el terminal, llama `beginUpdate` (`render.zig:373`), **desbloquea**,
   y termina con `endUpdate` (`render.zig:754`) sobre memoria propia del render state.
   **Usa las dos por separado, nunca `update()`**: entre fases el estilo por celda queda "stale" por
   diseño, y `update()` sostendría el lock del terminal durante la denormalización de estilos.
2. Hay **dos capas** de dirty: global (`RenderState.Dirty` = `.false` / `.partial` / `.full`,
   `render.zig:281-292`) y por fila. `beginUpdate` solo las pone; nunca las limpia.
3. **No hay iterador de filas sucias en la fachada Zig.** `row_iterator_next_dirty` vive solo en el
   shim C (`src/terminal/c/render.zig:575`) y no se re-exporta. El patrón Zig es el `MultiArrayList`
   de filas (`render.zig:97`) — el mismo que usa el test oficial `"dirty state"` (`render.zig:1960`):

   ```zig
   // Nada de `unreachable` aquí: esto es camino de render (regla del repo).
   const only_dirty = switch (state.dirty) {
       .false => return,   // nada cambió: no se pinta frame
       .partial => true,   // saltar las filas limpias
       else => false,      // .full: repintar todo (`lib.Enum` es exhaustivo, `lib/enum.zig:43`)
   };
   const rows = state.row_data.slice();
   const dirty = rows.items(.dirty);           // []bool, una entrada por fila
   for (dirty, 0..) |is_dirty, y| {
       if (only_dirty and !is_dirty) continue;
       // pintar la fila y
   }
   ```
4. Tras pintar el frame completo, `clean()` (`render.zig:818-820`) limpia las dos capas de una vez.
   Limpiar una no limpia la otra: quien consuma medio frame las limpia por separado.
5. **Guarda obligatoria antes de leer el estilo de una celda**: `cell.style` es memoria **indefinida**
   si la celda no tiene estilo (`render.zig:275-277`). Comprobar `hasStyling()` antes de tocarlo —
   y ojo al camino: `RenderState.Cell` **envuelve** la celda cruda en el campo `raw`
   (`render.zig:264-269`), así que la llamada es `cell.raw.hasStyling()`
   (`page.zig:2291-2293`, `style_id != stylepkg.default_id`).

**Ceiling de rendimiento:** un frame solo toca filas sucias; redibujar la pantalla entera es un bug de rendimiento, no una simplificación aceptable.

## GTK4/libadwaita vía zig-gobject

```zig
// build.zig.zon — la misma tarball y hash que Ghostty
.gobject = .{
    .url = "https://deps.files.ghostty.org/gobject-2026-07-28-36-1.tar.zst",
    .hash = "gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3",
    .lazy = true,
},
// build.zig — mapeo idéntico a Ghostty SharedDeps.zig:713-731
.{ "adw", "adw1" }, .{ "gdk", "gdk4" }, .{ "gio", "gio2" }, .{ "glib", "glib2" },
.{ "glibunix", "glibunix2" }, .{ "gobject", "gobject2" }, .{ "gtk", "gtk4" },
// además disponibles: gsk4 graphene1 pango1 pangocairo1 cairo1 gdkwayland4
```

- Los módulos ya enlazan sus librerías del sistema (pkg-config) al importarlos.
- Señales: `gobject.Object.signals.notify.connect(obj, *Self, handler, self, .{ .detail = "dark" })` (patrón de `application.zig:1456-1459`).
- Subclases de widget: el patrón vive en `src/apprt/gtk/class.zig` y `class/surface.zig`; léelo antes de definir una clase.
- Claro/oscuro: `adw.StyleManager` + `notify::dark`; libadwaita ya sigue el `color-scheme` de gsettings que Omarchy fija.
- CSS: `gtk.CssProvider` cargado desde archivo, prioridad `APPLICATION`; en GTK ≥ 4.20 el provider tiene la propiedad `prefers-color-scheme` (`application.zig:1650-1666`).
- **Renderer del terminal: `gtk.GLArea` + GL propio, NO nodos GSK.** El Spike B (#3) midió la ruta
  GSK y falla: ~28 fps en el mejor caso (shaping cacheado, `GSK_RENDERER=gl`) redibujando 200×60
  celdas, contra un umbral de 60. El cuello de botella es componer ~12.000 `gsk.TextNode` por frame,
  **no el shaping** — cachear el shaping solo duplica el fps, no cierra la brecha. Pango se conserva
  para shaping y métricas; lo que se descarta es la composición por nodos. Ver ADR-0001
  §"Resultado del gate (M0)".
- **zig-gobject prefija todos los campos de struct con `f_`** (`f_geometry`, `f_width`,
  `f_num_glyphs`, `f_glyphs`). Los métodos no llevan prefijo. Sin esto, cada acceso a un campo se
  escribe mal.
- Alineación en rejilla: tras `pango.shape`, sobreescribir el avance de cada glifo a una celda
  (`PANGO_SCALE` = 1024). Lo que compila y lo que midió el spike (`src/ui/grid_widget.zig:212-217`):

  ```zig
  const forced_width: pango.GlyphUnit = @intFromFloat(cell_w * 1024.0);
  if (gs.f_glyphs) |glyphs_ptr| {
      for (glyphs_ptr[0..@intCast(gs.f_num_glyphs)]) |*g| {
          g.f_geometry.f_width = forced_width;
      }
  }
  ```

  Consecuencia verificada y aceptada: **las ligaduras no fusionan** (`->` shapea a dos glifos). Es lo
  que una rejilla exige.
- `gtk.GLArea` crea contexto y limpia a un color en esta máquina (#3). Las llamadas GL crudas
  (`glClearColor`/`glClear`) no tienen binding en el tarball `gobject`: se declaran `extern "c"` y se
  linka la librería del sistema **sobre el módulo, no sobre el `Compile`** — en Zig 0.16
  `linkSystemLibrary` solo existe en `std.Build.Module` y lleva struct de opciones
  (`/usr/lib/zig/std/Build/Module.zig:363`). Tal cual está en este repo (`build.zig:53`):

  ```zig
  exe_mod.linkSystemLibrary("GL", .{});
  ```

  No es dependencia nueva del zig-pkg: Mesa/GTK ya la exigen en tiempo de ejecución.
- Nunca dibujar desde otro hilo (`App.zig:23`: GLArea tampoco lo permite).

## Crashes

Un emulador de terminal va a hacer SIGSEGV. `coredumpctl list kelpie`, luego la skill `diagnose-crash`. Compila en `Debug` o `ReleaseSafe` mientras se investiga.
