title: Gate M2 — el terminal embebido es un terminal usable y el attach reemplaza a Ghostty externo
labels: type:docs
milestone: M2 — Terminal embebido
---
## Contexto
Checklist de cierre de M2. Depende de #21–#27.

## Criterios de aceptación (todos, en la máquina de referencia)
- [ ] `kelpie --demo-shell`: 1 hora de uso con `bash`, `vim` (con colores y `mouse=a`), `htop`, `git log --graph`, `ls --color`, `less`, un `cat` de 50 MB — sin crash (`coredumpctl list kelpie` vacío) y sin fugas visibles (RSS estable ±10 %).
- [ ] Unicode: CJK ancho, emoji con ZWJ, combinantes, glifos Nerd Font — alineación correcta.
- [ ] Ligaduras de JetBrains Mono visibles; `omarchy font set` cambia la fuente en vivo.
- [ ] Redimensionar 20 veces seguidas no corrompe la pantalla (`reset` no es necesario).
- [ ] `omarchy theme set catppuccin` → `gruvbox` → tema original: paleta del terminal en vivo las tres veces.
- [ ] Attach embebido a un agente local y a uno remoto; "Abrir en Ghostty" sigue funcionando.
- [ ] Todo el trabajo del gate anotado en `docs/adr/0001-stack.md` §"Resultado M2" (fps medidos, tamaño del binario, RSS).

## Skills
`zig-libghostty`, `diagnose-crash`.
