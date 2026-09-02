# CONCERNS — deuda y preocupaciones vivas de kelpie

Append-only. **Solo el PM escribe aquí** (`/kelpie-flow`, `/kelpie-fleet`). Un worker que quiere
anotar algo se lo reporta al PM.

Qué entra: lo que se vio y no bloquea el issue en curso — un atajo deliberado con techo conocido, una
API pinneada que se va a mover, un gate que se aprobó a ojo. Qué no entra: bugs (esos son issues) y
ideas de features (esas son `later` en el roadmap).

Formato: `- [YYYY-MM-DD] #issue — qué se vio · por qué no se arregló ahora · qué lo dispara`

---

- [2026-08-27] #3 — primer Apply de `ui-builder`/MiMo para el spike B compiló y pasó `zig fmt`/`zig
  build`/`zig build test`, pero el diff era insatisfactorio: el tick callback nunca invalida el
  widget (`queueDraw`), así que el contador de fps mide un bucle de tick ocioso, no el redibujado de
  las 12.000 celdas que el spike existe para medir; y el shaping se hacía carácter por carácter
  (`pango.itemize` con `length=1`), lo que hace estructuralmente imposible el escenario de ligaduras
  del diseño (una ligadura necesita varios caracteres contiguos en un mismo run) · se descartó
  (`git checkout --`) y se relanzó con `ui-builder-fallback` en vez de un tercer intento del externo,
  porque el modelo ya había tardado ~48 min repartidos en dos invocaciones sin terminar ni su propia
  tabla de citas · dispara si vuelve a pasar con el mismo builder en otro issue de render: puede ser
  un patrón del modelo (itemizar por celda) más que un accidente puntual, vale la pena anotarlo en
  la skill `zig-libghostty` si se repite.
  que contenga `-h` (flag propio de la app clickeada, o un nombre de archivo así) se traga como
  ayuda y la notificación nunca sale · el spike E se salvó por casualidad (su argv usa `-c`, no
  `-h`) y no entra en el alcance de este issue arreglarlo · dispara al diseñar #18: kelpie debe
  invocar `omarchy-notification-send` directo, nunca a través del dispatcher `omarchy`.
- [2026-08-27] #6 — `scripts/spike-e.sh` no valida que `omarchy-shell notifications isDnd` haya
  devuelto algo: si falla, `dnd_original` queda vacío y el restore (trap + explícito) manda
  `setDnd ""`, que Omarchy interpreta como apagado aunque el original estuviera encendido · en un
  runbook interactivo que ya asume el shell vivo no vale una iteración de builder · dispara si este
  patrón de leer/restaurar un toggle se reutiliza en código de producción de kelpie (#18): ahí sí
  necesita el guard de valor vacío.
- [2026-08-27] #2 — `.gitignore` recibió `zig-pkg/` sin estar en la lista de archivos del diseño ·
  necesario porque Zig 0.16 materializa las lazy deps en `zig-pkg/` local al proyecto (~136 MB) y sin
  ignorarla el repo se ensucia · dispara si un futuro diseño quiere que las deps vivan en otro lado.
- [2026-08-27] #2 — CI no cachea `zig-pkg/`: cada job re-descarga y descomprime el tarball de
  ghostty (~136 MB) · no se resolvió en este spike porque es costo de CI transversal, no de este
  issue · dispara cuando el tiempo de CI moleste — issue dedicado con `actions/cache` sobre `zig-pkg/`.
- [2026-08-27] #2 — segundo test en `src/main.zig` (dimensiones no-hardcodeadas) es casi redundante
  con el primero · se dejó porque descarta un caso real de API que ignora `Options` · no dispara nada,
  aceptado como está.
- [2026-08-27] #4 — `core-builder` (OpenCode+MiMo) falló el Apply dos veces seguidas con el mismo
  diseño: intento 1 (`timeout 900`) y intento 2 (`timeout 1800`) terminaron en `exit 124` sin escribir
  ni un archivo y sin volcar salida al log · no se investigó la causa raíz en este ciclo (podría ser
  el tamaño del prompt — el diseño completo va inline — o un cuelgue de MiMo con esta tarea concreta)
  porque el fallback a `core-builder-fallback` (Claude) resuelve el issue sin bloquear más tiempo ·
  dispara si vuelve a pasar en otro issue: investigar si el prompt necesita ir por archivo en vez de
  inline, y medir si el límite real de MiMo en esta máquina es más bajo que 30 min para tareas de
  escritura+build.
- [2026-08-27] #4 — `src/vt_spike.zig:34` usa `@intCast(cp)` de `u21` a `u8` en el volcado de texto
  plano, que aborta en modo seguro con cualquier codepoint > 255 · no dispara en este spike porque el
  stream fijo es ASCII, pero `dumpDirty` es justo el tipo de helper que se recicla para depurar salida
  real · dispara si se reutiliza fuera de este test: cambiar a `std.unicode.utf8Encode` antes de
  tocar entrada no controlada.
- [2026-08-27] #4 — `src/vt_spike.zig:98` lee `cell.style.fg_color.palette` sin comprobar el tag de
  la unión; si la variante no fuera `.palette` el test entraría en panic en vez de fallar como
  aserción normal · aceptado porque es ruido de diagnóstico dentro de un test, no código de producto ·
  no dispara nada salvo que este patrón de lectura se copie a código de producción.
- [2026-08-27] #4 — el spike usa `RenderState.update()` (las dos fases juntas); el widget de M2 debe
  usar `beginUpdate`/`endUpdate` por separado bajo mutex, porque entre las dos fases el estilo por
  celda queda "stale" por diseño (`render.zig:373-378`) y `update()` sostendría el lock durante la
  denormalización de estilos · no aplica a este spike (sin hilos) · dispara al diseñar el widget de
  render en M2: usar las dos fases explícitas, nunca `update()`.
- [2026-08-27] #5 — `takeLine` (recorta el `\n` que `takeDelimiterInclusive` no descarta solo) está
  duplicado literal en `src/herdr/client.zig` (tests) y `src/herdr/probe.zig` (producción) · no se
  dedupó porque son 4 líneas en un spike, YAGNI legítimo — la deduplicación es mecánicamente trivial
  (`probe.zig` ya importa `client.zig`, sin ciclo posible: `client.zig` no importa nada del repo salvo
  `std`) — cualquier nota que diga lo contrario está mal · dispara al tocar este módulo para #9/#10:
  hacer `pub` una sola copia en `client.zig` y que `probe.zig` la use.
- [2026-08-28] #13 — `src/ui/app_shell.zig:41` lee `LANG` antes que `LC_ALL`; POSIX define `LC_ALL`
  como el que anula a `LANG`, no al revés, así que `LANG=en_US.UTF-8 LC_ALL=es_MX.UTF-8` (forzar
  español sobre un sistema en inglés) muestra "No agents" · no se corrigió en el ciclo porque el
  auditor lo marcó no bloqueante y el Gherkin del diseño solo pide "según LANG" (i18n real es YAGNI
  declarado) · dispara si i18n deja de ser YAGNI: invertir el orden de los dos `get` y añadir un test.
- [2026-08-28] #13 — `src/ui/app_shell.zig:108` (`toggleSidebar`) hace `user_data.?` sin fallback;
  el único registro pasa `split` así que hoy es provably no-nulo, pero es el único punto del diff
  donde un puntero nulo aborta el proceso en vez de degradar · no se corrigió porque el auditor lo
  marcó no bloqueante (una línea, sin urgencia) · dispara si se reutiliza este patrón de callback con
  un `user_data` que sí pueda ser nulo: cambiar a `orelse return 0`.
- [2026-08-28] #13 — `adw.ToolbarView.addBottomBar` se usó en el Apply sin estar en la tabla de citas
  del diseño (`roadmap/designs/13-app-shell.md`, que solo listaba `addTopBar`/`setContent`) · la API
  es real y la firma correcta (verificada por el auditor), así que no bloqueó, pero es reincidencia
  parcial de la lección de #7 (afirmación técnica fuera de la tabla de citas) · dispara si vuelve a
  pasar: el gate mecánico de FASE 5 debería diffear las llamadas nuevas del Apply contra la tabla del
  diseño, no solo verificar las filas que ya están.
- [2026-08-28] #13 — `std.process.exit(app_shell.run(init))` en `src/main.zig` salta el
  `try stdout.interface.flush()` final de `main` · inocuo hoy (esa rama no escribe nada a stdout antes
  de abrir la ventana) · dispara si alguien añade un `print` de diagnóstico antes de `app_shell.run`:
  hacer flush explícito antes del `exit`.
- [2026-08-28] #13 — de los 5 escenarios Gherkin, 4 solo tienen verificación manual en sesión Wayland
  (documentada con `hyprctl`/`wtype`/`grim`, no automatizable en CI headless — declarado en el propio
  diseño) · el quinto barato que sí sería automatizable (comparar el `app_id` contra la constante) no
  se escribió · dispara con el próximo issue de `src/ui/`: añadir ese test puntual.
- [2026-08-28] #8 — `core-builder` (OpenCode+MiMo) falló el Apply real dos veces seguidas con el
  diseño aprobado (`roadmap/designs/8-cliente-rpc.md`): 0 bytes de log, 0 diff en ambos intentos ·
  reincidencia exacta de las filas `#4`/`#5 · Motor / capacidad` de `lessons-learned.md` — no aporta
  regla nueva, por eso no entra ahí, solo aquí como constancia · se escaló a
  `core-builder-fallback` (Claude) sin más reintentos con MiMo, por la regla ya escrita: "0 bytes,
  0 diff" es la señal de ir a fallback, no de esperar más · dispara si un tercer issue en la misma
  ola repite el patrón: dejar de tratarlo como reincidencia aislada y abrir issue dedicado a
  investigar la causa raíz de MiMo en esta máquina (coincide con el hijo de #13 fallando en
  paralelo con el mismo síntoma).
- [2026-08-28] #8 — el guard de regresión de memoria del camino nuevo (`openForRequestGuardTest`,
  `src/herdr/client.zig`) prueba una réplica del setup de `request()`, no el `request()` real — si
  `request()` cambia su patrón de apertura de `Connection`, el guard sigue verde sin detectarlo ·
  no se resolvió porque exponer el `conn` interno de `request()` para un test externo requeriría
  cambiar la firma pública o una función de test-only más invasiva, y el patrón hoy es idéntico ·
  dispara si `request()` cambia cómo abre `Connection`: mover el guard a inspeccionar el `request()`
  real, no una copia.
- [2026-08-28] #8 — `last_received_line_buf` (test-only, `src/herdr/client.zig`) tiene una carrera de
  datos formal: se escribe desde el hilo del `FakeServer` y se lee desde el test antes de su
  `defer thread.join()` diferido — en la práctica el orden lo impone el ida y vuelta del socket, pero
  no hay happens-before declarado · no se resolvió porque no afecta código de producción, solo un
  test · dispara si `zig build test` empieza a fallar de forma intermitente en ese test específico:
  mover la lectura después del `join()` explícito, no confiar en el orden implícito.
- [2026-08-28] #8 — `request()` mete un `Connection` de 128 KiB (`read_buf`+`write_buf`, 64 KiB cada
  uno) en su propio frame de pila · aceptado porque el hilo de GTK tiene pila de sobra, pero no se
  verificó para ningún otro contexto de llamada · dispara si `request()` se llama algún día desde un
  hilo con pila reducida (p.ej. un hilo worker con stack_size explícito bajo): mover `Connection` a
  heap o reducir sus buffers para esa ruta.
- [2026-08-28] #14 — el doc-comment de `theme_css.zig:15-16` promete un parser de
  `--nombre: valor;` sin calificar que es *por línea*: `iterate(":root { --a: b; --c: d; }")`
  devuelve 0 variables en silencio porque, al no empezar la línea con `--`, salta hasta el próximo
  `\n` · no se resolvió porque el diseño lo declara explícitamente como "parser mínimo de líneas" y
  el `kelpie.css` real de Omarchy es una declaración por línea · dispara si #26 (el consumidor real)
  alimenta al parser un CSS minificado o con varias declaraciones por línea: documentar la
  limitación en el propio doc-comment antes de que #26 la descubra en producción.
- [2026-08-28] #14 — `roadmap/designs/14-tokens-color.md` no listaba `build.zig` en "archivos que se
  tocan" pese a que el Apply final sí lo edita (dos líneas: `addAnonymousImport` del fallback CSS y
  el `addTest` de `theme_css.zig`) · no se resolvió con una vuelta más de diseño porque las dos
  ediciones ya están verificadas como mínimas y correctas (mismo patrón que código existente) · el
  diseño se enmienda en este mismo PR para que el contrato refleje lo mergeado.
- [2026-08-28] #14 — `findThemeCssPath` (`app_shell.zig:121-140`) no reintenta
  `~/.local/state/omarchy/...` si `$XDG_STATE_HOME` está definido pero no contiene `kelpie.css` ·
  es el comportamiento correcto por spec XDG y por diseño, no un bug · anotado porque es la
  diferencia de entorno más probable entre la máquina del humano y CI: una captura con fallback en
  vez del tema activo puede parecer un bug de #14 cuando es solo un `$XDG_STATE_HOME` apuntando a
  otro lado.
- [2026-08-28] #9 — `src/herdr/types.zig` (test de conformidad) toma `Pong` como
  `one_of.array.items[0]` de `ResponseResult.oneOf`, asumiendo que la respuesta de `pong` siempre es
  el primer elemento del `oneOf` · no se resolvió porque hoy es cierto y cambiar a búsqueda por
  `properties.type.const == "pong"` es más código para un caso que no ha ocurrido · dispara si
  `scripts/update-schema.sh` regenera el schema con otro orden en `oneOf`: buscar el miembro por su
  discriminante `type` en vez de indexar por posición.
- [2026-08-28] #9 — el test `"required-field checker fails when a required field is renamed"`
  (`src/herdr/types.zig`) usa `std.heap.page_allocator` en vez de `testing.allocator` · verificado
  que hoy no oculta ninguna fuga (correr con `testing.allocator` sigue en verde) · no se cambió
  porque no es bloqueante y no hay fuga real que ocultar hoy · dispara si ese test empieza a crecer
  o a mutar más estado: cambiarlo a `testing.allocator` activa el detector de fugas para el futuro.
- [2026-08-28] #9 — `RequiredCheck.check` (`src/herdr/types.zig`) valida solo que el **nombre** de
  cada campo `required` del schema exista como campo del struct Zig — no valida tipo ni que el
  campo sea no-opcional · aceptado como el techo declarado del diseño (issue #9 pide "existencia",
  no un chequeo de tipos) · dispara si algún día se necesita detectar que un campo `required` del
  schema se volvió `?T = null` en el struct por error: habría que comparar también
  `field.default_value_ptr == null` para esos nombres.
- [2026-08-30] #14 — la paleta de `data/kelpie-fallback.css` es byte a byte la de Catppuccin Mocha
  (`--window-bg-color: #1e1e2e`, `--headerbar-bg-color: #313244`, `--accent-bg-color: #89b4fa`), así
  que con Catppuccin activo **no se distingue si cargó el tema o el fallback**: la verificación
  visual del criterio 2 fue ciega hasta que se repitió con `gruvbox` · no se cambió porque el
  fallback funciona y la paleta es una elección estética que el issue no fija · dispara la próxima
  vez que alguien verifique tematización a ojo: darle al fallback una paleta que no coincida con
  ningún tema instalado de Omarchy, para que "cargó el fallback" sea visible sin leer el log.
- [2026-08-30] #10 — dos criterios de aceptación de `Events.zig` (latencia < 200 ms de un
  `pane_updated` con herdr vivo, y reconexión real observada tras `herdr server stop`) quedan
  verificados **solo mecánicamente** (`zig build test`: 80/80, incluye el backoff con reloj
  inyectable, el aislamiento de hilo y un dispatcher que encola de verdad para reproducir el UAF que
  encontró la auditoría) pero **no en ventana real** · no se armó un harness desechable porque
  `Events.zig` todavía no tiene consumidor (ni `main.zig` ni `app.zig` lo importan, y `main.zig`
  estaba arrendado a #17 durante la ola) y ese harness reescribiría casi idéntico lo que el issue de
  wiring va a construir de verdad con el `Dispatcher` real sobre `glib.MainContext` · dispara: el
  issue que conecte `Events.zig` a `app.zig` **debe correr esos dos escenarios contra herdr real
  antes de darse por cerrado**, no asumir que #10 ya los cubrió.
- [2026-08-31] #12 — hallazgos menores de la segunda auditoría de `src/model/Store.zig`, ninguno
  bloqueante: (a) `errdefer` de la key nueva en `workspace_created/updated/metadata_updated` y
  `tab_created` se arma DESPUÉS de construir el literal (`WorkspaceKey{...}`/`TabKey{...}`), así que
  un OOM en el segundo `gpa.dupe` de esa misma construcción deja huérfano el primero — fuga solo bajo
  fallo de allocator, mismo patrón que el hallazgo de QA sobre `dupeWorkspaceInfo`/`dupeTabInfo`; (b)
  esos mismos cuatro handlers duplican la key SIEMPRE y la descarban en el camino común (`fetchPut`
  encuentra la entrada existente) — dos `alloc`/`free` de más por cada `workspace.updated`/
  `tab.created` sobre una entrada ya vista; `getOrPut` evitaría la doble asignación de raíz; (c)
  `pane_focused` verifica existencia con un recorrido O(n) del mapa de agentes cuando
  `self.agents.getPtr(key)` (ya usado en `upsertAgent`/`pane_agent_status_changed`) resuelve lo mismo
  en O(1) · no se corrigieron porque ninguno cambia comportamiento observable ni compromete memoria
  en el camino normal, y el issue ya llevaba 4 rondas de Apply · dispara: si `Store.zig` vuelve a
  tocarse (el consumidor de UI, o #34 con multi-dispositivo real), vale la pena aplicar los tres de
  una vez en lugar de arrastrarlos.
- [2026-08-31] #15 — los asserts de pared en `LocalServer.test.ensureRunning` (`src/herdr/
  LocalServer.zig`) fallan intermitentemente bajo `zig build test` — visto en al menos dos tests
  distintos del mismo archivo: `stopped_no_autostart` (línea 596) y `dead socket → ~1s retry window
  → launcher called` (línea 576, `elapsed.nanoseconds < 3000 * ns_per_ms`), ~1-2 de cada 8 corridas
  repetidas, con `errno 111`/`tryConnect` de fondo · no se tocó porque el territorio (`src/herdr/`)
  es de `core-builder`, ajeno al diff de #15, y el fix no está dentro del alcance de este issue ·
  dispara si el auditor de un futuro issue de `area:vt,render,pty,rpc,ssh,font` ve **cualquier**
  assert temporal de `ensureRunning` fallar en CI, no solo estas dos líneas exactas: no es su
  cambio, es deuda preexistente en la familia de tests de esa función — confirmarlo repitiendo
  `zig build test` unas 8-10 veces contra `develop` antes de culpar al diff en cuestión.
- [2026-08-31] #15 — el test de criterio 4 de `ThemeWatcher.zig`
  (`"current/ absent at start does not crash, engages once created, and keeps reloading"`) toma un
  snapshot `after_engage` tras bombear el main loop con un deadline de 2 s esperando el catch-up
  reload, y luego exige `reload_count > after_engage` · si esos 2 s se agotaran sin ningún reload
  (main loop muerto de hambre en una máquina patológicamente lenta), `after_engage` quedaría en 0 y
  el assert final podría darse por satisfecho con el catch-up tardío en vez de con el reload real
  post-`mkdir`/`writeFile` — un falso verde en vez de un falso rojo · no se resolvió porque requiere
  que el main loop se inicie de hambre 2 s completos mientras se está iterando activamente, un
  escenario no visto en ninguna corrida (auditor: 14/14 limpias) · dispara si este test aparece verde
  de forma sospechosa en CI tras un cambio real a `armDirectoryOrAncestor`/`onFileMonitorChanged`:
  revisar primero si el deadline de 2 s se agotó silenciosamente antes de confiar en el verde.
- [2026-08-31] #15 — la rama de ancestro de `ThemeWatcher.armDirectoryOrAncestor`
  (`src/omarchy/ThemeWatcher.zig:~147`) tiene el mismo agujero que tenía el bloqueante 1 del
  camino normal, un nivel más arriba: solo reconoce que `dir_path` apareció vía `.created` o
  `.moved_in` con basename exacto; si `current/` naciera de un `mv` desde un hermano dentro de
  `$XDG_STATE_HOME/omarchy/`, llegaría como `.renamed` con el nombre VIEJO y el watcher nunca
  engancharía · no se arregló porque el auditor verificó en la máquina que Omarchy no crea
  `current/` así (nace de `mkdir` en el install, no de un `mv`) · dispara si algún día Omarchy
  cambia cómo se provisiona `current/` por primera vez, o si un hook/instalador alternativo lo crea
  con un rename: aplicar ahí el mismo fix que el bloqueante 1 (tratar cualquier `.renamed` en el
  ancestro como candidato, no solo `.created`/`.moved_in`).
- [2026-08-31] #15 — `omarchy-theme-bg-next`/`-set` reescriben el symlink `current/background`
  dentro del mismo directorio que `ThemeWatcher` vigila; si coreutils lo hace con temp+rename, cada
  cambio de fondo de pantalla (sin cambio de tema) dispara un `reloadTheme()` de más — idempotente,
  ~100ms, sin fuga, pero innecesario · no se confirmó como hecho (el auditor no tenía `strace`
  disponible en la máquina para medirlo) ni se filtró, porque filtrar por nombre exacto de archivo
  es exactamente el patrón que ya falló una vez con `.renamed`/`"theme"` (bloqueante 1) · dispara si
  algún día hace falta afinar cuántas veces se llama a `loadCss()` por sesión (p.ej. para un futuro
  criterio de performance): medir primero con `strace -e trace=file` cuántos reloads de más produce
  un cambio de fondo antes de decidir si vale la pena filtrar.
- [2026-08-31] #15 — los helpers de test `pumpMainLoop`/`pumpUntil`
  (`src/omarchy/ThemeWatcher.zig`) arman un `glib.timeoutAddOnce(20ms, ...)` de watchdog en cada
  iteración del bombeo y nunca lo cancelan si el main loop ya avanzó por otra fuente primero — son
  no-ops inofensivos hoy, pero quedan pendientes en el `MainContext` por defecto y pueden despertar
  el `iteration()` de un test **posterior** que bombee el mismo contexto, hacer que retorne antes de
  lo esperado, y volverlo intermitente sin causa aparente en su propio código · no se arregló porque
  hoy solo `ThemeWatcher.zig` bombea `glib.MainContext.default()` en los tests del repo · dispara si
  un futuro test de otro archivo (`area:omarchy` o de otra área) también empieza a bombear el main
  loop por defecto y se vuelve flaky sin motivo visible: sospechar primero de watchdogs huérfanos de
  un test anterior en la misma corrida antes de asumir una carrera nueva.
- [2026-08-31] #15 — el criterio de aceptación 4 en su mitad manual (arrancar el **binario real** sin
  `~/.local/state/omarchy/current`, comprobar el warning y que el watcher engancha cuando el
  directorio aparece después, sin reiniciar) queda **sin verificar por decisión humana**: es el único
  gate de la ola que mueve el estado real de Omarchy de la máquina, y el riesgo de dejar el escritorio
  a medias no compensaba frente a lo que cubre · la mitad automatizable **sí** está cubierta por el
  test en tmpdir de `src/omarchy/ThemeWatcher.zig`, verificado por QA y por el auditor · los
  criterios 2 y 3 **sí** se verificaron en sesión real (UI cambia en < 1 s ida y vuelta; 20 cambios
  seguidos → RSS 78.008 KB → 79.396 KB, +1,8 % y aplanado, con **un solo fd de inotify**) · dispara:
  quien toque `ThemeWatcher` o el arranque del tema —#26 (paleta del terminal) o #43 (`kelpie setup`,
  que es justo el escenario de una máquina sin `current/` poblado)— debe correr ese gate con el
  binario real antes de cerrarse.

- **2026-08-31 · #16 (QA) · `ensureRunning: stopped_no_autostart never calls StatusReader` falla de forma
  intermitente.** Falló una vez durante el QA de #16 con `errno 111` al conectar el socket, y no volvió a
  reproducirse en 4 corridas más ni en 3 corridas de la rama base — o sea que **no lo causó #16**: es
  anterior y vive en `src/herdr/LocalServer.zig`. Sospecha: socket o proceso residual de una corrida previa,
  no una condición de carrera del código bajo prueba · **por qué importa**: un test que falla una de cada
  cinco veces acaba enrojeciendo el CI, y la respuesta natural —relanzar el job hasta que salga verde— es
  exactamente lo que el ruleset de este repo prohíbe; peor, entrena a leer un rojo como ruido · dispara:
  quien vea este test rojo en CI **no lo relanza**: aísla el estado residual (ruta del socket por corrida,
  limpieza en el `defer`) antes de tocar nada más, y quien vuelva a `LocalServer.zig` por cualquier motivo
  (#81 es el siguiente candidato, que lo usará de verdad) lo arregla de paso.
  · **ACTUALIZACIÓN 2026-09-01 (#81): ya no es intermitente, es determinista bajo carga.** Falla 5/5 en la
  rama de #81 **y 3/3 en `develop` limpio**, o sea que no lo causó ningún cambio: lo causa la máquina.
  `load average` ~10 en 8 núcleos (navegador, otras sesiones, herdr, quickshell — carga de escritorio
  normal, no de compilación). El test que cae es `ensureRunning: dead socket → ~1s retry window →
  launcher called` (`LocalServer.zig:544`), y `errno 111` (ECONNREFUSED) **escapa** de `ensureRunning`
  hasta el `try` del test, pese a que los tres `tryConnect` del camino están todos con `catch`. El mismo
  código pasó el CI de GitHub una hora antes. Que sea reproducible a voluntad lo vuelve **diagnosticable**,
  que es mejor que flaky: quien lo ataque tiene banco de pruebas. Sigue fuera del alcance de #81 —
  se registra, no se arregla de paso, porque tocar `LocalServer.zig` sin diseño es justo lo que este
  repo no hace.

- **2026-08-31 · #12 (hallado auditando #16) · `pane_agent_status_changed` borra `agent`, `display_agent`
  y `title` del agente.** `Store.zig:287-289` llama `updateOptionalField` con lo que traiga el evento, y
  `updateOptionalField` (`Store.zig:700-704`) duplica `null`, libera lo que había y deja el campo en `null`
  **sin condición**. Un evento de cambio de estado que solo traiga el status borra los tres campos.
  Observado en vivo por el auditor con el binario instrumentado: la fila pasó de `claude` a `pane-0` justo
  al bloquearse, porque `displayTitle` cae al `pane_id` · **por qué importa**: hoy no se nota porque nada
  cablea eventos reales, pero con #81 cada cambio de estado degradará el título de la fila que el usuario
  está mirando — y lo hará justo en el momento de máxima atención, al bloquearse · dispara: **#81, antes de
  cablear eventos reales**. Distinguir "el evento no trae el campo" de "el evento lo pone a null" es el
  arreglo; hoy el tipo no permite distinguirlos.

- **2026-08-31 · #16 · el escenario Gherkin 7 está escrito como si pasara, y no pasa.** El diseño dice
  «`focusAgent` recibe `("local","pane-3")`» al activar una fila, pero el click sale por
  `onSidebarActivated` (`src/ui/app_shell.zig:317-319`), que solo loguea. Las dos direcciones son distintas
  y el comportamiento es correcto —`focusAgent` es la entrada externa de `kelpie focus` (#17) y sí
  selecciona— pero el escenario quedó redactado sobre una costura que no es la que se ejerce · **por qué
  importa**: un Gherkin que describe una llamada que nadie hace es un criterio que se da por cumplido
  leyéndolo · dispara: **#19 (attach)**, que es quien conecta esa costura de verdad — al hacerlo, reescribe
  el escenario 7 en términos de lo que realmente ocurre y lo cubre con test.

- **2026-08-31 · #16 / #14 · en temas monocromos los tres colores de estado colapsan.** La plantilla
  `data/themed/kelpie.css.tpl:33-35` mapea `working→blue`, `blocked→yellow`, `done→green`, que es el
  mapeo correcto según la skill `omarchy-app`. Pero un tema derivado de wallpaper puede no tener tres
  colores distinguibles: en `wallhaven-5yk2o9` (el activo al hacer el gate visual de #16) `blue=#678194`,
  `yellow=#c6f9ff`, `green=#9fc7d4` — tres azules. Y `orange=#97a4b7` es **peor** que `yellow`, así que
  la regla alternativa de la skill ("si el tema trae `orange`, `orange`") tampoco salva el caso ·
  **por qué importa**: el valor #1 del producto es que se distinga de un vistazo qué agente reclama
  atención, y en estos temas el color no lo distingue. Lo que sí lo distingue es la **forma** del glifo
  —spinner / triángulo con `!` / check—, que el diseño de #16 especificó por separado; es la razón por
  la que el sidebar sigue siendo legible aquí · dispara: **#36** (sistema de diseño) y **#40** (gate M4,
  retematizar en vivo): antes de dar por bueno el mapeo semántico, probar con un tema monocromo y
  decidir si `blocked` necesita algo que no dependa del color del tema (peso, tamaño o un realce propio).

- **2026-09-01 · #81 · el arreglo del `Store` es correcto pero NO cierra la fila que decía cerrar.**
  `updateOptionalField` (`Store.zig:700`) dejó de borrar con `null`, y su test lo fija. Pero su único
  llamador es el brazo `.pane_agent_status_changed` (`Store.zig:287-289`), y **`pane.agent_status_changed`
  está excluido a propósito de `subscription_types`** (`Events.zig:68-78`), cosa que el propio diseño de
  #81 confirma en su "No entra". Con el cableado que entrega #81, ese brazo **no corre nunca en vivo**:
  el camino real es `pane.updated` → `upsertAgent` (`Store.zig:618-655`), que ni siquiera toca
  `title`/`agent` · **por qué importa**: la fila anterior sobre el borrado de campos sigue abierta, y
  cerrarla porque "ya lo arreglamos en #81" dejaría un problema real tapado por un arreglo que apunta a
  otro sitio · dispara: quien suscriba `pane.agent_status_changed` de verdad, o quien note la
  degradación por el camino de `pane.updated` — hay que **volver a observarla** antes de dar la fila
  por cerrada. Hallazgo del auditor de #81.

- **2026-09-01 · #81 · las fuentes idle en vuelo al cerrar se filtran (verificado, no supuesto).**
  `gio2.zig:894-895` dice que `shutdown` se emite «immediately after the main loop terminates», así que
  cuando corre `onShutdown` la loop ya está muerta y ningún idle pendiente se despacha: se pierden el
  `Box`, el `EventCtx`/`ResyncCtx` y el `json.Parsed`. Era el hueco que el diseño de #81 declaró sin
  verificar; queda verificado y la respuesta es **fuga de salida de proceso, no use-after-free** (el
  `Store` es global y nunca se `deinit`) · **por qué importa**: es inocuo hoy y deja de serlo el día que
  algo con vida propia —un fd, un lock de archivo, un socket— viaje en uno de esos contextos · dispara:
  quien haga que el `Store` se destruya de verdad al cerrar, o quien meta un recurso no-memoria en el
  contexto de un evento.

- **2026-09-01 · #81 · no hay arnés de herdr falso que tolere secuencias parciales.** QA escribió tres
  tests de ciclo de vida de `Link` con un servidor falso; **dos colgaban la suite entera** y se
  quitaron. La causa es del arnés, no de los tests: el falso herdr espera tres `accept` en secuencia
  —sonda, suscripción, resync— y un escenario legítimo como "parar inmediatamente" no produce los dos
  últimos, así que el `accept` bloquea para siempre y el `join` del `defer` no vuelve; cerrar el
  listener antes del join no lo desbloquea en esta implementación de `std.Io` · **por qué importa**: sin
  arnés, todo el ciclo de vida de `Link` queda en el gate manual, que es justo el que ya demostró pasar
  en verde sobre una app rota · dispara: quien vaya a tocar `Link` o `EventsClient` — un servidor falso
  que acepte N conexiones y responda a lo que le llegue, en vez de un guion fijo, desbloquea los tres
  tests de golpe.

- **2026-09-01 · #81 · un agente que nace con kelpie ya conectado no aparece hasta el siguiente
  resync.** Los eventos de pane dejaron de crear agentes (`Store.zig`, `upsertAgent`) porque su
  payload no trae identidad —ni `agent`, ni `title`, ni `cwd`—, así que crear desde ellos producía
  filas con el `pane_id` pelado. `pane.agent_detected` tampoco sirve: su payload es `pane_id` +
  `workspace_id` y nada más (verificado sobre el socket) · **por qué importa**: abrir un agente
  nuevo y no verlo aparecer es visible y desconcierta · dispara: **#84**, cuyo mecanismo de resync
  con rebote lo cierra de paso — al llegar cualquier evento se pide snapshot, y el snapshot sí trae
  la identidad. Si #84 se implementa como está descrito, esta fila se cierra con él; verificarlo.

---

## #84 — el snapshot como única fuente de `agent_status` (2026-09-01)

- **El techo de bloqueo del hilo de UI al cerrar sube a ~43 s, y su probabilidad sube mucho más**
  (`ui/herdr_link.zig:163-190`, `herdr/Events.zig:146`) · lo levantó el auditor de #84 · **qué es**:
  `EventsClient.stop()` hace dos joins secuenciales —trabajador de resync, luego lector— y los dos
  pueden acabar en `client.request` con `default_read_timeout_ms` = 15 s (`client.zig:88`), que
  `shutdown(.recv)` no desbloquea porque actúa sobre el fd de la suscripción, no el de la petición ·
  **por qué importa**: el tramo del lector solo se pagaba en la ventana de reconexión; el del
  trabajador se paga en cualquier momento, porque #84 deja un resync en vuelo ~1/s en sesión activa.
  Cerrar la ventana contra un herdr que no responde congela la UI hasta 15 s de forma rutinaria ·
  **el arreglo real**: una costura cancelable en `client.request` y otra en
  `LocalServer.ensureRunning`. Issue propio · **mitigación barata mientras tanto**: bajar el timeout
  de `realResync` (p95 medido 105 ms contra un timeout de 15 s). No se hizo en #84 porque el lector
  usa la misma función en frío y los 105 ms se midieron con 14 panes.

- **La huella compara snapshot contra snapshot, no snapshot contra Store** (`model/Store.zig:193`) ·
  **qué es**: si un evento mete una divergencia en el Store, un snapshot idéntico al anterior se
  descarta y no la repara. La propiedad real que da #84 es "el snapshot es la verdad **cuando el
  snapshot cambia**", no "el snapshot es la verdad siempre" · **por qué importa hoy poco**: tras #84
  ningún evento escribe `status`, y el replay converge · **cuándo importaría**: en cuanto un evento
  vuelva a mutar algo que la huella cubra.

- **El no-solapamiento vale entre resyncs del trabajador, no globalmente** (`herdr/Events.zig:245`) ·
  el hilo lector sigue llamando a `realResync` por su cuenta al abrir conexión · el diagrama del
  diseño (`roadmap/designs/84-snapshot-fuente-estado.md`) lo omite y debería decirlo.

- **`scheduleResync`/`debounceFired` no los ejercita ningún test** (`ui/herdr_link.zig:310` y `:321`) ·
  el test solo llama a `shouldSchedule`, la mitad pura · **y es deliberado**: la alternativa es armar
  timers de GLib en tests, que ya provocó un use-after-free en este mismo archivo (tercera vez, ver
  los comentarios de sus líneas 424-436 y 566-580) · el temporizador de 100 ms real solo se cubre en el gate de
  ventana real.

- **Los tres bucles de `applySnapshot` usan `put`** (`model/Store.zig:247`, `:261`, `:275`) · un
  `pane_id`/`workspace_id`/`tab_id` repetido dentro del mismo snapshot conserva la key vieja y filtra
  · misma familia que el `fetchPut` que denegó la auditoría de #12 · preexistente, pero los tres
  bucles se reescribieron en #84 sin cerrarlo.

- **`onTransition` queda como código muerto en producción** · tras #84 `upsertAgent` ya no dispara
  transiciones y el único emisor vivo sería `pane_agent_status_changed`, que no está suscrito
  (`herdr/Events.zig:72-81`) · el comentario de `ui/sidebar.zig:389-391` ya no dice la verdad ·
  **ojo**: #18 (notificaciones) se cuelga precisamente de `onTransition`, así que esto hay que
  resolverlo **antes** de empezarlo, no después.

- **`onEvent` no comprueba `link.stopping` antes de armar el timer** (`ui/herdr_link.zig:285`) · un
  evento que llegue durante el cierre programa un timeout que `stop()` puede no alcanzar a cancelar.

- **La huella excluye `revision` a propósito** (`model/Store.zig:601`) · consecuencia: el desempate
  por recencia dentro del mismo estado (`Store.zig:818-823`, de #16) deja de ser inmediato y se
  actualiza en el siguiente repintado real · **decisión del PM**, no accidente: incluirlo costaría
  una reconstrucción completa del sidebar ~1/s para siempre, y filas que saltan solas bajo el cursor
  tampoco son mejor UX · pendiente de que el dueño de #16 objete si no está de acuerdo.

- **El sondeo de 150 ms corre siempre, también con la ventana oculta**
  (`ui/herdr_link.zig:armPollTrampoline`) · **qué es**: ~6.6 peticiones `session.snapshot`/s a un
  socket unix local, para siempre, esté la ventana visible, minimizada o en otro espacio de trabajo ·
  **por qué importa**: no se ha medido su efecto en batería en un portátil · **la mitigación
  evidente, no implementada aquí**: suspender el sondeo cuando la ventana no está visible y
  reanudarlo al volver. El rebote por evento seguiría cubriendo el caso visible-con-actividad ·
  **por qué no se hizo en #84**: alcance; el issue ya revirtió una decisión de diseño y añadir
  gestión de visibilidad es superficie nueva sin criterio que la exija.

- **Las dos primeras transiciones tras arrancar tardan ~900-1300 ms** · medido en el gate de #84 ·
  desaparece en régimen (p50 161 ms sobre 12 muestras) · no se investigó la causa: candidatos son la
  ventana de `ensureRunning`, el momento en que se arma el sondeo, o el primer snapshot en frío.

- **`done` es pegajoso en herdr**: `report-agent --state idle` sobre un pane que está en `done` deja
  el snapshot en `done` (verificado tres veces el 2026-09-02) · no es un bug de kelpie, pero invalida
  cualquier guion de prueba que asuma poder volver de `done` a `idle` · el gate de #84 tuvo que
  excluir `done` de su secuencia por esto.
