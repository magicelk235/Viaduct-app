---
version: 1.0
name: Viaduct-app-design-system
surface: native macOS app (SwiftUI), system-adaptive (light + dark)
identity: >
  Viaduct's in-product design system. NOT a marketing-site spec — this is the
  app you actually ship. It follows Apple's own productivity-app model
  (Pages / Keynote / Numbers): a calm, NEUTRAL chrome that adapts to the system
  light or dark appearance, with the app icon's TEAL used as the single brand
  accent — symbols, selection, the primary action, focus. The chrome itself is
  greyscale (off-white surfaces in light, near-black neutral in dark); color is
  spent only where it carries meaning. Surfaces are built on Apple Liquid Glass
  (macOS 26 `.glassEffect`, which adapts to appearance automatically; degraded to
  `.ultraThinMaterial` on macOS 13–15). No drop shadows — depth comes from a
  four-step surface ladder and the refraction of glass. The brand face is the
  real Viaduct app icon — three teal glass arches (a viaduct) — rendered inline
  in its true color, not a flat re-drawn glyph. The app should feel like a
  precision instrument: Apple's neutral calm, teal-accented.

principles:
  - Follow the system. The window adapts to light AND dark; never lock an
    appearance. Every surface/text token is an adaptive light/dark pair.
  - Neutral chrome, one accent color. Surfaces and text are greyscale; the icon's
    teal is the ONLY brand hue — symbols, selection ring, primary action, focus.
    Spend it nowhere else (Apple's Pages-orange / Numbers-green model).
  - Glass is the elevation. Depth = surface ladder + Liquid Glass refraction,
    never a drop shadow. If something needs to lift, it floats on glass.
  - Color carries meaning, not decoration. Teal = brand/primary/focus. Green
    (#1A9D5A/#30D158) = success & progress ONLY. Red = failure. Yellow = warning.
  - Motion is feedback, not flourish. Springs confirm state changes; the
    progress bar models real work with physics; nothing animates to show off.
  - Hairlines, not boxes. Borders are 1px neutral (black/white) at low opacity,
    visible in both themes. Structure is implied, not drawn in heavy lines.
  - Type is monochrome and quiet. One family (SF Pro), neutral ink (dark-on-light
    / light-on-dark), hierarchy from size/weight/spacing — not color.

# ---------------------------------------------------------------------------
# COLOR — every token is an ADAPTIVE light/dark pair (light | dark). Neutral
# greyscale chrome; the icon's teal is the one brand accent. Token NAMES are
# stable and mirror Sources/Theme.swift — consumers never break on a retheme.
# ---------------------------------------------------------------------------
colors:
  # Brand accent — the app icon's teal, a touch brighter in dark. THE one
  # hue: symbols, selection, primary action, focus.
  primary:         "#12A594 | #2DD4BF"
  primary-pressed: "#0E8174 | #14B8A6"
  on-primary:      "#FFFFFF | #04201C"   # text on the teal pill
  accent-teal:     "#12A594 | #2DD4BF"   # = primary (focus / info)

  # Surface ladder (canvas → surface → elevated → card). Neutral greys that flip
  # with the system appearance. The ONLY source of solid-fill depth.
  canvas:           "#F5F5F7 | #1A1A1C"
  surface:          "#FFFFFF | #222225"
  surface-elevated: "#F0F0F2 | #2A2A2E"
  surface-card:     "#EAEAEC | #323237"

  # Hairlines — neutral black/white separators, visible in both themes.
  hairline:         "black 10% | white 10%"
  hairline-soft:    "black 5%  | white 5%"
  hairline-strong:  "black 18% | white 18%"

  # Text — neutral ink. Dark-on-light / light-on-dark. Hierarchy by value.
  ink:    "#1D1D1F | #F5F5F7"   # headlines
  body:   "#3A3A3C | #D4D4D8"   # paragraph / labels
  mute:   "#6E6E73 | #98989F"   # metadata
  ash:    "#9A9AA0 | #68686E"   # disabled
  stone:  "#BFBFC4 | #49494E"   # least-emphasis / empty-state glyphs

  # Status accents — semantic, adaptive for contrast in both themes.
  accent-green:  "#1A9D5A | #30D158"   # success & progress ONLY (true green, distinct from teal)
  accent-red:    "#E5484D | #FF6369"   # failure / destructive
  accent-yellow: "#D4A017 | #FFC53D"   # warning

  # Brand wash — teal crown → deep teal, behind the icon glow.
  wash-start: "#5EEAD4"
  wash-end:   "#0E8174 | #14B8A6"

# ---------------------------------------------------------------------------
# TYPOGRAPHY
# SF Pro (system). Inter's ss03 signature can't be reproduced natively, so we
# lean on SF Pro's optical sizing and hold deliberate weight contrast instead.
# Premium hierarchy = wide gap between display and caption; tracking opens up
# small labels so the chrome breathes.
# ---------------------------------------------------------------------------
typography:
  family: "SF Pro (system, .default design)"
  numbers: "monospaced digits in any live/numeric readout (versions, counts)"
  scale:
    display-xl: { size: 40, weight: bold,      tracking: "+0.2", use: "launch / hero moments" }
    display-lg: { size: 30, weight: semibold,  tracking: "0",    use: "splash / empty hero" }
    heading-xl: { size: 22, weight: semibold,  tracking: "+0.2", use: "window titles (Settings)" }
    heading-md: { size: 18, weight: semibold,  tracking: "+0.2", use: "card / screen titles" }
    heading-sm: { size: 16, weight: medium,    tracking: "+0.1", use: "section + drop-card titles" }
    body-lg:    { size: 16, weight: regular,   tracking: "0" }
    body:       { size: 14, weight: regular,   tracking: "0",    use: "default" }
    body-strong:{ size: 14, weight: medium,    tracking: "0" }
    caption:    { size: 12, weight: regular,   tracking: "+0.3", use: "metadata, helper text — tracked open" }
    button:     { size: 13, weight: medium,    tracking: "+0.1" }
    mono:       { size: 12, weight: regular,   tracking: "0",    use: "log output, versions" }
  notes:
    - "Display weights bumped to bold/semibold (was semibold/medium) for a
       sharper top-of-hierarchy. Caption tracked +0.3 so small text reads as
       intentional spacing, not cramped. This contrast IS the premium signal."

# ---------------------------------------------------------------------------
# SPACING & RADIUS
# ---------------------------------------------------------------------------
spacing:   # pt
  xxs: 2
  xs: 4
  sm: 8
  md: 12
  lg: 16
  xl: 24
  xxl: 32
  section: 96
  rhythm: >
    Screens are vertically centered in their available height, not pinned to
    the top. Card-centric layouts cap content at maxWidth 440 and sit in the
    optical center so the canvas frames them evenly top and bottom.

radius:   # pt, continuous (squircle) corners everywhere
  xs: 4     # keycaps, tiny tiles
  sm: 6     # rows, small chips
  md: 8     # buttons, fields
  lg: 10    # cards, glyph tiles
  xl: 16    # the hero drop-card, extension-icon tiles
  full: 9999

# ---------------------------------------------------------------------------
# ELEVATION & GLASS — the heart of the system
# ---------------------------------------------------------------------------
elevation:
  model: "Liquid Glass + surface ladder. No drop shadows, ever."
  liquid-glass:
    native: "macOS 26+ uses Apple `.glassEffect(_:in:)`; tint lightly colors it, interactive enables press/hover lensing."
    fallback: ".ultraThinMaterial + tint overlay (0.45) + a top-edge white highlight stroke (white 0.30→0.06→clear) to fake refraction. macOS 13–15."
    grouping: "Adjacent glass shapes fuse via GlassEffectContainer (LiquidGlassGroup) so they blend on the native API."
  glow:
    rule: "Glow is reserved for the icon motif and live status — a soft blurred color disc behind a tile or the CTA. Subtle (opacity 0.16–0.30), blur 12–14. Never a hard shadow."
  borders: "1px hairline neutral (black/white, low opacity). Active/focus state lifts to hairline-strong and/or the primary teal at lineWidth 2."

# ---------------------------------------------------------------------------
# MOTION
# ---------------------------------------------------------------------------
motion:
  springs:
    snappy:  "response 0.22, damping 0.75 — button press, hover scale"
    settle:  "response 0.25–0.35, damping 0.75–0.85 — card morphs, selection, phase change"
  ambient:
    glow: "one faint static teal crown glow on the User-mode canvas — brand presence, not motion. No drifting aurora (Apple chrome is calm)."
    pulse:  "phase glyph glow breathes on a 1.2s loop; SF Symbol .pulse on the active glyph"
  progress: >
    The convert progress bar models real work, not a fixed timeline: it races
    to catch up when a phase finishes early, crawls toward a soft ceiling while
    waiting (decaying quadratically so it never freezes at 90%), and on CLI exit
    eases hard to 100%. A traveling soft-light shine keeps it alive. Hover
    reveals a red Cancel affordance.
  reduce-motion: "The crown glow and glyph pulse are decorative and hit-test-disabled; honor Reduce Motion by holding them static."

# ---------------------------------------------------------------------------
# COMPONENTS  (all defined in Sources/Theme.swift)
# ---------------------------------------------------------------------------
components:
  brand-lockup: >
    The real Viaduct app icon (three glass arches) rendered inline above the
    "Viaduct" wordmark in heading-md ink. The top-of-window identity anchor on
    every primary surface. The icon art is used as an alpha mask over the brand
    real teal artwork shown as-is with a soft teal glow — never a flat re-drawn
    glyph (a stroked re-draw reads as a generic "M").
  buttons:
    primary:  "teal-tinted interactive Liquid Glass pill, 36pt, on-primary text, scale 0.97 on press. The one glowing action per screen."
    tertiary: "clear interactive glass + hairline-strong edge, 36pt. Mid-emphasis."
    ghost:    "text-only, body color, 32pt, dims to 0.6 on press. Lowest emphasis."
  fields:
    text:   "clear glass capsule, ink text, hairline edge, 32pt (.glass)"
    toggle: "switch with an accent-green on-track, white knob, spring (.glass)"
    pill-tab: "transparent chip strip; the active chip lifts onto glass with a hairline-strong capsule (PillTabPicker) — replaces AppKit segmented/radio so the window stays one dark mode. Each chip is a real Button so the strip is keyboard-reachable and reads as a selected control to VoiceOver."
  cards:
    raycast-card: "hairline-bordered card on the surface ladder; glass:true floats it on Liquid Glass. The default container."
    drop-card: "the hero of User mode — one xl-radius glass card that morphs through empty → ready → converting → done/failed. Dashed hairline border when empty, solid + teal glow on drag-target."
  icon-tiles:
    extension-icon: "60pt xl-radius glass tile holding the extension's real icon, or a focal placeholder glyph in primary teal."
    drop-glyph: "the empty-state focal point: an arch-motif glyph in a glass tile inside a glow ring — a designed centerpiece, not a stock SF placeholder."
    phase-glyph: "60pt glass tile, breathing teal glow, SF Symbol that swaps per phase with a scale/opacity transition."
  status:
    step-dots: "one capsule per convert phase; fills emerald and the active dot widens. Gives the wait a sense of journey."
    status-pill: "glass pill, green check / red octagon, for run results."
    value-row: "SF Symbol in an 18pt frame + the value in mono + a trailing control (VersionRow, SigningTeamRow). Mono covers any opaque identifier — a version, a team id — not just numerals. The card title labels the row, so the row carries no label of its own."
    keycap: "small glass keyboard glyph (⌘K, ⏎) for shortcut hints."
  backdrop:
    ambient-background: "the neutral adaptive canvas + one faint teal crown glow behind User mode."
    hero-stripe: "an optional single teal top wash used once per surface, fading into the canvas."

# ---------------------------------------------------------------------------
# LAYOUT
# ---------------------------------------------------------------------------
layout:
  windows:
    user-mode:   "min 540×600. Centered card column, maxWidth 440. Brand lockup → drop-card → morphing CTA → recent list. Neutral canvas + faint teal crown glow."
    developer:   "min 820×640. HSplitView: scrollable options form (min 400 / ideal 440) | live log pane (min 380). Toolbar: User-mode · CLI menu · Doctor · Analyze · Convert(primary). Flat canvas (no aurora — it's a workbench)."
    settings:    "fixed 460×600. Stacked RaycastCards: Mode · License · App updates · CLI · Keeping extensions working · Warnings · Support · Converted extensions. The signing card leads with its lifetime badge (7 DAYS yellow / 1 YEAR green) and, only on a Mac with more than one Apple team, a value row pinning which team signs."
    activation:  "min 540×600. Centered: key glyph → title → field → Activate(primary) → buy link."
  forms: "label column fixed at 96pt, glass field fills the rest; sections are glass RaycastCards titled with an SF Symbol + heading-sm."

# ---------------------------------------------------------------------------
# PREMIUM REFINEMENTS  (the v1.0 pass — what 'premium' concretely means here)
# ---------------------------------------------------------------------------
refinements:
  - "Brand anchor: every primary surface opens with the arch brand-lockup, not a bare text line. Identity first."
  - "Designed focal points: the empty drop-card and icon tiles use the arch motif, never a lonely stock SF glyph on a faint ring."
  - "Calm canvas: a single faint teal crown glow gives brand presence; no drifting aurora — Apple chrome is neutral and still."
  - "Type contrast: display weights up, captions tracked open — a visible, intentional hierarchy."
  - "Vertical rhythm: card columns optically centered, not top-pinned; even breathing room top and bottom."
  - "Consistency: developer mode inherits the same type/spacing refinements so both surfaces feel like one premium product."

dont:
  - "No light surfaces or opaque panels — never break the dark continuity."
  - "No drop shadows — depth is glass + ladder only."
  - "Don't spend teal on decoration; it marks the primary action, focus, and info — nothing else."
  - "Don't use green for anything but success/progress."
  - "No stock placeholder glyph as a focal point — design it with the arch motif."
  - "Don't pin content to the top; center it."
