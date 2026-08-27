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
- `zig fmt --check build.zig build.zig.zon src` es parte del CI: formatea antes de commitear.

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

### Contrato de filas sucias (render.h:23-72)

1. El hilo de render **bloquea** el terminal, llama `begin_update`, **desbloquea**, y termina con `end_update` sobre memoria propia del render state.
2. Hay **dos capas** de dirty: global (`false | partial | full`) y por fila. `update` solo las pone; nunca las limpia.
3. Se itera con el iterador de filas sucias (`next_dirty`): con global `partial` salta filas limpias, con `full` devuelve todas.
4. Tras pintar el frame completo, `clean()` limpia las dos capas de una vez. Limpiar una no limpia la otra.
5. Los nombres Zig equivalentes se leen en `src/terminal/render.zig` del commit pinneado; los nombres C de arriba son la referencia documentada.

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
- Renderer del terminal: vfunc `snapshot` del widget, texto con Pango (`pango1`) y nodos GSK; nunca dibujar desde otro hilo (`App.zig:23`: GLArea tampoco lo permite).

## Crashes

Un emulador de terminal va a hacer SIGSEGV. `coredumpctl list kelpie`, luego la skill `diagnose-crash`. Compila en `Debug` o `ReleaseSafe` mientras se investiga.
