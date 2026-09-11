import Foundation

/// Small JSON file cache under `AppPaths.cacheDirectory` (removed by the uninstaller). Never stores credentials.
struct BedrockFileCache: Sendable {
    let directory: URL

    struct Entry<Value: Codable>: Codable {
        var fetchedAt: Date
        /// Extra validity key, e.g. the month for Cost Explorer.
        var key: String?
        var value: Value
    }

    func url(_ prefix: String, profile: String, region: String?) -> URL {
        let parts = [prefix, profile] + (region.map { [$0] } ?? [])
        let name = parts.map(Self.safe).joined(separator: "-") + ".json"
        return directory.appendingPathComponent(name)
    }

    func load<Value: Codable>(_ type: Value.Type, from url: URL, maxAge: TimeInterval, now: Date, key: String? = nil) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let entry = try? decoder.decode(Entry<Value>.self, from: data) else { return nil }
        let age = now.timeIntervalSince(entry.fetchedAt)
        guard age >= 0, age < maxAge, entry.key == key else { return nil }
        return entry.value
    }

    func save<Value: Codable>(_ value: Value, to url: URL, now: Date, key: String? = nil) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Entry(fetchedAt: now, key: key, value: value)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func safe(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(mapped)
        return s.isEmpty ? "_" : s
    }
}

struct BedrockCostCacheEntry: Codable, Sendable, Equatable {
    var amountUSD: Double
    var services: [String]
}
