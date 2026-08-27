#!/bin/bash
# Spike E (issue #6) — desriesga el hint omarchy-exec-argv antes de diseñar #18.
# Runbook interactivo: cada escenario pausa para que confirmes lo que ves en pantalla.
# No es parte del paquete kelpie; vive en scripts/ y se puede borrar tras el spike.
set -uo pipefail

confirm() {
  read -r -p "$1 [s/N] " reply
  [[ $reply =~ ^[sS]$ ]]
}

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; }

echo "=== Spike E — toast de Omarchy con --exec clickeable ==="
echo

# --- Escenario 1: argv literal, sin expansión ni re-tokenización -----------
# -u critical: Service.qml:99-102 durationFor() -> 0 (no expira) SOLO en
# Critical; en normal expira a los 8s (normalPopupDuration) y el click nunca
# llega a tiempo del prompt. Aserción automática vía invokeLast (Service.qml:904,
# el mismo invokePopupDefault que onCardClicked en :1056) además del ojo humano.
echo "--- Escenario 1: argv literal al hacer click ---"
argv_file=$(mktemp)
rm -f "$argv_file"
omarchy notification send --app-name kelpie -u critical -p \
  "spike-e argv" "click para volcar el argv" \
  --exec bash -c 'printf "%s\n" "$@" > "$0"' "$argv_file" "arg con espacios" '$(id)'
echo "Toast enviada (urgencia critical, no expira sola)."
sleep 1
omarchy-shell notifications invokeLast >/dev/null
if [[ ! -s $argv_file ]]; then
  echo "Click automático no disparó el archivo; haz click a mano en la toast."
fi
if confirm "¿El archivo $argv_file existe con contenido (por el click automático o el tuyo)?"; then
  if [[ -s $argv_file ]]; then
    echo "  Contenido capturado:"
    sed 's/^/    /' "$argv_file"
    if grep -qFx 'arg con espacios' "$argv_file" && grep -qFx '$(id)' "$argv_file"; then
      pass "argv literal: espacios preservados como un solo argumento, \$(id) sin expandir"
    else
      fail "el contenido no coincide con lo esperado — revisa arriba"
    fi
  else
    fail "el archivo no tiene contenido — el --exec no se ejecutó o el argv se perdió"
  fi
else
  fail "no se pudo confirmar el click"
fi
echo

# --- Escenario 2: -p imprime id numérico; -r reemplaza sin apilar ----------
echo "--- Escenario 2: -p / -r (reemplazo, no apilado) ---"
id1=$(omarchy notification send --app-name kelpie -p "spike-e replace" "toast 1 de 2")
echo "  id devuelto por -p: '$id1'"
if [[ $id1 =~ ^[0-9]+$ ]]; then
  pass "-p imprimió un id numérico"
  sleep 1
  omarchy notification send --app-name kelpie -r "$id1" "spike-e replace" "toast 2 de 2 (reemplazo)"
  if confirm "¿Ves UNA sola toast 'spike-e replace' (la segunda reemplazó a la primera, no se apilaron)?"; then
    pass "-r reemplazó en vez de apilar"
  else
    fail "se apilaron dos toasts en vez de reemplazar"
  fi
else
  fail "-p no devolvió un id numérico"
fi
echo

# --- Escenario 3: dismiss retira la toast visible ---------------------------
# omarchy-notification-dismiss llama "omarchy-shell -q notifications dismiss":
# la -q es quiet y nunca imprime, aunque el método dismiss() en Service.qml
# devuelva "ok" internamente. Verificar solo que la toast desaparece, no la
# salida del comando (el criterio de aceptación del issue está mal escrito
# en ese punto; corrección anotada en el issue).
echo "--- Escenario 3: dismiss ---"
omarchy notification send --app-name kelpie "spike-e dismiss-me" "debería desaparecer"
sleep 1
omarchy notification dismiss "spike-e dismiss-me"
if confirm "¿La toast 'spike-e dismiss-me' desapareció?"; then
  pass "dismiss retiró la toast (la salida del comando es intencionalmente silenciosa: -q)"
else
  fail "la toast sigue visible"
fi
echo

# --- Escenario 4: kelpie respeta DND; app-name por defecto lo salta --------
echo "--- Escenario 4: no-molestar (DND) ---"
dnd_original=$(omarchy-shell notifications isDnd)
echo "  estado original de DND: $dnd_original"
trap 'omarchy-shell notifications setDnd "$dnd_original" >/dev/null 2>&1' EXIT
omarchy-shell notifications setDnd true >/dev/null
omarchy notification send --app-name kelpie "spike-e dnd kelpie" "NO debería aparecer"
sleep 1
kelpie_bypassed=N
confirm "¿Apareció la toast 'spike-e dnd kelpie' (con --app-name kelpie) estando DND activo?" && kelpie_bypassed=S
omarchy notification send --app-name omarchy-action "spike-e dnd default" "SÍ debería aparecer"
sleep 1
default_shown=N
confirm "¿Apareció la toast 'spike-e dnd default' (--app-name omarchy-action) estando DND activo?" && default_shown=S
# Restaura el estado original de DND, sin importar el resultado del escenario.
omarchy-shell notifications setDnd "$dnd_original" >/dev/null
echo "  DND restaurado a: $(omarchy-shell notifications isDnd)"
if [[ $kelpie_bypassed == N && $default_shown == S ]]; then
  pass "kelpie respeta DND; omarchy-action (default) lo salta — decisión: usar --app-name kelpie"
else
  fail "el comportamiento de DND no coincidió con lo esperado (kelpie_bypassed=$kelpie_bypassed default_shown=$default_shown)"
fi
echo

# --- Escenario 5: glifo y urgencia se distinguen visualmente ---------------
echo "--- Escenario 5: glifo y urgencia ---"
glyph=$'\U000f088c'
omarchy notification send --app-name kelpie -g "$glyph" -u critical "spike-e urgency" "critical"
sleep 1
omarchy notification send --app-name kelpie -g "$glyph" -u normal "spike-e urgency" "normal"
if confirm "¿Se ve el glifo Nerd Font en las toasts, y 'critical' vs 'normal' se distinguen visualmente?"; then
  pass "glifo visible; critical y normal se distinguen"
else
  fail "glifo ausente o critical/normal no se distinguen"
fi
# La toast critical no expira sola (Service.qml:99-102) — descártala explícito.
omarchy-shell notifications dismiss "spike-e urgency" >/dev/null
echo

# --- Escenario 6: la toast sigue clickeable tras omarchy restart shell -----
echo "--- Escenario 6: persistencia tras restart del shell ---"
restart_file=$(mktemp)
rm -f "$restart_file"
omarchy notification send --app-name kelpie -u critical -p \
  "spike-e restart" "sobrevive un restart del shell" \
  --exec bash -c 'printf "%s\n" "$@" > "$0"' "$restart_file" "post-restart"
echo "Toast enviada. NO hagas click todavía."
read -r -p "Presiona enter para correr 'omarchy restart shell'..." _
omarchy restart shell
echo "Shell reiniciado. Espera a que vuelva a aparecer la barra y la toast."
sleep 3
if confirm "¿La toast 'spike-e restart' sigue visible después del restart?"; then
  omarchy-shell notifications invokeLast >/dev/null
  if [[ ! -s $restart_file ]]; then
    echo "Click automático no disparó el archivo; haz click a mano en la toast."
  fi
  if confirm "¿$restart_file existe con contenido (por el click automático o el tuyo)?"; then
    if [[ -s $restart_file ]]; then
      pass "el argv persistido siguió siendo clickeable tras el restart (acción = dato, no callback)"
    else
      fail "el archivo está vacío tras el click post-restart"
    fi
  else
    fail "no se pudo confirmar el click post-restart"
  fi
else
  fail "la toast no sobrevivió al restart — hallazgo del spike, no un bug del script"
fi

rm -f "$argv_file" "$restart_file"
echo
echo "=== Fin del spike. Anota los resultados (PASS/FAIL de arriba) en el issue #6. ==="
