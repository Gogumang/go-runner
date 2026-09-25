import Foundation
import GoRunnerCore

/// Reports when `fileURL`'s modification date changes, without a polling timer.
///
/// Watches the *containing directory* rather than the file itself: the Claude statusline hook writes with
/// "temp file + mv" (see `StatuslineHook.script`), so a vnode source bound to the file's descriptor would stop
/// firing after the first replace. A directory source survives replacement and also catches first creation.
/// If the directory cannot be opened, it falls back to the timer it replaces.
@MainActor
final class FileChangeWatcher {
    static let fallbackPollInterval: TimeInterval = 15
    /// A directory write fires while the renamed file is still settling; read the mtime a beat later.
    private static let settleDelay: TimeInterval = 0.2

    private let fileURL: URL
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var lastModified: Date?
    private var pendingCheck: DispatchWorkItem?
    private var isRunning = false

    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastModified = Self.modificationDate(of: fileURL)
        if !openSource() {
            startPolling()
        }
    }

    func stop() {
        isRunning = false
        pendingCheck?.cancel()
        pendingCheck = nil
        source?.cancel()
        source = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Dispatch source

    private func openSource() -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        return true
    }

    /// Coalesces the burst of events a single `mv` produces into one mtime read.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    // MARK: Fallback polling

    private func startPolling() {
        Log.quota.notice("FileChangeWatcher: no directory source, falling back to polling")
        let timer = Timer(timeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        // Let the kernel coalesce this wake-up with others instead of firing on the exact second.
        timer.tolerance = Self.fallbackPollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: Change detection

    private func checkNow() {
        guard isRunning else { return }
        let modified = Self.modificationDate(of: fileURL)
        defer { lastModified = modified }
        guard let modified, modified != lastModified else { return }
        onChange()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
