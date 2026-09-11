import XCTest
@testable import BedrockUsage

final class AWSProfilesTests: XCTestCase {
    let config = """
    [default]
    region = us-east-1

    [profile work]
    sso_session = corp
    region = us-west-2

    [sso-session corp]
    sso_start_url = https://example.awsapps.com/start

    [ profile  spaced ]
    region = eu-west-1
    # [profile commented]
    ; [profile alsoCommented]
    [services dev]
    [profile Beta]
    """

    let credentials = """
    [default]
    aws_access_key_id = AKIAEXAMPLEEXAMPLE00
    [ci]
    [work]
    """

    func testParsesConfigAndCredentials() {
        XCTAssertEqual(AWSProfiles.configProfiles(config), ["default", "work", "spaced", "Beta"])
        XCTAssertEqual(AWSProfiles.credentialsProfiles(credentials), ["default", "ci", "work"])
        XCTAssertEqual(AWSProfiles.merge(config: AWSProfiles.configProfiles(config), credentials: AWSProfiles.credentialsProfiles(credentials)),
                       ["default", "Beta", "ci", "spaced", "work"])
    }

    func testReadsFilesFromHomeAndEnvOverrides() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try config.write(to: home.appendingPathComponent(".aws/config"), atomically: true, encoding: .utf8)
        try credentials.write(to: home.appendingPathComponent(".aws/credentials"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AWSProfiles.list(environment: [:], home: home), ["default", "Beta", "ci", "spaced", "work"])

        let altConfig = home.appendingPathComponent("alt-config")
        let altCredentials = home.appendingPathComponent("alt-credentials")
        try "[profile other]\n".write(to: altConfig, atomically: true, encoding: .utf8)
        try "[robot]\n".write(to: altCredentials, atomically: true, encoding: .utf8)
        XCTAssertEqual(AWSProfiles.list(environment: ["AWS_CONFIG_FILE": altConfig.path, "AWS_SHARED_CREDENTIALS_FILE": altCredentials.path], home: home),
                       ["default", "other", "robot"])
    }

    func testMissingFilesStillOfferDefault() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(AWSProfiles.list(environment: [:], home: home), ["default"])
        XCTAssertFalse(AWSProfiles.bedrockRegions.isEmpty)
    }
}
