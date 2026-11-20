import CryptoKit
import Foundation

/// One Amazon Transcribe streaming session over WebSocket (16 kHz, 16-bit mono PCM).
final class TranscribeClient: NSObject, URLSessionWebSocketDelegate {
    static let sampleRate = 16000

    var onOpen: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// Seconds between the audio sent so far and the end of the latest transcribed word.
    var onLag: ((Double) -> Void)?
    var onError: ((_ message: String, _ fatal: Bool) -> Void)?
    /// Called once. `opened` is false if the connection never got going.
    var onClosed: ((_ opened: Bool) -> Void)?

    private let credentials: AWSCredentials
    private let languageCode: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var opened = false
    private var closed = false
    private var queued: [Data] = []
    private var bytesSent = 0

    private static let audioHeaders = [
        (":content-type", "application/octet-stream"),
        (":event-type", "AudioEvent"),
        (":message-type", "event"),
    ]
    private static let fatalExceptions: Set<String> = [
        "BadRequestException", "UnrecognizedClientException", "AccessDeniedException",
    ]

    init(credentials: AWSCredentials, languageCode: String) {
        self.credentials = credentials
        self.languageCode = languageCode
    }

    func connect() {
        let url = Self.presignedURL(credentials: credentials, languageCode: languageCode)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receive()
    }

    func send(pcm: Data) {
        guard !closed else { return }
        guard isOpen else {
            queued.append(pcm)
            if queued.count > 40 { queued.removeFirst() } // keep at most ~2 s while connecting
            return
        }
        sendAudio(pcm)
    }

    /// Tells Transcribe the audio is over, so it finalises the last line and closes.
    func endStream() {
        guard isOpen, !closed else { return }
        task?.send(.data(EventStream.encode(headers: Self.audioHeaders, payload: Data()))) { _ in }
    }

    func close() {
        guard !closed else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        finish()
    }

    // MARK: private

    private func sendAudio(_ pcm: Data) {
        bytesSent += pcm.count
        task?.send(.data(EventStream.encode(headers: Self.audioHeaders, payload: pcm))) { _ in }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        isOpen = false
        session?.invalidateAndCancel()
        onClosed?(opened)
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(.data(let data)): self.handle(data)
            case .success(.string(let text)): self.onError?("Unexpected message: \(text.prefix(200))", false)
            case .success: break
            case .failure(let error): self.failed(error); return
            }
            self.receive()
        }
    }

    private func handle(_ data: Data) {
        guard let message = EventStream.decode(data) else { return }
        let json = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any]

        if message.headers[":message-type"] == "exception" {
            let type = message.headers[":exception-type"] ?? "Exception"
            let text = json?["Message"] as? String ?? String(decoding: message.payload, as: UTF8.self)
            onError?("\(type): \(text)", Self.fatalExceptions.contains(type))
            return
        }
        guard message.headers[":event-type"] == "TranscriptEvent",
              let transcript = json?["Transcript"] as? [String: Any],
              let results = transcript["Results"] as? [[String: Any]] else { return }

        for result in results {
            guard let alternatives = result["Alternatives"] as? [[String: Any]],
                  let text = alternatives.first?["Transcript"] as? String else { continue }
            if let end = result["EndTime"] as? Double {
                let audioSeconds = Double(bytesSent) / Double(Self.sampleRate * 2)
                onLag?(max(0, audioSeconds - end))
            }
            if result["IsPartial"] as? Bool ?? true {
                onPartial?(text)
            } else {
                onFinal?(text)
            }
        }
    }

    private func failed(_ error: Error) {
        guard !closed else { return }
        if let http = task?.response as? HTTPURLResponse, http.statusCode >= 400 {
            let code = http.statusCode
            if code == 403 || code == 401 {
                onError?("AWS refused the connection (HTTP \(code)). Check that the profile's IAM user is allowed transcribe:StartStreamTranscriptionWebSocket and that the Mac's clock is right.", true)
            } else {
                onError?("Transcribe error (HTTP \(code))", false)
            }
        } else if !opened {
            onError?("Can't reach Amazon Transcribe: \(error.localizedDescription)", false)
        }
        finish()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isOpen = true
        opened = true
        onOpen?()
        let pending = queued
        queued = []
        pending.forEach(sendAudio)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failed(error) } else { finish() }
    }

    // MARK: SigV4 presigned URL

    static func presignedURL(credentials c: AWSCredentials, languageCode: String) -> URL {
        let host = "transcribestreaming.\(c.region).amazonaws.com:8443"
        let path = "/stream-transcription-websocket"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: Date())
        let dateStamp = String(amzDate.prefix(8))
        let scope = "\(dateStamp)/\(c.region)/transcribe/aws4_request"

        var params: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(c.accessKeyId)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "300"),
            ("X-Amz-SignedHeaders", "host"),
            ("enable-partial-results-stabilization", "true"),
            ("language-code", languageCode),
            ("media-encoding", "pcm"),
            ("partial-results-stability", "high"),
            ("sample-rate", String(sampleRate)),
        ]
        if let token = c.sessionToken { params.append(("X-Amz-Security-Token", token)) }

        let query = params
            .map { (uriEncode($0.0), uriEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            "GET", path, query, "host:\(host)\n", "host", hex(SHA256.hash(data: Data())),
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(c.secretAccessKey)".utf8))
        for part in [dateStamp, c.region, "transcribe", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        return URL(string: "wss://\(host)\(path)?\(query)&X-Amz-Signature=\(signature)")!
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    private static func uriEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
