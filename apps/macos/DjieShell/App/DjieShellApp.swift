import AppKit
import SwiftUI

struct DjieShellApp: App {
    @State private var model = AppModel()
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .dark

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear {
                    appearance.apply()
                    KeyRouter.install(model: model)
                    Notifier.shared.install(model: model)
                }
                .onChange(of: appearance) { _, mode in mode.apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("Tentang Djie Shell")) {
                    model.section = .about
                    model.showHome()
                }
                .disabled(model.phase != .main)
                Button(L("Periksa Pembaruan…")) { Task { await model.checkForUpdates(manual: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Host Baru…")) { NotificationCenter.default.post(name: .djieNewHost, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(model.phase != .main)
            }
            CommandGroup(after: .sidebar) {
                Picker(L("Tampilan"), selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { m in Text(m.title).tag(m) }
                }
                Divider()
            }
            CommandMenu(L("Sesi")) {
                Button(L("Daftar Host")) { model.showHome() }.keyboardShortcut("t")
                Button(L("Terminal Lokal")) { model.openLocalTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.phase != .main)
                Button(L("Tutup Tab")) { model.closeActive() }
                Divider()
                Button(L("Split: Duplikat Tab")) { model.splitDuplicate() }
                    .keyboardShortcut("d")
                    .disabled(!model.canSplit)
                Button(model.broadcast ? L("Matikan Broadcast") : L("Broadcast ke Semua Panel")) { model.toggleBroadcast() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!model.splitVisible)
                Button(L("Keluar dari Split")) { model.unsplit() }
                    .disabled(!model.splitVisible)
                Divider()
                Button(L("Kunci Vault")) { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.phase != .main)
            }
        }
    }
}

extension Notification.Name {
    static let djieNewHost = Notification.Name("djie.newHost")
}

/// Shortcut tab yang harus diproses sebelum menu bawaan macOS:
/// ⌘W menutup tab terminal (bukan jendela) selama masih ada tab, ⌘1…9 pindah tab.
@MainActor
enum KeyRouter {
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Popup autocomplete terminal: Tab/→ terima, ↑↓ pilih, Esc tutup
            if let s = model.activeSession, s.autocomplete.active,
               NSApp.keyWindow?.firstResponder === s.view, s.autocomplete.handle(event) {
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command, model.phase == .main, let ch = event.charactersIgnoringModifiers else { return event }
            if ch == "w", model.activeSessionID != nil {
                model.closeActive()
                return nil
            }
            if let n = Int(ch), (1...9).contains(n) {
                if n <= model.sessions.count { model.focusTab(number: n) }
                return nil
            }
            if ch == "0" {
                model.showHome()
                return nil
            }
            // Copy / paste / select all ke terminal aktif — kecuali sedang mengetik di kolom teks.
            if ["c", "v", "a"].contains(ch), let term = model.activeTerminalView,
               !(NSApp.keyWindow?.firstResponder is NSTextView) {
                switch ch {
                case "c": term.copySelection()
                case "v": term.pasteClipboard()
                default: term.selectAll(nil)
                }
                term.window?.makeFirstResponder(term)
                return nil
            }
            return event
        }
    }
}
