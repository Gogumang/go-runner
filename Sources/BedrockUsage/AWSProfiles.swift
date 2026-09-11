import Foundation

// FACADE — `AWSProfiles.list()` and `AWSProfiles.bedrockRegions` are used by GoRunnerApp. Keep these signatures.

public enum AWSProfiles {
    /// Profile names from ~/.aws/config and ~/.aws/credentials ("default" first).
    /// Honors `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE`. Only section names are read — never keys.
    public static func list() -> [String] {
        list(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Common Bedrock regions for the settings picker.
    public static let bedrockRegions = ["us-east-1", "us-west-2", "ap-northeast-2", "ap-northeast-1", "eu-central-1", "eu-west-1"]

    static func list(environment: [String: String], home: URL) -> [String] {
        let configURL = path(environment["AWS_CONFIG_FILE"], default: home.appendingPathComponent(".aws/config"))
        let credentialsURL = path(environment["AWS_SHARED_CREDENTIALS_FILE"], default: home.appendingPathComponent(".aws/credentials"))
        let config = try? String(contentsOf: configURL, encoding: .utf8)
        let credentials = try? String(contentsOf: credentialsURL, encoding: .utf8)
        return merge(config: config.map(configProfiles) ?? [], credentials: credentials.map(credentialsProfiles) ?? [])
    }

    /// `[default]` → default, `[profile x]` → x. `[sso-session …]`, `[services …]` and other sections are skipped.
    static func configProfiles(_ text: String) -> [String] {
        sectionNames(text).compactMap { name in
            let words = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { return nil }
            if words.count == 1, first == "default" { return "default" }
            if first == "profile", words.count >= 2 { return words.dropFirst().joined(separator: " ") }
            return nil
        }
    }

    /// Every `[x]` section in the credentials file is a profile.
    static func credentialsProfiles(_ text: String) -> [String] {
        sectionNames(text)
    }

    /// De-duplicates, puts "default" first (always present), then the rest in case-insensitive order.
    static func merge(config: [String], credentials: [String]) -> [String] {
        var seen = Set<String>(["default"])
        var others: [String] = []
        for name in config + credentials where !name.isEmpty && seen.insert(name).inserted {
            others.append(name)
        }
        return ["default"] + others.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func sectionNames(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : inner
        }
    }

    private static func path(_ override: String?, default fallback: URL) -> URL {
        guard let override, !override.isEmpty else { return fallback }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
}
