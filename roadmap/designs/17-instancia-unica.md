# Diseño — #17 Instancia única con GApplication: `kelpie focus <device>/<pane>`, `reload-theme`, `reload-font` llegan a la instancia primaria

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-30 · rama `feature/17-instancia-unica`
> Scope gate aprobado por wA:p2 (orquestador de fleet) · 2026-08-30, con tres condiciones (ver
> "Riesgos y preguntas abiertas").

## Spec

`app_shell.zig` pasa a `G_APPLICATION_HANDLES_COMMAND_LINE`: la instancia primaria recibe
`focus <device>/<pane>`, `reload-theme`, `reload-font` y activación sin argumentos, vía el
handler `command-line`. `main.zig` despacha localmente — **antes** de construir ninguna
`adw.Application` — los subcomandos que nunca deben viajar por D-Bus: `--version`,
`--herdr-probe` (ya existían), y los nuevos `setup`, `askpass` (stubs: este issue no implementa
esas features, solo garantiza que su despacho no toca GApplication).

**Archivos que se tocan** (ambos leaseados en exclusiva para esta ola):
- `src/main.zig` — despacho local de `setup`/`askpass` por `argv[1]`, antes del loop de flags
  existente.
- `src/ui/app_shell.zig` — flag `handles_command_line`, handler `command-line`, parser puro de
  comandos (testeable sin GObject), `focusAgent` (seam), `reloadTheme` (extrae `loadCss()` a
  función invocable), `reloadFont` (stub con warn explícito), global `main_window` +
  `onActivate` hecho idempotente (presenta si ya existe en vez de crear una segunda ventana).

**No entra** (del issue + recorte YAGNI acordado en el scope gate):
- `gapplication` CLI como interfaz pública, acciones D-Bus con parámetros (issue).
- Selección real de un agente en el sidebar: **#16 (sidebar) sigue abierto**, no hay ningún
  modelo de agentes hoy. `focusAgent` es un seam que hoy siempre reporta "no encontrado" — es la
  verdad actual, no un stub falso — y #16/#19 lo conectan a datos reales.
- `reload-font`: no existe ningún subsistema de fuente (`area:font` sin empezar). El comando
  llega, se despacha, y responde con un warn explícito — no hace nada más.
- Verificación end-to-end de "seleccionar un agente real": diferida a #16/#19 (no hay agente que
  seleccionar hasta entonces).

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Todas verificadas con `sed -n` sobre el tarball `gobject` extraído
en `/home/alejodelosrios/.cache/ghostty-build/src/zig-global-cache/p/gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3/`
(mismo hash que declara `build.zig.zon`, ya extraído por un build anterior — mismo tarball que
citó #13).

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `ApplicationFlags` es `packed struct(c_uint)` con campo `handles_command_line: bool` | `src/gio2/gio2.zig:43648` | ✅ |
| `adw.Application.new(app_id: ?[*:0]const u8, flags: gio.ApplicationFlags) *adw.Application` | `src/adw1/adw1.zig:3247` | ✅ (ya usado en `app_shell.zig`, cambia el segundo argumento de `.{}` a `.{ .handles_command_line = true }`) |
| `gio.Application.signals.command_line.connect(app, T, cb, data, opts)` — `cb: fn(app, *gio.ApplicationCommandLine, T) callconv(.c) c_int` | `src/gio2/gio2.zig:790` | ✅ |
| `gio.Application.signals.activate.connect(...)` | `src/gio2/gio2.zig:773` | ✅ (patrón ya usado en `app_shell.zig`) |
| `gio.Application.activate(app: *Application) void` | `src/gio2/gio2.zig:1001` | ✅ |
| `gio.ApplicationCommandLine.getArguments(cmdline: *ApplicationCommandLine, argc: ?*c_int) [*][*:0]u8` | `src/gio2/gio2.zig:1894` | ✅ |
| `gio.ApplicationCommandLine.setExitStatus(cmdline, exit_status: c_int) void` | `src/gio2/gio2.zig:2049` | ✅ |
| `gio.ApplicationCommandLine.printLiteral(cmdline, message: [*:0]const u8) void` | `src/gio2/gio2.zig:2005` | ✅ |
| `gio.ApplicationCommandLine.printerrLiteral(cmdline, message: [*:0]const u8) void` | `src/gio2/gio2.zig:2022` | ✅ |
| `gtk.Window.present(w: *Window) void` | `src/gtk4/gtk4.zig:59315` | ✅ (ya usado en `app_shell.zig`) |

## Diseño del handler

```
onCommandLine(app, cmdline, _) callconv(.c) c_int:
    argv = ApplicationCommandLine.getArguments(cmdline, &argc)   // [*][*:0]u8, argv[0] = nombre de programa
    cmd  = parseCommand(argv[1..argc])                            // función pura, testeable
    switch (cmd):
        .activate       -> gio.Application.activate(app); setExitStatus(0)
        .focus(dev,pane):
            if (focusAgent(dev, pane))
                gio.Application.activate(app); presenta+selecciona; setExitStatus(0)
            else
                cmdline.printerrLiteral("focus: agente no encontrado: <dev>/<pane>\n")
                setExitStatus(1)
        .reload_theme   -> reloadTheme(); setExitStatus(0)
        .reload_font    -> cmdline.printerrLiteral("reload-font: no implementado (area:font)\n"); setExitStatus(0)
        .malformed(msg) | .unknown(msg):
            cmdline.printerrLiteral(msg); setExitStatus(1)
    return status  // el valor de retorno del handler SÍ importa: gio2.zig:2026-2029 documenta
                    // que GIO llama setExitStatus(cmdline, <retorno del handler>) DESPUÉS de que
                    // el handler retorna, pisando cualquier setExitStatus fijado adentro. `status`
                    // se acumula en el switch y debe coincidir con el último setExitStatus llamado.
```

`parseCommand([]const []const u8) Command` vive en `app_shell.zig` como función pura sobre
slices de `[]const u8` (no sobre `[*:0]u8` de C) para poder testearla sin GObject. El handler de
GIO hace `std.mem.span` sobre cada entrada de `argv` antes de llamarla.

`onActivate` gana un guardia: si el global `main_window` ya es no-nulo, hace
`gtk.Window.present(main_window.?)` y retorna — antes creaba una ventana nueva cada vez que
`activate` se emitía, lo cual con `command-line` disparando `activate()` repetidas veces
(una vez por `focus`/lanzamiento sin argumentos) habría abierto una ventana duplicada por
invocación. Mismo patrón de global de un solo hilo que `empty_state_text`.

`focusAgent(device: []const u8, pane: []const u8) bool`:
```zig
// ponytail: siempre false — no hay modelo de agentes hasta que #16 (sidebar) y #19 (attach)
// existan. Es la verdad de hoy, no un placeholder que finge éxito. Reemplazar por una consulta
// real al Store de agentes cuando #16 aterrice.
fn focusAgent(device: []const u8, pane: []const u8) bool {
    _ = device;
    _ = pane;
    return false;
}
```

`reloadTheme()` extrae el cuerpo de `loadCss()` ya existente en `app_shell.zig` (sin cambiar su
lógica) a una función invocable tanto desde `onActivate` como desde el nuevo handler.

## Escenarios (Gherkin)

```gherkin
Escenario: focus con kelpie ya abierta y agente inexistente (criterio 3)
  Dado kelpie corriendo como instancia primaria
  Cuando una segunda invocación corre "kelpie focus local/no-existe"
  Entonces la segunda invocación termina con exit 1
  Y su stderr contiene un mensaje de "agente no encontrado"
  Y la primera instancia no crashea ni abre una segunda ventana

Escenario: focus con un pane conocido inyectado por el seam de test (criterio 1, verificado vía seam)
  Dado kelpie corriendo como instancia primaria con un pane conocido inyectado en focusAgent para el test
  Cuando una segunda invocación corre "kelpie focus local/<pane-conocido>"
  Entonces la segunda invocación termina con exit 0 en menos de 100 ms
  Y la primera instancia presenta su ventana

Escenario: activación sin kelpie abierta (criterio 2)
  Dado que no hay ninguna instancia de kelpie corriendo
  Cuando se ejecuta "kelpie focus local/<pane>"
  Entonces esa misma invocación arranca kelpie como primera instancia
  Y tras el primer snapshot de activate, se aplica el comando focus

Escenario: --version y setup --dry-run no activan la primaria ni requieren D-Bus (criterio 4, duro)
  Dado un entorno sin DBUS_SESSION_BUS_ADDRESS ("env -u DBUS_SESSION_BUS_ADDRESS")
  Cuando se ejecuta "kelpie --version"
  Entonces imprime nombre y versión y sale con exit 0 sin construir ninguna adw.Application
  Cuando se ejecuta "kelpie setup --dry-run"
  Entonces sale con exit 0 sin construir ninguna adw.Application

Escenario: reload-theme llega a la primaria
  Dado kelpie corriendo como instancia primaria con el tema de Omarchy cargado
  Cuando una segunda invocación corre "kelpie reload-theme"
  Entonces la primera instancia vuelve a ejecutar loadCss()
  Y la segunda invocación sale con exit 0

Escenario: reload-font llega pero no hace nada (hueco documentado)
  Dado kelpie corriendo como instancia primaria
  Cuando una segunda invocación corre "kelpie reload-font"
  Entonces la primera instancia emite un warn explícito indicando que no está implementado
  Y la segunda invocación sale con exit 0 porque el despacho en sí funcionó

Escenario: parser de argumentos (test unitario, criterio 5)
  Dado la función pura parseCommand
  Cuando se le pasan distintas combinaciones de argumentos (vacío, "focus local/p1", "focus sin-slash",
    "focus /pane-vacio", "reload-theme", "reload-font", "comando-desconocido")
  Entonces cada una produce el variant de Command correcto, incluyendo los casos malformados
```

## Riesgos y preguntas abiertas

- **Corrección tras la 2ª auditoría (este hueco no existía)**: la versión original de este diseño
  afirmaba que "el binding extraído no documenta qué hace GIO con el valor `c_int` que retorna el
  handler" y que por tanto era seguro retornar `0` fijo. Era falso: `gio2.zig:2026-2029`, cuatro
  líneas por encima de la firma de `setExitStatus` que sí se citó, dice literalmente *"The return
  value of the `command-line` signal is passed to [`setExitStatus`] when the handler returns"* —
  GIO pisa cualquier `setExitStatus` fijado dentro del handler con lo que éste retorne al final.
  Con `return 0;` fijo, ningún `setExitStatus(cmdline, 1)` interno sobrevivía. El auditor lo probó
  con un experimento controlado (`return 0` → `return 7`, el exit code observado de la invocación
  remota cambió de `0` a `7`). Lección de método: un "hueco declarado" es una afirmación sobre la
  fuente, y se verifica con el mismo `sed -n` que cualquier cita — no con "no lo dice" sin haber
  mirado cuatro líneas más arriba de la firma que sí se citó.
- Condición (1) de wA:p2: el criterio 4 es dueño de este issue y se verifica literalmente con
  `env -u DBUS_SESSION_BUS_ADDRESS -- ./zig-out/bin/kelpie --version` y
  `env -u DBUS_SESSION_BUS_ADDRESS -- ./zig-out/bin/kelpie setup --dry-run`, ambos exit 0, en
  FASE 5/6.
- Condición (2): `reload-font` no es un no-op silencioso — emite `printerrLiteral` con el mensaje
  explícito antes de `setExitStatus(0)`. QA verifica que el mensaje llegue al stderr del
  invocador remoto, no solo al log de la primaria.
- Condición (3): el seam `focusAgent` es `// ponytail:` con `#16`/`#19` nombrados como punto de
  conexión. El test de QA para el camino de éxito inyecta el pane conocido reemplazando
  temporalmente el cuerpo de `focusAgent` en un build de test (o vía una variable de test
  inyectable si el propio parser lo permite sin tocar producción) — nunca mockeando D-Bus o el
  sistema.
- `setup --dry-run` y `askpass` no tienen ninguna especificación de comportamiento propia (issues
  futuros, aún no creados): el stub de este issue solo imprime que el subcomando existe y sale 0.
  No se inventa una interfaz de `--dry-run` real.
