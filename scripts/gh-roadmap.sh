#!/usr/bin/env bash
# Materializes roadmap/issues/*.md as GitHub labels + milestones + issues.
# Issue numbers == file order (01-*.md -> #1): bodies say "Depende de #N" on that
# assumption, so this only runs against a repo with ZERO issues/PRs.
set -euo pipefail
repo=${1:?usage: scripts/gh-roadmap.sh owner/repo}
cd "$(dirname "$0")/.."

n=$(gh issue list -R "$repo" --state all --limit 1 --json number --jq length)
[ "$n" = 0 ] || { echo "$repo already has issues; numbering would drift. Abort." >&2; exit 1; }

while IFS='|' read -r name color desc; do
  gh label create "$name" -R "$repo" --color "$color" --description "$desc" --force >/dev/null
done <<'LABELS'
area:vt|1d76db|Máquina de estados VT (libghostty-vt)
area:render|0e8a16|Renderer GL, atlas, filas sucias
area:font|5319e7|fontconfig / FreeType / HarfBuzz
area:pty|006b75|openpty, spawn, resize, hilo de lectura
area:rpc|fbca04|Cliente NDJSON-RPC de herdr
area:ssh|c2e0c6|Túneles y dispositivos remotos
area:ui|d93f0b|GTK4 / libadwaita / sistema de diseño
area:omarchy|b60205|Temas, notificaciones, barra, lanzador
area:pkg|bfdadc|PKGBUILD, CI, distribución
type:spike|e99695|Prueba con criterio binario de éxito
type:feat|a2eeef|Funcionalidad
type:fix|d73a4a|Corrección
type:docs|0075ca|Documentación / ADR
type:chore|cfd3d7|Infraestructura del repo
risk:high|000000|Puede tumbar el plan: hay que desriesgar antes
later|ededed|Fuera del camino crítico de 1.0
LABELS

while IFS='|' read -r title desc; do
  gh api -X POST "repos/$repo/milestones" -f title="$title" -f description="$desc" >/dev/null
done < roadmap/milestones.txt

for f in roadmap/issues/*.md; do
  title=$(sed -n 's/^title: //p' "$f")
  labels=$(sed -n 's/^labels: //p' "$f")
  ms=$(sed -n 's/^milestone: //p' "$f")
  body=$(sed '1,/^---$/d' "$f")
  gh issue create -R "$repo" --title "$title" --body "$body" --label "$labels" ${ms:+--milestone "$ms"} >/dev/null
  echo "created: $title"
done
