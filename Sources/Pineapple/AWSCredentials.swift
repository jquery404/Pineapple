import Foundation

/// Reads access keys for a named profile from ~/.aws/credentials (and its region from ~/.aws/config).
struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String

    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load(profile: String) throws -> AWSCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credentials = ini(home.appendingPathComponent(".aws/credentials"))
        let config = ini(home.appendingPathComponent(".aws/config"))

        guard let section = credentials[profile],
              let id = section["aws_access_key_id"], !id.isEmpty,
              let secret = section["aws_secret_access_key"], !secret.isEmpty
        else {
            throw LoadError(message: "No access keys for AWS profile \"\(profile)\" in ~/.aws/credentials")
        }
        let configSection = config[profile == "default" ? "default" : "profile \(profile)"] ?? [:]
        let region = configSection["region"] ?? section["region"] ?? "ap-southeast-2"
        return AWSCredentials(accessKeyId: id,
                              secretAccessKey: secret,
                              sessionToken: section["aws_session_token"],
                              region: region)
    }

    private static func ini(_ url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [String: String]] = [:]
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[current, default: [:]][key] = value
        }
        return result
    }
}
