import Foundation
import PDFKit

/// Loads the user's knowledge files (what to say) and style guides (how to say it)
/// from ~/Documents/Pineapple/Knowledge and ~/Documents/Pineapple/Style.
struct KnowledgeBase {
    static var knowledgeFolder: URL { TranscriptFile.folder.appendingPathComponent("Knowledge", isDirectory: true) }
    static var styleFolder: URL { TranscriptFile.folder.appendingPathComponent("Style", isDirectory: true) }

    /// Roughly 250k tokens. Everything is sent with every question (cached), so keep it focused.
    static let maxCharacters = 1_000_000

    var knowledge: String = ""
    var style: String = ""
    var knowledgeFiles = 0
    var styleFiles = 0
    var skipped: [String] = []
    var truncated = false

    var isEmpty: Bool { knowledgeFiles == 0 }

    var summary: String {
        var parts = ["\(knowledgeFiles) knowledge file\(knowledgeFiles == 1 ? "" : "s")",
                     "\(styleFiles) style guide\(styleFiles == 1 ? "" : "s")"]
        if truncated { parts.append("too large, some left out") }
        if !skipped.isEmpty { parts.append("skipped \(skipped.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    static func load() -> KnowledgeBase {
        createFoldersIfNeeded()
        var kb = KnowledgeBase()
        var budget = maxCharacters
        (kb.style, kb.styleFiles) = read(styleFolder, budget: &budget, skipped: &kb.skipped, truncated: &kb.truncated)
        (kb.knowledge, kb.knowledgeFiles) = read(knowledgeFolder, budget: &budget, skipped: &kb.skipped, truncated: &kb.truncated)
        return kb
    }

    private static func read(_ folder: URL, budget: inout Int, skipped: inout [String], truncated: inout Bool) -> (String, Int) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return ("", 0) }
        let urls = walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }

        var out = ""
        var count = 0
        for url in urls {
            let name = url.path.replacingOccurrences(of: folder.path + "/", with: "")
            if name.hasPrefix("_") { continue } // _README.md and other notes to self
            guard let text = extractText(url) else {
                skipped.append(name)
                continue
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if clean.count > budget {
                truncated = true
                continue
            }
            budget -= clean.count
            out += "<file name=\"\(name)\">\n\(clean)\n</file>\n\n"
            count += 1
        }
        return (out, count)
    }

    private static func extractText(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "text", "csv", "json", "html", "htm":
            return try? String(contentsOf: url, encoding: .utf8)
        case "pdf":
            return PDFDocument(url: url)?.string
        case "rtf", "docx", "doc", "rtfd":
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            return (try? NSAttributedString(url: url, options: options, documentAttributes: nil))?.string
        default:
            return nil
        }
    }

    static func createFoldersIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: knowledgeFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: styleFolder, withIntermediateDirectories: true)

        let knowledgeReadme = knowledgeFolder.appendingPathComponent("_README.md")
        if !fm.fileExists(atPath: knowledgeReadme.path) {
            try? """
            # Knowledge

            Put what Pineapple should know here: product facts, pricing, FAQs, past answers,
            CV, case studies. Files: .md .txt .pdf .docx .rtf .csv .json .html (subfolders are fine).

            Answers come only from these files. If something isn't here, Pineapple says so
            instead of guessing. Files starting with _ (like this one) are ignored.
            """.write(to: knowledgeReadme, atomically: true, encoding: .utf8)
        }
        let styleReadme = styleFolder.appendingPathComponent("_README.md")
        if !fm.fileExists(atPath: styleReadme.path) {
            try? """
            # Style

            Put your writing and speaking guides here: how you talk, words you use and avoid,
            tone, length, examples of good answers. Pineapple follows these when it writes
            what you should say. Files starting with _ (like this one) are ignored.
            """.write(to: styleReadme, atomically: true, encoding: .utf8)
        }
    }
}
