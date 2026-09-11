import Foundation
import GoRunnerCore

struct CodexAppServerResult: Sendable, Equatable {
    var rateLimits: CodexRateLimits
    var account: CodexAccountInfo?
}

/// Spawns `codex app-server`, performs `initialize` → `initialized` → `account/read` + `account/rateLimits/read`,
/// and always tears the child down. Read-only: never starts a thread or turn, never touches credentials.
struct CodexAppServerClient: Sendable {
    static let defaultTimeout: TimeInterval = 15
    static let clientName = "gorunner"

    var executableOverride: String?
    var arguments: [String]
    /// Overall budget, from `fetch()` start to the last response.
    var timeout: TimeInterval
    /// nil = `ShellEnvironment.environment()` (login-shell PATH so the node-based `codex` script finds `node`).
    var environment: [String: String]?

    init(executableOverride: String? = nil, arguments: [String] = ["app-server"],
         timeout: TimeInterval = Self.defaultTimeout, environment: [String: String]? = nil) {
        self.executableOverride = executableOverride
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
    }

    func fetch() async -> Result<CodexAppServerResult, ProviderError> {
        let started = Date()
        let override = executableOverride
        let explicitEnvironment = environment
        // Locating may query the login shell once (blocking, cached) — keep it off the cooperative pool.
        let launch = await Task.detached(priority: .utility) { () -> (URL, [String: String])? in
            guard let url = ExecutableLocator.locate("codex", override: override) else { return nil }
            return (url, explicitEnvironment ?? ShellEnvironment.environment())
        }.value
        guard let (executable, env) = launch else {
            return .failure(CodexErrors.notFound(override: override))
        }
        let remaining = max(0.5, timeout - Date().timeIntervalSince(started))
        return await run(executable: executable, environment: env, budget: remaining)
    }

    private func run(executable: URL, environment: [String: String],
                     budget: TimeInterval) async -> Result<CodexAppServerResult, ProviderError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = AppServerSession()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                session.fail(.closed)
            } else {
                session.receive(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                session.appendStderr(data)
            }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // Let stdout drain first so a final response is not lost.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
                session.fail(.exited(status))
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(ProviderError(kind: .toolNotFound,
                                          message: Loc.t("codex 실행 실패: ", "Could not launch codex: ") + error.localizedDescription,
                                          fixHint: CodexErrors.installHint))
        }

        let stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
        // A dead child must surface as a write error, not a SIGPIPE that kills GoRunner.
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        let timer = DispatchWorkItem { session.fail(.timeout) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget, execute: timer)
        defer {
            timer.cancel()
            ChildProcessTeardown.terminate(process, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
        }

        let result = await withTaskCancellationHandler {
            await exchange(session: session, stdinFD: stdinFD)
        } onCancel: {
            session.fail(.cancelled)
        }

        if case let .failure(error) = result {
            let stderr = session.stderrTail
            Log.quota.error("codex app-server failed (\(error.kind.rawValue, privacy: .public)): \(error.message, privacy: .public); stderr: \(stderr, privacy: .private)")
        }
        return result
    }

    private func exchange(session: AppServerSession, stdinFD: Int32) async -> Result<CodexAppServerResult, ProviderError> {
        let initializeID = 1
        let accountID = 2
        let rateLimitsID = 3

        let hello = CodexRPC.request(id: initializeID, method: CodexRPC.initialize,
                                     params: CodexRPC.initializeParams(clientName: Self.clientName,
                                                                       clientVersion: AppIdentity.version))
        guard writeAll(fd: stdinFD, data: hello) else {
            return .failure(map(await session.outcome(for: initializeID, grace: 1), session: session, method: CodexRPC.initialize))
        }
        switch await session.outcome(for: initializeID) {
        case .result:
            break
        case let other:
            return .failure(map(other, session: session, method: CodexRPC.initialize))
        }

        var batch = CodexRPC.notification(method: CodexRPC.initialized)
        batch.append(CodexRPC.request(id: accountID, method: CodexRPC.accountRead, params: [:]))
        batch.append(CodexRPC.request(id: rateLimitsID, method: CodexRPC.rateLimitsRead))
        guard writeAll(fd: stdinFD, data: batch) else {
            return .failure(map(await session.outcome(for: rateLimitsID, grace: 1), session: session, method: CodexRPC.rateLimitsRead))
        }

        let limitsOutcome = await session.outcome(for: rateLimitsID)
        // account/read is local and normally answers first; don't let it extend the budget.
        let accountOutcome = await session.outcome(for: accountID, grace: 1)
        var account: CodexAccountInfo?
        if case let .result(object) = accountOutcome {
            account = try? CodexResponseParser.account(fromResult: object.value)
        }

        switch limitsOutcome {
        case let .result(object):
            do {
                let limits = try CodexResponseParser.rateLimits(fromResult: object.value)
                return .success(CodexAppServerResult(rateLimits: limits, account: account))
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(CodexErrors.schema(error.localizedDescription))
            }
        case .rpcError, .failed:
            if let problem = CodexErrors.accountProblem(account) { return .failure(problem) }
            return .failure(map(limitsOutcome, session: session, method: CodexRPC.rateLimitsRead))
        }
    }

    private func map(_ outcome: AppServerSession.Outcome, session: AppServerSession, method: String) -> ProviderError {
        switch outcome {
        case .result:
            return CodexErrors.schema("\(method): unexpected result")
        case let .rpcError(code, message):
            return CodexErrors.rpcError(code: code, message: message, method: method)
        case .failed(.timeout):
            return CodexErrors.timeout(seconds: timeout)
        case .failed(.overflow):
            return CodexErrors.schema("\(method): response line too long")
        case .failed(.cancelled):
            return ProviderError(kind: .other, message: Loc.t("취소됨", "Cancelled"))
        case .failed(.closed), .failed(.exited):
            let stderr = session.stderrTail
            if CodexErrors.looksLikeAuthProblem(stderr) { return CodexErrors.notLoggedIn() }
            let lower = stderr.lowercased()
            if lower.contains("unrecognized subcommand") || lower.contains("unexpected argument") {
                return ProviderError(kind: .schemaChanged,
                                     message: Loc.t("이 codex 버전은 app-server를 지원하지 않습니다", "This codex version does not support app-server"),
                                     fixHint: Loc.t("Codex CLI를 업데이트하세요", "Update Codex CLI"))
            }
            let lastLine = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            var message = Loc.t("codex app-server가 응답 전에 종료되었습니다", "codex app-server exited before replying")
            if case let .failed(.exited(status)) = outcome { message += " (exit \(status))" }
            if !lastLine.isEmpty { message += ": \(lastLine.prefix(200))" }
            return ProviderError(kind: .other, message: message)
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

// MARK: - Session state

/// Matches newline-delimited responses to request ids. Thread-safe; fed from the stdout readability handler.
final class AppServerSession: @unchecked Sendable {
    enum Failure: Sendable, Equatable {
        case timeout, closed, overflow, cancelled
        case exited(Int32)
    }

    enum Outcome: Sendable {
        case result(JSONObject)
        case rpcError(code: Int, message: String)
        case failed(Failure)
    }

    private let lock = NSLock()
    private var buffer = LineBuffer()
    private var waiters: [Int: CheckedContinuation<Outcome, Never>] = [:]
    private var outcomes: [Int: Outcome] = [:]
    private var failure: Failure?
    private var stderr = Data()
    private let maxStderrBytes = 16_384

    var stderrTail: String {
        lock.withLock { String(decoding: stderr, as: UTF8.self) }
    }

    func appendStderr(_ data: Data) {
        lock.withLock {
            stderr.append(data)
            if stderr.count > maxStderrBytes { stderr = Data(stderr.suffix(maxStderrBytes)) }
        }
    }

    func receive(_ data: Data) {
        var resumes: [(CheckedContinuation<Outcome, Never>, Outcome)] = []
        lock.lock()
        let (lines, overflow) = buffer.append(data)
        for line in lines {
            switch CodexRPC.decode(line) {
            case let .response(id, result):
                deliverLocked(id: id, outcome: .result(result), into: &resumes)
            case let .error(id, code, message):
                deliverLocked(id: id, outcome: .rpcError(code: code, message: message), into: &resumes)
            case .notification, .serverRequest, .unparseable:
                continue
            }
        }
        if overflow { failLocked(.overflow, into: &resumes) }
        lock.unlock()
        for (continuation, outcome) in resumes { continuation.resume(returning: outcome) }
    }

    /// Waits for the response to `id`, or the session's terminal failure. `grace` bounds this particular wait.
    func outcome(for id: Int, grace: TimeInterval? = nil) async -> Outcome {
        if let grace {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
                self?.expire(id: id)
            }
        }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let ready = outcomes.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(returning: ready)
            } else if let failure {
                lock.unlock()
                continuation.resume(returning: .failed(failure))
            } else {
                waiters[id] = continuation
                lock.unlock()
            }
        }
    }

    func fail(_ reason: Failure) {
        var resumes: [(CheckedContinuation<Outcome, Never>, Outcome)] = []
        lock.lock()
        failLocked(reason, into: &resumes)
        lock.unlock()
        for (continuation, outcome) in resumes { continuation.resume(returning: outcome) }
    }

    private func expire(id: Int) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(returning: .failed(.timeout))
    }

    private func deliverLocked(id: Int, outcome: Outcome, into resumes: inout [(CheckedContinuation<Outcome, Never>, Outcome)]) {
        if let waiter = waiters.removeValue(forKey: id) {
            resumes.append((waiter, outcome))
        } else {
            outcomes[id] = outcome
        }
    }

    private func failLocked(_ reason: Failure, into resumes: inout [(CheckedContinuation<Outcome, Never>, Outcome)]) {
        if failure == nil { failure = reason }
        let terminal = Outcome.failed(failure ?? reason)
        for (_, waiter) in waiters { resumes.append((waiter, terminal)) }
        waiters.removeAll()
    }
}

// MARK: - Teardown

enum ChildProcessTeardown {
    static let killGrace: TimeInterval = 2

    /// Closes stdin (app-server exits on EOF), sends SIGTERM (the node wrapper forwards it to the native binary),
    /// then SIGKILL if the child is still alive after `killGrace`.
    static func terminate(_ process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        try? stdin.fileHandleForWriting.close()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        let box = ProcessBox(process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) {
            if box.process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
