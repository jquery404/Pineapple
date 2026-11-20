import AppKit
import SwiftUI

/// Small always-on-top window that floats over every app, including full-screen Zoom/Meet.
final class FloatingPanel: NSPanel {
    init(transcript: Transcript,
         onToggle: @escaping () -> Void,
         onMode: @escaping (ListenMode) -> Void,
         onAnswer: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Pineapple"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: TranscriptView(transcript: transcript, onToggle: onToggle,
                                                             onMode: onMode, onAnswer: onAnswer))

        if !setFrameUsingName("PineapplePanel"), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 20, y: screen.maxY - frame.height - 20))
        }
        setFrameAutosaveName("PineapplePanel")
    }

    override var canBecomeKey: Bool { true }
}

struct TranscriptView: View {
    @ObservedObject var transcript: Transcript
    var onToggle: () -> Void
    var onMode: (ListenMode) -> Void
    var onAnswer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if transcript.lines.isEmpty && transcript.partial.isEmpty {
                            Text(transcript.isRunning ? "Listening…" : "Press Start to transcribe.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(transcript.lines) { line in
                            if line.speaker == .answer {
                                answerCard(line.text, live: false)
                            } else {
                                row(line.speaker, line.text, partial: false)
                            }
                        }
                        ForEach([Speaker.me, .them], id: \.self) { speaker in
                            if let text = transcript.partial[speaker], !text.isEmpty {
                                row(speaker, text, partial: true)
                            }
                        }
                        if let draft = transcript.answerDraft {
                            answerCard(draft.isEmpty ? "Thinking…" : draft, live: true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: transcript.lines.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: transcript.partial) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: transcript.answerDraft) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 320, minHeight: 180)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(transcript.isRunning ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(transcript.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .help(transcript.status)
            if transcript.isRunning, let lag = transcript.lag {
                Text(String(format: "delay %.1fs", lag))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(lag < 1.5 ? .green : .orange)
                    .help("How far the text is behind the voice")
            }
            Spacer()
            Picker("", selection: Binding(get: { transcript.mode }, set: { onMode($0) })) {
                ForEach(ListenMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Who to transcribe")
            Button(transcript.isRunning ? "Stop" : "Start", action: onToggle)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundColor(.orange)
            Text(transcript.brainStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .help(transcript.brainStatus)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.plainText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            Button(action: onAnswer) {
                Label("Answer", systemImage: "sparkles")
            }
            .controlSize(.small)
            .help("Suggest what to say to the last thing they said")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func row(_ speaker: Speaker, _ text: String, partial: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker.rawValue)
                .font(.caption.bold())
                .foregroundColor(speaker == .me ? .accentColor : .green)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .foregroundColor(partial ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerCard(_ text: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(live ? "Say (writing…)" : "Say", systemImage: "sparkles")
                .font(.caption.bold())
                .foregroundColor(.orange)
            Text(text)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
    }
}
