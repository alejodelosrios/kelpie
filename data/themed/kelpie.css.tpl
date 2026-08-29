/* kelpie.css.tpl — Omarchy theme template for kelpie
 *
 * This file is processed by `omarchy-theme-set-templates` via sed.
 * Tokens: {{ token }} → hex value. Content transcribed verbatim from issue #14.
 *
 * Blocks:
 *   a) libadwaita :root overrides (headerbar, sidebar, accent, etc.)
 *   b) kelpie semantic tokens (--status-*, --text-*, --device-tint-*, …)
 *   c) terminal palette --term0..15 + --term-*
 */

/* ── a) libadwaita :root overrides ────────────────────────────────── */
:root {
  --accent-bg-color: {{ accent }};
  --accent-color: {{ accent }};
  --window-bg-color: {{ background }};
  --window-fg-color: {{ foreground }};
  --view-bg-color: {{ dark_background }};
  --view-fg-color: {{ foreground }};
  --headerbar-bg-color: {{ lighter_background }};
  --sidebar-bg-color: {{ background }};
  --card-bg-color: {{ lighter_background }};
  --popover-bg-color: {{ lighter_background }};
  --dialog-bg-color: {{ lighter_background }};
  --success-color: {{ green }};
  --warning-color: {{ yellow }};
  --error-color: {{ red }};
}

/* ── b) kelpie semantic tokens ────────────────────────────────────── */
:root {
  --status-working: {{ blue }};
  --status-blocked: {{ yellow }};
  --status-done: {{ green }};
  --status-danger: {{ red }};
  --text-1: {{ bright_foreground }};
  --text-2: {{ foreground }};
  --text-3: {{ dark_foreground }};
  --text-ghost: {{ muted }};
  --hairline: alpha({{ foreground }}, .07);
  --item-wash: alpha({{ foreground }}, .06);
  --item-wash-selected: alpha({{ foreground }}, .07);
  --accent-wash: alpha({{ accent }}, .13);
  --status-bar-bg: {{ lighter_background }};
  --mode: {{ mode }};
  --device-tint-0: {{ magenta }};
  --device-tint-1: {{ cyan }};
  --device-tint-2: {{ purple }};
  --device-tint-3: {{ brown }};
  --device-tint-4: {{ bright_cyan }};
}

/* ── c) terminal palette --term0..15 ──────────────────────────────── */
:root {
  --term0: {{ background }};
  --term1: {{ red }};
  --term2: {{ green }};
  --term3: {{ yellow }};
  --term4: {{ blue }};
  --term5: {{ magenta }};
  --term6: {{ cyan }};
  --term7: {{ foreground }};
  --term8: {{ muted }};
  --term9: {{ bright_red }};
  --term10: {{ bright_green }};
  --term11: {{ bright_yellow }};
  --term12: {{ bright_blue }};
  --term13: {{ bright_magenta }};
  --term14: {{ bright_cyan }};
  --term15: {{ bright_foreground }};
  --term-bg: {{ dark_background }};
  --term-fg: {{ foreground }};
  --term-cursor: {{ bright_foreground }};
  --term-selection-bg: {{ selection_background }};
  --term-selection-fg: {{ selection_foreground }};
}
