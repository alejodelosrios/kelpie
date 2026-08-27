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
