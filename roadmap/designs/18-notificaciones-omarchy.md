# Diseño — #18 Notificaciones por `omarchy notification send`

> Aprobado por: orquestador wA:p1 · 2026-09-07 (scope + diseño, más las dos desviaciones
> declaradas: binario directo en vez del dispatcher, y YAGNI en preferencias por estado).
> Corrección menor post-aprobación, pendiente de ratificación: la frase del hilo en §Riesgos
> (el archivado decía "no es el hilo de UI"; verificado hoy que SÍ lo es, acotado por timeout).

## Naturaleza del ciclo: recuperación, no escritura desde cero

Existe trabajo archivado y auditado en `d047cc6` (rama remota
`origin/feature/18-notificaciones-omarchy`): `src/omarchy/Notify.zig` (735 líneas),
wiring en `src/ui/app_shell.zig` y este mismo diseño (aprobado 2026-09-03).
#93 mergeó en `b4ce64d` y levantó el bloqueo. Este ciclo trae ese trabajo con
`git cherry-pick d047cc6`, resuelve conflictos conservando ambos lados y verifica
que el desbloqueo es real. La rama de este ciclo es
`feature/18-notificaciones-omarchy-v2`, nacida de `origin/develop` (`1bf5adf`).

## Spec

Un observador del `Store` (`src/omarchy/Notify.zig`) que, en cada transición de estado de un
agente, dispara una toast de Omarchy: `blocked` → `critical` con click-to-focus; `done` → `normal`,
salvo que ese agente sea el foco actual de una ventana activa. Reemplaza la toast anterior del mismo
agente en vez de apilar, y la retira cuando el usuario lo enfoca en kelpie.

**Archivos que se tocan** (territorio `ui-builder`, `area:omarchy`):
- `src/omarchy/Notify.zig` (recuperado de `d047cc6` vía cherry-pick) — construcción de argv,
  spawn sin shell, mapa `(device,pane)→id`, `dismiss`.
- `src/ui/app_shell.zig` (resolución de conflicto, no elección de lado) — instancia `Notify`,
  la registra como `ChangeObserver` del `Store` junto a `sidebar.observer()`, le inyecta
  `io`/`environ_map` y un callback `isWindowActive`, y llama `notify.dismiss(device, pane)`
  en los dos puntos donde kelpie ya "enfoca" un agente: `focusAgent` (CLI
  `focus <device>/<pane>`) y `onSidebarActivated` (click de fila). #19 aterrizó el hilo de
  attach externo en `onSidebarActivated`: la resolución **conserva el attach de #19 Y añade
  el `dismiss`**; el `dismiss` corre en el hilo UI (no bloquea), el attach sigue en su hilo
  detached.
- `CONCERNS.md`, `lessons-learned.md` (ledgers append-only): el cherry-pick los toca; se
  resuelven **conservando ambos lados** (hotspots, reglas vigentes f61/f74/f81).

**No entra** (copiado del issue):
- Sonido propio (lo decide el shell).
- DND (#46).
- libnotify (Omarchy usa D-Bus `org.freedesktop.Notifications` directo vía `busctl`).

**Corrección de alcance frente al issue**: el issue describe el comando como `omarchy notification
send ...`. La skill `omarchy-app` establece que el dispatcher `omarchy` escanea todo el remanente
de la línea buscando `-h`/`--help`, así que un argv de `--exec` que por casualidad contenga algo
parecido puede ser malinterpretado. Este diseño invoca **directamente**
`/usr/share/omarchy/bin/omarchy-notification-send` (el binario real), no el dispatcher — mismo
criterio que Spike E (#6), la fuente de comportamiento citada en el issue.

## Validez del diseño archivado contra el código de hoy (2026-09-07, verificado por el PM con `sed`)

- **Desbloqueo de #93: CONFIRMADO.** `applySnapshot` dispara `fireTransition` para agentes
  existentes cuyo estado cambió (`src/model/Store.zig:305-312`), con `fireChanged` antes
  (`:303`). Era el motivo exacto del bloqueo ("el único camino real nunca dispara
  `fireTransition`") y ya no es cierto.
- `Store.ChangeObserver` (`:122-134`) y `addObserver` (`:168-170`) **idénticos** a los citados
  en 2026-09-03. Sin cambios.
- Vía `applyEvent` (`pane_agent_status_changed` → `fireTransition` si `from != to`,
  `src/model/Store.zig:380-387`) **intacta**; `herdr_link.onEvent` sigue llegando a
  `store.applyEvent` + `scheduleResync` (`src/ui/herdr_link.zig:363-372`).
- `Agent` (`:18-35`, con `displayTitle()`), `types.AgentStatus`
  (`src/herdr/types.zig:9-14`), glifos del sidebar (`src/ui/sidebar.zig:514,520`),
  `parseCommand`/`onCommandLine`/`focusAgent` (`src/ui/app_shell.zig:51-60`, `:310-322`,
  `:354-359`), `std.process.SpawnOptions` (`/usr/lib/zig/std/process.zig:360-365`),
  `Child.wait` (`/usr/lib/zig/std/process/Child.zig:134-137`), `gtk.Window.isActive`
  (paquete pinneado `gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`,
  `src/gtk4/gtk4.zig:59231` — verificado extrayendo el tarball de `~/.cache/zig/p`;
  el archivado citaba `:59230-59231`, mismo símbolo, corrimiento de 1 línea) y
  `omarchy-notification-send` (`-r` `:60-77`, `--exec` `:162-180`, `-p`/`"u <id>"`
  `:195-208`) + `dismiss` (`:1-10`) — **todo re-verificado hoy**.
- Único cambio real desde el archivado: `onSidebarActivated` hoy es el hilo de attach de #19
  (`src/ui/app_shell.zig:427-445`) donde el archivado ponía `notify.dismiss`. De ahí el plan
  de resolución (arriba): sumar, no elegir.

## Cadena de activación (la cita prueba que existe, no que se ejecuta — f108)

Producción, camino snapshot (fuente fiable fijada en #86): evento herdr →
`herdr_link.onEvent` (`:363`) → `applyEvent` + `scheduleResync` con debounce →
`session.snapshot` → `Store.applySnapshot` → `fireTransition` (`:305-312`) →
`Notify.onTransition` → `omarchy-notification-send` (argv, sin shell). Camino rápido:
`applyEvent` directo (`:380-387`). Click en la toast: hint `omarchy-exec-argv` →
`kelpie focus <device>/<pane>` → `onCommandLine` (`:310`) → `focusAgent` (`:354`,
selecciona fila + `dismiss`) y presenta ventana. Enfoque por click de fila:
`onSidebarActivated` → attach (#19, hilo detached) + `dismiss` (hilo UI).
Comprobación: `zig build test` para argv/ids/dismiss; toast real + click con
orquestador en Wayland (criterio 1, ver abajo); `omarchy-shell notifications invokeLast`
como aserción sin humano si hace falta.

Nota conocida (comportamiento de #93, no de este issue): `applySnapshot` solo dispara
transiciones para agentes **ya existentes** cuyo estado cambió; un agente que aparece por
primera vez ya en `blocked` no notifica, y un snapshot sin cambios relevantes se descarta
por huella (`:194-199`) sin disparar nada. No se recorta ni se amplía aquí.

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `--exec` consume el resto del argv como comandos del click, dato nunca reinterpretado por shell | `/usr/share/omarchy/bin/omarchy-notification-send:162-180` | ✅ hoy |
| `-p` imprime a stdout el id numérico (`"u <id>"` de `busctl`, se emite solo el id) | `/usr/share/omarchy/bin/omarchy-notification-send:195-208` | ✅ hoy |
| `-r <id>` reemplaza una toast existente (`replaces_id`) | `/usr/share/omarchy/bin/omarchy-notification-send:60-77` (parseo), `:190-201` (uso) | ✅ hoy |
| `omarchy-notification-dismiss <substring>` → `omarchy-shell -q …`, no imprime nada | `/usr/share/omarchy/bin/omarchy-notification-dismiss:1-10` | ✅ hoy |
| `Store.ChangeObserver` — `onChangedFn`/`onTransitionFn(ptr, agent, from, to)` | `src/model/Store.zig:122-134` | ✅ hoy |
| `Store.addObserver(self, observer) !void` | `src/model/Store.zig:168-170` | ✅ hoy |
| `applySnapshot` dispara `fireTransition` para agentes existentes con estado cambiado (**desbloqueo #93**) | `src/model/Store.zig:305-312` | ✅ hoy |
| `applyEvent` (`pane_agent_status_changed`) dispara `fireTransition` si `from != to` | `src/model/Store.zig:380-387` | ✅ hoy |
| Eventos reales de herdr llegan a `store.applyEvent` + resync a snapshot | `src/ui/herdr_link.zig:363-372` | ✅ hoy |
| `Agent` — campos y `displayTitle()` | `src/model/Store.zig:18-35` | ✅ hoy |
| `types.AgentStatus` — `idle, working, blocked, done, unknown` | `src/herdr/types.zig:9-14` | ✅ hoy |
| Glifos Nerd Font del sidebar para blocked/done | `src/ui/sidebar.zig:514,520` (`\u{f0026}`, `\u{f012c}`) | ✅ hoy |
| `parseCommand`/`onCommandLine`/`focusAgent` aceptan `focus <device>/<pane>` (consumidor de `--exec`) | `src/ui/app_shell.zig:51-60`, `:310-322`, `:354-359` | ✅ hoy |
| `std.process.SpawnOptions{ argv, … }` | `/usr/lib/zig/std/process.zig:360-365` | ✅ hoy |
| `Child.wait(child, io) WaitError!Term` | `/usr/lib/zig/std/process/Child.zig:134-137` | ✅ hoy |
| `gtk.Window.isActive(window) c_int` — ventana activa | tarball pinneado `gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`, `src/gtk4/gtk4.zig:59231` | ✅ hoy |

## Escenarios (Gherkin — uno por criterio del issue)

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

- `device_id` es siempre el literal `"local"` en el Store hoy
  (`src/model/Store.zig:232,273,287`) — sin soporte multi-dispositivo todavía, así que
  `--exec kelpie focus <device>/<pane>` en la práctica siempre lleva `local`. Estado real
  del Store, no recorte de este issue.
- `omarchy-notification-send -p` captura stdout (`pipe` + espera del hijo): corre en el hilo
  de UI — los callbacks llegan por `idleAddOnce` al main context de GLib
  (`src/ui/herdr_link.zig:41-51`), como ya advirtió la auditoría archivada en `CONCERNS.md`.
  Aceptado porque es acotado (`.timeout` de 3 s; típicamente ms de D-Bus vía `busctl`) y no
  interactivo, no porque corra en otro hilo. Vale también para `dismiss` en `onSidebarActivated`.
- Preferencias por estado (mencionadas en Alcance) sin AC numerado ni persistencia en este
  repo → **fuera**, recortado por YAGNI.
- **Criterio 1 (toast real < 500 ms + click enfoca) abre ventana Wayland: se ejecuta con el
  orquestador, no en solitario.** QA cubre argv/ids/dismiss/inyección en tests; el valor se
  prueba en sesión Wayland con el humano.
- Sin preguntas abiertas que bloqueen: ninguna firma se escribió de memoria; todo lo citado
  se verificó hoy con `sed`/lectura por rango.

## Obligaciones del ledger bajadas a este diseño (qué rastro dejan)

- Procedencia fleet (f52/f60/f72/f109): el diseño se publicó con pendiente y el PM esperó
  el mensaje de wA:p1 antes del cherry-pick; aprobación recibida 2026-09-07. Rastro:
  este encabezado + transcript.
- Cadena de activación (f108): sección dedicada arriba; el auditor la cruza contra el diff.
- Citas cubren toda afirmación técnica (f46/f48/f54): tabla re-verificada hoy, no heredada.
- Ledgers hotspots, ambos lados (f61/f74/f81): resolución de cherry-pick declarada arriba;
  rastro en el diff de `CONCERNS.md`/`lessons-learned.md`.
- Auditor tras QA commiteado, artefacto congelado (f47/f90/f95): fases en orden, canal 5.
- Gate de valor con ventana real y control negativo (f89/f93/f102): criterio 1 con orquestador.
- Verificación con `git diff HEAD` (f90, estado `MM` miente) e higiene (rangos, comandos a
  fichero con exit code, sin `cmd | tail`): la aplica el PM en FASE 5.
