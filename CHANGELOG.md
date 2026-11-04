# Changelog

All notable changes to this project will be documented in this file.

## [1.5.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.5.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.0] - 2026-11-04

### Changed
- Every puzzle now has exactly one solution. Easy grids were often
  ambiguous even with every wall numbered (10×10 Easy about 4 times in 5,
  14×14 Easy nearly always); such a grid now gets a few extra numbered
  walls where the other solutions differ (Easy grids have about 2-3% more
  black cells than before). Puzzles are new.
- Much faster: 10×10 Easy took up to 6 s on a desktop (minutes on a Kobo),
  now under 0.02 s; every size and difficulty stays under 0.02 s (about
  0.5 s on a Kobo).
- Opening the game no longer builds a puzzle it then throws away (it was
  generated even when a saved game was about to be restored).
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Added
- "New game" once the puzzle is solved (or revealed): the action bar shows
  it in place of Undo, Check, Hint and Reveal, so the next puzzle no longer
  needs the menu.

### Changed
- Redesigned play screen, in line with the other games: a full-width action
  bar, a larger board that fills the available room, and one frame around
  it. The status line reads "size · difficulty · Lit: n/m · Bulbs: n" and
  wraps in landscape instead of being cut off; the tap/hold help moved from
  the status line to the rules.
- Title-bar menu shows the current values: "Size: …" and "Difficulty: …"
  instead of bare values.
- The dot marking a cell that can't hold a bulb is a painted disc, easier to
  see than the tiny "·" glyph it replaces.
- New README screenshot.

### Fixed
- Using Hint wiped the saved game: the board was saved as nothing. And when
  a hint fills the last cell, the status now shows the win message.
- Clue digits outgrew their cells on high-DPI screens.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

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
