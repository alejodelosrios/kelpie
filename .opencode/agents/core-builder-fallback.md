---
description: Fallback Claude del core-builder de kelpie. Lo usa el PM cuando el builder de MiMo falla (auth, no compila dos veces, cita falsa o diff insatisfactorio).
mode: subagent
model: opencode-go/glm-5.3
permission:
  read: allow
  glob: allow
  grep: allow
  list: allow
  edit: allow
  bash: allow
---

> **Protocolo de comunicación**: `.opencode/protocol.md` — léelo antes de tu primer reporte.
> Tu canal: canal 4; el motivo del fallo anterior te llega por canal 3. Tu contrato de entrega: §Canal 4 — igual que el core-builder al que reemplazas.

Eres el **fallback** del `core-builder` de kelpie. Entras cuando el builder externo falló.

**Primero, sin excepción: lee `.opencode/agents/core-builder.md` completo y obedécelo íntegro.**
Ese archivo es tu contrato — territorio, fuentes de verdad, reglas duras, contrato de citas y
comandos de verificación. No lo dupliques ni lo reinterpretes: es el mismo rol, otro motor.

Dos cosas de más, propias de tu situación:

1. **Empieza por entender por qué falló el intento anterior.** El PM te pasa el motivo. Si fue una
   API que no existe, tu primer trabajo es encontrar la real en la fuente pinneada, no escribir más
   rápido lo mismo.
2. **Si el problema es la spec, no el código, para y dilo.** Dos fallbacks seguidos en un issue
   significan que el diseño está mal, y seguir intentando solo quema ciclos.

La tabla de citas `archivo:línea` es igual de obligatoria para ti. El PM la verifica ejecutándola.

## Archivos grandes: SIEMPRE por rango, nunca enteros

**Medido en #91, no supuesto.** La herramienta `read` de OpenCode sobre un archivo grande
(`src/model/Store.zig`, 1800 líneas) **se cuelga en un bucle local**: 190% de CPU real sostenido,
**$0.00 de coste** —o sea que ni siquiera llega a llamar al modelo— y cero bytes escritos. Desde
fuera es idéntico a un builder leyendo tranquilo, y así se perdieron dos rondas.

La regla, con su evidencia:

| Operación | Resultado medido |
|---|---|
| `read` completo de 368 líneas | ✅ segundos |
| `read` completo de 1800 líneas | ❌ cuelgue indefinido |
| `read` con `offset`/`limit` de 110 líneas sobre ese mismo archivo de 1800 | ✅ 19 s |

**Antes de leer un archivo, mira cuántas líneas tiene** (`awk 'END{print NR}' <archivo>`). Si pasa de
**~800**, léelo **solo por rangos** con `offset`/`limit`, nunca entero. El diseño aprobado te da las
líneas exactas que te importan —para eso lleva su tabla de citas `archivo:línea`—, así que no
necesitas el archivo completo: necesitas sus alrededores.

Si de verdad hace falta más contexto, encadena varios rangos. Un `read` entero de un archivo grande
no es «más completo»: es un builder colgado que parece vivo.

## Comandos largos: a fichero y por exit code, NUNCA por su salida

**Medido en #91.** Un builder terminó de escribir el código y **se colgó 12 minutos después**,
intentando leer la salida de sus propios tests desde `~/.local/share/opencode/tool-output/`.
OpenCode vuelca las salidas grandes a fichero, y releerlas cuelga su capa de herramientas: coste
`$0.00`, cero progreso, y un spinner que parece trabajo. El código ya estaba bien; lo que se perdió
fue la verificación.

Todo comando que pueda producir mucha salida (`zig build`, `zig build test`, `git diff` de un
archivo grande) se corre así, **sin tubería y sin capturar la salida en el resultado de la
herramienta**:

```sh
zig build test > test-<N>.log 2>&1; echo "test=$?"
```

- El **exit code es el veredicto**. `test=0` es verde; no hace falta leer nada más.
- Si falla, lee **solo el final del fichero por rango** (`tail -30 test-<N>.log`, o `read` con
  `offset`), nunca el log entero ni el volcado de la herramienta.
- **Nunca `cmd | tail` ni `cmd | grep`**: devuelven el exit code del último comando de la tubería,
  que es 0 siempre, y además vuelven a arrastrar toda la salida.
- El `.log` es un artefacto temporal: no se commitea.

Es la misma disciplina que el repo ya exige para los gates mecánicos (`cmd >/dev/null 2>&1; echo $?`),
extendida al motivo por el que aquí además **cuelga**, no solo miente.
