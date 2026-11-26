import AppKit
import SwiftTerm
import SwiftUI

/// Satu tab terminal = satu proses SSH.
///
/// Tahap awal memakai `/usr/bin/ssh` bawaan macOS (mendukung key, agent, known_hosts, ProxyJump).
/// Nanti diganti SSH dari djie-core (russh) agar sama dengan versi Windows.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum Status: Equatable { case connecting, connected, disconnected(Int32?) }

    let id = UUID()
    let host: Host
    /// Terminal lokal (shell di Mac ini), bukan SSH.
    let isLocal: Bool
    var title: String
    /// Tema yang sedang dipakai tab ini (bisa diganti tanpa reconnect).
    var themeID: String?
    var status: Status = .connecting
    /// Saran perintah saat mengetik.
    let autocomplete: Autocomplete

    @ObservationIgnored private let key: SshKey?
    @ObservationIgnored private let jump: Host?
    @ObservationIgnored private let run: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var logID: String?
    @ObservationIgnored private var tempFiles: [URL] = []
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private(set) lazy var view: DjieTerminalView = makeView()

    init(host: Host, key: SshKey?, jump: Host?, run: String? = nil, model: AppModel? = nil, local: Bool = false) {
        self.host = host
        self.isLocal = local
        self.key = key
        self.jump = jump
        self.run = run
        self.model = model
        self.title = host.title
        self.themeID = host.terminalTheme
        self.autocomplete = Autocomplete(hostID: host.id)
    }

    func applyTheme(_ id: String?) {
        themeID = id
        TerminalThemes.apply(id, to: view)
    }

    /// Kirim teks ke terminal (dipakai snippet).
    func send(_ text: String) {
        view.send(txt: text)
    }

    // MARK: Lifecycle

    private func makeView() -> DjieTerminalView {
        let v = DjieTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        TerminalThemes.apply(themeID, to: v)
        let d = Delegate(session: self)
        delegate = d
        v.processDelegate = d
        autocomplete.view = v
        autocomplete.snippets = { [weak model] in model?.snippets ?? [] }
        // Password sudo = password login host yang tersimpan (bukan untuk terminal lokal)
        autocomplete.secret = { [weak self] in
            guard let self, !self.isLocal, let pw = self.host.password, !pw.isEmpty, !self.host.username.isEmpty else { return nil }
            return (self.host.username, pw)
        }
        v.onOutput = { [weak ac = autocomplete] in ac?.outputArrived() }
        v.onInput = { [weak self, weak ac = autocomplete] data in
            ac?.consume(data)
            if let self { self.model?.broadcastInput(from: self, data: data) }
        }

        v.onFirstData = { [weak self] in
            guard let self else { return }
            withAnimation(.djie) { self.status = .connected }
            let commands = [host.startupSnippet, run].compactMap { $0 }.filter { !$0.isEmpty }
            for (i, cmd) in commands.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.3) { v.send(txt: cmd + "\n") }
            }
        }
        start(in: v)
        return v
    }

    /// "Host" semu untuk tab terminal lokal (tidak disimpan di vault).
    static func localHost() -> Host {
        var h = Host.blank()
        h.id = "local"
        h.label = L("Lokal")
        h.hostname = "localhost"
        h.username = NSUserName()
        h.color = "#94A3B8"
        return h
    }

    private func start(in v: DjieTerminalView) {
        if isLocal {
            // Shell login pengguna di folder home, mis. -zsh
            let base = ProcessInfo.processInfo.environment
            let shell = base["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
            var env = base
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
            env["TERM_PROGRAM"] = "DjieShell"
            v.resetFirstData()
            status = .connecting
            v.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                           execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: NSHomeDirectory())
            return
        }
        let cmd = SSHCommand(host: host, key: key, jump: jump)
        tempFiles = cmd.tempFiles
        v.resetFirstData()
        status = .connecting
        logID = model?.logStart(host)
        v.startProcess(executable: "/usr/bin/ssh", args: cmd.args, environment: cmd.environment, execName: "ssh")
    }

    func reconnect() {
        cleanup()
        view.getTerminal().resetToInitialState()
        start(in: view)
    }

    func terminate() {
        if case .disconnected = status {} else {
            view.terminate()
            model?.logEnd(logID, code: nil)
            logID = nil
        }
        cleanup()
    }

    fileprivate func processEnded(_ raw: Int32?) {
        // SwiftTerm mengirim status mentah dari waitpid; ambil exit code-nya.
        let code = raw.map { $0 > 255 ? ($0 >> 8) & 0xFF : $0 }
        cleanup()
        model?.logEnd(logID, code: code)
        logID = nil
        withAnimation(.djie) { status = .disconnected(code) }
        view.feed(text: "\r\n\u{1b}[2m— " + L("sesi berakhir") + " —\u{1b}[0m\r\n")
    }

    private func cleanup() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
    }

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        weak var session: TerminalSession?
        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in if !title.isEmpty { self.session?.title = title } }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in self.session?.processEnded(exitCode) }
        }
    }
}

/// Terminal SwiftTerm dengan callback saat data pertama diterima (tanda sudah tersambung).
final class DjieTerminalView: LocalProcessTerminalView {
    var onFirstData: (() -> Void)?
    /// Semua input ke shell (ketikan, paste, snippet) — dipakai autocomplete.
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    /// Output baru dari shell (dipakai deteksi prompt password sudo).
    var onOutput: (() -> Void)?
    private var gotData = false
    private var sendingSecret = false

    /// Kirim rahasia (password sudo) langsung ke shell: tidak lewat autocomplete, riwayat, atau broadcast.
    func sendSecret(_ text: String) {
        sendingSecret = true
        defer { sendingSecret = false }
        send(txt: text)
    }

    func resetFirstData() { gotData = false }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        if !sendingSecret { onInput?(data) }
    }

    /// Ukuran satu sel karakter (untuk menaruh popup di posisi kursor).
    var cellSize: CGSize {
        let term = getTerminal()
        let h = getOptimalFrameSize().height / CGFloat(max(1, term.rows))
        let w = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: w, height: h)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let onOutput { DispatchQueue.main.async(execute: onOutput) }
        if !gotData {
            gotData = true
            DispatchQueue.main.async { self.onFirstData?() }
        }
    }

    // MARK: Copy / paste

    /// SwiftTerm tidak membuka status seleksi secara publik; validasi menu Copy-nya
    /// mengembalikan `true` hanya jika ada teks yang dipilih.
    var hasSelection: Bool {
        validateUserInterfaceItem(NSMenuItem(title: "", action: #selector(copy(_:)), keyEquivalent: ""))
    }

    func copySelection() {
        guard hasSelection else { return }
        copy(self)
    }

    func pasteClipboard() {
        guard NSPasteboard.general.string(forType: .string) != nil else { return }
        paste(self)
    }

    func clearScreen() {
        // Ctrl+L: shell membersihkan layar dan menggambar ulang prompt
        send(txt: "\u{0C}")
    }

    /// Menu klik kanan.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let copyItem = NSMenuItem(title: L("Salin"), action: #selector(menuCopy), keyEquivalent: "c")
        copyItem.isEnabled = hasSelection
        m.addItem(copyItem)
        m.addItem(NSMenuItem(title: L("Tempel"), action: #selector(menuPaste), keyEquivalent: "v"))
        m.addItem(NSMenuItem(title: L("Pilih Semua"), action: #selector(menuSelectAll), keyEquivalent: "a"))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: L("Bersihkan layar"), action: #selector(menuClear), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        m.autoenablesItems = false
        return m
    }

    @objc private func menuCopy() { copySelection() }
    @objc private func menuPaste() { pasteClipboard() }
    @objc private func menuSelectAll() { selectAll(nil) }
    @objc private func menuClear() { clearScreen() }
}

/// Susun argumen `ssh` dari data host.
struct SSHCommand {
    var args: [String] = []
    var environment: [String] = []
    var tempFiles: [URL] = []

    init(host: Host, key: SshKey?, jump: Host?, extra: [String] = []) {
        args = extra + [
            "-p", String(host.port),
            "-o", "ServerAliveInterval=30",
            // Terima host baru otomatis (TOFU), tolak jika fingerprint berubah.
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        #if DEBUG
        // Tes: known_hosts terpisah agar ~/.ssh/known_hosts pengguna tidak tersentuh
        if let kh = ProcessInfo.processInfo.environment["DJIE_TEST_KNOWN_HOSTS"] { args += ["-o", "UserKnownHostsFile=\(kh)"] }
        #endif
        if !host.username.isEmpty { args += ["-l", host.username] }
        if host.agentForwarding { args.append("-A") }
        if let jump { args += ["-J", "\(jump.username)@\(jump.hostname):\(jump.port)"] }
        // Proxy SOCKS5/HTTP: app ini sendiri jadi ProxyCommand (lihat main.swift).
        // Login proxy lewat environment, bukan argumen (tidak terlihat di `ps`).
        var proxyEnv: [String: String] = [:]
        if jump == nil, let p = host.proxy, !p.host.isEmpty, let exe = Bundle.main.executablePath {
            let kind = p.kind == .http ? "http" : "socks5"
            args += ["-o", "ProxyCommand=\"\(exe)\" --djie-proxy \(kind) \(p.host) \(p.port) %h %p"]
            if let u = p.username, !u.isEmpty { proxyEnv["DJIE_PROXY_USER"] = u }
            if let pw = p.password, !pw.isEmpty { proxyEnv["DJIE_PROXY_PASS"] = pw }
        }

        var secret: String?
        switch host.auth {
        case .password:
            secret = host.password
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive,publickey"]
        case .key:
            if let key, let file = Self.writeKey(key) {
                tempFiles.append(file)
                args += ["-i", file.path, "-o", "IdentitiesOnly=yes"]
                secret = key.passphrase
            }
        case .agent:
            break
        }
        for e in host.env where !e.name.isEmpty {
            args += ["-o", "SetEnv=\(e.name)=\(e.value)"]
        }
        args.append(host.hostname)

        // Environment proses
        let base = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": host.charset.uppercased() == "UTF-8" ? "en_US.UTF-8" : "C",
            "HOME": base["HOME"] ?? NSHomeDirectory(),
            "USER": base["USER"] ?? NSUserName(),
            "PATH": base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if let sock = base["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = sock }
        env.merge(proxyEnv) { $1 }
        // Password / passphrase dikirim lewat helper askpass, bukan argumen (tidak terlihat di `ps`).
        if let secret, !secret.isEmpty, let askpass = Self.askpassScript() {
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
            env["DJIE_SECRET"] = secret
        }
        environment = env.map { "\($0.key)=\($0.value)" }
    }

    /// Tulis private key ke file sementara (izin 0600), dihapus saat sesi berakhir.
    private static func writeKey(_ key: SshKey) -> URL? {
        let dir = Config.appSupport.appendingPathComponent("session-keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(UUID().uuidString)
        let pem = key.privateKey.hasSuffix("\n") ? key.privateKey : key.privateKey + "\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(pem.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }

    /// Skrip kecil yang menjawab prompt password/passphrase dari variabel DJIE_SECRET.
    private static func askpassScript() -> URL? {
        let url = Config.appSupport.appendingPathComponent("askpass.sh")
        let script = """
        #!/bin/sh
        case "$1" in
          *assword*|*assphrase*|*PIN*) printf '%s\\n' "$DJIE_SECRET" ;;
          *) exit 1 ;;
        esac
        """
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else { return nil }
        return url
    }
}
