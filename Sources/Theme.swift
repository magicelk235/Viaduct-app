import SwiftUI

/// Central design tokens. DARK mode, lit by the app icon's teal-slate palette:
/// a deep teal-black canvas with a 4-step surface ladder, and the icon teal
/// (#21AF9F bright → #16746F deep, from the arch icon) carrying the CTA, accents,
/// hairlines and glow. Token NAMES are unchanged so every consumer view keeps
/// working without edits. Inter is substituted with SF Pro (macOS fallback).
enum Theme {

    // MARK: - Colors

    // APPLE-STYLE: neutral system-adaptive chrome (light OR dark, follows the
    // system) with the app icon's TEAL as the single brand accent — the model
    // Pages/Keynote/Numbers use (neutral surfaces, icon-colored symbols). Every
    // surface/text token is an adaptive light/dark pair; the accent is teal in
    // both. Token NAMES are unchanged so every consumer view re-themes for free.
    enum Colors {
        // Brand accent — the arch icon's teal (#21AF9F → #16746F). Deep end in light,
        // bright end in dark, for legible contrast. THE one hue: symbols, selection, primary
        // action, focus.
        static let primary        = Color(light: 0x16746F, dark: 0x21AF9F)
        static let primaryPressed = Color(light: 0x0F5551, dark: 0x1B958A)
        static let onPrimary      = Color(light: 0xFFFFFF, dark: 0x0A1A1E)   // text on the teal pill
        static let accentBlue      = Color(light: 0x16746F, dark: 0x21AF9F)  // = brand teal (focus/info)

        // Surface ladder (canvas → surface → elevated → card). Neutral greys,
        // a hair warm-cool-neutral, that flip with the system appearance.
        static let canvas          = Color(light: 0xF5F5F7, dark: 0x1A1A1C)
        static let surface         = Color(light: 0xFFFFFF, dark: 0x222225)
        static let surfaceElevated = Color(light: 0xF0F0F2, dark: 0x2A2A2E)
        static let surfaceCard     = Color(light: 0xEAEAEC, dark: 0x323237)

        // Hairlines — neutral separators, visible in both themes.
        static let hairline       = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.10)
        static let hairlineSoft   = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.05)
        static let hairlineStrong = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.18)

        // Text — neutral ink, dark-on-light / light-on-dark. Hierarchy by value.
        static let ink      = Color(light: 0x1D1D1F, dark: 0xF5F5F7)   // headlines
        static let body     = Color(light: 0x3A3A3C, dark: 0xD4D4D8)   // paragraph
        static let mute     = Color(light: 0x6E6E73, dark: 0x98989F)   // metadata
        static let ash      = Color(light: 0x9A9AA0, dark: 0x68686E)   // disabled
        static let stone    = Color(light: 0xBFBFC4, dark: 0x49494E)   // least-emphasis

        // Status accents — semantic, also adaptive for contrast in both themes.
        static let accentRed    = Color(light: 0xE5484D, dark: 0xFF6369)   // failure / destructive
        static let accentGreen  = Color(light: 0x1A9D5A, dark: 0x30D158)   // success & progress (true green, distinct from teal accent)
        static let accentYellow = Color(light: 0xD4A017, dark: 0xFFC53D)   // warning

        // Brand wash — teal crown → deep teal-slate, behind the icon glow.
        static let heroStripeStart = Color(light: 0x5FCEC0, dark: 0x5FCEC0)
        static let heroStripeEnd   = Color(light: 0x16746F, dark: 0x136C68)
    }

    // MARK: - Radius

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: - Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 96
    }

    // MARK: - Typography
    //
    // Inter is substituted with SF Pro (the documented macOS fallback). The
    // ss03 alternate-g signature can't be reproduced with SF, so we hold the
    // positive letter-spacing that gives Viaduct's chrome its airy feel.

    // Weights carry the hierarchy (display/heading bumped one step heavier than
    // before for a sharper top-of-scale). Tracking lives in the `.tracked()` /
    // `.heading()` text modifiers below so it's one call, not scattered numbers.
    enum Font {
        static func displayXL() -> SwiftUI.Font { .system(size: 40, weight: .bold,     design: .default) }
        static func displayLG() -> SwiftUI.Font { .system(size: 30, weight: .semibold, design: .default) }
        static func headingXL() -> SwiftUI.Font { .system(size: 22, weight: .semibold, design: .default) }
        static func headingMD() -> SwiftUI.Font { .system(size: 18, weight: .semibold, design: .default) }
        static func headingSM() -> SwiftUI.Font { .system(size: 16, weight: .medium,   design: .default) }
        static func bodyLG()    -> SwiftUI.Font { .system(size: 16, weight: .regular,  design: .default) }
        static func body()      -> SwiftUI.Font { .system(size: 14, weight: .regular,  design: .default) }
        static func bodyStrong()-> SwiftUI.Font { .system(size: 14, weight: .medium,   design: .default) }
        static func caption()   -> SwiftUI.Font { .system(size: 12, weight: .regular,  design: .default) }
        static func button()    -> SwiftUI.Font { .system(size: 13, weight: .medium,   design: .default) }
        static func mono()      -> SwiftUI.Font { .system(size: 12, weight: .regular,  design: .monospaced) }
    }
}

// MARK: - Type tracking
//
// Premium hierarchy needs deliberate letter-spacing: small labels open up,
// headings hold a hair of positive tracking. These are the canonical values —
// use them instead of bare `.tracking(...)` numbers at call sites.
extension Text {
    /// Metadata / helper text: tracked open (+0.3) so 12pt reads as intentional.
    func tracked() -> Text { self.tracking(0.3) }
    /// Heading text: a hair of positive tracking (+0.2) for an airy chrome.
    func heading() -> Text { self.tracking(0.2) }
}

// MARK: - Hex + adaptive helpers

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha)
    }

    /// An appearance-adaptive color: resolves to `light` in light mode and
    /// `dark` in dark mode, following the system the way AppKit's semantic
    /// colors do. This is what lets the chrome flip light/dark while the accent
    /// stays the brand teal.
    init(light: UInt, dark: UInt, alpha: Double = 1) {
        let l = NSColor(Color(hex: light, alpha: alpha))
        let d = NSColor(Color(hex: dark, alpha: alpha))
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? d : l
        })
    }
}

// MARK: - Liquid Glass
//
// Uses Apple's real Liquid Glass (`.glassEffect`, macOS 26 Tahoe) when
// available, and falls back to a tuned `.ultraThinMaterial` glass on macOS
// 13–15 so the app still runs and still reads as glass.

extension View {
    /// Apply Liquid Glass clipped to a rounded rect. `tint` lightly colors the
    /// glass; `interactive` enables the press/hover lensing on the native API.
    @ViewBuilder
    func liquidGlass(radius: CGFloat = Theme.Radius.lg,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.buildGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill((tint ?? Theme.Colors.surfaceCard).opacity(0.45)))
                .overlay(                       // top edge highlight (fake refraction)
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .white.opacity(0.06), .clear],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private static func buildGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Container that fuses nearby glass shapes so they blend/merge correctly on the
/// native API. A passthrough on older systems.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = Theme.Space.sm
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Hero gradient band
//
// DESIGN.md's signature decorative moment: the aqua-to-deep-teal wash from the
// Viaduct icon's arch, used exactly ONCE per surface across the very top of the
// canvas as a launch-banner. A thin top wash, not a full band — the
// window is small, so the gradient fades into the canvas rather than padding 96px.
struct HeroStripe: View {
    var height: CGFloat = 120
    var body: some View {
        LinearGradient(
            colors: [Theme.Colors.heroStripeStart.opacity(0.55),
                     Theme.Colors.heroStripeEnd.opacity(0.18),
                     Theme.Colors.canvas.opacity(0)],
            startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

// MARK: - Brand lockup
//
// The top-of-window identity anchor: a clean text wordmark + subtitle. No icon
// mark (removed by request) — the title carries it.
struct BrandLockup: View {
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            Text("Viaduct")
                .heading()
                .font(Theme.Font.headingMD())
                .foregroundStyle(Theme.Colors.ink)
            if let subtitle {
                Text(subtitle)
                    .tracked()
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Drop glyph
//
// The empty drop-card's focal point: a glass tile with a puzzle-piece (the
// universal browser-extension symbol) in the brand teal. Brightens and lifts
// when a file is dragged over.
struct ArchDropGlyph: View {
    var active: Bool = false
    var body: some View {
        ZStack {
            Color.clear.liquidGlass(radius: Theme.Radius.lg)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(active ? Theme.Colors.primary : Theme.Colors.hairline,
                                  lineWidth: active ? 1.5 : 1))
            // The symbol = a square body + a knob on its RIGHT. SwiftUI centers
            // the whole glyph, so the body lands left-of-center. Push right so the
            // BODY is centered and the knob overhangs into the right margin.
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.Colors.primary)
                .symbolRenderingMode(.hierarchical)
                .opacity(active ? 1 : 0.92)
                .offset(x: 3)
        }
        .frame(width: 64, height: 64)
    }
}

// MARK: - Ambient canvas
//
// Apple's productivity apps (Pages/Keynote/Numbers) sit on a flat, neutral
// system-adaptive canvas — nothing behind the content. Just the adaptive canvas
// color. Struct name kept so consumers don't change.
struct AmbientBackground: View {
    var body: some View {
        Theme.Colors.canvas.ignoresSafeArea()
    }
}

// MARK: - Glow ring
//
// The app's icon motif: a rounded-square (squircle) glass tile floating inside a
// soft circular glow. ExtensionIcon builds it inline; this
// modifier applies the same circle-behind-square treatment to any square icon view.
extension View {
    func glowRing(_ color: Color, diameter: CGFloat, opacity: Double = 0.20) -> some View {
        self.background(
            Circle()
                .fill(color.opacity(opacity))
                .frame(width: diameter, height: diameter)
                .blur(radius: 14))
    }
}

// MARK: - Reusable surfaces

/// A hairline-bordered card on the Raycast surface ladder. Depth comes from the
/// surface color step, never from a drop shadow. With `glass`, the card floats
/// on Liquid Glass instead of a solid surface.
struct RaycastCard<Content: View>: View {
    var surface: Color = Theme.Colors.surface
    var radius: CGFloat = Theme.Radius.lg
    var padding: CGFloat = Theme.Space.xl
    var border: Color = Theme.Colors.hairline
    var glass: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .padding(padding)
            .background {
                if glass {
                    Color.clear.liquidGlass(radius: radius)
                } else {
                    shape.fill(surface)
                }
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }
}

/// Small physical-feeling keyboard glyph (⌘ K, ⏎, Esc) rendered in Liquid Glass.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.caption())
            .foregroundStyle(Theme.Colors.body)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .frame(minHeight: 20)
            .liquidGlass(radius: Theme.Radius.xs)
    }
}

// MARK: - Button styles (all Liquid Glass)

/// The universal primary action — a white-tinted interactive Liquid Glass pill.
struct RaycastPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.button())
            .foregroundStyle(Theme.Colors.onPrimary)
            .padding(.horizontal, Theme.Space.lg)
            .frame(height: 36)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                if #available(macOS 26.0, *) {
                    Color.clear.liquidGlass(radius: Theme.Radius.md,
                                            tint: Theme.Colors.primary, interactive: true)
                } else {
                    shape.fill(configuration.isPressed
                               ? Theme.Colors.primaryPressed : Theme.Colors.primary)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Mid-emphasis action — clear interactive Liquid Glass with a hairline edge.
struct RaycastTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.button())
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, Theme.Space.lg)
            .frame(height: 36)
            .background(Color.clear.liquidGlass(radius: Theme.Radius.md, interactive: true))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Lowest-emphasis text button.
struct RaycastGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.button())
            .foregroundStyle(Theme.Colors.body)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 32)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == RaycastPrimaryButtonStyle {
    static var raycastPrimary: RaycastPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == RaycastTertiaryButtonStyle {
    static var raycastTertiary: RaycastTertiaryButtonStyle { .init() }
}
extension ButtonStyle where Self == RaycastGhostButtonStyle {
    static var raycastGhost: RaycastGhostButtonStyle { .init() }
}

// MARK: - Glass form controls

/// A Liquid Glass text field — clear glass capsule, ink text, hairline edge.
struct GlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Theme.Font.body())
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 32)
            .background(Color.clear.liquidGlass(radius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

extension TextFieldStyle where Self == GlassTextFieldStyle {
    static var glass: GlassTextFieldStyle { .init() }
}

/// A Liquid Glass toggle styled as a switch with an accent-green "on" track.
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            Spacer(minLength: Theme.Space.md)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? AnyShapeStyle(Theme.Colors.accentGreen.opacity(0.9))
                          : AnyShapeStyle(.clear))
                    .background(configuration.isOn ? nil : Color.clear.liquidGlass(radius: Theme.Radius.full))
                    .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
                    .frame(width: 40, height: 24)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(
                        configuration.isOn ? Color.clear : Theme.Colors.hairlineStrong, lineWidth: 1))
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 2, y: 1)
            }
            .frame(width: 40, height: 24)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    configuration.isOn.toggle()
                }
            }
        }
    }
}

extension ToggleStyle where Self == GlassToggleStyle {
    static var glass: GlassToggleStyle { .init() }
}

// MARK: - Pill-tab segmented control
//
// DESIGN.md's `pill-tab`: a transparent chip strip where the active chip lifts
// one surface notch onto glass. Replaces raw AppKit segmented/radio pickers so
// the whole window stays in one continuous dark mode.

/// A segmented control rendered as Raycast pill-tab chips. Generic over any
/// `CaseIterable & Identifiable` enum with a `label`.
struct PillTabPicker<T: Hashable & Identifiable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options) { option in
                let active = option == selection
                Text(label(option))
                    .font(Theme.Font.button())
                    .foregroundStyle(active ? Theme.Colors.ink : Theme.Colors.body)
                    .padding(.horizontal, Theme.Space.md)
                    .frame(height: 28)
                    .background {
                        if active {
                            Color.clear.liquidGlass(radius: Theme.Radius.full)
                                .overlay(Capsule().strokeBorder(
                                    Theme.Colors.hairlineStrong, lineWidth: 1))
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            selection = option
                        }
                    }
            }
        }
    }
}

// Equality via id since the enums are simple String-backed cases.
extension PillTabPicker where T: CaseIterable {}
