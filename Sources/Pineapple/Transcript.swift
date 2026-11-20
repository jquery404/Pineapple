import Foundation

enum Speaker: String {
    case me = "Me"
    case them = "Them"
    case answer = "Say"
}

/// Which audio sources are transcribed.
enum ListenMode: String, CaseIterable {
    case both, me, them

    var title: String {
        switch self {
        case .both: return "Me + Them"
        case .me: return "Me only"
        case .them: return "Them only"
        }
    }
    var usesMic: Bool { self != .them }
    var usesSystemAudio: Bool { self != .me }
}

struct Line: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let time: Date
}

/// What the floating window shows.
final class Transcript: ObservableObject {
    @Published var lines: [Line] = []
    @Published var partial: [Speaker: String] = [:]
    @Published var status = "Ready"
    @Published var isRunning = false
    @Published var lag: Double?
    @Published var mode: ListenMode = .both
    /// The answer being written right now (streams in).
    @Published var answerDraft: String?
    @Published var brainStatus = ""

    var plainText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { "[\(f.string(from: $0.time))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    /// The conversation from the last `seconds`, for giving Claude context.
    func recentConversation(seconds: TimeInterval) -> String {
        let cutoff = Date().addingTimeInterval(-seconds)
        return lines.filter { $0.time >= cutoff && $0.speaker != .answer }
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Appends finished lines to ~/Documents/Pineapple/<date time>.md as the meeting goes.
final class TranscriptFile {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Pineapple", isDirectory: true)
    }

    let url: URL
    private(set) var lineCount = 0
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init?() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd HHmm"
        let title = DateFormatter()
        title.dateStyle = .full
        title.timeStyle = .short
        let now = Date()
        url = Self.folder.appendingPathComponent("\(name.string(from: now)).md")
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: Data("# Transcript, \(title.string(from: now))\n\n".utf8)) else {
                return nil
            }
        }
    }

    func append(_ line: Line) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let text: String
        if line.speaker == .answer {
            text = "> **Suggested answer:** \(line.text.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        } else {
            text = "**\(timeFormat.string(from: line.time)) \(line.speaker.rawValue):** \(line.text)\n\n"
        }
        handle.write(Data(text.utf8))
        if line.speaker != .answer { lineCount += 1 }
    }

    /// Removes the file if nothing was said.
    func finish() {
        if lineCount == 0 { try? FileManager.default.removeItem(at: url) }
    }
}
