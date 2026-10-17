import AppKit
import SwiftUI

/// Owns the Settings window. Built in AppKit rather than as a SwiftUI
/// `Settings` scene because the window needs `.fullSizeContentView` from the
/// start, which is what gives the sidebar macOS 26's glass chrome; SwiftUI
/// scenes don't expose the style mask.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show(vm: ConverterViewModel) {
        if shared == nil { shared = SettingsWindowController(vm: vm) }
        // Quitting to the menu bar drops the Dock icon; a window needs it back.
        NSApp.setActivationPolicy(.regular)
        shared?.showWindow(nil)
    }

    private init(vm: ConverterViewModel) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 720, height: 580)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.toolbarStyle = .automatic
        window.setFrameAutosaveName("SettingsWindow")
        window.minSize = NSSize(width: 680, height: 520)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView(vm: vm).tint(Theme.Colors.primary))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

/// Brings up the main window from places that aren't inside a SwiftUI scene
/// (the AppKit-hosted Settings window). The action is captured from the first
/// scene view that appears.
@MainActor
enum MainWindow {
    static var openAction: OpenWindowAction?

    static func show() {
        NSApp.setActivationPolicy(.regular)
        openAction?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension View {
    /// The sidebar toggle hides the page list, which Settings never wants.
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    /// macOS 26's soft blur where content scrolls under the toolbar.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
