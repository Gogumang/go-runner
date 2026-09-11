import XCTest
@testable import BedrockUsage

final class BedrockQuotaMatcherTests: XCTestCase {
    private func q(_ name: String, _ value: Double = 1) -> BedrockServiceQuota {
        BedrockServiceQuota(code: "L-\(abs(name.hashValue) % 100_000)", name: name, value: value, unit: "None")
    }

    private lazy var quotas: [BedrockServiceQuota] = [
        q("On-demand model inference tokens per minute for Anthropic Claude Sonnet 4.5", 400_000),
        q("Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.5", 200_000),
        q("Global cross-Region model inference tokens per minute for Anthropic Claude Sonnet 4.5", 500_000),
        q("Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.5 V1 1M Context Length", 100_000),
        q("Cross-region model inference requests per minute for Anthropic Claude Sonnet 4.5", 200),
        q("Model invocation max tokens per day for Anthropic Claude Sonnet 4.5", 288_000_000),
        q("On-demand InvokeModel tokens per minute for Anthropic Claude Opus 4", 11),
        q("Cross-Region InvokeModel tokens per minute for Anthropic Claude Opus 4.1", 12),
        q("Cross-region model inference tokens per minute for Anthropic Claude Opus 4.8", 48),
        q("Global cross-Region model inference tokens per minute for Anthropic Claude Opus 5", 50),
        q("On-demand model inference input tokens per minute for Anthropic Claude Opus 5", 999),
        q("Cross-region model inference tokens per minute for Anthropic Claude Sonnet 5", 55),
        q("Cross-region model inference tokens per minute for Anthropic Claude Fable 5", 5),
        q("Cross-region model inference tokens per minute for Anthropic Claude Fable 5.1", 51),
        q("Cross-region model inference tokens per minute for Anthropic Claude Haiku 4.5", 45),
        q("On-demand InvokeModel tokens per minute for Anthropic Claude 3.5 Sonnet", 35),
        q("On-demand InvokeModel tokens per minute for Anthropic Claude 3.5 Sonnet V2", 352),
        q("Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4 V1", 4),
        q("Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4 V1 1M Context Length", 41),
        q("InvokeModel requests per minute for Anthropic Claude 3 Haiku", 3),
        q("On-demand model inference tokens per minute for Meta Llama 3.1 70B Instruct", 70),
        q("On-demand model inference tokens per minute for Amazon Nova Pro", 1_000_000),
        q("Batch inference job size (in GB) for Amazon Nova Pro", 5),
    ]

    private func tpm(_ id: String) -> Double? {
        BedrockQuotaMatcher.tpmQuota(for: id, in: quotas)?.value
    }

    func testAnthropicScopes() {
        XCTAssertEqual(tpm("anthropic.claude-sonnet-4-5-20250929-v1:0"), 400_000)
        XCTAssertEqual(tpm("us.anthropic.claude-sonnet-4-5-20250929-v1:0"), 200_000)
        XCTAssertEqual(tpm("eu.anthropic.claude-sonnet-4-5-20250929-v1:0"), 200_000)
        XCTAssertEqual(tpm("apac.anthropic.claude-sonnet-4-5-20250929-v1:0"), 200_000)
        XCTAssertEqual(tpm("global.anthropic.claude-sonnet-4-5-20250929-v1:0"), 500_000)
    }

    func testCurrentGenerationModels() {
        XCTAssertEqual(tpm("eu.anthropic.claude-opus-4-8"), 48)
        XCTAssertEqual(tpm("global.anthropic.claude-opus-5"), 50)
        XCTAssertNil(tpm("us.anthropic.claude-opus-5"), "only a global quota exists; cross-region must not borrow it")
        XCTAssertNil(tpm("anthropic.claude-opus-5"), "the mantle input-token quota must not match")
        XCTAssertEqual(tpm("global.anthropic.claude-sonnet-5"), 55, "global falls back to the cross-region quota")
        XCTAssertEqual(tpm("us.anthropic.claude-fable-5-1"), 51)
        XCTAssertEqual(tpm("us.anthropic.claude-fable-5"), 5)
        XCTAssertEqual(tpm("apac.anthropic.claude-haiku-4-5-20251001-v1:0"), 45)
    }

    func testVersionsDoNotBleed() {
        XCTAssertEqual(tpm("anthropic.claude-opus-4-20250514-v1:0"), 11)
        XCTAssertEqual(tpm("us.anthropic.claude-opus-4-1-20250805-v1:0"), 12)
        XCTAssertNil(tpm("us.anthropic.claude-opus-4-7"))
        XCTAssertEqual(tpm("anthropic.claude-3-5-sonnet-20240620-v1:0"), 35)
        XCTAssertEqual(tpm("anthropic.claude-3-5-sonnet-20241022-v2:0"), 352)
        XCTAssertEqual(tpm("us.anthropic.claude-sonnet-4-20250514-v1:0"), 4, "the 1M-context variant is a different quota")
    }

    func testNonAnthropicAndArns() {
        XCTAssertEqual(tpm("meta.llama3-1-70b-instruct-v1:0"), 70)
        XCTAssertEqual(tpm("amazon.nova-pro-v1:0"), 1_000_000)
        XCTAssertNil(tpm("amazon.nova-lite-v1:0"))
        XCTAssertEqual(tpm("arn:aws:bedrock:us-east-1:111122223333:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0"), 200_000)
        XCTAssertNil(tpm("arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/abcd1234efgh"))
    }

    func testRPM() {
        XCTAssertEqual(BedrockQuotaMatcher.rpmQuota(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", in: quotas)?.value, 200)
        XCTAssertEqual(BedrockQuotaMatcher.rpmQuota(for: "anthropic.claude-3-haiku-20240307-v1:0", in: quotas)?.value, 3)
        XCTAssertNil(BedrockQuotaMatcher.tpmQuota(for: "anthropic.claude-3-haiku-20240307-v1:0", in: quotas))
        XCTAssertNil(BedrockQuotaMatcher.rpmQuota(for: "us.anthropic.claude-opus-4-8", in: quotas))
    }

    func testQuotaNameParsing() {
        XCTAssertEqual(BedrockQuotaMatcher.parse(quotaName: "Cross-Region InvokeModel tokens per minute for Anthropic Claude Opus 4.1"),
                       ParsedQuotaName(kind: .tokensPerMinute, scope: .crossRegion, modelTokens: ["claude", "opus", "4.1"]))
        XCTAssertEqual(BedrockQuotaMatcher.parse(quotaName: "Global cross-Region model inference tokens per minute for Anthropic Claude Opus 5")?.scope, .global)
        XCTAssertEqual(BedrockQuotaMatcher.parse(quotaName: "InvokeModel requests per minute for Anthropic Claude 3 Haiku")?.kind, .requestsPerMinute)
        XCTAssertNil(BedrockQuotaMatcher.parse(quotaName: "Model invocation max tokens per day for Anthropic Claude Sonnet 4.5"))
        XCTAssertNil(BedrockQuotaMatcher.parse(quotaName: "On-demand model inference output tokens per minute for Anthropic Claude Opus 5"))
        XCTAssertNil(BedrockQuotaMatcher.parse(quotaName: "Batch inference job size (in GB) for Amazon Nova Pro"))
    }

    func testModelIDParsing() {
        let sonnet = BedrockModelID("us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        XCTAssertEqual(sonnet.scope, .crossRegion)
        XCTAssertEqual(sonnet.provider, "anthropic")
        XCTAssertEqual(sonnet.tokens, ["claude", "sonnet", "4.5"])
        XCTAssertEqual(sonnet.shortName, "Sonnet 4.5 (us)")
        XCTAssertEqual(BedrockModelID("global.anthropic.claude-opus-5").shortName, "Opus 5 (global)")
        XCTAssertEqual(BedrockModelID("anthropic.claude-fable-5-1").shortName, "Fable 5.1")
        XCTAssertEqual(BedrockModelID("anthropic.claude-opus-4-6-v1").tokens, ["claude", "opus", "4.6"])
        XCTAssertEqual(BedrockModelID("amazon.nova-pro-v1:0").shortName, "Nova Pro")
        XCTAssertEqual(BedrockModelID("meta.llama3-1-70b-instruct-v1:0").tokens, ["llama", "3.1", "70b", "instruct"])
        XCTAssertEqual(BedrockModelID("meta.llama3-1-70b-instruct-v1:0").shortName, "Llama 3.1 70B Instruct")
        XCTAssertEqual(BedrockModelID("openai.gpt-oss-120b-1:0").tokens, ["gpt", "oss", "120b"])
    }

    func testBurndownTable() {
        func m(_ id: String) -> Double { BedrockBurndown.multiplier(for: BedrockModelID(id)) }
        XCTAssertEqual(m("us.anthropic.claude-opus-4-8"), 15)
        XCTAssertEqual(m("global.anthropic.claude-opus-5"), 10)
        XCTAssertEqual(m("anthropic.claude-sonnet-5"), 10)
        XCTAssertEqual(m("us.anthropic.claude-fable-5-1"), 10)
        XCTAssertEqual(m("anthropic.claude-opus-4-7"), 5)
        XCTAssertEqual(m("anthropic.claude-sonnet-4-5-20250929-v1:0"), 5)
        XCTAssertEqual(m("apac.anthropic.claude-haiku-4-5-20251001-v1:0"), 5)
        XCTAssertEqual(m("anthropic.claude-3-7-sonnet-20250219-v1:0"), 5)
        XCTAssertEqual(m("anthropic.claude-3-5-sonnet-20241022-v2:0"), 1)
        XCTAssertEqual(m("amazon.nova-pro-v1:0"), 1)
        XCTAssertEqual(m("meta.llama3-1-70b-instruct-v1:0"), 1)
    }
}
