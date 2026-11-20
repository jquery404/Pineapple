import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let transcript = Transcript()
    private lazy var brain = Brain(transcript: transcript)
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!

    private var mic: MicCapture?
    private var systemAudio: SystemAudioCapture?
    private var clients: [Speaker: TranscribeClient] = [:]
    private var failedConnects: [Speaker: Int] = [:]
    private var lags: [Speaker: Double] = [:]
    private var echoFilter = EchoFilter()
    private var file: TranscriptFile?
    private var credentials: AWSCredentials?
    private var wantRunning = false
    private var themNote: String?

    private let defaults = UserDefaults.standard
    private var awsProfile: String {
        get { defaults.string(forKey: "awsProfile") ?? "default" }
        set { defaults.set(newValue, forKey: "awsProfile") }
    }
    private var languageCode: String {
        get { defaults.string(forKey: "languageCode") ?? "en-AU" }
        set { defaults.set(newValue, forKey: "languageCode") }
    }
    private var echoCancellation: Bool {
        get { defaults.bool(forKey: "echoCancellation") }
        set { defaults.set(newValue, forKey: "echoCancellation") }
    }
    private var listenMode: ListenMode {
        get { defaults.string(forKey: "listenMode").flatMap(ListenMode.init(rawValue:)) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "listenMode") }
    }
    private var autoAnswer: Bool {
        get { defaults.object(forKey: "autoAnswer") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoAnswer") }
    }
    private var model: String {
        get {
            let saved = defaults.string(forKey: "model")
            return Brain.models.contains { $0.0 == saved } ? saved! : Brain.models[0].0
        }
        set { defaults.set(newValue, forKey: "model") }
    }
    private static let menuBarImage = PineappleIcon.menuBarIcon()
    private static let languages = [("en-AU", "English (Australia/NZ)"), ("en-GB", "English (UK)"), ("en-US", "English (US)")]

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        transcript.mode = listenMode
        brain.model = model
        brain.onAnswer = { [weak self] text in self?.addAnswer(text) }
        brain.reload()
        loadCredentials()

        panel = FloatingPanel(transcript: transcript,
                              onToggle: { [weak self] in self?.toggle() },
                              onMode: { [weak self] mode in self?.setMode(mode) },
                              onAnswer: { [weak self] in self?.brain.answer(nil) })
        panel.orderFrontRegardless()
    }

    @discardableResult
    private func loadCredentials() -> Bool {
        do {
            let credentials = try AWSCredentials.load(profile: awsProfile)
            self.credentials = credentials
            brain.setCredentials(credentials)
            return true
        } catch {
            transcript.status = error.localizedDescription
            return false
        }
    }

    /// Accessory apps have no menu bar of their own; this gives text fields Cmd-C/V/A.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Pineapple", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(wantRunning ? "Stop Listening" : "Start Listening", #selector(toggle)))
        menu.addItem(item(panel.isVisible ? "Hide Window" : "Show Window", #selector(togglePanel)))
        menu.addItem(submenu("Transcribe", ListenMode.allCases.map { ($0.rawValue, $0.title) },
                             selected: listenMode.rawValue, action: #selector(chooseMode(_:))))
        menu.addItem(.separator())

        menu.addItem(item("Suggest an Answer Now", #selector(answerNow)))
        let auto = item("Auto-Answer Their Questions", #selector(toggleAutoAnswer))
        auto.state = autoAnswer ? .on : .off
        menu.addItem(auto)
        menu.addItem(item("Open Knowledge Folder", #selector(openKnowledge)))
        menu.addItem(item("Open Style Folder", #selector(openStyle)))
        menu.addItem(item("Reload Knowledge and Style", #selector(reloadKnowledge)))
        menu.addItem(submenu("Answer Model", Brain.models, selected: model, action: #selector(chooseModel(_:))))
        menu.addItem(.separator())

        menu.addItem(item("Copy Transcript", #selector(copyTranscript)))
        menu.addItem(item("Clear Window", #selector(clearWindow)))
        menu.addItem(item("Open Transcripts Folder", #selector(openFolder)))
        menu.addItem(.separator())

        menu.addItem(submenu("Language", Self.languages, selected: languageCode, action: #selector(chooseLanguage(_:))))
        let ec = item("Apple Echo Cancellation (lowers other audio)", #selector(toggleEchoCancellation))
        ec.state = echoCancellation ? .on : .off
        menu.addItem(ec)
        menu.addItem(item("AWS Profile: \(awsProfile)…", #selector(askForProfile)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pineapple", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ options: [(String, String)], selected: String, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (value, name) in options {
            let i = item(name, action)
            i.representedObject = value
            i.state = value == selected ? .on : .off
            menu.addItem(i)
        }
        parent.submenu = menu
        return parent
    }

    // MARK: start / stop

    @objc func toggle() {
        wantRunning ? stop() : start()
    }

    private func start() {
        if listenMode.usesMic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted { self.start() } else { self.transcript.status = "Microphone access denied" }
                    }
                }
                return
            default:
                transcript.status = "Microphone blocked. Allow Pineapple in System Settings → Privacy & Security → Microphone."
                return
            }
        }
        guard loadCredentials() else { return }
        brain.reload()

        wantRunning = true
        failedConnects = [:]
        lags = [:]
        themNote = nil
        echoFilter = EchoFilter()
        transcript.isRunning = true
        transcript.lag = nil
        transcript.status = "Connecting…"
        file = TranscriptFile()

        if listenMode.usesMic { startMe() }
        if listenMode.usesSystemAudio { startThem() }
        updateIcon()
    }

    private func startMe() {
        connect(.me)
        let mic = MicCapture(echoCancellation: echoCancellation)
        mic.onChunk = { [weak self] chunk in self?.clients[.me]?.send(pcm: chunk) }
        do {
            try mic.start()
            self.mic = mic
        } catch {
            fail("Microphone error: \(error.localizedDescription)")
        }
    }

    private func stopMe() {
        mic?.stop()
        mic = nil
        finishStream(.me)
    }

    private func startThem() {
        guard SystemAudioCapture.hasPermission else {
            SystemAudioCapture.requestPermission()
            themNote = "Can't hear other people yet. Allow Pineapple in System Settings → Privacy & Security → Screen Recording, then quit and reopen Pineapple."
            refreshStatus()
            return
        }
        let capture = SystemAudioCapture()
        capture.onChunk = { [weak self] chunk in self?.clients[.them]?.send(pcm: chunk) }
        capture.onStopped = { [weak self] message in
            guard let self, self.wantRunning else { return }
            self.themNote = "Stopped hearing other people: \(message)"
            self.systemAudio = nil
            self.clients[.them]?.close()
            self.refreshStatus()
        }
        systemAudio = capture
        connect(.them)
        capture.start { [weak self] error in
            guard let self, let error else { return }
            self.systemAudio = nil
            self.clients[.them]?.close()
            self.themNote = "Can't capture Mac audio: \(error.localizedDescription)"
            self.refreshStatus()
        }
    }

    private func stopThem() {
        systemAudio?.stop()
        systemAudio = nil
        themNote = nil
        finishStream(.them)
    }

    /// Lets Transcribe finalise the last sentence, then closes that stream.
    private func finishStream(_ speaker: Speaker) {
        guard let client = clients[speaker] else { return }
        client.endStream()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { client.close() }
    }

    private func connect(_ speaker: Speaker) {
        guard let credentials else { return }
        let client = TranscribeClient(credentials: credentials, languageCode: languageCode)
        client.onOpen = { [weak self] in
            self?.refreshStatus()
        }
        client.onPartial = { [weak self] text in
            self?.partial(speaker, text)
        }
        client.onFinal = { [weak self] text in
            self?.final(speaker, text)
        }
        client.onLag = { [weak self] lag in
            guard let self else { return }
            self.lags[speaker] = lag
            self.transcript.lag = self.lags.values.max()
        }
        client.onError = { [weak self] message, fatal in
            guard let self else { return }
            if fatal { self.fail(message) } else { self.transcript.status = message }
        }
        client.onClosed = { [weak self, weak client] opened in
            guard let self, let client, self.clients[speaker] === client else { return }
            self.clients[speaker] = nil
            self.lags[speaker] = nil
            // Only reconnect while that stream's audio source is still running.
            let sourceRunning = speaker == .me ? self.mic != nil : self.systemAudio != nil
            guard self.wantRunning, sourceRunning else { return }
            // Transcribe sessions end (time limit, network blip): reconnect straight away.
            let failures = opened ? 0 : (self.failedConnects[speaker] ?? 0) + 1
            self.failedConnects[speaker] = failures
            if failures >= 5 {
                self.fail("Can't connect to Amazon Transcribe. Check your internet connection.")
                return
            }
            self.transcript.status = "Reconnecting…"
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures)) {
                if self.wantRunning && self.clients[speaker] == nil { self.connect(speaker) }
            }
        }
        clients[speaker] = client
        client.connect()
    }

    private func refreshStatus() {
        guard wantRunning else { return }
        if let themNote {
            transcript.status = themNote
        } else {
            switch (mic != nil, systemAudio != nil) {
            case (true, true): transcript.status = "Listening to you and them"
            case (true, false): transcript.status = "Listening to you"
            case (false, true): transcript.status = "Listening to them"
            case (false, false): transcript.status = "Not listening"
            }
        }
    }

    private func setMode(_ mode: ListenMode) {
        listenMode = mode
        transcript.mode = mode
        guard wantRunning else { return }
        if mode.usesMic, mic == nil { startMe() }
        if !mode.usesMic, mic != nil { stopMe() }
        if mode.usesSystemAudio, systemAudio == nil { startThem() }
        if !mode.usesSystemAudio, systemAudio != nil || themNote != nil { stopThem() }
        refreshStatus()
    }

    // MARK: transcript

    private func partial(_ speaker: Speaker, _ text: String) {
        if speaker == .me, systemAudio != nil, echoFilter.isEcho(text, themPartial: transcript.partial[.them]) {
            transcript.partial[.me] = nil
            return
        }
        transcript.partial[speaker] = text
    }

    private func final(_ speaker: Speaker, _ text: String) {
        if speaker == .them {
            echoFilter.addThem(text)
        } else if systemAudio != nil, echoFilter.isEcho(text, themPartial: transcript.partial[.them]) {
            transcript.partial[.me] = nil
            return
        }
        commit(speaker, text)
        if speaker == .them, autoAnswer, Brain.isQuestion(text) {
            brain.answer(text)
        }
    }

    private func addAnswer(_ text: String) {
        guard !text.lowercased().hasPrefix("(no answer needed") else {
            transcript.brainStatus = "No answer needed"
            return
        }
        commit(.answer, text)
    }

    private func commit(_ speaker: Speaker, _ text: String) {
        transcript.partial[speaker] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = Line(speaker: speaker, text: trimmed, time: Date())
        transcript.lines.append(line)
        file?.append(line)
    }

    private func stop() {
        wantRunning = false
        mic?.stop()
        mic = nil
        systemAudio?.stop()
        systemAudio = nil
        transcript.isRunning = false
        updateIcon()

        let open = Array(clients.values)
        guard !open.isEmpty else { finishSession(); return }
        // Let Transcribe finalise the last sentence before closing.
        transcript.status = "Finishing…"
        open.forEach { $0.endStream() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            open.forEach { $0.close() }
            if let self, !self.wantRunning { self.finishSession() }
        }
    }

    private func fail(_ message: String) {
        wantRunning = false
        mic?.stop()
        mic = nil
        systemAudio?.stop()
        systemAudio = nil
        clients.values.forEach { $0.close() }
        clients = [:]
        transcript.isRunning = false
        finishSession()
        transcript.status = message
        updateIcon()
    }

    private func finishSession() {
        for (speaker, text) in transcript.partial { commit(speaker, text) }
        if let file {
            file.finish()
            transcript.status = file.lineCount > 0 ? "Saved to Documents/Pineapple/\(file.url.lastPathComponent)" : "Stopped"
        } else {
            transcript.status = "Stopped"
        }
        file = nil
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage
        button.contentTintColor = wantRunning ? .systemRed : nil  // red while transcribing
    }

    // MARK: menu actions

    @objc private func togglePanel() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ListenMode(rawValue: raw) else { return }
        setMode(mode)
    }

    @objc private func answerNow() {
        brain.answer(nil)
    }

    @objc private func toggleAutoAnswer() {
        autoAnswer.toggle()
    }

    @objc private func openKnowledge() {
        KnowledgeBase.createFoldersIfNeeded()
        NSWorkspace.shared.open(KnowledgeBase.knowledgeFolder)
    }

    @objc private func openStyle() {
        KnowledgeBase.createFoldersIfNeeded()
        NSWorkspace.shared.open(KnowledgeBase.styleFolder)
    }

    @objc private func reloadKnowledge() {
        brain.reload()
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        model = value
        brain.model = value
    }

    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText, forType: .string)
    }

    @objc private func clearWindow() {
        brain.cancel()
        transcript.lines.removeAll()
        transcript.partial.removeAll()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: TranscriptFile.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(TranscriptFile.folder)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        languageCode = code
        restartIfRunning()
    }

    @objc private func toggleEchoCancellation() {
        echoCancellation.toggle()
        restartIfRunning()
    }

    @objc private func askForProfile() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AWS profile"
        alert.informativeText = "The profile in ~/.aws/credentials used for Amazon Transcribe and Bedrock."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = awsProfile
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            awsProfile = value
            loadCredentials()
            restartIfRunning()
        }
    }

    private func restartIfRunning() {
        guard wantRunning else { return }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.start() }
    }

    @objc private func quit() {
        let wasRunning = wantRunning
        if wasRunning { stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasRunning ? 2.2 : 0)) { NSApp.terminate(nil) }
    }
}
