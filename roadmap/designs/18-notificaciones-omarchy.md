# Diseño — #18 Notificaciones por `omarchy notification send`

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-09-03

## Spec

Un observador del `Store` (`src/omarchy/Notify.zig`) que, en cada transición de estado de un
agente, dispara una toast de Omarchy: `blocked` → `critical` con click-to-focus; `done` → `normal`,
salvo que ese agente sea el foco actual de una ventana activa. Reemplaza la toast anterior del mismo
agente en vez de apilar, y la retira cuando el usuario lo enfoca en kelpie.

**Archivos que se tocan** (territorio `ui-builder`, `area:omarchy`):
- `src/omarchy/Notify.zig` (nuevo) — construcción de argv, spawn sin shell, mapa `(device,pane)→id`,
  `dismiss`.
- `src/ui/app_shell.zig` — instancia `Notify`, la registra como `ChangeObserver` del `Store` junto a
  `sidebar.observer()`, le inyecta `io`/`environ_map` y un callback `isWindowActive`, y llama
  `notify.dismiss(device, pane)` en los dos puntos donde kelpie ya "enfoca" un agente:
  `focusAgent` (CLI `focus <device>/<pane>`) y `onSidebarActivated` (click de fila).

**No entra** (copiado del issue):
- Sonido propio (lo decide el shell).
- DND (#46).
- libnotify (Omarchy usa D-Bus `org.freedesktop.Notifications` directo vía `busctl`).

**Corrección de alcance frente al issue**: el issue describe el comando como `omarchy notification
send ...`. La skill `omarchy-app` (verificada contra `/usr/share/omarchy/bin/omarchy:128-137` en #6)
establece que el dispatcher `omarchy` escanea todo el remanente de la línea buscando `-h`/`--help`, así
que un argv de `--exec` que por casualidad contenga algo parecido puede ser malinterpretado. Este
diseño invoca **directamente** `/usr/share/omarchy/bin/omarchy-notification-send` (el binario real),
no el dispatcher — mismo criterio que Spike E (#6), la fuente de comportamiento citada en el issue.

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `--exec` consume el resto del argv como comandos del click, dato nunca reinterpretado por shell | `/usr/share/omarchy/bin/omarchy-notification-send:162-180` | ✅ |
| `-p` imprime a stdout el id numérico devuelto por `Notify` (`"u <id>"` de `busctl`, se emite solo el id) | `/usr/share/omarchy/bin/omarchy-notification-send:195-208` | ✅ |
| `-r <id>` reemplaza una toast existente en vez de crear una nueva (`replaces_id`) | `/usr/share/omarchy/bin/omarchy-notification-send:60-77` (parseo), `:190-201` (uso en `notify_cmd`) | ✅ |
| `omarchy-notification-dismiss <substring>` → `omarchy-shell -q notifications dismiss "$1"`, no imprime nada | `/usr/share/omarchy/bin/omarchy-notification-dismiss:1-10` | ✅ |
| `Store.ChangeObserver` — `onChangedFn`/`onTransitionFn(ptr, agent, from, to)` | `src/model/Store.zig:122-134` | ✅ |
| `Store.addObserver(self, observer) !void` | `src/model/Store.zig:168-170` | ✅ |
| `pane_agent_status_changed` dispara `fireTransition` cuando `from_status != data.agent_status` | `src/model/Store.zig:337-347` | ✅ |
| Eventos reales de herdr llegan a `store.applyEvent` (no solo tests/demo) | `src/ui/herdr_link.zig:363-368` | ✅ |
| `Agent` — campos `device_id, pane_id, workspace_id, status, focused, agent, display_agent, title` y `displayTitle()` | `src/model/Store.zig:18-35` | ✅ |
| `types.AgentStatus` — `idle, working, blocked, done, unknown` | `src/herdr/types.zig:9-14` | ✅ |
| Glifos Nerd Font ya usados por el sidebar para blocked/done (mismos codepoints que pide el issue) | `src/ui/sidebar.zig:514,520` (`\u{f0026}`, `\u{f012c}`) | ✅ |
| `parseCommand`/`onCommandLine` ya aceptan `focus <device>/<pane>` → activa ventana y selecciona fila (consumidor de `--exec kelpie focus ...`) | `src/ui/app_shell.zig:41-68`, `:305-324`, `:353-358` | ✅ |
| `std.process.SpawnOptions{ argv, stdout: .pipe, ... }` / `std.process.spawn(io, options) SpawnError!Child` | `/usr/lib/zig/std/process.zig:360-444` | ✅ |
| `Child.wait(child, io) WaitError!Term` | `/usr/lib/zig/std/process/Child.zig:134-137` | ✅ |
| `gtk.Window.isActive(window) c_int` — ventana activa (recibe teclas) | dep. `gobject` (build.zig.zon), `src/gtk4/gtk4.zig:59230-59231` del paquete pinneado `gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: bloqueo notifica con click-to-focus
  Dado un agente (device="local", pane="p1") en estado idle
  Cuando el Store recibe pane_agent_status_changed → blocked para ese agente
  Entonces Notify invoca omarchy-notification-send con -u critical, -g \u{f0026},
    --exec kelpie focus local/p1, y sin shell de por medio (argv, no string)
  Y la toast, al hacer click, activa la ventana de kelpie con ese agente seleccionado

Escenario: dos bloqueos seguidos del mismo agente no apilan
  Dado que Notify ya envió una toast para (local, p1) y capturó su id N
  Cuando ese mismo agente vuelve a transicionar a blocked
  Entonces el argv de la segunda llamada incluye -r N
  Y no aparece una segunda toast independiente

Escenario: inyección por título es imposible por construcción
  Dado un título de agente literal: `$(rm -rf ~); "; echo pwned #`
  Cuando Notify construye el argv de la toast
  Entonces ese texto viaja como un único elemento de argv (headline), nunca interpolado en un string
    de shell, y llega literal tanto a la toast como al --exec

Escenario: terminado del pane que estoy mirando no notifica
  Dado un agente (local, p1) con focused=true y la ventana de kelpie activa (isWindowActive=true)
  Cuando ese agente transiciona a done
  Entonces Notify no invoca omarchy-notification-send

Escenario: terminado de otro agente sí notifica, con normal
  Dado un agente (local, p2) con focused=false
  Cuando ese agente transiciona a done
  Entonces Notify invoca omarchy-notification-send con -u normal, -g \u{f012c}

Escenario: enfocar un agente retira su toast
  Dado una toast pendiente para (local, p1) con headline "T · agent"
  Cuando el usuario enfoca (local, p1) vía CLI focus o click de fila
  Entonces Notify invoca omarchy-notification-dismiss "T · agent"
```

## Riesgos y preguntas abiertas

- `device_id` es siempre el literal `"local"` en el Store hoy (`src/model/Store.zig:314,334`) — no
  hay soporte multi-dispositivo todavía, así que `--exec kelpie focus <device>/<pane>` en la práctica
  siempre lleva `local`. No es un recorte de este issue: es el estado real del Store.
- `omarchy-notification-send -p` requiere capturar stdout del subproceso (`StdIo.pipe` +
  `child.wait`), lo que bloquea brevemente el hilo que procesa la transición (una llamada D-Bus vía
  `busctl`, del orden de ms). Aceptado: no es el hilo de render/PTY que ADR-0001 protege, y el
  bloqueo es acotado y no interactivo (a diferencia de leer PTY o esperar la ventana real).
- Preferencias de activar/desactivar por estado (mencionadas en Alcance) no tienen AC numerado ni
  mecanismo de persistencia definido en este repo todavía → **fuera de este issue**, recortado por
  YAGNI; el gate de diseño solo cubre los 5 criterios de aceptación listados.
