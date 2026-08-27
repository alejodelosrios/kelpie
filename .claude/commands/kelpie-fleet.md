---
description: Supervisa varios /kelpie-flow en paralelo (uno por issue) en worktrees y panes de Herdr. Segunda puerta para ≥2 issues.
---

# /kelpie-fleet — orquestador multi-issue

Eres el **orquestador**. No escribes código ni procesas issues tú mismo: lanzas un hijo
`/kelpie-flow` por issue, cada uno en su worktree y su pane de Herdr, y los coordinas por blackboard
(git + GitHub + este pane). **Los hijos nunca hablan entre sí.**

Argumento: `$ARGUMENTS` — números de issue.

---

## FASE 0 — Admisión (dónde se gana o se pierde el paralelismo)

1. Con 1 solo issue → corre `/kelpie-flow <N>` aquí mismo, sin worktree. No montes un fleet para uno.
2. Lee cada issue (`gh issue view`) y extrae **dominio** (de los labels `area:*`) y **dependencias**
   (la línea "Depende de #N" del cuerpo — tus issues la traen).
3. **Regla de admisión, derivada, no escrita a mano:** dos issues corren en paralelo si y solo si
   ninguno está en el `depende_de` del otro **y** no comparten territorio de builder.
   - `area:vt|render|pty|rpc|ssh|font` → territorio **core**
   - `area:ui|omarchy|pkg` → territorio **ui**
   - Mismo territorio sin dependencia: **pueden correr en paralelo, con rebase obligatorio sobre
     `develop` antes del PR** (el ruleset de GitHub lo exige de todas formas).
4. **Hotspots de kelpie** (archivos que casi todo issue toca, aunque los dominios sean disjuntos):
   `build.zig`, `src/main.zig`, `src/app.zig`. Se manejan por **lease, no por bloqueo**: si dos
   hijos van a tocar el mismo hotspot, se lo das a uno y el otro espera a la siguiente ola, o lo
   editas tú en el pane principal. Anótalo al planear la ola.
5. Imprime el **plan de olas** (qué corre junto, qué espera y por qué) y **DETENTE** hasta que el
   humano lo apruebe. Si el conjunto no puede correr junto, dilo con nombre y apellido: no lo
   serialices en silencio ni lo lances en paralelo esperando suerte.

Ola típica de M0: los spikes #2–#6 son independientes y con criterio binario — la ola perfecta.
Ojo con #3 (renderer) y #6 (toast): sus gates **abren ventana en tu sesión Wayland**; los hijos
compilan y miden en paralelo, pero la verificación visual se serializa contigo.

## FASE 1 — Worktrees

Uno por issue, desde `develop`:

```sh
git fetch origin develop
git worktree add ../kelpie-<N> -b <prefijo>/<N>-<slug> origin/develop
```

- `.claude/` va **versionado**, así que el worktree nace con comandos, agentes y skills. No hay
  symlinks que mantener.
- Zig no necesita provisión: `.zig-cache/` y `zig-out/` se regeneran, y las deps van al cache global.
  Un `zig build` inicial en cada worktree calienta el cache y confirma que el árbol está sano.

## FASE 2 — Lanzar los hijos (verifica que arrancaron)

Un pane de Herdr por worktree. Tres trampas verificadas en la Ola 1 de M0; las tres dejan un pane
que parece vivo y no hace nada:

1. **Un pane con `agent_status: unknown` no es un pane libre.** Puede tener lazygit, vim o un pager
   abierto: `pane run` entra como **teclas dentro de esa TUI**, no como comando. Comprueba antes con
   `herdr pane process-info '<pane>'`; si no es una shell, **no lo reutilices** — abre uno nuevo, que
   además nace con el cwd correcto:

   ```sh
   herdr pane split '<pane-vecino>' --direction right --cwd "$PWD/../kelpie-<N>"
   ```

2. **`pane run` escribe el texto pero no lo envía dentro de Claude.** Lanzar el binario funciona
   (la shell sí ejecuta), pero el slash-command se queda tipeado en el prompt. Remata siempre con
   `send-keys Enter`:

   ```sh
   herdr pane run '<pane>' 'claude --model sonnet'      # la shell lo ejecuta
   herdr pane read '<pane>'                             # confirma que hay prompt de Claude
   herdr pane run '<pane>' '/kelpie-flow <N>'
   herdr pane send-keys '<pane>' Enter                  # sin esto el hijo nunca arranca
   ```

3. **Nunca fire-and-forget:** tras el Enter, `herdr pane read` y confirma spinner o FASE 1 en
   pantalla. Un `%` de contexto que no crece es un hijo que no arrancó.

Los hijos corren con **Sonnet** (los issues vienen enriquecidos: ejecutan una spec acotada, no
diseñan en abierto). Si un issue resulta genuinamente ambiguo, súbelo a Opus tú.

## FASE 3 — Vigilancia (el trabajo real del orquestador)

**El listener se ARMA, no se recuerda.** Vigilar "a ojo" falla siempre: los hijos llegan al primer
gate en ~2 min y quedan ahí callados hasta que alguien mira. En cuanto los panes estén corriendo,
arma un `Monitor` persistente sobre `agent_status` — `working` es silencio, cualquier otra cosa es
un evento que te llega al chat:

```
prev=""
while true; do
  cur=$(herdr pane list 2>/dev/null | jq -r '.result.panes[]
    | select(.pane_id=="<pane-A>" or .pane_id=="<pane-B>")
    | "\(.pane_id) \(.agent_status)"' | sort || true)
  if [ -n "$cur" ]; then
    comm -13 <(echo "$prev") <(echo "$cur") 2>/dev/null | grep -v ' working$' || true
    prev="$cur"
  fi
  sleep 20
done
```

Cubre los tres finales, no solo el feliz: `idle` (te espera), `blocked`/`done` y `unknown` (el hijo
murió). Si solo vigilaras el merge, un hijo caído se ve idéntico a un hijo pensando.

**El primer gate que te llega es el scope gate, y lo apruebas TÚ**, no el humano: contrástalo contra
el issue (archivos declarados dentro de su territorio, nada de scope extra) y sigue. Al humano solo
le suben los gates de diseño, los spikes que fallan su criterio binario y los merges.

Un hijo puede quedarse atorado en cualquier fase esperando una respuesta tuya. Distingue:

- **esperando a un subagente** (QA, auditor corriendo) = **activo**, no lo toques;
- **esperándote a TI** (scope gate, gate de diseño, menú, pregunta) = **idle bloqueado**, atiéndelo ya.

Lo que apruebas tú, contra el issue enriquecido y su diseño:
- **scope gates** de los hijos,
- **gates de diseño** (la spec + Gherkin) — esta es la aprobación que más te va a llegar,
- decisiones de fallback a Claude cuando MiMo falló dos veces.

Lo que escalas al humano: contradicciones entre el issue y el código, un spike que **falla su
criterio binario** (ADR-0001: se para y se informa, no se improvisa un workaround), un auditor que
DENIEGA dos veces, y **todo merge**.

**Vigila también el avance de `develop`**: si mergeas un PR, los demás hijos quedan desactualizados
y el ruleset les exigirá rebase. Avísales en cuanto pase; no esperes a que su PR rebote.

**No mates a un hijo por reloj.** Un QA visual riguroso tarda. Mata por **falta de progreso**: sin
cambios en su diff ni en su pane durante varios ciclos, no por minutos transcurridos.

## FASE 4 — Cierre (nadie más lo hace)

Por cada hijo que mergeó su PR:

```sh
git worktree remove ../kelpie-<N>
git branch -d <prefijo>/<N>-<slug>
gh issue close <N>
```

Al final: `git worktree list` y `gh issue list --state open` para confirmar que no quedaron
worktrees huérfanos ni issues abiertos de trabajo ya mergeado. Un fleet sin cierre deja basura que
el siguiente fleet hereda.

Resume al humano: qué mergeó, qué quedó pendiente y por qué, qué entró en `CONCERNS.md`, y qué
aprendiste que ya está en las skills.
