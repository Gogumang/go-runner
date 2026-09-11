import Foundation
import GoRunnerCore

/// Tails `AppPaths.agentEventsFile` (appended by `gorunner-agent-event`, see AgentEvents.swift) and reports each new
/// complete line. Starts at the end of the file, so events recorded while GoRunner wasn't running are never replayed.
///
/// Uses a vnode dispatch source while the file exists and polls every 2 s until it appears. The file is truncated
/// in place once it grows past 512 KB (the recorder appends with `>>`, so it keeps writing from offset 0).
@MainActor
final class AgentEventWatcher {
    static let maxFileBytes: UInt64 = 512 * 1024
    static let pollInterval: TimeInterval = 2
    /// A "line" longer than this without a newline is garbage; drop it rather than buffer forever.
    private static let maxPendingBytes = 64 * 1024

    private let fileURL: URL
    private let onEvent: (AgentEvent) -> Void

    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var isRunning = false

    init(fileURL: URL = AppPaths.agentEventsFile, onEvent: @escaping (AgentEvent) -> Void) {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pending.removeAll()
        offset = Self.fileSize(fileURL) ?? 0
        if offset > Self.maxFileBytes {
            truncateFile()
        }
        if !openSource() {
            startPolling()
        }
    }

    func stop() {
        isRunning = false
        closeSource()
        stopPolling()
    }

    // MARK: Dispatch source

    private func openSource() -> Bool {
        closeSource()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .extend, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let flags = self.source?.data else { return }
                self.handle(flags)
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        return true
    }

    private func closeSource() {
        source?.cancel()
        source = nil
    }

    private func handle(_ flags: DispatchSource.FileSystemEvent) {
        guard isRunning else { return }
        if flags.contains(.delete) || flags.contains(.rename) {
            // The path now names a different file (or nothing). Anything at the path from here on is new.
            closeSource()
            offset = 0
            pending.removeAll()
            if openSource() {
                readNewLines()
            } else {
                startPolling()
            }
            return
        }
        readNewLines()
    }

    // MARK: Polling (file doesn't exist yet)

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard isRunning, FileManager.default.fileExists(atPath: fileURL.path), openSource() else { return }
        stopPolling()
        // The file appeared after we started watching, so every line in it is new.
        offset = 0
        pending.removeAll()
        readNewLines()
    }

    // MARK: Reading

    private func readNewLines() {
        guard let size = Self.fileSize(fileURL) else { return }
        if size < offset {
            // Truncated or replaced by someone else.
            offset = 0
            pending.removeAll()
        }
        guard size > offset else { return }
        if size - offset > Self.maxFileBytes {
            // Far too much at once to be real events; skip it.
            offset = size
            truncateFile()
            return
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            data = try handle.readToEnd() ?? Data()
        } catch {
            Log.app.error("Agent events read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        offset += UInt64(data.count)
        pending.append(data)

        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if let line = String(data: lineData, encoding: .utf8), let event = AgentEventLog.parse(line: line) {
                onEvent(event)
            }
        }
        if pending.count > Self.maxPendingBytes {
            pending.removeAll()
        }
        if offset > Self.maxFileBytes {
            truncateFile()
        }
    }

    private func truncateFile() {
        if truncate(fileURL.path, 0) == 0 {
            offset = 0
            pending.removeAll()
        } else {
            Log.app.error("Agent events truncate failed: errno \(errno)")
        }
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }
}
