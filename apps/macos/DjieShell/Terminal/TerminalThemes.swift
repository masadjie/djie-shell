import AppKit
import SwiftTerm
import SwiftUI

/// Tema terminal: warna latar, teks, kursor, dan palet 16 warna ANSI.
enum TerminalThemes {
    struct Def: Identifiable, Equatable {
        let id: String
        let name: String
        let bg: String
        let fg: String
        let accent: String
        /// 16 warna ANSI: hitam, merah, hijau, kuning, biru, magenta, cyan, putih, lalu versi terang.
        let ansi: [String]
        var isLight: Bool { id == "paper" || id == "sand" }
    }

    static let all: [Def] = [
        Def(id: "djie", name: "Djie Night", bg: "#0B0E13", fg: "#E6EDF3", accent: "#3FD0B4",
            ansi: ["#1B212A", "#F0616D", "#8BD450", "#F2C55A", "#5B9CF5", "#B48CF2", "#3FD0B4", "#C9D1D9",
                   "#4B5563", "#FF7B86", "#A6E36E", "#FFD77A", "#7DB3FF", "#CBA6FF", "#6EE7CF", "#FFFFFF"]),
        Def(id: "ocean", name: "Deep Ocean", bg: "#0A1628", fg: "#D6E4F5", accent: "#5B9CF5",
            ansi: ["#14243B", "#F07178", "#9ADE7B", "#FFCB6B", "#5B9CF5", "#C792EA", "#4FD6E8", "#C3D3E8",
                   "#3B4E6B", "#FF8B92", "#B5F09A", "#FFDB8E", "#82B6FF", "#DDB3FF", "#7DE8F5", "#FFFFFF"]),
        Def(id: "violet", name: "Violet Dusk", bg: "#14101F", fg: "#E9E2F7", accent: "#9D7CF2",
            ansi: ["#221B33", "#FF6B8B", "#7EE0A2", "#F5D07A", "#7A9CFF", "#C49BFF", "#6FD9E0", "#D9D0EC",
                   "#4A4063", "#FF8FA8", "#9FF0BC", "#FFE19C", "#9DB6FF", "#DCBDFF", "#93EBF0", "#FFFFFF"]),
        Def(id: "forest", name: "Forest Mist", bg: "#0E1612", fg: "#DCEADF", accent: "#7FD18B",
            ansi: ["#1A2620", "#E5786D", "#7FD18B", "#E3C76A", "#6FA8DC", "#C59AD9", "#6CCFBF", "#C8D8CC",
                   "#3E5247", "#F2958B", "#A0E3A9", "#F0DA8E", "#93C1E8", "#D8B6E6", "#8FE0D3", "#FFFFFF"]),
        Def(id: "ember", name: "Ember", bg: "#17110E", fg: "#F2E6DC", accent: "#F2A65A",
            ansi: ["#271D18", "#F0616D", "#B6D46B", "#F2A65A", "#7BA7E0", "#D88AC0", "#68C6B8", "#E0D2C5",
                   "#544036", "#FF8590", "#CBE68C", "#FFC07E", "#9CC0F0", "#EBA6D4", "#8ADBCE", "#FFFFFF"]),
        Def(id: "paper", name: "Paper Light", bg: "#F7F6F2", fg: "#24262B", accent: "#0F9D84",
            ansi: ["#24262B", "#C8323F", "#3C8A2E", "#A86E00", "#2462C4", "#8A3FC0", "#0F8C80", "#C7C4BC",
                   "#6B6E75", "#E04452", "#4FA63F", "#C48612", "#3A7BE0", "#A257D9", "#18A898", "#F7F6F2"]),
        Def(id: "sand", name: "Sand", bg: "#F3EDE2", fg: "#3A3226", accent: "#C46F2E",
            ansi: ["#3A3226", "#B83A3A", "#5E8A2E", "#B07A12", "#3567A8", "#8E4C9E", "#2F8A86", "#CFC6B6",
                   "#7A6F5E", "#D14F4F", "#73A33C", "#CC921F", "#4A80C4", "#A865B8", "#3BA39E", "#F3EDE2"]),
    ]

    /// Tanpa pilihan tema: ikut mode app (gelap → Djie Night, terang → Paper Light).
    @MainActor static func def(_ id: String?) -> Def {
        if let t = all.first(where: { $0.id == id }) { return t }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? all[0] : all.first { $0.id == "paper" }!
    }

    @MainActor static func apply(_ id: String?, to v: TerminalView) {
        let d = def(id)
        let bg = NSColor(Color(hex: d.bg))
        v.installColors(d.ansi.map { termColor($0) })
        v.nativeForegroundColor = NSColor(Color(hex: d.fg))
        v.nativeBackgroundColor = bg
        v.caretColor = NSColor(Color(hex: d.accent))
        v.selectedTextBackgroundColor = NSColor(Color(hex: d.accent)).withAlphaComponent(0.35)
        v.font = terminalFont
        // SwiftTerm hanya mengisi warna layer saat dibuat; perbarui manual supaya tema langsung terlihat.
        v.wantsLayer = true
        v.layer?.backgroundColor = bg.cgColor
        v.needsDisplay = true
    }

    /// JetBrains Mono + cadangan ikon Symbols Nerd Font (bawaan app) untuk prompt Oh My Posh / Starship.
    static let terminalFont: NSFont = {
        if let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // Font sistem (SF Mono) mengabaikan font cadangan saat menggambar, jadi cadangannya Menlo.
        let base = NSFont(name: "JetBrains Mono", size: 13) ?? NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let icons = NSFontDescriptor(fontAttributes: [.name: "SymbolsNFM"])
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [icons]]), size: 13) ?? base
    }()

    private static func termColor(_ hex: String) -> SwiftTerm.Color {
        let ns = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB) ?? .white
        return SwiftTerm.Color(red: UInt16(ns.redComponent * 65535), green: UInt16(ns.greenComponent * 65535),
                               blue: UInt16(ns.blueComponent * 65535))
    }
}
