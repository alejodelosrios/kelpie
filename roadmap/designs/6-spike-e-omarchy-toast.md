# Diseño — #6 Spike E — toast de Omarchy con `--exec` clickeable

> Aprobado por: Manuel Alejandro Ramirez · 2026-08-27 · rama `chore/6-spike-e-omarchy-toast`

## Spec

Un script bash desechable, `scripts/spike-e.sh`, que ejercita `omarchy notification send/dismiss`
para verificar empíricamente, antes de diseñar #18, que el hint `omarchy-exec-argv` sobrevive un
`omarchy restart shell` y que el argv llega literal (sin re-tokenizar, sin expandir `$(...)`).

**Archivos que se tocan:**
- `scripts/spike-e.sh` — nuevo. Script de shell puro, sin dependencias del build de Zig.
- `roadmap/designs/6-spike-e-omarchy-toast.md` — este diseño.
- Cuerpo del issue #6 — se anotan los resultados observados (marca de checkboxes + notas), no vía
  este repo sino con `gh issue comment` / edición del cuerpo al cerrar el spike.

**No entra** (copiado del issue):
- Código Zig de notificaciones (eso es #18, que consume estos resultados).
- Diseño de la notificación real de kelpie (formato de headline, glifo, esquema de reemplazo por
  device/pane) — solo se prueba el mecanismo, no se decide el producto.
- Cambios en `/usr/share/omarchy/` (solo lectura, nunca escritura).

Recorte YAGNI: el script no necesita flags, logging estructurado, ni reintentos — es un runbook de
un solo uso con salidas legibles por humano (el propio PM/humano lee la salida y marca el issue).

## Firmas / contrato del CLI que se va a usar

Ninguna se escribe de memoria. Cada fila la verificó el PM ejecutando `sed -n` contra la máquina
(gana la máquina sobre la doc, por regla del repo).

| Comportamiento | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `-r`/`--replace-id` exige id numérico (`^[0-9]+$`), si no, error y exit 1 | `/usr/share/omarchy/bin/omarchy-notification-send:65-70` | ✅ |
| `--exec` consume el resto de la línea como argv ya tokenizado por el shell **del llamador**; nunca se re-parsea | `/usr/share/omarchy/bin/omarchy-notification-send:113-127` | ✅ |
| Un solo `exec_args` con espacio interno → error "usa palabras separadas, no un string citado" | `/usr/share/omarchy/bin/omarchy-notification-send:170-174` | ✅ |
| El argv se serializa a JSON NUL-delimitado vía `jq -Rsc` y se guarda como hint `omarchy-exec-argv` | `/usr/share/omarchy/bin/omarchy-notification-send:176-179` | ✅ |
| `shouldBypassDnd`: bypassa no-molestar solo si `appName === "omarchy-action"` (o `notify-send` + urgencia crítica) — `--app-name kelpie` **no** bypassa, por lo tanto respeta DND | `/usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js:34-38` | ✅ |
| `execArgvFromHints` lee el hint como dato persistido (sobrevive un restart del shell, a diferencia de una acción libnotify que muere con su emisor) | `/usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js:60-65` | ✅ |
| `Util.execArgv(argv)` ejecuta `bash -lc 'exec "$@"' bash <argv>` — argv como posicionales, la shell nunca re-interpola el string | `/usr/share/omarchy/shell/Commons/Util.qml:57-64` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: argv literal al hacer click, sin expansión ni re-tokenización
Dado que se envía una toast con --exec que incluye un argumento con espacios y otro "$(id)"
Cuando el usuario hace click en la toast
Entonces el archivo temporal contiene los argumentos literales
Y el argumento con espacios llega como un solo elemento del argv
Y "$(id)" llega como el string literal "$(id)", sin expandir

Escenario: -p imprime un id numérico y -r reemplaza en vez de apilar
Dado que se envía una primera toast con -p
Cuando se reenvía una segunda notificación con -r <id-devuelto>
Entonces solo hay una toast visible (la segunda reemplazó a la primera)
Y no se apilan dos toasts

Escenario: dismiss retira la toast visible
Dado una toast visible con un headline conocido
Cuando se ejecuta `omarchy notification dismiss "<substring del headline>"`
Entonces la toast desaparece
Y el comando devuelve "ok"

Escenario: kelpie respeta no-molestar (DND)
Dado que "omarchy toggle notification silencing" está activo
Cuando se envía una toast con --app-name kelpie
Entonces la toast NO aparece
Cuando se envía una toast con --app-name por defecto (omarchy-action)
Entonces la toast SÍ aparece
Y al terminar el spike se restaura el estado original de DND

Escenario: glifo y urgencia se distinguen visualmente
Dado que se envía una toast con -g <glifo Nerd Font>
Entonces el glifo aparece en la toast
Cuando se envían dos toasts, una con -u critical y otra con -u normal
Entonces se distinguen visualmente entre sí

Escenario: la toast sigue siendo clickeable tras un restart del shell
Dado una toast enviada con --exec activa y visible
Cuando se ejecuta "omarchy restart shell"
Y la toast sigue visible tras el restart
Entonces al hacer click, el argv persistido se sigue ejecutando
Y el archivo temporal recibe los argumentos, confirmando que la acción es dato y no un callback en memoria
```

## Riesgos y preguntas abiertas

- No se pudo verificar en la fuente si una toast sobrevive un `omarchy restart shell` en todos los
  casos (p.ej. si ya expiró por `-t`) — el escenario de restart depende de que la toast siga visible
  en el momento del restart; si no persiste, es un hallazgo del spike, no un hueco de diseño.
- El comportamiento exacto de `-t` (expire-time) no está en el alcance de este issue y no se prueba
  aquí.
