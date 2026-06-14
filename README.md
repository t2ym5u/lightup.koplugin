# lightup.koplugin

A Light Up (Akari) plugin for [KOReader](https://github.com/koreader/koreader).


## Screenshot

*(Screenshot to be added.)*

## Rules

Place light bulbs so every white cell is illuminated. Bulbs shine in four directions until blocked. Numbered black cells indicate exactly how many orthogonally adjacent bulbs are required. No two bulbs may illuminate each other.

## Concept

Light Up (Japanese: Akari, "light") is a binary-determination logic puzzle.
Place light bulbs in white cells of a grid so that:

1. Every white cell is illuminated (a bulb lights its entire row and column until
   blocked by a black cell).
2. No two bulbs illuminate each other.
3. Black cells with a digit must have exactly that many bulbs in adjacent cells.

## Features

- **Multiple grid sizes** — 7×7, 10×10, 14×14
- **Three difficulty levels** — Easy, Medium, Hard
- **Cell states** — empty, bulb, lit (yellow tint / hatched on greyscale), dot (confirmed empty)
- **Constraint highlighting** — tap a numbered black cell to highlight its adjacent cells
- **Illumination preview** — shows the lit area of a selected bulb
- **Check** — highlights conflicts (two bulbs seeing each other, wrong adjacency count)
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Place / remove a bulb | Tap a white cell (in bulb mode) |
| Mark a cell as empty (dot) | Long-press or tap in dot mode |
| Toggle bulb / dot mode | Tap the **Mode** button |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |
| Show rules | Tap **Rules** |

## Why e-ink friendly?

Illumination zones are static fill patterns (hatching) that refresh only when
bulbs are placed or removed. No animation is needed between moves.

## License

GPL-3.0
