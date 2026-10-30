# A Little Guy — web edition

A static web version of the A Little Guy drawing trick (the Canvas Grid / playing-card
path only). Live at **https://kafoosh.github.io/psychic-bassoon/**.

## Performing

**Unarmed** (the default), it's an ordinary drawing toy. The page ignores taps, and the
four bubbles are real tools:

| Bubble | Does |
|---|---|
| Palette | opens the colour picker; pick a colour to draw with it |
| Eraser | rubs out lines |
| Pencil | draws |
| Square + pencil | starts a new page ("New canvas created") |

Tap **✓** to put the tools away. Nothing else happens.

**To perform:**

1. **Arm:** hold the page for about 0.65s. The "i" in the bottom-left circle disappears
   while the hold registers and comes back when you let go. That's your confirmation.
2. **Value:** tap the ruled page (or start a drag on it). The page is a hidden 4×4 grid:
   rows `A 2 3 4` / `5 6 7 8` / `9 10 J Q`, and the whole bottom row is `K`. The last
   touch before a suit counts.
3. **Suit:** press a bubble. Left to right they are **C**lubs, **H**earts, **S**pades,
   **D**iamonds. While armed, every bubble opens the colour picker. Hand it over: the
   spectator picks a colour and draws a little guy.
4. The spectator taps **✓**. Four seconds later he comes to life, performs one of five
   random routines and reveals the card.

- One hold arms one reveal. After a reveal the page is unarmed again; hold again for the
  next one. A fresh hold also forgets the previous card.
- If you arm but press a bubble without tapping the page first, ✓ won't perform.
- **Undo:** tap to step back (this also undoes the eraser); hold for half a second to
  clear the page.
- **Long-press the yellow ribbon** to open the menu with **New Page**. Pressing a bubble
  after a reveal also starts a fresh page.
- The drawing and the reveal scale with the window.
- For full-screen use, add it to the Home Screen (Share ▸ Add to Home Screen).

The card is kept in memory only. It is never stored, logged, or put in the URL.

## Development

Plain HTML, CSS and ES modules. There is no build step and nothing is requested from
other sites.

```bash
python3 -m http.server 8000     # then open http://localhost:8000
node --test tests/rig.test.mjs  # rig regression gates
```

Debug-only URL flags (not linked anywhere): `?demo=1` seeds a figure and a random card
and arms automatically; `?routine=classic|topHat|fishing|painter|balloon` forces a routine.

`src/rig/` and `src/anim/` are one-to-one ports of the Swift source in `reference/swift/`.
The step names and constants are kept in the comments. `tests/figures.mjs` ports the
`RigHarness` figure library. The current scores match the Swift baseline:

- clean set: 1897/1900 figures
- proportions set: 92%
- 0 explosions
- every user fixture passes

## Deploying

The first time only, go to **Settings ▸ Pages ▸ Build and deployment ▸ Source** and pick
**GitHub Actions**. After that, every push to `main` runs the tests and then deploys the
app files (not `reference/`) with `.github/workflows/pages.yml`.

## Credits

Gochi Hand by Juan Pablo del Peral, SIL Open Font License 1.1 (`fonts/OFL.txt`).
