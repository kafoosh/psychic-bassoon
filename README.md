# A Little Guy — web edition

A static web version of the A Little Guy drawing trick (the Canvas Grid / playing-card
path only). Live at **https://kafoosh.github.io/psychic-bassoon/**.

## Performing

1. **Value:** tap the ruled page (or start a drag on it). The page is a hidden 4×4 grid:
   rows `A 2 3 4` / `5 6 7 8` / `9 10 J Q`, and the whole bottom row is `K`. The last
   touch before a suit counts.
2. **Suit:** press one of the four bubbles — left to right **C**lubs, **H**earts,
   **S**pades, **D**iamonds. This opens the pen.
3. The spectator draws a little guy. Tap **✓**. Four seconds later he comes to life,
   performs one of five random routines and reveals the card.

- If you press a bubble without tapping the page first, ✓ just closes the pen.
- **Undo:** tap to remove the last stroke; hold for half a second to clear the page.
- **Long-press the yellow ribbon** to open the menu with **New Page**. Pressing a bubble
  after a reveal also starts a fresh page.
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
