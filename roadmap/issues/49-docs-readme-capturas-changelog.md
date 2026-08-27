title: README con capturas, `docs/architecture.md` y CHANGELOG
labels: type:docs
milestone: M6 — Distribución
---
## Contexto
Cierra M6 hacia la comunidad de Omarchy. Depende de #48.

## Alcance
Entra: README con 4 capturas (sidebar con 2 dispositivos, toast clickeable, attach con split,
widget de barra), instalación (`omarchy pkg aur add kelpie && kelpie setup`), atajos, snippet
Hyprland, preguntas frecuentes (DND, fuente, tema); `docs/architecture.md` (hilos UI/IO/túneles,
flujo de datos herdr → store → UI/status.json → barra, decisiones enlazadas a ADRs);
`CHANGELOG.md` (Keep a Changelog) con 0.1.0.
No entra: sitio web, vídeo.

## Criterios de aceptación
- [ ] Una persona que no conoce el proyecto instala y ve su primer agente siguiendo solo el README (prueba con alguien externo, anotar fricciones).
- [ ] `docs/architecture.md` tiene un diagrama (texto/mermaid) de hilos y procesos, y cada decisión enlaza su ADR.
- [ ] El CHANGELOG lista lo entregado en 0.1.0 por milestone.

## Skills
—
