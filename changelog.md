# Changelog

All notable changes to Reckon are listed here. Newest first.

## 0.8.0

- Header quick-toggle buttons: DMG/HEAL (metric), PLY/GRP (per-player vs group), and < > to page through past fights - no chat commands needed.
- Fight history: each finished fight is saved (last 15). Page back with the < > buttons (or /reckon history and /reckon live). Damage/Healing and your ability drill-down all work on stored fights; history reflects the display mode used at the time.
- Trash handling: the group estimate now only appears when a boss was present. On trash (no boss), the unreliable estimate bar is hidden and the footer drops the "~".
- Cleaner header: removed the "(est)" tag from the title; the estimate is now signalled by the "~" on the footer total instead.
- Diagnostics: /reckon status is now /reckon dev (still works either way) and is no longer listed in the public command help.

## 0.7.0

- Visuals reworked closer to Details!: ESO class-coloured bars, real character names (your own name instead of "You"), bigger fonts, taller rows, and a faint highlight on your own row.
- Added a settings cog in the header that opens the options panel (also `/reckon settings`).
- Bundled LibAddonMenu-2.0 inside the addon, so the settings GUI works on install with no extra download. The combat libraries stay external (install via Minion for per-player).

## 0.6.0

- Healing / HPS mode: toggle with `/reckon heal` (or the Metric setting). Shows your HPS plus effective HPS for any group member sharing via LibGroupCombatStats; clicking your bar drills into your healing abilities.
- Healing has no "Unknown" estimate (ESO can't derive group healing from target health), so heal mode shows you plus measured healers only.
- The status line now reports each member's hps too.
- Note: heal bars use the library's effective HPS (overheal excluded); the heal drill-down lists your healing per ability including overheal.

## 0.5.0

- Row drill-down: click your bar to expand into your per-ability breakdown (damage, DPS and percent per ability), normalized like the main view. Click again or right-click to go back. Also `/reckon abilities`.
- Other players can't be drilled (ESO doesn't share their per-ability data); clicking their bar says so once.
- Note: rows are now clickable, so drag the window by its title bar.

## 0.4.0

- Visual rework in the style of Details!: dark header and footer strips, class-distinct bars normalized to the top performer, rank numbers, name on the left and value + percent-of-total on the right, a subtle gloss on each bar, and shadowed text.
- Each player keeps a stable colour for the whole session.
- Header shows the current mode; footer shows the estimated group total and fight time.

## 0.3.0

- `/reckon status` diagnostic: reports whether LibGroupCombatStats is loaded, whether sharing is on, and exactly which group members the library can see.
- Configurable reset delay (`/reckon resetdelay <s>`, default 6s): re-entering combat within the gap continues the same parse instead of wiping it, so the bar stays readable between quick pulls.
- More tolerant per-player detection: a groupmate now shows as soon as the library has any DPS for them, regardless of how it labels the data type.

## 0.2.0

- Per-player DPS via LibGroupCombatStats (reads Hodor Reflexes and any compatible addon).
- `Unknown ~` estimate for non-sharers, derived from the target's health drain.
- Toggle between per-player and group-estimate views (`/reckon mode`).
- Self-calibration of shared DPS units against your own known DPS.
- Opt-out of sharing your own DPS (`/reckon share`).

## 0.1.0

- Initial release: live personal DPS, estimated group total, and your share %.
- Draggable bar window with an optional end-of-fight chat summary.
- LibAddonMenu-2.0 settings panel (optional) plus slash commands.
