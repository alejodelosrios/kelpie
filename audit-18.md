# Auditoría #18 — veredicto v1 (código con bloqueo en UI)

> Transcripción literal del reporte del auditor delegado (canal 4 → PM). El PM no
> reinterpreta: un veredicto binario no se resume. El agente `auditor` (sin permiso
> de edición) no pudo escribir este archivo; lo escribe el PM transcribiendo.
> Proveniencia: task `ses_f82bc90e4ffe4f2SL3OHMe5056`, auditor-18 = Claude Opus
> (`claude-opus-5[1m]`) en pane propio por canal 5. Pane hijo cerrado y verificado
> (`herdr pane list` sin fantasmas). Artefacto congelado: commit `295fc86`, árbol
> limpio, `git diff 1bf5adf..295fc86` = 5 archivos / +995 −2.

## Veredicto de Opus — LITERAL, sin reinterpretar

```
APROBADO

**Artefacto verificado por mí:** `git rev-parse --short HEAD` → `295fc86`, `git status --porcelain` vacío, `git diff --stat 1bf5adf..295fc86` → los 5 archivos declarados en el diseño, ni uno más. `zig fmt --check` → 0. `zig build test --summary all` → **51/51 pasos, 205/205 tests**, exit 0, verde a la primera en este árbol (el flaky de `LocalServer` que reportó el PM no se reprodujo). Declaraciones `^test ` bajo `src/`: 144 en `1bf5adf` → 155 en `295fc86` = **+11 exactos** (f107 cumplido).

## Lo que verifiqué en la fuente, no en el reporte

| Afirmación del diff | Fuente leída hoy | Veredicto |
|---|---|---|
| `std.process.run(gpa, io, RunOptions)` con `timeout` | `/usr/lib/zig/std/process.zig:496`, `RunOptions.timeout: Io.Timeout` `:485`, `RunResult{term,stdout,stderr}` `:488-492` | ✅ real, no alucinada |
| El `timeout` **sí acota** el bloqueo | `process.zig:510` (`defer child.kill(io)`), `:520` (`multi_reader.fill(..., options.timeout)`) | ✅ |
| `Io.Timeout{.duration: Clock.Duration}`, `Clock.awake` monotónico | `/usr/lib/zig/std/Io.zig:1132-1135`, `:756` | ✅ |
| `Store.ChangeObserver.onTransitionFn(ptr, *const Agent, from, to)` ↔ `Notify.observer()` | `src/model/Store.zig:122-134` vs `Notify.zig:97-103` | ✅ firma idéntica |
| `applySnapshot` dispara `fireTransition` (desbloqueo #93) | `src/model/Store.zig:305-312` | ✅ |
| `gtk.Window.isActive(*Window) c_int` | tarball pinneado `gobject-0.3.2-Skun7F6Hog…`, `src/gtk4/gtk4.zig:59230-59231` | ✅ |
| `gtk.Application.getActiveWindow(*Application) ?*gtk.Window` | mismo tarball, `:2151-2152` | ✅ — y `app_shell.zig:482-486` guarda el **Application**, no el Window, y reconsulta: no puede colgar puntero |
| `-r` / `-p` / `--exec` / orden del argv | `/usr/share/omarchy/bin/omarchy-notification-send:85-91` (1er bucle de opciones), `:98` (headline), `:112-115` (description), `:117-137` (`--exec` al final) | ✅ el argv de `buildArgv:341-376` se parsea exactamente como el diseño dice |
| `omarchy-notification-dismiss <substring>` no imprime nada | `/usr/share/omarchy/bin/omarchy-notification-dismiss:1-11` | ✅ |
| Los callbacks llegan por el hilo de UI | `src/ui/herdr_link.zig:37-51` (`idleAddOnce`, con el porqué escrito), `:363-372` | ✅ — y por tanto **el bloqueo ES en el hilo de UI**, como el diseño ya corrigió |

## Los cuatro sitios donde busqué el DENEGADO y no lo encontré

1. **La reincidencia del ledger (`errdefer` que no dispara en un `return;` de éxito, fila #18 2026-09-03)** — es el hallazgo que este ciclo tenía más probabilidad de repetir, porque la fila lo describe como punto ciego de MiMo *dos veces en este mismo issue*. Cruzado: `Notify.zig:201-208` y `:218-226` son los dos `return;` de éxito, y ambos liberan **las cuatro** asignaciones vivas a mano (`headline`, `key_device`, `key_pane`, `agent_name_dup`) con el comentario que lo dice. No queda ningún tercer camino de retorno temprano en `sendNotification` (`:141-246`). `dismiss` (`:249-276`) no tiene nada asignado antes de su `catch … return`. La regla se honró.
2. **Panics** — `/usr/bin/grep` sobre el archivo nuevo y sobre las líneas `+` de `app_shell`: cero `unreachable`, `catch unreachable`, `@panic`, `orelse unreachable`. El `run_result.term != .exited or run_result.term.exited != 0` (`:213`) es seguro por cortocircuito de `or`.
3. **El `notify.dismiss` pelado de `app_shell.zig:453`** (sin guarda, a diferencia de `:370`) — lo perseguí como posible UB sobre `io: std.Io = undefined`. No lo es: `dismiss` llama `ensureMapInited` y sale por `self.notifs.get(key) orelse return` antes de tocar `io`, y `HashMap.getIndex` corta en `if (self.size == 0) return null` (`/usr/lib/zig/std/hash_map.zig:965-971`) sin llamar al contexto. Además el mapa solo puede tener entradas si el observador ya se registró. La guarda sobra, no falta.
4. **Memoria del mapa** — dueños explícitos y correctos: claves duplicadas (`:161-164`), rama `found_existing` que libera el duplicado y no la clave viva (`:230-237`), `fetchRemove` que libera las slices **propias** del mapa (`:270-275`), `deinit` que recorre las cuatro (`:84-94`). El test `:583-652` lo ejercita con `std.testing.allocator` (caza UAF y doble free) liberando el `Agent` original antes de la búsqueda. Correcto.

**Sobre los dos huecos que el PM aceptó por escrito: coincido, no bloquean.** El switch de `:118-135` y el `dismiss` de `:249` no son testeables sin abrir una costura de inyección en `sendNotification`, que el diseño no pidió; la mitad de forma de ambos escenarios sí está testeada (`buildArgv` critical/normal/`-r`), el patrón exacto de las cuatro liberaciones de `fetchRemove` está probado en rojo-verde en `:644-649`, y el gate Wayland enseña urgencia, glifo y retirada en pantalla. Un DENEGADO aquí quemaría una iteración por dos brazos de `switch`.

## Preocupaciones — para que el PM las mande a CONCERNS.md (ninguna bloquea)

1. **Un `displayTitle()` que empiece por un flag reconocido se come el argv.** El primer bucle de opciones del script (`omarchy-notification-send:85-91` → `parse_omarchy_option:30-52`) corre **antes** de `headline=$1` (`:98`), así que un título literal `-u` consume el body como valor de urgencia y el script muere en `:144-146` (`exit 1`, sin toast). Aplica a `-g -u -i -t -r -p --app-name --image --icon` y sus formas `--flag=valor`. **No es inyección** — el escenario Gherkin de inyección se sostiene, el dato viaja como un elemento de argv y jamás por un shell — pero el headline es dato influenciable por el agente colocado en posición de opción, y el test de inyección (`Notify.zig:499-529`) solo prueba títulos con `$(...)`, nunca uno que empiece por guion. Consecuencia real: una toast perdida y un `log.warn`. El arreglo limpio (`--` terminador) es territorio de Omarchy, no de este issue.
2. **El `timeout` de 3 s es por llamada a `fill()`, no un presupuesto total.** `process.zig:520` pasa un `.duration` relativo dentro del bucle, así que se rebasa en cada iteración: un hijo que gotea salida más lento que 3 s por trozo nunca se corta. Irrelevante para la línea única de `busctl -p`, relevante si alguna vez algo escribe más por ese stdout.
3. **Coste del bloqueo del hilo de UI, sin medir.** El diseño lo declara y `CONCERNS.md` lo registra, y verifiqué que está acotado — pero el número que se acepta es «3 s peor caso», nunca el típico. Cada toast es `fork`+`exec` de bash → `jq` → `busctl` → D-Bus, sincrónico en el main context; y `applySnapshot:305-312` los dispara **en bucle**, uno detrás de otro, si varios agentes transicionan en el mismo snapshot. Vale la pena medir el típico en el gate Wayland (el instrumento ya está: es el mismo gate del criterio 1) antes de que alguien lo dé por gratis.
4. **`notify` no se `deinit`-a nunca** (sin call site en el árbol). Crecimiento acotado por número de panes distintos jamás notificados y no dismisseados — un agente que va `blocked → done` y nunca se enfoca deja su entrada para siempre. Tres slices cortas por pane; ruido, no fuga peligrosa. Mismo patrón de vida-de-proceso que `theme_watcher`, así que es consistente con el repo, no una desviación.
5. **La fila de `CONCERNS.md` sobre el hilo (`+`, la segunda del diff) cita el diseño diciendo lo contrario de lo que el diseño dice hoy.** La fila reprocha al diseño la frase «no es el hilo de render/PTY»; el diseño de este ciclo ya la corrigió en §Riesgos («corre en el hilo de UI … los callbacks llegan por `idleAddOnce`»). La fila es historia del ciclo archivado y como tal es correcta, pero un lector futuro que la siga a `roadmap/designs/18-notificaciones-omarchy.md:95-98` no encontrará lo que la fila cita. Una anotación `⚠️ corregido en el diseño v2` la deja legible.

**Alcance y ADR-0001:** el diff hace lo que el diseño dijo y solo eso — sin refactor de paso, sin archivos fuera del territorio `ui-builder`, `build.zig`/`build.zig.zon` intactos, cero dependencias nuevas, cero hexadecimales de color (los `\u{f0026}`/`\u{f012c}` son glifos Nerd Font citados contra `src/ui/sidebar.zig`, no color), nada reimplementado de `ghostty-vt`. `/usr/share/omarchy/` solo se lee; el paquete no escribe en `$HOME`; no se vigila CSS de tema por archivo; no hay `-A` de libnotify por ningún lado — se llama al binario real, no al dispatcher, con el motivo escrito.

— auditor-18 (Claude Opus, claude-opus-5[1m])
```

## Nota del PM (no parte del veredicto)

El orquestador (wA:p1) **reabrió su aprobación del diseño** tras este veredicto: el
`std.process.run` sincrónico en el hilo de UI (incluido el camino interactivo del click
en `onSidebarActivated`) viola la regla dura «nunca bloquear el hilo de UI», y el
comentario de `Notify.zig:197` («so a hung D-Bus never freezes the UI thread») es falso.
El v1 queda como historia; el merge exige el rework (spawn+detach, mutex en `notifs`,
comentario veraz) + re-auditoría explícita del punto. Ver `audit-18b.md` (cuando exista).
