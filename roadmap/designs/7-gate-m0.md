# Diseño — #7 Gate M0 — veredicto de los spikes contra la tabla de aborto del ADR-0001

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-28 · rama `docs/7-gate-m0`
>
> Scope gate aprobado por el humano en la misma sesión (los tres recortes YAGNI y el salto de motor).

## Spec

Cerrar M0: escribir en el ADR-0001 el veredicto binario de los cinco spikes con su evidencia
medida, adoptar formalmente el **plan B GL** que #3 forzó, y volcar a las skills lo que los spikes
enseñaron sobre las APIs reales —incluidas **dos afirmaciones que hoy son falsas** en
`zig-libghostty`.

**Archivos que se tocan** (issue `type:docs`; Apply por el PM, ver "Motor" abajo):
- `docs/adr/0001-stack.md` — sección nueva "Resultado del gate (M0)" con una fila por spike
  (veredicto / evidencia / issue); §Decisión punto 4 reescrito a `GtkGLArea` + renderer GL propio;
  título del ADR y §Alternativas actualizados para que "plan B" deje de ser hipotético;
  §Consecuencias con el costo real de M2.
- `.claude/skills/zig-libghostty/SKILL.md` — corregir el contrato de filas sucias para consumidores
  **Zig** y el párrafo del renderer.
- `.claude/skills/omarchy-app/SKILL.md` — cuatro gotchas verificados en #6.
- `roadmap/designs/7-gate-m0.md` — este archivo.

**Fuera del repo** (parte del entregable, no del diff): comentario en los issues de M2 afectados por
el plan B (**#21, #22, #26**) y en el gate **#20** de M1.

**No entra:**
- Los 13 comentarios "desbloqueado" en cada issue de M1. El criterio del issue es una disyuntiva
  (*"Si todo pasó → comentario en cada uno; si algo falló → se paró, se informó y el ADR describe el
  fallback"*): B falló, aplica la segunda rama. Basta el comentario en el gate #20.
- Empezar cualquier trabajo de M1/M2.
- El contrato del socket de herdr (#5): vive en `src/herdr/README.md`; la skill `herdr` es global del
  usuario y quedó fuera de alcance en su propio ciclo.
- Reabrir el veredicto de #3. Está firmado por el humano en el issue; aquí solo se transcribe.

## Firmas y hechos que se van a citar

No hay APIs nuevas: el entregable son afirmaciones sobre APIs y sobre el sistema. Cada una la
verificó el PM con `sed -n`/`grep -n` antes de escribirla. Rutas absolutas; `G` =
`/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src`.

| Afirmación que se escribe | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| No hay iterador de filas sucias en la fachada Zig: `row_iterator_next_dirty` solo existe en el shim C | `$G/terminal/c/render.zig:575` | ✅ |
| El consumo Zig es el `MultiArrayList` de filas: `row_data.items(.dirty)` | `$G/terminal/render.zig:97`, `:818-820` | ✅ |
| Estado global `Dirty` = `false` / `partial` / `full` | `$G/terminal/render.zig:281-292` | ✅ |
| `clean()` limpia las dos capas a la vez; para consumir medio frame se limpian por separado | `$G/terminal/render.zig:816-820` | ✅ |
| `beginUpdate` y `endUpdate` son funciones separadas (`update()` sostendría el lock) | `$G/terminal/render.zig:373`, `:754` | ✅ |
| `cell.style` es indefinido salvo que el `style_id` no sea el default | `$G/terminal/render.zig:275-277` | ✅ |
| Guarda `Cell.hasStyling()` = `style_id != stylepkg.default_id` | `$G/terminal/page.zig:2291-2293` | ✅ |
| El patrón lo usa el test oficial `"dirty state"` | `$G/terminal/render.zig:1960` | ✅ |
| El dispatcher `omarchy` escanea **todo** el remanente buscando `-h`/`--help` (y para en `--`) | `/usr/share/omarchy/bin/omarchy:128-137` | ✅ |
| `omarchy-notification-dismiss` llama `omarchy-shell -q` → nunca imprime nada | `/usr/share/omarchy/bin/omarchy-notification-dismiss:11` | ✅ |
| Urgencia `normal` expira a 8000 ms; solo `Critical` devuelve `0` | `/usr/share/omarchy/shell/plugins/notifications/Service.qml:98-105` | ✅ |
| `omarchy-shell notifications invokeLast` llama al mismo `invokePopupDefault` que el click | `…/Service.qml:904-906`, `:360`, `:1056` | ✅ |
| `RenderState.Cell` envuelve la celda cruda en `raw` → la llamada es `cell.raw.hasStyling()` | `$G/terminal/render.zig:264-269` | ✅ |
| `lib.Enum` construye un enum **exhaustivo** (no hay valor imprevisto que manejar) | `$G/lib/enum.zig:43` | ✅ |
| En Zig 0.16 `linkSystemLibrary` vive en `std.Build.Module` y lleva struct de opciones | `/usr/lib/zig/std/Build/Module.zig:363`, uso real en `build.zig:53` | ✅ |
| Los campos de struct de zig-gobject llevan prefijo `f_`: `g.f_geometry.f_width`, `gs.f_num_glyphs` | `src/ui/grid_widget.zig:212-217` | ✅ |

> Añadidas tras la primera pasada del auditor: `linkSystemLibrary` y el acceso al avance del glifo se
> habían escrito **de memoria**, por fuera de esta tabla, y las dos estaban mal. Es la regla que manda
> sobre todas, incumplida en el propio PR que la refuerza. Toda afirmación de skill entra por aquí.

Evidencia de los veredictos (números medidos, no re-derivados aquí):
#2 → issue #2 comment; #3 → `issues/3#issuecomment-5446538175`; #4 → issue #4 comment;
#5 → issue #5 comment; #6 → issue #6 comment.

## Escenarios (Gherkin)

Issue de documentación: los escenarios se verifican leyendo el artefacto, no ejecutando tests Zig.

```gherkin
Escenario: cada spike tiene veredicto binario y evidencia en el ADR
  Dado el ADR-0001 con su sección "Resultado del gate (M0)"
  Cuando se lee la fila de cada uno de los cinco spikes (#2..#6)
  Entonces cada fila dice PASA o FALLA, trae el número o hecho medido, y enlaza a su issue
  Y ninguna fila afirma algo que no esté en el comentario del issue que enlaza

Escenario: el spike que falló deja el fallback adoptado por escrito
  Dado que #3 falla la fila "B — renderer Pango/GSK" de la tabla de aborto
  Cuando se lee la §Decisión del ADR
  Entonces el punto del renderer dice GtkGLArea + renderer GL propio, no Pango/GSK
  Y el ADR registra el número que lo forzó (~28 fps en el mejor caso, umbral 60)
  Y los issues #21, #22 y #26 de M2 llevan un comentario con el cambio de plan

Escenario: M1 queda desbloqueado sin arrastrar el fallo de B
  Dado que el fallo de #3 solo toca el renderer del terminal (M2)
  Cuando se comenta el gate #20 de M1
  Entonces el comentario declara M0 cerrado y M1 desbloqueado, y acota que el plan B es de M2

Escenario: las skills dejan de afirmar lo que los spikes falsificaron
  Dado el contrato de filas sucias de zig-libghostty y su párrafo de renderer
  Cuando se busca "next_dirty" y "Pango y nodos GSK" en la skill
  Entonces el iterador aparece marcado como exclusivo del shim C, con el patrón Zig real al lado
  Y el párrafo del renderer apunta a GL con el número medido que lo justifica
  Y cada afirmación nueva de ambas skills es rastreable a una fila de la tabla de citas de arriba
```

## Riesgos y preguntas abiertas

- **El ADR cambia de conclusión, no solo se anota.** El título y la §Decisión nacieron nombrando
  "renderer Pango/GSK"; dejarlos intactos con una tabla que dice lo contrario abajo es peor que no
  escribir la tabla. Se edita el ADR en sitio (sigue `aceptado`, con nota de enmienda fechada) en vez
  de abrir un ADR-0002: el propio ADR-0001 previó este resultado como "plan B", así que esto es el
  gate ejecutándose según lo escrito, no una decisión nueva.
- **`->`/`!=` no ligan**: no se registra como fallo del stack. Es la consecuencia directa de forzar
  el avance de cada glifo a `cell_width`, que es lo que una rejilla de terminal exige. Se anota como
  hecho, no como deuda.
- **`GSK_RENDERER=vulkan` no se midió de verdad**: esta máquina no tiene ICD Vulkan
  (`VK_ERROR_INCOMPATIBLE_DRIVER`) y GTK cae al fallback. El ADR lo declara como hueco, no como dato.
- **El plan B GL no está medido todavía.** #3 solo probó que `gtk.GLArea` crea contexto y limpia a un
  color; que un renderer GL propio con atlas llegue a 60 fps es una hipótesis heredada de Ghostty, no
  un número de este repo. El ADR lo dice explícitamente y #21 se queda con `risk:high`.

## Motor (FASE 4)

Territorio `docs/` → `docs-writer` (OpenCode+MiMo). Se salta al Apply por Claude, con el humano
aprobándolo en el scope gate, por dos motivos registrados: `lessons-learned.md` documenta **dos**
ciclos (#4 y #5) en que MiMo terminó un Apply de escritura con 0 bytes y 0 diff, y el contenido de
este issue es la síntesis de evidencia que solo el PM leyó (los comentarios de los cinco issues).
Queda anotado en `.claude/state/7.json` con su motivo.
