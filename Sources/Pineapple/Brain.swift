import Foundation

/// Spots questions from "Them" and asks Claude (on Bedrock) what you should say,
/// using only your knowledge files, in your style.
final class Brain {
    /// "au." profiles keep requests inside Australia (Sydney/Melbourne).
    static let models = [
        ("au.anthropic.claude-opus-5-5", "Claude Opus 5.5 (best answers)"),
        ("au.anthropic.claude-sonnet-5-5", "Claude Sonnet 5.5 (faster)"),
        ("au.anthropic.claude-haiku-5-5", "Claude Haiku 5.5 (fastest)"),
        ("au.anthropic.claude-opus-4-6-v1", "Claude Opus 4.6"),
        ("au.anthropic.claude-sonnet-4-6", "Claude Sonnet 4.6"),
    ]
    /// Models the account isn't allowed to use, skipped for the rest of this run of the app.
    private var unavailable = Set<String>()

    private let transcript: Transcript
    private var client: ClaudeClient?
    private(set) var knowledge = KnowledgeBase()
    private var startedAt = Date()
    var model = "au.anthropic.claude-opus-5-5"
    var onAnswer: ((String) -> Void)?

    init(transcript: Transcript) {
        self.transcript = transcript
    }

    func reload() {
        knowledge = KnowledgeBase.load()
        transcript.brainStatus = knowledge.isEmpty
            ? "No knowledge files yet. Add them in Documents/Pineapple/Knowledge."
            : knowledge.summary
    }

    func setCredentials(_ credentials: AWSCredentials) {
        client?.cancel()
        client = ClaudeClient(credentials: credentials)
    }

    /// Cheap check on a finished "Them" line. Transcribe adds question marks.
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.split(separator: " ").count >= 3 else { return false }
        if t.contains("?") { return true }
        let starters = ["can you", "could you", "would you", "will you", "do you", "does ", "did you", "how ",
                        "what ", "why ", "when ", "where ", "which ", "who ", "is there", "are there",
                        "tell me", "walk me through", "explain", "talk me through", "describe"]
        return starters.contains { t.hasPrefix($0) }
    }

    /// Answers `question` (or, if nil, whatever was said last).
    func answer(_ question: String?) {
        guard let client else {
            transcript.brainStatus = "Brain needs AWS credentials. Press Start once."
            return
        }
        let conversation = transcript.recentConversation(seconds: 180)
        let asked = question ?? transcript.lines.last(where: { $0.speaker == .them })?.text
        guard let asked, !asked.isEmpty else {
            transcript.brainStatus = "Nothing to answer yet."
            return
        }

        if let draft = transcript.answerDraft, !draft.isEmpty { onAnswer?(draft) } // keep the unfinished one
        transcript.answerDraft = ""
        transcript.brainStatus = "Thinking…"
        startedAt = Date()
        // Chosen model first, then the others, in case some aren't switched on for the account.
        let order = ([model] + Self.models.map(\.0).filter { $0 != model }).filter { !unavailable.contains($0) }
        run(client, order, body: requestBody(question: asked, conversation: conversation))
    }

    private func run(_ client: ClaudeClient, _ models: [String], body: [String: Any]) {
        guard let current = models.first else {
            transcript.answerDraft = nil
            transcript.brainStatus = "No Claude model is switched on for this AWS account (Bedrock → Model access)."
            return
        }
        var firstWordAt: Date?

        client.stream(model: current, body: body) { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let text):
                if firstWordAt == nil {
                    firstWordAt = Date()
                    let name = Self.models.first { $0.0 == current }?.1.components(separatedBy: " (").first ?? current
                    self.transcript.brainStatus = String(format: "%@ · first words in %.1fs", name,
                                                         firstWordAt!.timeIntervalSince(self.startedAt))
                }
                self.transcript.answerDraft = (self.transcript.answerDraft ?? "") + text
            case .done(let stopReason):
                let text = (self.transcript.answerDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self.transcript.answerDraft = nil
                if stopReason == "refusal" {
                    self.transcript.brainStatus = "Claude declined to answer this one."
                } else {
                    self.transcript.brainStatus = String(format: "Answered in %.1fs", Date().timeIntervalSince(self.startedAt))
                }
                if !text.isEmpty { self.onAnswer?(text) }
            case .failed(let message):
                self.transcript.answerDraft = nil
                self.transcript.brainStatus = message
            case .unavailable:
                self.unavailable.insert(current)
                self.run(client, Array(models.dropFirst()), body: body)
            }
        }
    }

    func cancel() {
        client?.cancel()
        transcript.answerDraft = nil
    }

    // MARK: prompt

    private func requestBody(question: String, conversation: String) -> [String: Any] {
        var system: [[String: Any]] = [["type": "text", "text": Self.instructions]]
        var reference = ""
        if !knowledge.style.isEmpty {
            reference += "<style_guides>\nFollow these for how the answer sounds: wording, tone, length.\n\n\(knowledge.style)</style_guides>\n\n"
        }
        reference += knowledge.knowledge.isEmpty
            ? "<knowledge>\n(No knowledge files have been added.)\n</knowledge>"
            : "<knowledge>\n\(knowledge.knowledge)</knowledge>"
        // Cached: the knowledge and style stay the same between questions, so repeats are fast and cheap.
        system.append(["type": "text", "text": reference, "cache_control": ["type": "ephemeral"]])

        let user = """
        <conversation>
        \(conversation.isEmpty ? "(nothing yet)" : conversation)
        </conversation>

        The question to answer now: "\(question)"

        The earlier lines are only background. They may be off-topic, from other people, or about something \
        else entirely. Answer this question, as me, from my background.
        """
        return [
            "max_tokens": 1024,
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
    }

    private static let instructions = """
    You help the user answer questions live, during a meeting or interview. "Me" is the user; "Them" \
    is the other people. The transcript comes from speech recognition, so expect misheard words and \
    read for the intended meaning.

    When they ask something, write what the user should say out loud, in the first person, as the user.

    Always answer. The meeting may not match the notes: a different job, a different organisation, a \
    different topic, or a noisy transcript with other people's talk. That doesn't matter. Answer the \
    question as the user, using whatever in <knowledge> fits it. Never comment on the conversation, the \
    context or the notes, never speak to the user, and never ask the user anything. Your whole output is \
    read aloud to the other people.

    Rules:
    - Use only facts from <knowledge>. Never invent numbers, names, dates, experience or claims.
    - Questions about the user (tell me about yourself, your strengths, your experience, why this role, \
    a time when...) are always covered by the CV and background. Answer them directly.
    - Use "Not in your notes:" only when the question needs a specific fact that isn't in <knowledge> \
    (a number, a name, a project detail). Then give a short, honest line the user could say instead, \
    such as offering to follow up. Don't fill the gap with guesses.
    - Follow <style_guides> when they exist. Otherwise: plain spoken English, short sentences, no jargon \
    or filler, no hype.
    - Length: follow <style_guides> if they set one. Otherwise keep it to about 20 seconds out loud, \
    2 to 4 sentences. The user reads it while talking, so the first sentence must carry the answer.
    - The <style_guides> are the user's own rules. Treat them as binding, especially rules on what to \
    say, how to sound human, and what not to claim.
    - Answer the question that was asked. No preamble like "Great question", no summary at the end.
    - If it's not really a question for the user (small talk, a rhetorical question, them talking to \
    each other), reply with just: (no answer needed)

    Output only the words to say. No headings, no markdown (no **bold**, no #).
    - Normally write plain sentences, no bullet points.
    - Exception: when the answer is several separate questions for the user to ask (for example, \
    "Do you have any questions for us?"), put each question on its own line starting with "• ", \
    best one first, at most 3. The user asks them one at a time.
    """
}
