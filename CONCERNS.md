# CONCERNS — deuda y preocupaciones vivas de kelpie

Append-only. **Solo el PM escribe aquí** (`/kelpie-flow`, `/kelpie-fleet`). Un worker que quiere
anotar algo se lo reporta al PM.

Qué entra: lo que se vio y no bloquea el issue en curso — un atajo deliberado con techo conocido, una
API pinneada que se va a mover, un gate que se aprobó a ojo. Qué no entra: bugs (esos son issues) y
ideas de features (esas son `later` en el roadmap).

Formato: `- [YYYY-MM-DD] #issue — qué se vio · por qué no se arregló ahora · qué lo dispara`

---

- [2026-08-27] #6 — `remaining_has_help_flag` en `/usr/share/omarchy/bin/omarchy:125-137` escanea
  todo el remainder de argumentos buscando `-h`/`--help` y solo para en `--`; un argv de `--exec`
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
