# Changelog

All notable changes to this project will be documented in this file.

## [1.1.12] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  0% unique at Easy/Medium across every grid size, and only ~13% unique
  even at Hard. Added a uniqueness solver (with proper wall-forcing and
  illumination-forcing constraint propagation) and reworked generation
  to escalate how many black cells reveal their wall number before
  accepting a puzzle. 7×7 and 10×10 puzzles are now unique far more
  reliably; 14×14 is a documented partial improvement (see README).
