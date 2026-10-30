# A Little Guy — web edition

A static web version of the A Little Guy drawing trick (the Canvas Grid / playing-card
path only). Live at **https://draw.oddpaq.com/**.

## Performing

**Unarmed** (the default), it's an ordinary drawing toy. The page ignores taps, and the
four bubbles are real tools:

| Bubble | Does |
|---|---|
| Palette | opens the colour picker; pick a colour to draw with it |
| Eraser | rubs out lines |
| Pencil | draws |
| Square + pencil | starts a new page ("New canvas created") |

Tap **✓** or **Back** to put the tools away. Nothing else happens.

**To perform:**

1. **Value + arm:** long-press (about 0.65s) the cell of the card's value. The page is a
   hidden 4×4 grid: rows `A 2 3 4` / `5 6 7 8` / `9 10 J Q`, and the whole bottom row is
   `K`. The "i" in the bottom-left circle disappears while the hold registers and comes back
   when you let go. That's your confirmation. Ordinary taps on the page never change the
   value; another long press replaces it.
2. **Suit:** press a bubble. Left to right they are **C**lubs, **H**earts, **S**pades,
   **D**iamonds. While armed, every bubble opens the colour picker. Hand it over: the
   spectator picks a colour and draws a little guy.
3. The spectator taps **✓**. Four seconds later he comes to life, performs one of five
   random routines and reveals the card. **Back** (the arrow) returns to the main page
   without performing.

- One long press arms one reveal. After a reveal the page is unarmed again.
- A drawing that doesn't read clearly as a little guy (no head, a missing arm or leg, or a
  doubtful fit) still performs and reveals, but moves as one piece instead of bending.
- The props (wand, box, hat, rod, balloon, card) are sized to the drawing.
- Limbs never pull a line apart: where one pen stroke crosses from one body part into
  another, the join is kept at a joint, so nothing stretches out of the body.
- **Long-press the yellow ribbon** to open the menu with **New Page**. Pressing a bubble
  after a reveal also starts a fresh page.
- The drawing and the reveal scale with the window.
- For full-screen use, add it to the Home Screen (Share ▸ Add to Home Screen).

**URL force (no input on the page):** put the card right after the address, for example
`draw.oddpaq.com/7D` for the 7♦ (`draw.oddpaq.com/?=7D` also works). Anything may follow
the card (`/7D90382sd` works the same), so the link doesn't look like a card. Values are
`A 2–10 J Q K` and suits `C H S D`, in either case. The code is wiped from the address bar
before the page appears, so only `draw.oddpaq.com` shows. (The short form works because
the deploy also publishes the app as `404.html`, which GitHub Pages serves for any unknown
path.)

With a URL card loaded, the bubbles stay ordinary tools, and the next ✓ with a drawing
performs that card after the usual delay. After that one reveal, the page is back to the
long-press method. A long press before then replaces the URL card.

The card is kept in memory only. It is never stored or logged, and a URL card is wiped from
the address bar straight away.

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
Web-only additions sit on top: `src/rig/seams.js` (stretch-proof seams), the confidence gate
`rigIsConfident` and figure-sized props in `RoutineSetup`.
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
