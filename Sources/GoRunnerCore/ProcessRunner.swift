import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case timeout
    case launchFailed(String)
}

/// GUI apps launched from Finder do not inherit the user's shell PATH, so tools installed via
/// Homebrew / nvm / volta (claude, codex, aws) are invisible. This resolves the login-shell PATH once.
public enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?

    public static var fallbackDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                    "\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    /// PATH from `$SHELL -lic`, merged with common tool directories. Cached after the first call.
    public static func loginPATH() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        var parts: [String] = []
        if let shellPATH = queryLoginShellPATH() {
            parts = shellPATH.split(separator: ":").map(String.init)
        }
        for dir in fallbackDirectories where !parts.contains(dir) {
            parts.append(dir)
        }
        let path = parts.joined(separator: ":")
        cachedPATH = path
        return path
    }

    /// Process environment with the resolved PATH.
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH()
        return env
    }

    private static func queryLoginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '__GORUNNER_PATH__%s__END__' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__GORUNNER_PATH__"), let end = text.range(of: "__END__", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}

public enum ExecutableLocator {
    /// Finds an executable by name. `override` (absolute path) wins when it is executable.
    public static func locate(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in ShellEnvironment.loginPATH().split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

public enum ProcessRunner {
    /// Runs a process to completion with a timeout, capturing stdout/stderr. Uses the login-shell PATH by default.
    public static func run(_ executable: URL, arguments: [String] = [], stdin: Data? = nil, timeout: TimeInterval = 20,
                           environment: [String: String]? = nil, currentDirectory: URL? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment ?? ShellEnvironment.environment()
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = stdin == nil ? nil : Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe ?? FileHandle.nullDevice

            let box = OutputBox()
            outPipe.fileHandleForReading.readabilityHandler = { box.appendOut($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { box.appendErr($0.availableData) }

            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                box.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                box.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                guard box.claimResume() else { return }
                if box.timedOut {
                    continuation.resume(throwing: ProcessRunnerError.timeout)
                } else {
                    continuation.resume(returning: ProcessResult(exitCode: finished.terminationStatus, stdout: box.out, stderr: box.err))
                }
            }

            do {
                try process.run()
            } catch {
                if box.claimResume() {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
                return
            }

            if let stdin, let inPipe {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    box.markTimedOut()
                    process.terminate()
                }
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    private var _timedOut = false
    private var resumed = false

    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }
    var timedOut: Bool { lock.withLock { _timedOut } }

    func appendOut(_ data: Data) { lock.withLock { _out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { _err.append(data) } }
    func markTimedOut() { lock.withLock { _timedOut = true } }

    func claimResume() -> Bool {
        lock.withLock {
            if resumed { return false }
            resumed = true
            return true
        }
    }
}
