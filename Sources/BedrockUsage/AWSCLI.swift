import Foundation
import GoRunnerCore

/// Runs the user's `aws` CLI (v2) so profiles, SSO and `credential_process` work without SigV4 code in GoRunner.
struct AWSCLI: Sendable {
    let executable: URL
    let profile: String
    let region: String
    let environment: [String: String]

    init(executable: URL, profile: String, region: String, baseEnvironment: [String: String]? = nil) {
        self.executable = executable
        self.profile = profile
        self.region = region
        var env = baseEnvironment ?? ShellEnvironment.environment()
        env["AWS_PAGER"] = ""
        env["AWS_CLI_AUTO_PROMPT"] = "off"
        self.environment = env
    }

    /// Full argument list: `<args> --profile p --region r --output json`.
    func arguments(_ args: [String], region overrideRegion: String? = nil) -> [String] {
        args + ["--profile", profile, "--region", overrideRegion ?? region, "--output", "json"]
    }

    /// Runs one CLI call. `permission` names the IAM action reported when the call is denied.
    func run(_ args: [String], region overrideRegion: String? = nil, timeout: TimeInterval,
             permission: String?) async -> Result<Data, ProviderError> {
        do {
            let result = try await ProcessRunner.run(executable, arguments: arguments(args, region: overrideRegion),
                                                     timeout: max(1, timeout), environment: environment)
            if result.exitCode == 0 { return .success(result.stdout) }
            return .failure(AWSErrorMapper.map(stderr: result.stderrString, exitCode: result.exitCode,
                                               profile: profile, permission: permission))
        } catch ProcessRunnerError.timeout {
            return .failure(ProviderError(kind: .timeout,
                                          message: Loc.t("AWS CLI 응답 시간 초과 (\(Int(timeout))초)", "AWS CLI timed out (\(Int(timeout)) s)"),
                                          fixHint: Loc.t("네트워크 또는 SSO 세션을 확인하세요", "Check the network or the SSO session")))
        } catch {
            return .failure(AWSErrorMapper.toolNotFound(detail: String(describing: error)))
        }
    }
}

/// Maps `aws` stderr to `ProviderError`. Pure, so it is unit-tested with real CLI messages.
enum AWSErrorMapper {
    static func map(stderr: String, exitCode: Int32, profile: String, permission: String?) -> ProviderError {
        let lower = stderr.lowercased()
        let summary = sanitize(firstMeaningfulLine(stderr))

        if lower.contains("expiredtoken") || lower.contains("token has expired") || lower.contains("token is expired")
            || lower.contains("security token included in the request is expired")
            || (lower.contains("sso") && (lower.contains("expired") || lower.contains("sso login")))
            || lower.contains("error when retrieving token from sso") || lower.contains("refresh token")
        {
            return ProviderError(
                kind: .authExpired,
                message: Loc.t("AWS 자격 증명이 만료되었습니다 (프로필 \(profile))", "AWS credentials expired (profile \(profile))"),
                fixHint: Loc.t("터미널에서 `aws sso login --profile \(profile)` 실행 (정적 키라면 자격 증명 갱신)",
                               "Run `aws sso login --profile \(profile)` in Terminal (or refresh static keys)"))
        }

        if lower.contains("unable to locate credentials") || lower.contains("partial credentials found")
            || (lower.contains("profile") && lower.contains("could not be found"))
            || lower.contains("invalidclienttokenid") || lower.contains("unrecognizedclientexception")
            || lower.contains("signaturedoesnotmatch")
        {
            return ProviderError(
                kind: .authMissing,
                message: Loc.t("AWS 자격 증명을 찾을 수 없습니다 (프로필 \(profile))", "No usable AWS credentials (profile \(profile))"),
                fixHint: Loc.t("`aws configure --profile \(profile)` 또는 `aws sso login --profile \(profile)` 실행",
                               "Run `aws configure --profile \(profile)` or `aws sso login --profile \(profile)`"))
        }

        if lower.contains("accessdenied") || lower.contains("access denied") || lower.contains("not authorized to perform")
            || lower.contains("unauthorizedoperation")
        {
            let action = deniedAction(in: stderr) ?? permission ?? "?"
            return ProviderError(
                kind: .permissionDenied,
                message: Loc.t("IAM 권한 없음: \(action)", "Missing IAM permission: \(action)"),
                fixHint: Loc.t("프로필 \(profile)의 IAM 정책에 `\(action)` 허용 추가", "Allow `\(action)` in the IAM policy for profile \(profile)"))
        }

        if lower.contains("throttl") || lower.contains("rate exceeded") || lower.contains("toomanyrequests") {
            return ProviderError(kind: .rateLimited, message: Loc.t("AWS API 호출 제한: \(summary)", "AWS API throttled: \(summary)"),
                                 fixHint: Loc.t("잠시 후 다시 시도", "Try again later"))
        }

        if lower.contains("could not connect to the endpoint") || lower.contains("connect timeout")
            || lower.contains("read timeout") || lower.contains("ssl validation failed") || lower.contains("name resolution")
            || lower.contains("nodename nor servname")
        {
            return ProviderError(kind: .network, message: Loc.t("AWS 연결 실패: \(summary)", "AWS connection failed: \(summary)"),
                                 fixHint: Loc.t("네트워크와 리전을 확인하세요", "Check the network and region"))
        }

        if lower.contains("invalid choice") || lower.contains("unknown options") {
            return ProviderError(kind: .schemaChanged, message: Loc.t("AWS CLI가 명령을 지원하지 않음: \(summary)", "AWS CLI does not support the command: \(summary)"),
                                 fixHint: Loc.t("AWS CLI v2로 업데이트", "Update to AWS CLI v2"))
        }

        return ProviderError(kind: .other, message: summary.isEmpty ? "aws exit \(exitCode)" : summary)
    }

    static func toolNotFound(detail: String? = nil) -> ProviderError {
        ProviderError(kind: .toolNotFound,
                      message: Loc.t("aws CLI를 찾을 수 없습니다", "aws CLI not found") + (detail.map { " (\(sanitize($0)))" } ?? ""),
                      fixHint: Loc.t("AWS CLI 설치 필요 (`brew install awscli`) 또는 설정에서 경로 지정",
                                     "Install the AWS CLI (`brew install awscli`) or set its path in Settings"))
    }

    /// "… is not authorized to perform: cloudwatch:GetMetricData on resource …" → "cloudwatch:GetMetricData".
    static func deniedAction(in stderr: String) -> String? {
        guard let range = stderr.range(of: #"perform:\s*([A-Za-z0-9-]+:[A-Za-z0-9*]+)"#, options: .regularExpression) else { return nil }
        let match = stderr[range]
        return match.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)
    }

    /// Removes account ids, ARNs and access key ids from messages that may be shown or cached.
    static func sanitize(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"arn:aws[a-zA-Z-]*:[^\s"',]+"#, with: "<arn>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(AKIA|ASIA)[A-Z0-9]{12,}\b"#, with: "<key>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{12}\b"#, with: "<account>", options: .regularExpression)
        return s
    }

    private static func firstMeaningfulLine(_ stderr: String) -> String {
        let line = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(300))
    }
}
