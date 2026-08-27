# Diseño — #<N> <título del issue>

> Estado: **PENDIENTE DE APROBACIÓN** · rama `<prefijo>/<N>-<slug>`
>
> Al aprobar el gate, y solo entonces, sustituye la línea de arriba por
> `Aprobado por: <humano> · <fecha>`. Escribirla antes deja en el repo un registro de una
> aprobación que nunca ocurrió.

## Spec

Qué se construye, en una frase.

**Archivos que se tocan** (territorio de un solo builder):
- `src/…/…zig` — qué cambia

**No entra** (copiado del issue, más lo que se recortó por YAGNI):
- …

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Cada fila la verificó el PM ejecutando `sed -n '<línea>p' <archivo>`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `Terminal.resize(cols, rows)` | `~/.cache/ghostty-build/src/ghostty/src/lib_vt.zig:NNN` | ✅ |

## Escenarios (Gherkin)

Uno por criterio de aceptación del issue. QA los convierte en tests; el auditor los usa de vara.

```gherkin
Dado <el estado de partida>
Cuando <la acción concreta>
Entonces <el resultado observable y medible>
Y <el efecto secundario que también se comprueba>
```

## Riesgos y preguntas abiertas

- <lo que no se pudo verificar en la fuente — declarado como hueco, NUNCA supuesto como hecho>
