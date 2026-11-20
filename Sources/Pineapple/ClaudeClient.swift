import CryptoKit
import Foundation

/// Streams a Messages API request to Claude through Amazon Bedrock Runtime
/// (InvokeModelWithResponseStream), signed with AWS SigV4.
/// In Sydney, Claude is reached through the "au." inference profiles (data stays in Australia).
final class ClaudeClient {
    enum Event {
        case text(String)
        case done(stopReason: String?)
        case failed(String)
        /// This model isn't switched on for the account; another model may work.
        case unavailable(String)
    }

    private let credentials: AWSCredentials
    private var task: Task<Void, Never>?

    init(credentials: AWSCredentials) {
        self.credentials = credentials
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `body` is a Messages API body without "model" or "stream". Events arrive on the main queue.
    func stream(model: String, body: [String: Any], onEvent: @escaping (Event) -> Void) {
        cancel()
        var bedrockBody = body
        bedrockBody["anthropic_version"] = "bedrock-2023-05-31"
        let request: URLRequest
        do {
            request = try Self.signedRequest(credentials: credentials, model: model, body: bedrockBody)
        } catch {
            onEvent(.failed(error.localizedDescription))
            return
        }
        task = Task {
            func emit(_ e: Event) { DispatchQueue.main.async { if !Task.isCancelled { onEvent(e) } } }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { emit(.failed("No response")); return }
                guard http.statusCode == 200 else {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    emit(Self.errorEvent(status: http.statusCode, body: data))
                    return
                }

                var buffer = Data()
                var stopReason: String?
                for try await byte in bytes {
                    if Task.isCancelled { return }
                    buffer.append(byte)
                    // Pull out every complete event-stream frame.
                    while buffer.count >= 4 {
                        let total = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                        guard buffer.count >= total else { break }
                        let frame = buffer.prefix(total)
                        buffer.removeFirst(total)
                        guard let message = EventStream.decode(Data(frame)) else { continue }

                        if message.headers[":message-type"] == "exception" {
                            let text = Self.message(in: message.payload) ?? "Bedrock stream error"
                            emit(.failed("\(message.headers[":exception-type"] ?? "Error"): \(text)"))
                            return
                        }
                        guard let wrapper = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any],
                              let b64 = wrapper["bytes"] as? String,
                              let inner = Data(base64Encoded: b64),
                              let event = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                emit(.text(text))
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any] { stopReason = delta["stop_reason"] as? String }
                        case "error":
                            let text = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                            emit(.failed(text))
                            return
                        default:
                            break
                        }
                    }
                }
                emit(.done(stopReason: stopReason))
            } catch {
                if !Task.isCancelled { emit(.failed(error.localizedDescription)) }
            }
        }
    }

    private static func message(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["message"] as? String ?? json["Message"] as? String
            ?? (json["error"] as? [String: Any])?["message"] as? String
    }

    private static func errorEvent(status: Int, body: Data) -> Event {
        let text = message(in: body) ?? String(decoding: body.prefix(300), as: UTF8.self)
        if text.contains("not available for this account") {
            return .unavailable(text)
        }
        if text.contains("use case details") {
            return .failed("AWS needs the Anthropic use-case form first: Bedrock console → Model catalog → "
                + "any Claude model → submit use case details. Works about 15 minutes after.")
        }
        if status == 429 || text.lowercased().contains("too many") {
            return .failed("Bedrock is busy (rate limit). Try again in a moment.")
        }
        return .failed("Bedrock error \(status): \(text)")
    }

    // MARK: SigV4 (header signing)

    static func signedRequest(credentials c: AWSCredentials, model: String, body: [String: Any]) throws -> URLRequest {
        let service = "bedrock"
        let host = "bedrock-runtime.\(c.region).amazonaws.com"
        // Path segments are encoded once in the URL and twice in the canonical request (non-S3 SigV4).
        let encodedModel = encode(model)
        let path = "/model/\(encodedModel)/invoke-with-response-stream"
        let canonicalPath = "/model/\(encode(encodedModel))/invoke-with-response-stream"
        let payload = try JSONSerialization.data(withJSONObject: body)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: Date())
        let dateStamp = String(amzDate.prefix(8))
        let scope = "\(dateStamp)/\(c.region)/\(service)/aws4_request"

        var headers: [(String, String)] = [
            ("accept", "application/vnd.amazon.eventstream"),
            ("content-type", "application/json"),
            ("host", host),
            ("x-amz-date", amzDate),
        ]
        if let token = c.sessionToken { headers.append(("x-amz-security-token", token)) }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let payloadHash = hex(SHA256.hash(data: payload))

        let canonicalRequest = ["POST", canonicalPath, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(c.secretAccessKey)".utf8))
        for part in [dateStamp, c.region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 120
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(c.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
