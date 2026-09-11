import Foundation

/// Metrics GoRunner reads from namespace `AWS/Bedrock` (docs/research/04-ai-quota.md §4.1).
enum BedrockMetric: String, CaseIterable, Sendable {
    case inputTokens = "InputTokenCount"
    case outputTokens = "OutputTokenCount"
    case invocations = "Invocations"
    case throttles = "InvocationThrottles"
    case cacheReadTokens = "CacheReadInputTokenCount"
    case cacheWriteTokens = "CacheWriteInputTokenCount"
    case estimatedTPM = "EstimatedTPMQuotaUsage"

    /// Query id suffix (ids must be `[a-z][A-Za-z0-9_]*`).
    var short: String {
        switch self {
        case .inputTokens: "in"
        case .outputTokens: "out"
        case .invocations: "inv"
        case .throttles: "thr"
        case .cacheReadTokens: "cr"
        case .cacheWriteTokens: "cw"
        case .estimatedTPM: "est"
        }
    }

    init?(short: String) {
        guard let match = Self.allCases.first(where: { $0.short == short }) else { return nil }
        self = match
    }
}

struct MetricPoint: Sendable, Equatable {
    var timestamp: Date
    var value: Double
}

/// Parsed `get-metric-data` output keyed by model and metric.
struct BedrockMetricData: Sendable, Equatable {
    var series: [String: [BedrockMetric: [MetricPoint]]] = [:]
    /// Results whose StatusCode was Forbidden / InternalError.
    var problems: [String] = []

    func points(_ model: String, _ metric: BedrockMetric) -> [MetricPoint] {
        series[model]?[metric] ?? []
    }

    func sum(_ model: String, _ metric: BedrockMetric) -> Double {
        points(model, metric).reduce(0) { $0 + $1.value }
    }

    func has(_ model: String, _ metric: BedrockMetric) -> Bool {
        !points(model, metric).isEmpty
    }
}

enum BedrockParseError: Error, Equatable {
    case invalidJSON(String)
}

enum BedrockParsing {
    // MARK: get-metric-data

    /// Builds MetricDataQueries for `models` × `metrics`. Query ids are `m<modelIndex>_<metricShort>`.
    static func metricQueries(models: [String], metrics: [BedrockMetric], period: Int) -> [[String: Any]] {
        var queries: [[String: Any]] = []
        for (index, model) in models.enumerated() {
            for metric in metrics {
                queries.append([
                    "Id": "m\(index)_\(metric.short)",
                    "MetricStat": [
                        "Metric": [
                            "Namespace": "AWS/Bedrock",
                            "MetricName": metric.rawValue,
                            "Dimensions": [["Name": "ModelId", "Value": model]],
                        ],
                        "Period": period,
                        "Stat": "Sum",
                    ] as [String: Any],
                    "ReturnData": true,
                ])
            }
        }
        return queries
    }

    /// Parses `get-metric-data` JSON. Entries with the same Id (CLI pagination) are merged.
    static func parseMetricData(_ data: Data, models: [String]) throws -> BedrockMetricData {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["MetricDataResults"] as? [[String: Any]]
        else { throw BedrockParseError.invalidJSON("MetricDataResults missing") }
        var out = BedrockMetricData()
        for result in results {
            guard let id = result["Id"] as? String, id.hasPrefix("m"),
                  let underscore = id.firstIndex(of: "_"),
                  let index = Int(id[id.index(after: id.startIndex)..<underscore]), models.indices.contains(index),
                  let metric = BedrockMetric(short: String(id[id.index(after: underscore)...]))
            else { continue }
            if let status = result["StatusCode"] as? String, status == "Forbidden" || status == "InternalError" {
                out.problems.append("\(metric.rawValue): \(status)")
            }
            let timestamps = (result["Timestamps"] as? [Any]) ?? []
            let values = (result["Values"] as? [Any]) ?? []
            var points: [MetricPoint] = []
            for (ts, value) in zip(timestamps, values) {
                guard let date = parseDate(ts), let number = (value as? NSNumber)?.doubleValue else { continue }
                points.append(MetricPoint(timestamp: date, value: number))
            }
            let model = models[index]
            out.series[model, default: [:]][metric, default: []].append(contentsOf: points)
        }
        for (model, metrics) in out.series {
            for (metric, points) in metrics {
                out.series[model]?[metric] = points.sorted { $0.timestamp < $1.timestamp }
            }
        }
        return out
    }

    static func parseDate(_ value: Any) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: list-metrics

    /// Distinct `ModelId` dimension values from `list-metrics` JSON, in first-seen order.
    static func parseModelIDs(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metrics = root["Metrics"] as? [[String: Any]]
        else { throw BedrockParseError.invalidJSON("Metrics missing") }
        var seen = Set<String>()
        var ids: [String] = []
        for metric in metrics {
            for dimension in (metric["Dimensions"] as? [[String: Any]]) ?? [] {
                guard dimension["Name"] as? String == "ModelId", let value = dimension["Value"] as? String, !value.isEmpty
                else { continue }
                if seen.insert(value).inserted { ids.append(value) }
            }
        }
        return ids
    }

    // MARK: list-service-quotas

    static func parseQuotas(_ data: Data) throws -> [BedrockServiceQuota] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotas = root["Quotas"] as? [[String: Any]]
        else { throw BedrockParseError.invalidJSON("Quotas missing") }
        return quotas.compactMap { entry in
            guard let name = entry["QuotaName"] as? String, let value = (entry["Value"] as? NSNumber)?.doubleValue else { return nil }
            return BedrockServiceQuota(code: entry["QuotaCode"] as? String ?? "", name: name, value: value, unit: entry["Unit"] as? String)
        }
    }

    /// `NextToken` of a list-service-quotas page, if any.
    static func nextToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["NextToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: get-cost-and-usage

    /// Sums `UnblendedCost` of every SERVICE group whose name contains "Bedrock"
    /// (covers "Amazon Bedrock" and Marketplace "Claude … (Amazon Bedrock Edition)").
    static func parseBedrockCost(_ data: Data) throws -> (amount: Double, services: [String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["ResultsByTime"] as? [[String: Any]]
        else { throw BedrockParseError.invalidJSON("ResultsByTime missing") }
        var total = 0.0
        var services: [String] = []
        for result in results {
            for group in (result["Groups"] as? [[String: Any]]) ?? [] {
                guard let service = (group["Keys"] as? [String])?.first,
                      service.localizedCaseInsensitiveContains("Bedrock"),
                      let metrics = group["Metrics"] as? [String: Any],
                      let unblended = metrics["UnblendedCost"] as? [String: Any],
                      let amountString = unblended["Amount"] as? String,
                      let amount = Double(amountString)
                else { continue }
                total += amount
                if !services.contains(service) { services.append(service) }
            }
        }
        return (total, services)
    }
}
