# A Little Guy — web edition (GitHub Pages, `kafoosh/psychic-bassoon`)

## Context
A Little Guy is an iOS SwiftUI magic-trick app. A spectator's card is captured covertly: a tap on a hidden 4×4 value grid ruled into a sketchbook page, then a press on one of four disguised "draw" bubbles for the suit. The spectator then draws a stickman. After the performer taps ✓, the drawing auto-rigs, comes to life, performs a routine and reveals the card. The web version reproduces **only the Canvas Grid / playing-card path**. It has:
- no settings, Home Screenshot, Spotlight/word reveal, walkthrough, peek lesson or GlyphStudio
- a **handwriting-looking reveal** using the Gochi Hand font
- a fixed **4-second delay**
- **auto-rig always on**
- a **random routine of all five** on each reveal

It is a static site served from GitHub Pages.

The cloud session only sees `psychic-bassoon`. So before handoff, the Swift source it ports is copied into that repo under `reference/swift/`, together with the project's `CLAUDE.md` as `reference/ARCHITECTURE.md`. Port **one-to-one from that source**: the rig fitter's many passes are the hard-won value, so do not simplify or re-invent them.

## Step 0 — done in the local session before handoff (not by the cloud session)
1. Clone `https://github.com/kafoosh/psychic-bassoon` to a scratch folder.
2. Copy the files below from the local working tree (which includes the latest uncommitted rig work) into `reference/swift/`, keeping their folder layout:
   - `Stickman/`: RigModel, RigFitter, RigPlausibility, RigHarness, RoutineSupport, AnimationRoutine, LittleGuyStage, SketchInk, Routines/{Classic,TopHat,Fishing,Painter,Balloon}Routine
   - `Reveal/RevealContent`
   - `Canvas/`: CanvasScreen, LittleGuyController, LittleGuyChrome, StickerButtons, CanvasStyle
   - `Input/Grid/`: ValueGrid, GridToolbar
   - `App/`: AppState, Models
   - `Support/Color+Hex`
3. Also copy `CLAUDE.md` → `reference/ARCHITECTURE.md` and `Assets.xcassets/LittleGuyIcon.imageset/LittleGuyIcon.png` → `icon.png`.
4. Commit "Add Swift reference source for the web port" and push to the default branch.
5. Start the cloud session on `kafoosh/psychic-bassoon` with this plan as the brief.

## Stack
- Plain HTML + CSS + **vanilla ES modules, no build step**, so Pages serves the repo as is.
- Canvas 2D for the paper, ruling, scatter, drawing and stage. The toolbar is DOM.
- Deploy with `.github/workflows/pages.yml` (`actions/upload-pages-artifact` + `actions/deploy-pages`). The user sets Settings ▸ Pages ▸ Source = GitHub Actions once; put that in the README.
- No frameworks, no analytics, no external requests. The font is self-hosted.

```
index.html  styles.css  manifest.webmanifest  icon.png  fonts/GochiHand-Regular.woff2 (+ OFL.txt)
src/main.js            state machine (AppState + LittleGuyController + CanvasScreen logic)
src/palette.js         LGPalette colours, det()
src/chrome.js          toolbar DOM, sticker bubbles, ribbon + long-press menu, original SVG icons
src/grid.js            value-grid geometry, ruling, value mapping, tap/drag-start capture
src/backdrop.js        flower/sparkle/burst scatter
src/drawing.js         pen input, stroke model, undo stack
src/rig/model.js  rig/fitter.js  rig/plausibility.js
src/anim/support.js  anim/setup.js (RoutineSetup.make + factory)  anim/sketchInk.js  anim/stage.js
src/anim/routines/{classic,topHat,fishing,painter,balloon}.js
src/reveal.js          card face
tests/figures.mjs  tests/rig.test.mjs   (node --test)
reference/…            read-only Swift source (never served from app code)
```

## 1. Page + paper + grid (`grid.js`, `backdrop.js`, `styles.css`)
- **Viewport:** full-viewport, phone-first. Meta `viewport-fit=cover, user-scalable=no`, `touch-action:none`, `overscroll-behavior:none`, `100dvh`, `-webkit-user-select:none`. Use the `env(safe-area-inset-*)` values for insets.
- **Home-screen web app:** include `apple-mobile-web-app-capable` + a manifest (`display: standalone`, `icon.png`) so it can be launched full screen from the Home Screen.
- **Canvas size:** scale by `devicePixelRatio`.
- **Palette:** ink `#1C1B19`, white `#FFFDF8`, orange `#EE7D2B`, purple `#B6A2E8`, yellow `#F4C740`, paper `#FBF6EA`, decor `#EF8326`, decorDeep `#C75A1E`. Light only.
- **Grid rect:** full width. The top is the measured bottom of the toolbar (`getBoundingClientRect`, re-measured on resize). The bottom is the screen height minus the bottom safe inset.
- **Value mapping:** value = `row*4+col+1`, except the whole of row 3 is 13 (King).
- **Ruling** (port `ValueGridBackground`, `ValueGrid.swift:58-107`):
  - Minor lines: pitch = cellW/4, with row pitch snapped so major lines fall on minor lines. `#EF8326` at 7% opacity, 0.5px.
  - Major lines: 3 interior verticals spanning the full height, and horizontals at cellH pitch phase-aligned to the grid top, across the whole screen. `#EF8326` at 8% opacity, 1px.
  - No visual tell for where the grid ends or that the bottom row is King.
- **Backdrop scatter:** port the 9 decorations and the flower/sparkle/burst recipes from `LittleGuyChrome.swift:148-225`.

## 2. Toolbar (`chrome.js`)
- **Button size:** `min(innerWidth, 430)/8.5`; icon = 0.37 × button; hit area ≥ 44px.
- **Sticker surface:** fill, 2px ink border, and a hard solid ink copy offset down-left by 0.1 × size. Never a blur or shadow.
- **Press feel:** on press, shrink the backdrop to 0.25 × offset and slide the face 0.75 × offset into it. Use a CSS transition approximating a spring (~180ms).
- **Idle layout:** 4 round suit bubbles in **CHaSeD** order, with flexible spacing, max width 398, centred. Padding: 16 horizontal, 6 top, 8 bottom, then 10px gap. Below them the yellow **"DRAW A LITTLE GUY"** ribbon: rounded heavy 12px, tracking 0.5, padding 10/6, corner 8, offset 3, rotated −1.5°.
- **Drawing layout:** Undo (purple, left) · Done ✓ (orange, right). The ribbon is hidden with `visibility:hidden` (not removed) so the measured toolbar height doesn't change. The bar swallows touches.
- **Icons:** draw **original inline SVG** look-alikes. SF Symbols may not be copied.

  | Button | Look-alike | Fill |
  |---|---|---|
  | ♣ | paint palette | white |
  | ♥ | eraser outline | white |
  | ♠ | pencil and scribble | white |
  | ♦ | square with pencil | **orange** |
  | Undo | curved back arrow | purple |
  | Done | checkmark | orange |

- **Ribbon menu:** a long-press on the ribbon (~500ms) opens a small sticker-style menu with a single **New Page** item. There are no settings and no Animation submenu.

## 3. Drawing (`drawing.js`)
- **Pointer handling:** pointer events. Only the first pointer draws; ignore multi-touch.
- **Pen:** ink `#1C1B19`, constant width 5px, round caps/joins. Rendered with quadratic-midpoint smoothing.
- **Stroke model:** `{points:[{x,y}], width, color}`. The fitter takes the width directly; this replaces PencilKit's `renderedWidth` raster measurement, because the web pen width is known.
- **Undo** (port `CanvasScreen.swift:292-299`):
  - tap: pop the last stroke
  - long-press 0.5s: clear the page and reset the controller
- **When drawing is live:** only in drawing mode. Otherwise pointer events go to the grid catcher.

## 4. State machine (`main.js`) — port `AppState`, `LittleGuyController`, `CanvasScreen`
- **Grid tap / drag start:** a 1-finger tap, or the touch-down point of a 1-finger drag, on the grid while not drawing → `captureValue`. The last touch before a suit wins. It works while idle, armed, performing or done. Add an optional `navigator.vibrate?.(8)` tick; iOS Safari ignores it.
- **Suit bubble** → `commitCard(suit)`:
  - uses and consumes `capturedValue`
  - with no grid tap first, there is no secret, and ✓ will not arm
  - **auto-fresh:** if the phase isn't idle, clear the page and call `controller.reset()`
  - then enter drawing mode
- **Done ✓:** always return to idle mode. Arm only if all of these hold: it was drawing, a secret exists, there are strokes, and `canArm` (phase idle and not spent). Arming = `.armed` → wait **4000ms** → `.performing` → `comeToLife()`.
- **comeToLife:**
  - `fit(strokes)` (auto-rig always on)
  - `RoutineSetup.make(rig, viewport, topInset = toolbarBottom − safeTop + 10, bottomInset = safeBottom + 10)`
  - routine = random of the five, re-rolled each reveal
  - hide the static strokes and run the stage
- **Finish:** `.done`, `isSpent`, and hold the final frame on a static canvas. Re-arming needs New Page or a suit press (auto-fresh).
- **Secret handling:** memory only. Never persisted, logged, put in the URL, or printed.
- **Souvenir:** skipped. Browsers block clipboard image writes outside a user gesture, so there's nothing to port.

## 5. Rig (`rig/*.js`) — one-to-one port of `RigModel` / `RigFitter` / `RigPlausibility`
- **Coverage:** translate every pass in order and keep the Swift step names as comments: Step 0 sample/densify/dots → 1 raster → 2 runs → 3 head/neck/spineX → 4 crotch → 5 torso width → 5b legs → 6 labels → 7 skin → 7g → leg override → 7a → 7b → 7c → 7e → 7d → 7h → 7f → hip-raise → 8 refineJoints → 8b plausibility → 9 forearm split/confidence/hand parts. Keep the confidence fallback (<0.5 → all-torso). Keep every constant.
- **Types:** `CGPoint` becomes `{x,y}`. `CGRect` becomes a small helper. Colours are plain RGBA.
- **DOM-free:** the rig modules must not touch the DOM, so `node --test` can run them.
- **Model:** port `Rig.worldPoint` two-level FK (`RigModel.swift:132-170`) and `FigurePose`/`FigurePose.rest`.

## 6. Animation (`anim/*.js`)
- **Port:** `RoutineSupport` (easing, `worldJoint`, `worldHand`, `DropLand`, `Approach`), `RoutineSetup.make` (`AnimationRoutine.swift:61-105`, including the chrome-aware floor and capped `propScale`), `SketchInk` (`det`, `sketch`, `sketchPartial`, `rectPts`, `ovalPts`, `star`, `sparkles`, `wand`, `cardFace` with `wipe`), and all five routines.
- **Canvas 2D translation hazards:**
  - SwiftUI `var c = ctx` copies become `save()`/`restore()`.
  - Multiply nested opacities manually.
  - TopHat's rect ∪ ellipse clip needs consistent winding (non-zero).
  - Translate/rotate maps directly.
- **Stage:** a `requestAnimationFrame` loop. Compute the pose once per frame, map each stroke's points through `worldPoint`, stroke them, then `drawProps`. Clamp `t` to `totalDuration`. On finish, stop the loop and draw the final frame once. No timeline may stay alive while idle.

## 7. Handwritten reveal (`reveal.js`)
- **Font:** self-host Gochi Hand (SIL OFL; ship `OFL.txt`). Preload it and `await document.fonts.load('48px "Gochi Hand"')` before the first reveal.
- **Card layout:** port `RevealContent.swift` geometry.
  - Inner rect = card inset 9%/7%.
  - Corner index: value at height h×0.15, centred at (w×0.16, h×0.13); suit below it at y + cornerH×1.05, size ×0.95.
  - Bottom-right index rotated 180° about its corner.
  - Centre pip at height h×0.44.
  - Red suits `rgb(0.85,0.16,0.16)`; black suits use the figure's ink colour.
- **Values:** draw them in Gochi Hand through a port of `drawLooseText`. Each glyph:
  - jx = det(i,seed)·size·0.05
  - jy = det(i,seed+3.3)·size·0.06
  - rot = det(i,seed+7.1)·0.14
  - glyph gap size·0.02, with shrink-to-fit

  Keep the same seeds.
- **Suits:** Gochi Hand probably has no ♣♥♦♠, and a system-font fallback would look typed. So draw the **suit symbols (corner + centre pip) as hand-sketched vector paths**: heart/diamond/spade/club outlines built from points, jittered with `det()` like `sketch`, stroked and filled in the pip colour.

## 8. Tests + verification
- **Rig tests:** `tests/figures.mjs` ports a representative subset of `RigHarness.swift`'s generators:
  - head/torso/arm/leg variants, line + outline forms
  - lowAttach and side legs
  - λ body
  - the hand-built user fixtures with ground truth

  `tests/rig.test.mjs` asserts per-stroke label accuracy against truth, no explosion (run each routine and check the animated bbox stays within the viewport), and no leg stroke partly labelled arm. Run with `node --test`. Gates: the clean subset ≥ 99% figures correct, all fixtures pass, 0 explosions.
- **Demo mode:** `?demo=1` (debug only, not linked anywhere) seeds a synthetic figure and a secret and auto-arms, like CanvasScreen's walkthrough demo. Also `?routine=classic|topHat|…` to force a routine.
- **Browser check:** serve with `python3 -m http.server`. Use headless Chromium/Playwright if the environment has it; otherwise note it was skipped. At 390×844 and 430×932:
  1. tap a cell
  2. press a suit
  3. draw a crude stickman with pointer events
  4. press ✓
  5. wait 4s plus the routine, screenshotting several frames per routine

  Confirm the card shows the right value and suit in the handwritten style and that props stay inside the playfield (below the toolbar, above the bottom inset).
- **Deploy:** push → Actions deploys → `https://kafoosh.github.io/psychic-bassoon/`. Use relative asset paths so the sub-path works.
- **Left for the user on a real iPhone:** touch feel, long-presses, and Safari gestures.

## Conventions
- No real brand names.
- Nothing on screen says "magic".
- `<title>` is "A Little Guy".
- Commit in logical steps on a feature branch and open a PR to the default branch.
