# Diseño — #19 Attach externo (v0.1): abrir el agente con `omarchy launch or focus tui … herdr agent attach <pane> --takeover`

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-09-03

## Spec

Al hacer click en un agente local de la sidebar, kelpie lanza una ventana del terminal de Omarchy
que ejecuta `herdr agent attach <pane> --takeover`, usando `omarchy launch or focus tui` para que un
segundo click sobre el mismo agente enfoque esa ventana en vez de abrir otra.

**Archivos que se tocan:**
- `src/herdr/attach.zig` (nuevo, territorio core-builder) — construcción pura del argv (array, sin
  string de shell), formateo del `--app-id`, y `spawnAttach`/`attachOrLogMismatch` que hacen el
  spawn real vía `std.process.spawn`, reutilizando `LocalServer.readHerdrStatus` para el chequeo de
  compatibilidad de protocolo.
- `src/ui/app_shell.zig` (territorio ui-builder) — reemplaza el stub `onSidebarActivated` (línea 427,
  marcado explícitamente "attach pending #19") por el disparo del attach en un hilo aparte (nunca
  bloquear el hilo de UI), con una copia propia (`gpa.dupe`) del `pane` para no arrastrar un slice
  prestado de `Sidebar.rows` que puede liberarse en un `refresh()` concurrente.

**No entra** (copiado del issue, más el recorte de esta ronda):
- Terminal embebido (#21+).
- Attach de solo lectura (`herdr terminal session observe`).
- Remotos vía SSH (M3) — el argv de hoy es solo el camino local.
- Preferencia "Abrir agentes en el terminal de Omarchy" (default on/off) — no hay UI de
  preferencias todavía en el repo; issue de seguimiento si se necesita antes de M2.
- Toast/diálogo de error dedicado: no existe infraestructura de `adw.Toast` en el repo. El caso
  `protocol_mismatch` se resuelve con `std.log.err` (mismo criterio ya usado por el stub que
  reemplaza: "logging is the honest truth of today, not a false stub") — no se abre ninguna ventana
  cuando el servidor es incompatible, que es el efecto observable que pide el criterio 4.

## Firmas de API que se van a usar

| API | Fuente | Verificada |
|---|---|---|
| `omarchy launch or focus tui [--app-id=<app-id>] <command> [args...]` → `omarchy-launch-or-focus-tui` | `omarchy commands --all` (máquina) + `/usr/share/omarchy/bin/omarchy-launch-or-focus-tui` | ✅ leído completo, argv builds `omarchy-launch-tui $@` y delega en `omarchy-launch-or-focus "$APP_ID" "$LAUNCH_COMMAND"` |
| `herdr agent attach <TARGET> [--takeover]` | `herdr agent attach --help` (máquina) | ✅ `Usage: herdr agent attach <TARGET> [OPTIONS]` + `--takeover` |
| `pub fn spawn(io: Io, options: SpawnOptions) SpawnError!Child` | `/usr/lib/zig/std/process.zig:442` | ✅ `sed -n '442p'` |
| `pub const SpawnOptions = struct { argv: []const []const u8, environ_map: ?*const Environ.Map = null, stdin: StdIo = .inherit, stdout: StdIo = .inherit, stderr: StdIo = .inherit, ... }` con `StdIo` incluyendo `.ignore` | `/usr/lib/zig/std/process.zig:360-434` | ✅ `sed -n '360,434p'` |
| `pub const Map = struct { array_hash_map: ArrayHashMapUnmanaged(...), allocator: Allocator }` | `/usr/lib/zig/std/process/Environ.zig:99` | ✅ `sed -n '99p'` |
| `pub fn spawn(config: SpawnConfig, comptime function: anytype, args: anytype) SpawnError!Thread` / `pub fn detach(self: Thread) void` | `/usr/lib/zig/std/Thread.zig:344,364` | ✅ `sed -n '344p;364p'` |
| Patrón de spawn con argv array + `environ_map` ya usado en este repo (`spawnHerdrServer`) | `src/herdr/LocalServer.zig:127-134` | ✅ leído completo |
| `pub fn readHerdrStatus(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat` — swallow-on-failure, `null` si no se puede leer | `src/herdr/LocalServer.zig:146-181` | ✅ leído completo |
| `pub const ServerCompat = struct { compatible: bool, restart_needed: bool }` | `src/herdr/LocalServer.zig:46-49` | ✅ `sed -n '46,49p'` |
| Stub reemplazado `onSidebarActivated` | `src/ui/app_shell.zig:427-429` | ✅ leído completo |
| Wiring del callback (`setFocusCallback`) en `ensureSidebarInited` | `src/ui/app_shell.zig:414-415` | ✅ leído completo |
| `pub const FocusFn = *const fn (data: ?*anyopaque, device: []const u8, pane: []const u8) void` | `src/ui/sidebar.zig:241` | ✅ `sed -n '241p'` |
| Globals reutilizables `gpa`/`io`/`environ_map` (set-once-en-run) | `src/ui/app_shell.zig:110,114-115` | ✅ `sed -n '110p;114,115p'` |

## Argv exacto (criterio "se construye como array, sin string de shell")

```
["omarchy", "launch", "or", "focus", "tui",
 "--app-id=io.github.alejodelosrios.kelpie.attach.<pane>",
 "herdr", "agent", "attach", "<pane>", "--takeover"]
```

`buildAttachArgv` es pura (recibe el flag `--app-id=...` ya formateado y `pane`, devuelve `[11][]const u8`)
y por tanto testeable sin GTK ni proceso real — mismo enfoque que `parseCommand` en `app_shell.zig`.
Solo el flag `--app-id=...` requiere formateo (`std.fmt.bufPrint` en un buffer del llamador); el resto
son literales estáticos o el propio slice de `pane`.

## Escenarios (Gherkin)

```gherkin
Escenario: Primer click abre el terminal de Omarchy con el attach
  Dado un agente local presente en la sidebar
  Cuando el usuario hace click en su fila
  Entonces se lanza `omarchy launch or focus tui --app-id=io.github.alejodelosrios.kelpie.attach.<pane> herdr agent attach <pane> --takeover`
  Y el argv se construye como array de strings, nunca como un comando de shell concatenado

Escenario: Segundo click enfoca en vez de abrir otra ventana
  Dado que ya existe una ventana lanzada para `<pane>` (mismo `--app-id`)
  Cuando el usuario hace click de nuevo en la misma fila
  Entonces `omarchy-launch-or-focus` encuentra la ventana por `app-id` y la enfoca
  Y no se abre una segunda ventana (comportamiento de `omarchy-launch-or-focus-tui`, no reimplementado)

Escenario: protocol_mismatch no abre una ventana vacía
  Dado que `herdr status --json` reporta `compatible: false`
  Cuando el usuario hace click en un agente
  Entonces kelpie NO lanza el proceso `omarchy launch or focus tui …`
  Y registra el error (`restart_needed`) vía `std.log.err`, visible sin abrir ninguna ventana

Escenario: el argv no bloquea el hilo de UI
  Dado que el chequeo de compatibilidad (`herdr status --json`, hasta 3 s) se dispara desde un click
  Cuando `onSidebarActivated` corre en el hilo de GTK
  Entonces el chequeo y el spawn ocurren en un hilo aparte (`std.Thread.spawn` + `.detach()`)
  Y el `pane` que recibe ese hilo es una copia propia (`gpa.dupe`), no un slice prestado de `Sidebar.rows`
```

(El criterio "`ctrl+b q` cierra el attach y el agente sigue vivo en herdr" es comportamiento de
`herdr agent attach --takeover` en sí — kelpie no lo implementa, solo lo invoca; no hay escenario de
código propio que cubrirlo, se verifica manualmente en QA con ventana real.)

## Riesgos y preguntas abiertas

- No existe infraestructura de toast/diálogo en el repo todavía — el caso `protocol_mismatch` se
  resuelve con log, no con UI visible más allá de "no se abre ventana". Si el dueño quiere un aviso
  visible, es un issue de seguimiento (requiere diseñar el primer `adw.Toast` del repo).
- `omarchy-launch-or-focus` internamente hace `eval exec setsid $LAUNCH_COMMAND` (string de shell) —
  es el script de Omarchy, fuera de nuestro control y fuera de "no entra" de este issue; nuestro argv
  hacia `omarchy` sigue siendo un array real, que es lo que pide el criterio de aceptación.
- `pane` (el `TARGET` de `herdr agent attach`) se usa tal cual, sin escapar — viene de `Store`
  (`herdr`), no de entrada de usuario; mismo nivel de confianza que el resto de IDs de pane en el
  código existente (`focusAgent`, `selectByKey`).
