# ADR-0001 — Stack: Zig 0.16 + módulo Zig `ghostty-vt` + GTK4/libadwaita, renderer Pango/GSK

Estado: aceptado · Fecha: 2026-08-26

## Contexto

kelpie es la consola de herdr para Omarchy: sidebar multi-dispositivo por urgencia, notificación
clickeable cuando un agente se bloquea, búsqueda global y terminal real con attach. Hyprland ya da
tiling; el mosaico de panes queda fuera de alcance.

Hechos verificados en la máquina de referencia (Omarchy 4.0.0.alpha, Zig 0.16.0, GTK 4.22.4,
libadwaita 1.9.3, Ghostty 1.3.2-dev commit `15ff186f65ca0bdbd1fa397ab03908d59de16463`):

- Ghostty exporta un **módulo Zig nativo `ghostty-vt`** (`src/build/GhosttyZig.zig`,
  `example/zig-vt/`). Un consumidor Zig no necesita la API C ni el allocator FFI.
- El API embebido completo de Ghostty (`include/ghostty.h`) es **solo macOS/iOS**: la enum de
  plataforma no tiene Linux y `apprt/embedded.zig` devuelve `UnsupportedPlatform`.
- `src/renderer/` de Ghostty está acoplado a su núcleo de aplicación (`apprt.zig`, `Surface.zig`,
  `App.zig`); `src/font/` (30 k LOC) sería vendorizable, pero no lo necesitamos.
- Los bindings `ghostty-org/zig-gobject` (tarball 0.3.2 en deps.files.ghostty.org) incluyen
  `gtk4 adw1 gio2 gobject2 glib2 glibunix2 gdk4 gsk4 graphene1 pango1 pangocairo1 cairo1 gdkwayland4`.
  No incluyen VTE ni libsecret.
- Omarchy no tematiza GTK más allá de claro/oscuro (`omarchy-theme-set-gnome`). El color real
  llega solo por plantilla propia en `~/.config/omarchy/themed/`.

## Decisión

1. **Lenguaje y build**: Zig 0.16 (`minimum_zig_version = "0.16.0"`), CI en contenedor `archlinux`.
2. **Emulación VT**: dependencia `ghostty` pinneada por commit, importada como
   `dep.module("ghostty-vt")`. Terminal, RenderState, Selection y codificadores de teclado/ratón/paste
   vienen de ahí. **No se reimplementa nada de eso.**
3. **UI**: GTK4 + libadwaita vía la misma tarball de `gobject` que usa Ghostty (mismo hash), con el
   mismo mapeo de imports que `src/build/SharedDeps.zig:713-731`.
4. **Renderer del terminal**: widget GTK4 propio que dibuja **solo filas sucias** en su vfunc
   `snapshot` con Pango (shaping HarfBuzz, fallback fontconfig, emoji) y GSK (caché de glifos en GPU
   del propio GTK). Sin FreeType/HarfBuzz directos, sin atlas propio, sin shaders. Se valida en el
   Spike B con un umbral de rendimiento binario.
5. **Colores**: cero hexadecimales en código. Una plantilla `kelpie.css.tpl` en
   `~/.config/omarchy/themed/` genera `~/.local/state/omarchy/current/theme/kelpie.css`, que
   redefine las variables de libadwaita (`--accent-bg-color`, `--window-bg-color`, …) y declara la
   paleta del terminal como custom properties (`--term0..15`). La app carga ese CSS con
   `GtkCssProvider` y lo recarga vigilando el **directorio** `~/.local/state/omarchy/current/`.
6. **Notificaciones**: `omarchy notification send … --exec kelpie focus <destino>`; el foco llega a
   la instancia primaria por `GApplication` (`HANDLES_COMMAND_LINE`), sin IPC propia.
7. **Remoto**: `ssh -N -L <sock-local>:<sock-remoto>` como subproceso (OpenSSH), sin librería SSH.
8. **Licencia**: MIT.

## Alternativas descartadas

- **API C de libghostty-vt + FFI**: más código (allocator, `GhosttyResult` en cada llamada) para el
  mismo resultado; el módulo Zig es el camino que Ghostty documenta para consumidores Zig.
- **libghostty embebido completo**: solo macOS. Descartado por evidencia, no por preferencia.
- **Renderer GL propio estilo Ghostty (atlas + FreeType + HarfBuzz)**: es el "trabajo caro" del
  plan original. Queda como **plan B** del Spike B si Pango/GSK no cumple el umbral.
- **VTE4** (extra/vte4 0.84.1): resuelve el widget entero, pero sin Kitty graphics, con otra calidad
  de render y exigiría regenerar bindings (`Vte-3.91.gir` no viene en zig-gobject). **Plan C.**
- **Rust + GTK4 + VTE4**: reescritura total. **Plan D**, solo si Zig+GTK no se sostiene (Spike A/B).

## Escalera de fallback y criterios de aborto (gate de M0)

| Spike | Falla si… | Entonces |
|---|---|---|
| A — `ghostty-vt` como módulo Zig | no compila con Zig 0.16 en el commit pinneado tras 1 día de trabajo | probar el commit anterior estable; si tampoco, plan C (VTE4) |
| B — renderer Pango/GSK | < 60 fps redibujando 200×60 celdas completas en Wayland con el renderer por defecto | plan B: `GtkGLArea` + renderer GL propio (M2 crece ~3×) |
| B — bindings GTK4/Wayland | la ventana no abre o `GtkGLArea` no crea contexto | plan D |
| C — núcleo VT | la salida no coincide con la esperada para SGR + CSI básicos | reportar upstream; congelar el commit anterior |
| D — socket herdr | `ping` sin `protocol` o `agent.list` con forma distinta al schema | actualizar herdr; si persiste, parar |
| E — toast clickeable | el `--exec` no se ejecuta al hacer click | abrir issue en Omarchy; mientras, `-A` de libnotify NO es sustituto (muere con el emisor) |

Regla: **si un spike falla, se para y se informa**; no se improvisa un workaround en el mismo PR.

## Consecuencias

- M2 (terminal) deja de ser "la parte cara": sin stack de fuentes propio. El costo se traslada a
  medir bien el Spike B.
- La API de `ghostty-vt` es explícitamente inestable: el commit va pinneado y cada bump es un PR
  propio con `zig build test` verde.
- Sin VTE ni libsecret en 1.0: la autenticación SSH usa llaves/agente; contraseñas guardadas quedan
  como `later`.
