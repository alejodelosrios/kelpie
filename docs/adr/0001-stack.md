# ADR-0001 — Stack: Zig 0.16 + módulo Zig `ghostty-vt` + GTK4/libadwaita, renderer GL propio

Estado: aceptado · Fecha: 2026-08-26 · **Enmendado 2026-08-28** por el gate de M0 (#7): el
renderer del terminal pasa de Pango/GSK a `GtkGLArea` + renderer GL propio. El resto del stack se
confirma. Ver §"Resultado del gate (M0)".

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
4. **Renderer del terminal** (~~Pango/GSK~~ → **enmendado por el gate de M0**): widget
   `gtk.GLArea` con renderer GL propio que sube al atlas **solo las filas sucias** del `RenderState`.
   El shaping sigue siendo de Pango (HarfBuzz, fallback fontconfig, emoji): lo que el Spike B
   descartó fue componer la rejilla como nodos GSK, no Pango. Redacción original, conservada porque
   el gate la falsificó con un número: *"widget GTK4 propio que dibuja solo filas sucias en su vfunc
   `snapshot` con Pango y GSK; sin atlas propio, sin shaders"* — medido a ~28 fps en el mejor caso
   contra un umbral de 60 (#3).
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
- **Renderer GL propio estilo Ghostty (atlas + shaping)**: era el "trabajo caro" del plan original,
  reservado como **plan B** del Spike B. El Spike B falló su umbral, así que **plan B es hoy la
  decisión adoptada** (§Decisión punto 4), no una alternativa descartada.
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

## Resultado del gate (M0)

Cinco spikes corridos entre el 2026-08-26 y el 2026-08-27 en la máquina de referencia. Veredicto
binario contra la tabla de arriba; la evidencia completa (tablas de medición, salidas reales) vive en
el comentario de cada issue, que es lo que enlaza cada fila.

| Spike | Veredicto | Evidencia medida | Issue |
|---|---|---|---|
| A — `ghostty-vt` como módulo Zig | **PASA** | Compila con Zig 0.16 en el commit pinneado; `--vt-info` imprime dimensiones reales de un `Terminal` (test dedicado que descarta hardcodeo). Build limpio ~1m15s local, ~1m29s–2m03s en CI; binario ~5.2 MB Debug. Auditoría APROBADA. | [#2](https://github.com/alejodelosrios/kelpie/issues/2) |
| B — renderer Pango/GSK | **FALLA** | ~28 fps en el mejor caso (`GSK_RENDERER=gl`, shaping cacheado) redibujando 200×60 celdas; 4.9–9.8 fps con shaping por frame. Umbral: 60. Cuello de botella aislado: componer ~12.000 `gsk.TextNode` por frame — **no** el shaping (cachearlo solo duplica el fps). | [#3](https://github.com/alejodelosrios/kelpie/issues/3#issuecomment-5446538175) |
| B — bindings GTK4/Wayland | **PASA** | La ventana abre en Hyprland con el renderer por defecto y con `GSK_RENDERER=ngl`/`gl`, sin crash. `gtk.GLArea` crea contexto y limpia a un color → plan B viable. | [#3](https://github.com/alejodelosrios/kelpie/issues/3) |
| C — núcleo VT | **PASA** | SGR + CSI básicos producen la salida esperada; las filas sucias se consumen desde Zig con `row_data.items(.dirty)` + el `Dirty` global. Sin reimplementar nada de `ghostty-vt`. | [#4](https://github.com/alejodelosrios/kelpie/issues/4) |
| D — socket herdr | **PASA** | `ping` → `pong` con `protocol=20`; `session.snapshot` (5 workspaces / 8 tabs / 15 panes) y `agent.list` (9 agentes con `pane_id`/`agent`/`agent_status`) coinciden con el schema vendorizado; `events.subscribe` entrega eventos reales; errores tipados `invalid_request`. Contrato confirmado: **una petición por conexión**, `events.subscribe` es la única excepción persistente. | [#5](https://github.com/alejodelosrios/kelpie/issues/5) |
| E — toast clickeable | **PASA** | 6/6 escenarios. El argv de `--exec` llega literal (espacios respetados, `$(id)` sin expandir), `-p`/`-r` reemplaza sin apilar, `dismiss` retira la toast, y el click sigue funcionando tras `omarchy restart shell` — la acción es dato (hint `omarchy-exec-argv`), no un callback en memoria. Con `--app-name kelpie` la toast respeta no-molestar. | [#6](https://github.com/alejodelosrios/kelpie/issues/6) |

### Qué cambia por el fallo de B

- §Decisión punto 4 pasa a `GtkGLArea` + renderer GL propio, alimentado por el contrato de filas
  sucias que demostró el Spike C: el renderer solo re-sube al atlas las filas marcadas sucias, que es
  justo el costo que B aisló como cuello de botella.
- M2 crece ~3× como el propio ADR anticipaba. Afecta a **#21** (TerminalView), **#22** (fuente y
  métricas de celda) y **#26** (cursor, paleta, scrollback).
- **M1 no se toca**: el fallo es del renderer del terminal, que es M2. La consola local (sidebar,
  tema, notificaciones, attach externo) queda desbloqueada.

### Huecos declarados, no supuestos

- **`GSK_RENDERER=vulkan` nunca se midió de verdad**: esta máquina no tiene ICD Vulkan
  (`VK_ERROR_INCOMPATIBLE_DRIVER`) y GTK cae al fallback por defecto. Los números de esa fila miden
  el fallback, no Vulkan.
- **El plan B GL no tiene número propio todavía.** El Spike B probó que `gtk.GLArea` crea contexto y
  limpia a un color; que un renderer GL con atlas llegue a 60 fps es una hipótesis heredada de
  Ghostty, no un dato de este repo. Por eso #21 se queda con `risk:high`.
- **Las ligaduras (`->`, `!=`) no fusionan** en ninguna ruta probada. No es un fallo del stack: es la
  consecuencia directa de forzar el avance de cada glifo a `cell_width`, que es lo que una rejilla de
  terminal exige. Se registra como hecho, no como deuda.

## Consecuencias

- ~~M2 (terminal) deja de ser "la parte cara"~~ — **falsificado por el gate**: el Spike B midió que
  Pango/GSK no sostiene 60 fps, así que M2 vuelve a ser la parte cara (atlas y renderer GL propios,
  ~3× el trabajo). Lo que sí se conserva es el **stack de fuentes**: el shaping sigue siendo de Pango
  y fontconfig, no hay FreeType/HarfBuzz directos.
- La API de `ghostty-vt` es explícitamente inestable: el commit va pinneado y cada bump es un PR
  propio con `zig build test` verde.
- Sin VTE ni libsecret en 1.0: la autenticación SSH usa llaves/agente; contraseñas guardadas quedan
  como `later`.
