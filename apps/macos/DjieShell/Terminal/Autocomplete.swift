import AppKit
import SwiftTerm
import SwiftUI

enum AutocompleteKeys {
    static let enabled = "terminal.autocomplete"
}

/// Riwayat perintah per host. Hanya di Mac ini (tidak ikut sync), file dengan izin 0600.
enum CommandHistory {
    private static let limit = 500
    private static var cache: [String: [String]]?

    private static var url: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["DJIE_HISTORY_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("command-history.json")
        }
        #endif
        return Config.appSupport.appendingPathComponent("command-history.json")
    }

    private static func all() -> [String: [String]] {
        if let cache { return cache }
        let loaded = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))) ?? [:]
        cache = loaded
        return loaded
    }

    static func commands(for hostID: String) -> [String] { all()[hostID] ?? [] }

    static func add(_ command: String, hostID: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        // Perintah diawali spasi tidak disimpan (konvensi HISTCONTROL=ignorespace)
        guard cmd.count >= 2, !command.hasPrefix(" ") else { return }
        var map = all()
        var list = map[hostID] ?? []
        list.removeAll { $0 == cmd }
        list.insert(cmd, at: 0)
        map[hostID] = Array(list.prefix(limit))
        cache = map
        save(map)
    }

    static func clear() {
        cache = [:]
        try? FileManager.default.removeItem(at: url)
    }

    static var count: Int { all().values.reduce(0) { $0 + $1.count } }

    private static func save(_ map: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Saran perintah ala Termius: riwayat host, snippet, dan perintah umum.
@MainActor
@Observable
final class Autocomplete {
    struct Suggestion: Hashable, Identifiable {
        enum Kind { case history, snippet, command }
        let text: String
        let kind: Kind
        var label: String?
        var id: String { "\(kind)-\(text)" }
    }

    /// Baris yang sedang diketik (dilacak dari input keyboard).
    private(set) var buffer = ""
    private(set) var items: [Suggestion] = []
    var index = 0
    /// Posisi kursor (kolom, baris) di layar terminal untuk menaruh popup.
    private(set) var caret: (col: Int, row: Int) = (0, 0)

    var visible: Bool { !items.isEmpty }
    /// Popup apa pun (saran perintah atau tawaran password sudo) sedang tampil.
    var active: Bool { visible || sudo != nil }

    /// Prompt password sudo terdeteksi untuk user host ini → tawarkan password tersimpan.
    struct SudoOffer: Equatable { let user: String }
    private(set) var sudo: SudoOffer?
    /// Password tersimpan host ini (nil = tidak ada / terminal lokal). Hanya dibaca saat diperlukan.
    @ObservationIgnored var secret: () -> (user: String, password: String)? = { nil }
    @ObservationIgnored private var lastCommand = ""
    @ObservationIgnored private var sudoDismissed = false
    @ObservationIgnored private var promptCheck: DispatchWorkItem?

    @ObservationIgnored private var tracking = true
    @ObservationIgnored private var dismissed = false
    @ObservationIgnored private var inPaste = false
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private let hostID: String
    @ObservationIgnored weak var view: DjieTerminalView?
    @ObservationIgnored var snippets: () -> [Snippet] = { [] }

    init(hostID: String) {
        self.hostID = hostID
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: AutocompleteKeys.enabled) as? Bool ?? true }

    // MARK: Input

    /// Dipanggil untuk setiap byte yang dikirim ke shell (ketikan, paste, snippet).
    func consume(_ data: ArraySlice<UInt8>) {
        var text = String(decoding: data, as: UTF8.self)
        // Mengetik sendiri di prompt password → tawaran ditutup
        if sudo != nil, !SudoPrompt.isTerminalReply(text) {
            sudoDismissed = true
            withAnimation(.djieSnappy) { sudo = nil }
        }

        // Bracketed paste: isi paste dianggap ketikan biasa
        if text.contains("\u{1b}[200~") || text.contains("\u{1b}[201~") {
            text = text.replacingOccurrences(of: "\u{1b}[200~", with: "").replacingOccurrences(of: "\u{1b}[201~", with: "")
        } else if text.hasPrefix("\u{1b}") {
            // Panah, Home/End, dsb.: isi baris tidak bisa dipastikan lagi sampai Enter
            tracking = false
            hide()
            return
        }

        for ch in text.unicodeScalars {
            switch ch.value {
            case 0x0D, 0x0A:
                commit()
            case 0x7F, 0x08:
                if !buffer.isEmpty { buffer.removeLast() }
            case 0x03, 0x15, 0x04:  // Ctrl-C, Ctrl-U, Ctrl-D: baris kosong lagi
                reset()
            case 0x17:  // Ctrl-W: hapus satu kata
                while buffer.last == " " { buffer.removeLast() }
                while let l = buffer.last, l != " " { buffer.removeLast() }
            case 0x09:  // Tab: shell melengkapi sendiri → baris tidak pasti
                tracking = false
            case 0..<0x20:
                tracking = false
            default:
                buffer.unicodeScalars.append(ch)
            }
        }
        dismissed = false
        schedule()
    }

    private func reset() {
        buffer = ""
        tracking = true
        dismissed = false
        hide()
    }

    private func commit() {
        if tracking, isEchoed(buffer), let view, !view.getTerminal().isCurrentBufferAlternate {
            CommandHistory.add(buffer, hostID: hostID)
        }
        lastCommand = tracking ? buffer : ""
        sudoDismissed = false
        reset()
    }

    // MARK: Password sudo

    /// Dipanggil saat output baru masuk: periksa apakah baris kursor adalah prompt password sudo.
    func outputArrived() {
        promptCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkPrompt() }
        promptCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func checkPrompt() {
        guard enabled, let view, !view.getTerminal().isCurrentBufferAlternate else { setSudo(nil); return }
        let term = view.getTerminal()
        let cur = term.getCursorLocation()
        let line = term.getLine(row: cur.y)?.translateToString(trimRight: false, startCol: 0, endCol: cur.x) ?? ""
        guard let user = SudoPrompt.user(in: line, lastCommand: lastCommand, hostUser: secret()?.user) else {
            sudoDismissed = false
            setSudo(nil)
            return
        }
        guard !sudoDismissed, let s = secret(), s.user == user else { setSudo(nil); return }
        caret = (cur.x, cur.y)
        hide()
        setSudo(SudoOffer(user: user))
    }

    private func setSudo(_ offer: SudoOffer?) {
        guard offer != sudo else { return }
        withAnimation(.djieSnappy) { sudo = offer }
    }

    /// Kirim password tersimpan ke prompt sudo (tidak ikut broadcast / riwayat).
    func fillSudo() {
        guard sudo != nil, let s = secret(), let view else { return }
        sudoDismissed = true
        setSudo(nil)
        view.sendSecret(s.password + "\r")
        view.window?.makeFirstResponder(view)
    }

    /// Tunggu sebentar sampai shell menampilkan (echo) ketikan, baru hitung saran.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    /// Ketikan benar-benar tampil di layar? Prompt password tidak meng-echo → tidak ada saran & tidak disimpan.
    private func isEchoed(_ typed: String) -> Bool {
        guard let view, !typed.isEmpty else { return false }
        let term = view.getTerminal()
        let cur = term.getCursorLocation()
        guard let line = term.getLine(row: cur.y) else { return false }
        let before = line.translateToString(trimRight: false, startCol: 0, endCol: cur.x)
        // Perintah panjang yang membungkus ke baris berikutnya: cukup cocokkan ujungnya
        let tail = String(typed.suffix(max(1, min(typed.count, cur.x))))
        return before.hasSuffix(tail)
    }

    private func refresh() {
        guard enabled, tracking, !dismissed, let view,
              !buffer.trimmingCharacters(in: .whitespaces).isEmpty,
              !view.getTerminal().isCurrentBufferAlternate,
              isEchoed(buffer) else { hide(); return }
        let term = view.getTerminal()
        let cur = term.getCursorLocation()
        let next = suggestions(for: buffer)
        withAnimation(.djieSnappy) {
            caret = (cur.x, cur.y)
            if next.map(\.id) != items.map(\.id) { index = 0 }
            items = next
        }
    }

    func hide() {
        pending?.cancel()
        if !items.isEmpty { withAnimation(.djieSnappy) { items = [] } }
    }

    // MARK: Pencocokan

    private func suggestions(for typed: String) -> [Suggestion] {
        let history = CommandHistory.commands(for: hostID).map { Suggestion(text: $0, kind: .history) }
        let snips = snippets().map { Suggestion(text: $0.command, kind: .snippet, label: $0.label) }
        let commands = Self.common.map { Suggestion(text: $0, kind: .command) }
        let pool = history + snips + commands

        var seen = Set<String>()
        var out: [Suggestion] = []
        func take(_ s: Suggestion) {
            guard out.count < 6, s.text != typed, !seen.contains(s.text) else { return }
            seen.insert(s.text)
            out.append(s)
        }
        // 1. Awalan sama persis (riwayat terbaru dulu), 2. awalan tanpa beda huruf besar, 3. mengandung (≥3 huruf)
        pool.filter { $0.text.hasPrefix(typed) }.forEach(take)
        pool.filter { $0.text.lowercased().hasPrefix(typed.lowercased()) }.forEach(take)
        if typed.count >= 3 {
            pool.filter { $0.text.localizedCaseInsensitiveContains(typed) }.forEach(take)
            // Snippet juga dicari lewat namanya
            snips.filter { ($0.label ?? "").localizedCaseInsensitiveContains(typed) }.forEach(take)
        }
        return out
    }

    // MARK: Keyboard

    /// Tab / → menerima, ↑↓ memilih, Esc menutup. `true` = tombol dipakai popup.
    func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if sudo != nil, mods.isEmpty {
            switch event.keyCode {
            case 48: fillSudo(); return true  // Tab
            case 53: sudoDismissed = true; setSudo(nil); return true  // Esc
            default: return false
            }
        }
        guard visible else { return false }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 48, 124:  // Tab, →
            accept(index)
        case 125:  // ↓
            withAnimation(.djieSnappy) { index = (index + 1) % items.count }
        case 126:  // ↑
            withAnimation(.djieSnappy) { index = (index - 1 + items.count) % items.count }
        case 53:  // Esc
            dismissed = true
            hide()
        default:
            return false
        }
        return true
    }

    func accept(_ i: Int) {
        guard items.indices.contains(i), let view else { return }
        let s = items[i].text
        hide()
        if s.hasPrefix(buffer) {
            view.send(txt: String(s.dropFirst(buffer.count)))
        } else {
            // Ctrl-U kosongkan baris, lalu ketik saran lengkap
            view.send(txt: "\u{15}" + s)
        }
        view.window?.makeFirstResponder(view)
    }

    /// Perintah umum Linux/server.
    static let common: [String] = [
        "ls -la", "ls -lah", "cd ..", "cd ~", "pwd", "clear", "exit", "history",
        "cat /etc/os-release", "uname -a", "uptime", "whoami", "hostname -I",
        "df -h", "du -sh *", "du -sh .[!.]* * | sort -h", "free -h", "top", "htop", "ps aux | grep ",
        "kill -9 ", "lsof -i :", "ss -tulpn", "netstat -tulpn", "ip a", "ping -c 4 ", "curl -I ", "wget ",
        "tail -f /var/log/syslog", "tail -n 100 -f ", "journalctl -u ", "journalctl -xe", "dmesg | tail",
        "systemctl status ", "systemctl restart ", "systemctl start ", "systemctl stop ", "systemctl enable ",
        "systemctl list-units --type=service --state=running", "service nginx reload",
        "sudo apt update && sudo apt upgrade -y", "sudo apt install ", "sudo yum install ", "sudo dnf install ",
        "sudo -i", "sudo su -", "chmod +x ", "chmod -R 755 ", "chown -R www-data:www-data ",
        "tar -czvf arsip.tar.gz ", "tar -xzvf ", "unzip ", "zip -r arsip.zip ",
        "find . -name \"*.log\"", "grep -rn \"\" .", "nano ", "vim ", "less ", "mkdir -p ", "rm -rf ", "cp -r ", "mv ",
        "scp ", "rsync -avz ", "ssh-keygen -t ed25519", "crontab -e", "crontab -l",
        "docker ps", "docker ps -a", "docker images", "docker logs -f ", "docker exec -it  bash", "docker compose up -d",
        "docker compose down", "docker compose logs -f", "docker compose ps", "docker system prune -af", "docker stats",
        "git status", "git pull", "git log --oneline -10", "git diff", "git checkout ", "git branch -a",
        "nginx -t", "sudo nginx -t && sudo systemctl reload nginx", "certbot renew --dry-run",
        "pm2 list", "pm2 logs", "pm2 restart all", "php artisan migrate", "php artisan cache:clear",
        "composer install", "npm install", "npm run build", "npm run dev",
        "mysql -u root -p", "psql -U postgres", "redis-cli", "ufw status", "sudo ufw allow ",
        "kubectl get pods -A", "kubectl get svc", "kubectl logs -f ", "kubectl describe pod ",
    ]
}

/// Pengenal prompt password sudo (dipakai Mac; logika yang sama ada di term.js Windows).
enum SudoPrompt {
    /// "[sudo] password for deploy:" / "[sudo] kata sandi untuk deploy:"
    private static let named = try! NSRegularExpression(
        pattern: #"^\[sudo\] (?:password|kata sandi|sandi) (?:for|untuk) (\S+?)\s*:\s*$"#, options: [.caseInsensitive])
    /// "Password:" polos — hanya dianggap sudo jika perintah terakhir diawali `sudo`.
    private static let plain = try! NSRegularExpression(pattern: #"^(?:\[sudo\] )?(?:password|kata sandi)\s*:\s*$"#, options: [.caseInsensitive])

    /// User yang diminta password-nya, atau nil jika baris ini bukan prompt sudo.
    static func user(in line: String, lastCommand: String, hostUser: String?) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(text.startIndex..., in: text)
        if let m = named.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
        let cmd = lastCommand.trimmingCharacters(in: .whitespaces)
        if plain.firstMatch(in: text, range: range) != nil, cmd == "sudo" || cmd.hasPrefix("sudo ") {
            return hostUser
        }
        return nil
    }

    /// Balasan otomatis terminal (posisi kursor, fokus) — bukan ketikan pengguna.
    static func isTerminalReply(_ s: String) -> Bool {
        s.range(of: #"^(\x1b\[\??[\d;]*[Rcn]|\x1b\[[IO])+$"#, options: .regularExpression) != nil
    }
}

/// Tawaran mengisi password sudo dari host yang tersimpan.
struct SudoPopup: View {
    let ac: Autocomplete
    let hostTitle: String
    let cell: CGSize
    let paneSize: CGSize
    let theme: TerminalThemes.Def

    private let width: CGFloat = 320

    var body: some View {
        let height: CGFloat = 76
        let x = min(max(10, 10 + CGFloat(ac.caret.col) * cell.width - 14), max(10, paneSize.width - width - 12))
        let below = 6 + CGFloat(ac.caret.row + 1) * cell.height + 4
        let y = below + height > paneSize.height - 8 ? max(4, 6 + CGFloat(ac.caret.row) * cell.height - height - 4) : below

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Isi password tersimpan")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text("\(ac.sudo?.user ?? "")@\(hostTitle)").font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { ac.fillSudo() }
            HStack(spacing: 10) {
                hint("⇥", L("isi password"))
                hint("esc", L("tutup"))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .padding(2)
        .frame(width: width, alignment: .leading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(SwiftUI.Color(hex: theme.bg).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .offset(x: x, y: y)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)), removal: .opacity))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(SwiftUI.Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }
}

/// Popup saran di dekat kursor terminal.
struct AutocompletePopup: View {
    let ac: Autocomplete
    let cell: CGSize
    let paneSize: CGSize
    let theme: TerminalThemes.Def

    private let rowHeight: CGFloat = 30
    private let width: CGFloat = 440

    var body: some View {
        let height = CGFloat(ac.items.count) * rowHeight + 34
        let x = min(max(10, 10 + CGFloat(ac.caret.col) * cell.width - 14), max(10, paneSize.width - width - 12))
        let below = 6 + CGFloat(ac.caret.row + 1) * cell.height + 4
        let y = below + height > paneSize.height - 8 ? max(4, 6 + CGFloat(ac.caret.row) * cell.height - height - 4) : below

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ac.items.enumerated()), id: \.element.id) { i, s in
                row(s, selected: i == ac.index)
                    .onTapGesture { ac.accept(i) }
                    .onHover { if $0 { ac.index = i } }
            }
            HStack(spacing: 10) {
                hint("⇥", L("terima"))
                hint("↑↓", L("pilih"))
                hint("esc", L("tutup"))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SwiftUI.Color.white.opacity(0.03))
        }
        .padding(2)
        .frame(width: width, alignment: .leading)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(SwiftUI.Color(hex: theme.bg).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .offset(x: x, y: y)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)),
                                removal: .opacity))
    }

    private func row(_ s: Autocomplete.Suggestion, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon(s.kind))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(kindColor(s.kind))
                .frame(width: 20, height: 20)
                .background(kindColor(s.kind).opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            highlighted(s.text)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let label = s.label {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            } else if s.kind == .history {
                Text(L("riwayat")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(selected ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Bagian yang sudah diketik tebal, sisanya (yang akan ditambahkan) redup.
    private func highlighted(_ text: String) -> Text {
        let typed = ac.buffer
        if text.hasPrefix(typed) {
            return Text(typed).foregroundStyle(.white).bold() + Text(text.dropFirst(typed.count)).foregroundStyle(Theme.accent)
        }
        return Text(text).foregroundStyle(.white.opacity(0.85))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(SwiftUI.Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }

    private func icon(_ k: Autocomplete.Suggestion.Kind) -> String {
        switch k {
        case .history: "clock.arrow.circlepath"
        case .snippet: "curlybraces"
        case .command: "terminal"
        }
    }

    private func kindColor(_ k: Autocomplete.Suggestion.Kind) -> SwiftUI.Color {
        switch k {
        case .history: Theme.accent
        case .snippet: SwiftUI.Color(hex: "#8B5CF6")
        case .command: Theme.accent2
        }
    }
}
