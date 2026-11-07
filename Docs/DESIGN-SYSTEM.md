# AirPointer design system

The reference for anything a person sees or reads in AirPointer: screens, images, copy and the logo. If a change doesn't follow this file, change the file first and say why.

---

## 1. Principles

1. **One obvious next step.** Every state has exactly one primary (ink) button. Everything else is secondary, tertiary, or a menu item.
2. **The case is the interface.** Show the physical object and what to do with it, rather than describing sensors. A picture of the case beats a paragraph.
3. **Calm until live.** The UI is grayscale. Red (`laser`) appears only when something is live: the pointer dot, the "Pointing" chip, the menu-bar dot.
4. **Plain words.** No yaw, pitch, IMU, MTIC, model IDs or confidence scores. Say what happened and what to do next.
5. **Explain every stop.** If pointing pauses, say why and how to continue ("Paused — your AirPods disconnected. Open the case to reconnect.").
6. **Sensor-product setup.** Borrow from AirPods pairing and Face ID: a few full-attention steps, automatic capture where possible (hold still to set a calibration dot), and a clear "done".
7. **Don't hide the escape hatch.** The pointer shortcut (fn ⌃ unless changed in Settings) works from any app, and Esc backs out of overlays.

## 2. How the case is used (canonical)

Every image, animation and instruction must match this. Nothing else.

| Step | What the person does | What we show |
|---|---|---|
| Start | Holds the closed case in front of them, both AirPods inside, and clicks Connect. Then opens the lid. | Front view, lid closed. After Connect, the lid opening (the close loop in reverse) until the AirPods connect. |
| Connect | Holds the case sideways in front of them, lid **open**, both AirPods inside. | Front view: the lid opens once, then stays open with the earbuds visible. The case never spins. |
| Close | Closes the lid. The status light turns green. | Same view, lid closed, green light. |
| Turn | Turns the closed case a quarter turn **clockwise**, so it stands upright with the lid edge on the right. | The closed case rotating 90° clockwise in place. |
| Point | Aims the upright closed case at the screen. | The upright closed case (the logo pose). |
| Click | Taps the **front** of the upright closed case: one tap left-clicks, with one short click sound from the Mac. | The upright closed case, with "Tap its front to click." |

Never show or describe tapping the back of the case, holding the open case upright, or "keep the lid open", except in the Connect step.

**How the case is held (`PointingPlane`).** The closed case is the only pointer, from its motion and taps alone. People can choose how they use it in Setup (Step 2: **How to point**) or in Settings ▸ **How to point**:
- **Upright (`upright`, default):** Turn the closed case upright and aim at the screen.
- **Flat swivel (`flatSwivel`):** Keep the closed case flat on a surface; swivel left/right and tilt forward/back to aim at the three calibration dots.
- **Flat tilt (`flatTilt`):** Keep the closed case flat and rock it left/right and forward/back like a joystick; uses gravity directly after aiming at the three calibration dots.

A single tap on the case left-clicks whenever the pointer is pointing; there is no double click and no setting for tapping itself, and Pause or fn ⌃ stops tapping along with the cursor. There are no swipes. Never mention the microphone in the product. The only sounds are the tap’s click and the notch’s shimmer (below).

## 3. Surfaces

| Surface | Purpose | Size |
|---|---|---|
| Setup assistant | First run: Allow → Style → Connect → Calibrate → Tap. Permission comes first because the mouse is out of reach once the case is in hand; Style lets the person pick Upright, Flat swivel, or Flat tilt; from Connect onward each finished step leads to the next by itself, and the dots start on their own. Tap is the last step: it starts listening by itself, fills three dots as the person taps the case, and can be skipped; once learned, its primary is Finish, with the fn ⌃ footer. Settings reaches the same step with Teach Tap…. One step per screen, a step indicator on top, a primary button bottom-right (Return). Connect walks through Connect → open the lid → Lid Closed (Return) → turn upright (if Upright) → "You’re connected", with the matching `CaseStepView`. Before the first press, Connect says what a session does to the AirPods and the case, and a problem shows above that note instead of replacing it. Until that first press, fn ⌃ and every other way to connect open this step instead. Finish and Skip for Now wait for Accessibility: without it, they go back to Allow. Setup always connects the closed case; the dots wait for the Calibrate step. | 560 × 620 window |
| Calibration overlay | Full-screen dark overlay. Three dots: center, right edge, top edge. Each captures when the person holds still on it. Esc cancels. With saved edges it is one dot ("AirPointer · Recentering", no step row); if the case is held differently from last time, it carries on to the two edges. | Full screen of the controlled display |
| Main window ("Remote") | Two pages, **Pointer** and **Settings**, and no section tabs: the toolbar is only the gear. Settings opens with a "‹ Pointer" back button; esc and ⌘1 also go back. Pages scroll; a notice bar sits above them. | 440 × 700, min 400 × 620, max width 560 |
| Menu-bar popover | Live aim pad, Recenter, Pause, speed, then menu rows: Open AirPointer, Calibrate…, Disconnect (only while the closed case is connected), Settings…, Quit. | 320 wide |
| Control HUD | A small non-activating capsule: "Pointing", "Paused — reason", "Disconnected — connect again, then open the lid", "Pointer stopped — allow AirPointer in Accessibility". | 40 tall, ≤ 480 wide |
| Sheets | Attached to the main window, for a task that starts there. None are in use. | ≈ 420 wide |
| Developer tools | Keep audio on Mac and the tap test window. Under **File ▸ Developer** only; never linked from the main flows. The test window uses the same parts as the product: a DEVELOPER eyebrow and status chip, a 22 pt title, one primary bottom-right. | 480 × 440 |

A flow should never open a second regular window to finish a task that started in the main window. Use the overlay, a sheet, or the page itself.

### Pointer page: state → content

| State | Title | Primary button (key hint) | Secondary |
|---|---|---|---|
| Needs Accessibility | Allow control | Allow | n/a |
| Needs AirPods | Connect your AirPods | Connect AirPods | n/a |
| Waiting for the lid | Open the lid (AirPointer connects when it sees the lid open; skipped when the AirPods are already connected) | Cancel (esc) | n/a |
| Connecting | Looking for your AirPods… | Cancel (esc) | n/a |
| Lid open, connected | Close the lid | Lid Closed (Return); closing the lid also moves on by itself | n/a |
| Lid closed, no saved sensor offset | Set it down (only when no offset was measured in the last week; 1.2 s of stillness, shown as a green ring around the case that empties on movement; a very steady hand also passes) | Cancel (esc) | n/a |
| Lid closed, offset known | Turn it upright (moves on a quarter second after the case has tilted 35° from where the lid closed or where it was set down; no holding still) | Cancel (esc) | n/a |
| Upright, not calibrated | Point at the dots (the overlay opens on its own) | Start Calibration | Disconnect |
| Upright, edges saved | Settles for 0.4 s, then pointing starts; the dot only if Recenter is pressed | Recenter | Recalibrate… · Disconnect |
| Ready | Ready to point | Start Pointing (fn ⌃) | Recalibrate… · Disconnect |
| Centering | Hold still · 3 | Cancel (esc) | n/a |
| Pointing | Pointing | Pause (fn ⌃) | Recenter · Recalibrate… · Disconnect |
| Paused | Paused, with the reason as subtitle | Resume (fn ⌃) | Recenter · Recalibrate… · Disconnect |

Until the closed case is upright and held, the stage shows the step to do with it (`CaseStepView`: closed, opening, open, close, turn). After that it shows the live aim pad.

**Pause never drops the connection.** Pause, fn ⌃, closing the window, opening Settings and display changes only stop the pointer (`ClosedCaseSession.pause`), and Resume continues at once. **Disconnect** is the one way to end it on purpose: a tertiary button on the Pointer page, a row in the popover and an item in the File menu, shown only while the closed case is connected. Quitting also disconnects. Cancel (esc) before the case is upright ends the attempt. Allow only ever opens the Accessibility list: losing Accessibility mid-session stops the pointer but keeps the connection.

When a connection drops on its own, the page goes back to "Connect your AirPods", the notice bar says why and what to do, and the HUD shows "Disconnected — connect again, then open the lid". Disconnecting on purpose shows no notice.

**Motion drops keep the calibration.** Under two seconds without motion, the pointer just freezes and carries on. Longer, it pauses ("Lost the case’s motion. Pointing resumes when it’s back."), keeps the saved edges and asks for the center again (one dot); pointing then comes back without a click. A pause the person chose never resumes on its own.

**Every failure to connect names its cause and what to do:** no Bluetooth access (opens Privacy & Security ▸ Bluetooth), Bluetooth off, no AirPods Pro paired, more than one pair (opens Settings to choose), not paired any more, the AirPods didn't answer, or they're also connected to an iPhone and send no motion. No message tells the person to rebuild the app. Setup says it on its Connect step and a session from the notch says it there; any other session opens the window to say it, even if it was closed.

### Connecting from the notch

fn ⌃ from any app drops the connect steps out of the notch (`NotchFlow.swift`), so nobody has to open the window. The panel hangs from the camera housing: a neck the notch's width, 7 pt concave fillets where it meets the menu bar's bottom edge, 20 pt outer top corners and 22 pt bottom corners, pure black fading to #1C1C1C. The case art sits in the middle, playing the same `CaseStepView` steps as the window (lid opening, closing, the quarter turn, upright); three progress bars (open, close, turn) sit under it, then the title and one line, all centered. It opens in about 0.3 s with a slight rebound and closes in about 0.26 s (the step first, then the shape); with Reduce Motion it appears and goes at once. It never takes focus or clicks. Each time it drops down it plays one shimmer (`Assets/NotchShimmer.wav`), on the Mac's output, never on a step change.

There's no Start Pointing at the end, from the notch or the window: with saved edges the pose the upright case settles in (within 2.5° for 0.4 s) is the center, and the cursor starts, even if it's held another way (Recalibrate fixes the aim then). Only the first time do the dots take over, and the notch tucks away. "Pointing" and "Paused" show for under two seconds, then the notch closes; a connection that drops on its own says why, in up to four lines, for at least four seconds and longer for a longer message. fn ⌃ cancels while connecting and pauses or resumes once pointing. The notch replaces the HUD on its own screen.

### Sound stays on the Mac

While the pointer is in use, from Connect until the session ends, Mac sound and mic stay off AirPods (`AudioOutputGuard`). A mic opening on them would put them in a hands-free call and stop motion, and sound shouldn't move to AirPods that are in their case. When the session ends, whatever it moved goes back unless someone has chosen another device since. The moves are saved, so after a force quit or crash they go back the next time the app opens, under the same rule, as long as the device is still connected. With no session, AirPointer leaves audio alone, even with the app open.

### The pointer shortcut

One shortcut does it all from any app: connect, cancel, pause and resume (`PointerShortcut.swift`). It's fn ⌃ until changed in Settings, and every surface shows the current one, never a fixed string. It's either modifiers alone, which must include fn, or a key with ⌃ or ⌥; anything looser would go off during typing or other apps' shortcuts.

### Cursor size

A cursor smaller than 2× grows to 2× while pointing and goes back on pause or when the session ends (`CursorSize.swift`). It never shrinks one, and it won't undo a size changed in System Settings meanwhile. macOS has no public call, so it's looked up at run time and does nothing if it's gone. The size outlives the app, so a crash is put right at the next launch.

### The tap's click

Each tap that clicks plays one short sound, the same every time: a mouse button pressing down and coming back up (`Assets/TapClick/click.wav`, from cuelume's `mech` tap). Never vary it per tap. It plays on the Mac's output, so never in the AirPods. Settings ▸ Tap to click ▸ **Click sound** turns it off; it is on by default.

## 4. Color

All color comes from `HomePalette` in `RemoteKit.swift`. Each token resolves for light, dark and Increase Contrast. Don't add a color in a view; add a token here and in `HomePalette`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | #FFFFFF | #1C1C1E | Window and page background; text on ink |
| `sidebar` | #F2F2F4 | #232325 | Secondary panes |
| `raised` | #F5F5F7 | #2A2A2D | Cards, notice bar, popover snapshot background |
| `stage` | #2A2A2D | #2A2A2D | Behind case art. Dark in both appearances so the white case stands out; anything drawn beside the case on it (the turn arrow) is white |
| `control` | black 7.5% | white 13% | Secondary button fill |
| `track` | black 10% | white 16% | Switch and meter tracks |
| `focusedSelection` | black 10% | white 12% | Row hover and selection |
| `rule` | black 10% | white 12% | Hairlines; high-contrast outlines (45%) |
| `ink` | #1D1D1F | #F2F2F2 | Primary buttons, on-switches, glyphs (pure black or white in Increase Contrast) |
| `accent` | #4A4A4A | #B8B8B8 | Rare emphasis in drawings |
| `screen` | #141416 | #0B0B0C | The miniature display behind the live pointer |
| `laser` | #FF3B30 | #FF453A | **Live only.** Pointer dot, live chip dot, menu-bar dot. Never a button, border or decoration. |

Rules:
- **No system accent blue.** System controls that draw in the accent color (NSSwitch, slider fills) get an ink stand-in (`InkSwitch`, `trackFillColor = ink`).
- **Opaque over glass.** Popovers and toolbars are translucent on macOS 26. A control that has to stay legible there needs an opaque fill (`ink`). Translucent tracks wash out.
- Text uses the system label colors (`labelColor`, `secondaryLabelColor`), plus `canvas` on ink.

## 5. Type

System font (SF Pro) only. Sizes in points:

| Role | Size / weight | Helper |
|---|---|---|
| Calibration overlay heading | 32 bold | `rkTitle(_, 32)` |
| Hero / setup step title | 26 bold, centered | `rkTitle(_, 26)` |
| Page title (Settings) | 22 bold | `rkLabel(_, 22, .bold)` |
| Sheet title | 17 semibold | `rkLabel(_, 17, .semibold)` |
| Popover title, HUD, empty-state title, hero button | 15 semibold | n/a |
| Body, row titles, secondary buttons | 13 regular / semibold | `rkLabel`, `rkWrap` |
| Captions, slider ends | 12 regular, secondary color | `rkWrap(_, 12)` |
| Eyebrow section header | 11 semibold, uppercase, +0.6 kern, secondary | `hmEyebrow` / `addHeader` |
| Key caps and shortcut hints | 11 monospaced medium | `KeyCap`, `RemoteButton(hint:)` |
| Changing numbers (1.4×, counts) | 13 medium, monospaced digits | n/a |

Wrapping text uses `rkWrap` (a `RemoteWrappingLabel`, which tracks its own width) so stack views size it correctly.

## 6. Layout

- **Page column:** 24 pt side padding. Sections start with an eyebrow header: 24 pt above, 8 pt below (`PageColumn.addHeader`).
- **Centered rows** (chips, the secondary button pair, the shortcut footer) go in a full-width holder (`addCentered`). Hide the holder, not the row, so the space collapses.
- **Popover:** 16 pt padding, 288 pt content width. Footer menu rows are inset 8 pt.
- **Scroll views** use `scrollerStyle = .overlay`, so a legacy scroller never narrows the column.
- **Radii:** buttons `min(10, h/2 − 1)`; cards and notice bar 10; aim pad 10–12; key caps 5; chips and switches fully round.
- **Heights:** hero primary 48; default button 44; secondary and tertiary 32; status chip 26; HUD 40; switch 40 × 24.

## 7. Components (`RemoteKit.swift`, plus a few private views)

| Component | Use | Notes |
|---|---|---|
| `RemoteButton` | Every button in product surfaces. `.primary` (ink), `.secondary` (control fill), `.tertiary` (borderless). | Optional `symbol:` (SF Symbol) and `hint:` key chip ("fn ⌃", "Return", "esc"). One primary per state. |
| `InkSwitch` | On/off in the popover (pointer control). | Ink when on; never blue. |
| `StatusChip` | The current state in a few words ("Pointing", "Paused"). | `live: true` adds the red dot and halo. |
| `KeyCap` | A shortcut on its own ("fn ⌃"). | Monospaced, outlined. |
| `AimPadView` | The live pointer on a miniature screen. | `screen` fill, `laser` dot with a fading trail. Shows a caption ("Projector") when there are several displays. |
| `CaseStepView` | One connect step: `.open`, `.close` (lid closing), `.turn` (quarter turn clockwise, with an ink arrow), `.point` (upright). | Loops while on screen and stops when hidden. Reduce Motion holds a still; the turn keeps its arrow. `pinnedTime` freezes a moment for previews. |
| `RemoteSurface`, `RemoteRule` | Filled rounded surfaces; hairline separators. | n/a |
| `NoticeBar` | A dismissible message above the pages. | Plain sentence plus what to do. |
| `ControlHUD` | Transient status over any app. | Doesn't take focus; respects Reduce Motion. |
| `AccessibilityGuide` | Replaces macOS's Accessibility prompt: opens the list in System Settings, with AirPointer as a card to drag into it. | Hangs above the + and − buttons in that window and follows it. Shows only while System Settings is in front, never takes focus, and goes away once allowed. |
| `CalibrationOverlayView` | Full-screen dwell calibration. | Step, progress ring, hint, success state. |
| `MenuRow` | Popover menu rows. | n/a |

When a system control can't meet the rules in §4 (blue, translucent), draw a small custom control here, with accessibility, keyboard and focus-ring support, instead of restyling it locally.

## 8. Logo and icons

**The mark:** the closed case held upright to point, with a ridge two-thirds across. The menu bar draws it in outline with a solid ridge; the app icon draws it solid with the ridge cut through.

- Case: 0.754 as wide as tall; corner radius 25% of the width; stroke a tenth of the height.
- Ridge: a rounded bar 1.6/15 of the case height wide and 47% of it tall, centered vertically, centered 68% of the way across.
- **App icon** (`Assets/AppIcon.icns`): the outline's outside edge filled light (white 0.95) on a dark tile (white 0.12), with the ridge cut through in the tile's color, never narrower than two pixels. Filling the outline keeps the icon and the menu bar on one silhouette.
- **Menu bar** (`StatusBarController.menuBarImage`): the same mark at 18 pt with a 1.5 pt stroke. It's drawn per appearance rather than as a template, because of the red dot. States: idle (mark only), **live** (red dot on the left half), **connecting** (small ring there), **off** (35% ink).
- Don't outline the ridge at menu-bar size; an outlined pill reads as a zero. Don't add a seam line.

**SF Symbols** handle everything else: `scope` Recenter, `pause.fill` Pause, `dot.viewfinder` Recalibrate. Tint them with palette colors (`paletteColors:`), never the accent color.

## 9. Imagery and 3D renders

- **Source:** Apple's AirPods Pro 3 AR asset, `Assets/airpods-pro.usdz`. The source URL is in `Assets/README.md` and its hash in `Assets/CaseLid/lid.json`. Apple owns the model. Keep the USDZ bytes unchanged, and only bundle renders (PNG).
- **Rendering:** `Scripts/render-closed-case.py`, run with Blender in the background (never a live Blender session). Cycles, AgX "Medium High Contrast", a dark studio (near-black world, soft key and fill, thin strip lights left, right, top and front, and a rim) so the gloss reads as crisp highlight bands, transparent film, and a measured silhouette in a JSON sidecar. The earbuds are seated with the transform from `Scripts/seat-earbuds.py` so they clear the closed lid. Output goes to `work/case-renders`; copy it into `Assets/` as described in `Assets/README.md`.
- **Bundled set (one front camera, 12° above, shared by every frame):**
  - `CaseLid/lid-00.png`…`lid-11.png`: the lid easing from open (115°) to closed. The light comes on in the last two frames.
  - `CaseFront.png`: the closed case turned a quarter clockwise, upright, lid seam on the right, light facing you.
  - The turn is drawn by rotating the closed frame 90° clockwise about the image center and crossfading into `CaseFront`. This is exact because the case turns about the viewing axis.
- **The green status light** is the real case's light, part of the picture. It is not a UI color: never use green in the interface, with one exception: the ring around the case during Set it down is `systemGreen`, to read as the case's own connection light.
- **Animation:** nothing spins; every step uses the one front camera. No floor reflection; the stage is the floor. The Connect step plays once: hold closed 0.4 s, open over 0.9 s, then stay open. The lid loop is 3.4 s (hold open 0.7 s, close 0.9 s, hold closed 1.4 s, fade back); the opening loop after Connect is the same in reverse. The turn loop is 3.6 s (hold 0.7 s, turn 1 s with smoothstep easing, hold upright 1.4 s, fade back). With Reduce Motion, show the end state still: the open case, and the turn shows the closed case with its clockwise arrow.

## 10. Writing

- **Voice:** short, direct, second person. "Close the lid." not "The lid should now be closed."
- **Sentence case** for titles and buttons ("Start Pointing" is the exception: it's a product command, Title Case like the menu items).
- **Buttons are verbs:** Start Pointing, Recenter, Recalibrate…, Disconnect, Finish. Add "…" when more UI follows before anything happens.
- **Typography:** curly apostrophes and quotes (’ “ ”); in HTML or React, escape as `&rsquo;`/`&apos;`. Use the real ellipsis (…), the × sign for speeds ("1.4×"), and key glyphs (fn ⌃, ⌘R).
- **Numbers:** numerals, as in "Step 2 of 3".
- **Vocabulary:**

| Say | Don't say |
|---|---|
| case, lid, front, upright, light | shell, rear, vertical grip, IMU |
| Recenter / Recalibrate… | Set center / Learn your grip / Calibrate axis |
| Aim with the case. Tap its front to click. | mode, mic |
| Paused — reason | Error, Failed, code numbers |

- Every paused or failed state names one action the person can take.

## 11. Motion and feedback

- Durations: 0.16–0.18 s for controls (switches), 0.2–0.3 s for page changes and HUD fades. Use ease-out.
- Check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` before any animation; jump straight to the end state when it's on.
- The HUD confirms things that happen outside the window (pointing started, paused, disconnected). It never asks a question.

## 12. Accessibility

- Contrast: body text ≥ 4.5:1, and control states ≥ 3:1 against what's actually behind them, glass included.
- Increase Contrast: tokens switch to their contrast values, and custom controls add an outline.
- VoiceOver: every custom control sets a role and label. Switches report on/off; the aim pad is an image labeled with what it shows.
- Keyboard: full keyboard access reaches every control. Return triggers the primary action in setup, and Esc cancels overlays and leaves Settings.
- Shortcuts: ⌘, Settings · ⌘R Recenter · ⌘1 Pointer · ⌘0 the AirPointer window · fn ⌃ pause from any app.

## 13. Checking your work

1. `AIRPOINTER_OPTIMIZATION=-Onone ./build.sh` (runs the self-tests).
2. `AirPointer.app/Contents/MacOS/AirPointer --check-home --preview-directory <dir>` renders every main-window state, including the closed-case steps; the setup steps; the calibration overlay; the popover (light and dark); the menu-bar glyph states; and contact sheets of the lid and turn loops (`case-steps-close`, `case-steps-turn`). Look at them all in light and dark.
3. `--check-closed-case-native` covers the closed-case motion bridge without touching a device.
4. New surface or state? Add a preview to `HomeChecks.swift` in the same change.

Review checklist:
- [ ] One primary button per state; the rest are secondary or tertiary.
- [ ] Only palette tokens; red only when live; no accent blue.
- [ ] Images and copy follow §2 (closed case, taps on the front, turn clockwise).
- [ ] Copy follows §10; pause and failure states say what to do.
- [ ] Light, dark and Increase Contrast checked; Reduce Motion respected.
- [ ] Works at the minimum window size (400 × 620) without clipping.
- [ ] VoiceOver label and role on anything custom.
