# Changelog

All notable changes to this project will be documented in this file.

## [1.1.16] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_LIGHT_GRAY).

## [1.1.12] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  0% unique at Easy/Medium across every grid size, and only ~13% unique
  even at Hard. Added a uniqueness solver (with proper wall-forcing and
  illumination-forcing constraint propagation) and reworked generation
  to escalate how many black cells reveal their wall number before
  accepting a puzzle. 7×7 and 10×10 puzzles are now unique far more
  reliably; 14×14 is a documented partial improvement (see README).
