import XCTest
@testable import BedrockUsage

final class BedrockParsingTests: XCTestCase {
    let models = ["us.anthropic.claude-sonnet-4-5-20250929-v1:0", "amazon.nova-pro-v1:0", "meta.llama3-1-70b-instruct-v1:0"]

    func testListMetricsCollectsDistinctModelIDs() throws {
        let ids = try BedrockParsing.parseModelIDs(Fixtures.data("list-metrics.json"))
        XCTAssertEqual(ids, models)
    }

    func testMetricDataMergesPagesAndSorts() throws {
        let data = try BedrockParsing.parseMetricData(Fixtures.data("get-metric-data-recent.json"), models: models)
        let input = data.points(models[0], .inputTokens)
        XCTAssertEqual(input.map(\.value), [100000, 20000, 10000], "duplicate Id entries are merged and sorted by time")
        XCTAssertEqual(input.first?.timestamp, Fixtures.iso("2026-09-11T03:02:00Z"))
        XCTAssertEqual(data.sum(models[0], .throttles), 2)
        XCTAssertEqual(data.sum(models[0], .cacheReadTokens), 50000)
        XCTAssertFalse(data.has(models[0], .estimatedTPM))
        XCTAssertEqual(data.sum(models[1], .outputTokens), 2000)
        XCTAssertTrue(data.problems.isEmpty)
    }

    func testMetricDataRejectsGarbage() {
        XCTAssertThrowsError(try BedrockParsing.parseMetricData(Data("{}".utf8), models: models))
        XCTAssertThrowsError(try BedrockParsing.parseMetricData(Data("not json".utf8), models: models))
    }

    func testMetricDataFlagsForbiddenResults() throws {
        let json = #"{"MetricDataResults":[{"Id":"m0_est","Timestamps":[],"Values":[],"StatusCode":"Forbidden"}]}"#
        let data = try BedrockParsing.parseMetricData(Data(json.utf8), models: models)
        XCTAssertEqual(data.problems, ["EstimatedTPMQuotaUsage: Forbidden"])
    }

    func testMetricQueriesShape() throws {
        let queries = BedrockParsing.metricQueries(models: ["a.b"], metrics: [.inputTokens, .estimatedTPM], period: 60)
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries[1]["Id"] as? String, "m0_est")
        let stat = try XCTUnwrap(queries[0]["MetricStat"] as? [String: Any])
        XCTAssertEqual(stat["Period"] as? Int, 60)
        XCTAssertEqual(stat["Stat"] as? String, "Sum")
        let metric = try XCTUnwrap(stat["Metric"] as? [String: Any])
        XCTAssertEqual(metric["Namespace"] as? String, "AWS/Bedrock")
        XCTAssertEqual(metric["MetricName"] as? String, "InputTokenCount")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: queries))
    }

    func testServiceQuotasPages() throws {
        let page1Data = try Fixtures.data("list-service-quotas-page1.json")
        let page1 = try BedrockParsing.parseQuotas(page1Data)
        XCTAssertEqual(page1.count, 5)
        XCTAssertEqual(page1[1].name, "Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.5")
        XCTAssertEqual(page1[1].value, 200000)
        XCTAssertEqual(BedrockParsing.nextToken(page1Data), "page-2-token")
        let page2Data = try Fixtures.data("list-service-quotas-page2.json")
        XCTAssertEqual(try BedrockParsing.parseQuotas(page2Data).count, 3)
        XCTAssertNil(BedrockParsing.nextToken(page2Data))
    }

    func testCostExplorerSumsBedrockServicesOnly() throws {
        let cost = try BedrockParsing.parseBedrockCost(Fixtures.data("get-cost-and-usage.json"))
        XCTAssertEqual(cost.amount, 12.3456 + 30.5, accuracy: 0.0001)
        XCTAssertEqual(cost.services, ["Amazon Bedrock", "Claude Sonnet 4.5 (Amazon Bedrock Edition)"])
    }

    func testDateParsingVariants() {
        XCTAssertEqual(BedrockParsing.parseDate("2026-09-11T03:07:00+00:00"), Fixtures.iso("2026-09-11T03:07:00Z"))
        XCTAssertEqual(BedrockParsing.parseDate("2026-09-11T03:07:00.000Z"), Fixtures.iso("2026-09-11T03:07:00Z"))
        XCTAssertEqual(BedrockParsing.parseDate(NSNumber(value: 1_789_096_020)), Date(timeIntervalSince1970: 1_789_096_020))
    }
}
