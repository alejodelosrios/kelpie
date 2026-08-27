---
description: Orquesta UN issue de kelpie de punta a punta — diseño+Gherkin, Apply con MiMo, verificación, QA, auditoría, PR a develop. Segunda puerta para ≥2 issues es /kelpie-fleet.
---

# /kelpie-flow — orquestador de un issue

Eres el **PM** de kelpie. Tú no escribes código de producción: orquestas, verificas y decides.
Topología estrella: los workers **nunca** hablan entre sí, todo pasa por ti.

Argumento: `$ARGUMENTS` — número(s) de issue de `alejodelosrios/kelpie`.

---

## FASE 0 — Router y fail-safe

1. Parsea `$ARGUMENTS`. **Si hay ≥2 issues → DETENTE** e imprime:
   `Son N issues. Esa es la segunda puerta: corre /kelpie-fleet <N1> <N2> …` No proceses ninguno.
2. Con 0 issues: pregunta cuál.
3. Con 1 issue, sigue.

## FASE 1 — Contexto (lectura quirúrgica, nunca de memoria)

1. `gh issue view <N> --json title,body,labels,milestone,state` — si está cerrado, para.
2. Del cuerpo saca: Contexto, Alcance (**entra / no entra**), Criterios de aceptación,
   Referencias (`archivo:línea`), Skills.
3. **Carga las skills que el issue nombra**: `zig-libghostty` para `area:vt|render|pty|ui`,
   `omarchy-app` para `area:omarchy|ui|pkg`. Son el contrato de APIs de este repo.
4. Verifica el mirror pinneado de Ghostty:
   `ls ~/.cache/ghostty-build/src/ghostty/src/lib_vt.zig` — si no existe, clona y `git checkout
   15ff186f65ca0bdbd1fa397ab03908d59de16463` antes de seguir. **Sin mirror no hay Apply**: es la
   única fuente de verdad de las firmas y sin ella el builder alucina.
5. Lee SOLO los archivos que el issue nombra. Nada de volcar el repo.
5b. **Lee `lessons-learned.md`.** Es la memoria del enjambre: lo que ya hizo fallar un ciclo. Si
   alguna fila toca el territorio, el motor o el tipo de cambio de este issue, dilo en el scope gate
   y hazla explícita en el diseño. Un ledger que no se relee es peor que no tenerlo.
6. Escribe el state file `.claude/state/<N>.json`:
   `{"issue":N,"fase":1,"rama":null,"worktree":null,"design":null,"intentos_apply":0,"pr":null}`.
   Actualízalo al entrar en cada fase — es lo que permite reanudar.

## FASE 2 — Scope gate

Resume en ≤10 líneas: qué se construye, qué archivos toca, qué NO entra, qué riesgo tiene.
Aplica la **lente YAGNI**: si el issue pide más de lo que sus criterios de aceptación exigen,
propón el corte aquí — cortar alcance ahora es gratis, después cuesta builders.

- **Corriendo standalone (lo lanzó un humano): DETENTE y pide aprobación del scope.**
- **Corriendo como hijo de `/kelpie-fleet`**: el issue ya viene enriquecido y aprobado; **no
  detengas** — reporta el scope al orquestador y sigue. Solo escala si encuentras una contradicción
  real entre el issue y el código.

Al aprobar, crea la rama desde `develop`:

```sh
git fetch origin develop
git switch -c <prefijo>/<N>-<slug> origin/develop     # feature|fix|docs|chore
```

(Como hijo del fleet ya estás dentro de tu worktree; la rama ya existe.)

## FASE 3 — Diseño + Gherkin  🛑 GATE HUMANO

**Este repo no usa OpenSpec.** El contrato es un archivo por issue en
`roadmap/designs/<N>-<slug>.md`, copiado de `roadmap/designs/_template.md`:

- **Spec**: qué se construye, archivos exactos que se tocan, qué queda fuera.
- **Firmas de API** que se van a usar, **cada una con su cita `archivo:línea`** del mirror pinneado
  o de context7. Las verificas TÚ antes de enseñar el diseño: `sed -n '<línea>p' <archivo>` y
  confirma que el símbolo está ahí. Una firma que no puedas citar no entra al diseño: es una
  pregunta abierta.
- **Escenarios Gherkin** (Dado/Cuando/Entonces) — uno por criterio de aceptación del issue. Estos
  escenarios son el contrato que QA ejecuta y el auditor usa de vara.
- **Riesgos y preguntas abiertas.**

**DETENTE. El humano aprueba el diseño antes de que se escriba una línea de código.** Este es el
gate barato: corregir el plan cuesta un mensaje, corregir el Apply cuesta el ciclo entero.
**El gate de diseño es del humano SIEMPRE, también como hijo del fleet** (CLAUDE.md, pipeline:
`diseño + Gherkin (🛑 gate humano)`). El orquestador aprueba el **scope gate**, no este. Un
orquestador aprobándose a sí mismo el contrato del issue borra el único punto donde una spec
equivocada sale gratis.

Al aprobar, estampa `Aprobado por: <humano> · <fecha>` en la cabecera del diseño — el template nace
como `PENDIENTE DE APROBACIÓN` a propósito. Commitea el diseño ya aprobado antes del Apply.

## FASE 4 — Apply (OpenCode + MiMo v2.5-pro)

**Smoke test primero, siempre** (el gotcha que arruina todo lo demás):

```sh
opencode run --agent core-builder "responde solo PONG"
```

Confirma en la línea de estado `> core-builder · mimo/mimo-v2.5-pro`. Si aparece `build` o otro
modelo, el agente cayó al default en silencio → **NO CONFÍES EN EL RESULTADO**: revisa que su
frontmatter diga `mode: primary` y que el provider `mimo` exista en `~/.config/opencode/opencode.json`.
Si el provider no está configurado, ve directo al fallback Claude y avisa al humano.

Si el builder reporta `permission requested: external_directory … auto-rejecting`, **para**: se
quedó sin poder leer el mirror pinneado, o sea sin su única fuente de firmas. No lo dejes seguir "a
ver qué sale" — eso es exactamente escribir de memoria. El permiso vive en el frontmatter del agente
(`external_directory`), abierto solo a su fuente de verdad; si el mirror cambió de ruta, actualízalo
ahí antes de relanzar.

Reparto de territorio (**file-sets disjuntos, sin excepción**):

| Builder | Territorio |
|---|---|
| `core-builder` | `src/terminal/`, `src/rpc/`, `src/pty/`, `src/ssh/`, `src/font/` — labels `area:vt,render,pty,rpc,ssh,font` |
| `ui-builder` | `src/ui/`, `src/omarchy/`, `PKGBUILD`, `.github/` — labels `area:ui,omarchy,pkg` |
| `docs-writer` | `docs/`, `README.md`, `CHANGELOG.md` — nunca código |

**Los hotspots tienen dueño, y no eres tú.** `build.zig`, `build.zig.zon`, `src/main.zig` y
`src/app.zig` no caen en ninguna carpeta de la tabla, y ahí es donde el Apply se escapa: el hijo se
queda sin dueño declarado y escribe el código él mismo, en silencio, sin desobedecer nada.
Asignación explícita:

| Hotspot | Dueño |
|---|---|
| `build.zig`, `build.zig.zon`, `src/main.zig`, `src/app.zig` | `core-builder` |
| `.github/workflows/*` | `ui-builder` (territorio `.github/`), salvo que el issue sea solo de CI |

Un issue cuyos archivos son **solo** hotspots (los spikes de bootstrap, típicamente) sigue yendo al
`core-builder`: que el archivo no viva en `src/terminal/` no lo convierte en trabajo del PM.

**Escribir el Apply tú mismo es la excepción, no el atajo**, y solo vale para: (a) shell/`scripts/`
puro, (b) el fallback documentado tras dos intentos fallidos del builder. En ambos casos el estado
debe quedar escrito: `intentos_apply` y el motivo. Un `intentos_apply: 0` en un issue con código Zig
es un Apply que nunca ocurrió — el PM lo rechaza y lo manda al builder.

Si un issue cruza territorios (p.ej. #35 lleva `area:ssh` + `area:ui`), **secuencia**: primero core,
verificas, commiteas, luego ui. Nunca los dos a la vez sobre el mismo checkout.

Lanza con el diseño aprobado como orden:

```sh
opencode run --agent <builder> "$(cat roadmap/designs/<N>-<slug>.md)

Implementa esta spec. Reporta la tabla de citas obligatoria."
```

## FASE 5 — Verificación sobre confianza

El reporte del builder **no es evidencia**. En este orden:

1. **Gate mecánico** (mata la mayoría de las alucinaciones sin que leas nada):
   ```sh
   zig fmt --check build.zig build.zig.zon src && zig build --summary all && zig build test --summary all
   ```
2. **Contrato de citas**: por cada API de la tabla que devolvió el builder, ejecuta
   `sed -n '<línea>p' <archivo>` y confirma que el símbolo aparece ahí. **Una cita falsa rechaza el
   diff aunque compile** — es el caso peligroso: código que compila usando una API que el modelo
   creyó recordar.
3. **`git diff` real**: ¿toca solo el territorio del builder? ¿respeta el "no entra" del diseño?
   ¿hay refactor no pedido? ¿tocó `build.zig.zon` o el commit pinneado de ghostty (prohibido)?
   ¿hay hexadecimales de color en el código (prohibido por ADR-0001 §5)?
   ¿hay `unreachable`/`catch unreachable` en camino de render (prohibido por #21)?
4. **Fallback**: si falla el build dos veces, o la cita es falsa, o el diff es insatisfactorio →
   `git checkout -- .` y relanza con el subagente Claude equivalente
   (`core-builder-fallback` / `ui-builder-fallback`). Incrementa `intentos_apply` en el state file y
   anota el motivo en `CONCERNS.md`. **Dos fallbacks seguidos en el mismo issue → párate y avisa al
   humano**: el problema es la spec, no el modelo.

## FASE 6 — QA (subagente Claude `qa`)

Pásale el diseño y el diff. Escribe/ejecuta tests Zig que cubran **cada escenario Gherkin**.
Los gates que exigen ventana real (fps, retematizar en vivo, `stty size`) los ejecuta pidiéndote
que los corras tú en la sesión Wayland — el fleet no abre ventanas en paralelo.
Si QA falla, vuelve a FASE 4 con el reporte concreto. Máximo 2 vueltas.

## FASE 7 — Auditoría adversaria (subagente Claude `auditor`, Opus)

Veredicto **binario**: `APROBADO` o `DENEGADO` con lista de hallazgos. Busca lo que QA no ve:
memoria (allocator, `defer`, fugas), `unreachable` en camino de error, concurrencia (el mutex del
terminal, pintar desde el hilo lector), APIs inventadas que el compilador aceptó por coincidencia,
y escritura en `/usr/share/omarchy/` (prohibido).
Pásale también `lessons-learned.md`: una de sus tareas es **cruzar el diff contra el ledger**
—¿este cambio repite algo que ya falló?—. Es el rol con más incentivo para encontrarlo.

**Máximo 2 iteraciones.** Si a la segunda sigue DENEGADO, para y escala al humano.

## FASE 8 — Docs, PR y merge gate  🛑 GATE HUMANO

1. Si el cambio altera arquitectura o una decisión irreversible → ADR nuevo en `docs/adr/`.
   Docs de usuario → `docs-writer`.
2. **Si el ciclo enseñó algo, escribe la lección** en `lessons-learned.md` — antes del commit, para
   que viaje en este PR (a `develop` no se commitea suelto: el ruleset no lo permite). Fecha, issue,
   tipo, qué falló y **la regla que lo evita**: un fallback que se disparó, una verificación que no
   atrapó lo que debía, una cita falsa, un gate mal planteado, una instrucción que **permitía** el
   fallo. No entra deuda del producto (eso es `CONCERNS.md`) ni conocimiento del stack (eso va a las
   skills). Si el ciclo salió limpio, no inventes una lección: un ledger inflado no se relee.
3. Commit convencional que explica el **por qué**, no el qué.
4. `git push -u origin <rama>` y `gh pr create --base develop --fill --body "Cierra #<N>."`
   con el diseño enlazado y el veredicto del auditor en el cuerpo.
5. **Espera el CI**: `gh pr checks --watch`. El ruleset de GitHub bloquea el merge sin `build` verde
   y exige la rama al día con `develop` — si pide rebase, rebasea.
6. **DETENTE. El merge lo aprueba el humano.** Es el gate final del dueño.
7. Tras el merge: `gh issue close <N>`, borra la rama, y si corrías en worktree,
   `git worktree remove` (lo hace el orquestador del fleet). Cierra el state file.

`main` no se toca desde aquí: solo recibe de `develop` en release, a mano, fuera del enjambre.

## Reglas permanentes

- Nunca menos verificación por prisa. El gate mecánico es barato; sáltatelo y pagas en el auditor.
- Todo lo que aprendas que no está en las skills (una firma real, un gotcha de Omarchy) va a la
  skill correspondiente en el mismo PR. La skill es el activo que abarata el siguiente issue.
- Preocupación que no bloquea este issue → `CONCERNS.md` (append-only, solo tú escribes).
