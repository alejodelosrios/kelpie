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
