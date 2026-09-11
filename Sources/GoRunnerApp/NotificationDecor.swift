import AppKit
import GoRunnerCore
import RunnerArt
import RunnerKit
import UniformTypeIdentifiers
import UserNotifications

/// Who a notification is about. Picks the image, the bundled sound and the thread (macOS groups by thread).
enum NotificationSource: String, Sendable, CaseIterable {
    case claude, codex, slack

    /// Bundled by scripts/build-app.sh into Contents/Resources.
    var soundFileName: String { "gorunner-\(rawValue).aiff" }
    var threadIdentifier: String { "gorunner.\(rawValue)" }
}

extension AgentKind {
    var notificationSource: NotificationSource {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// Image attachments and per-service sounds for notifications. Any failure falls back to no attachment and the
/// default sound, so a notification is never lost because of decoration.
@MainActor
final class NotificationDecor {
    static let codexBundleID = "com.openai.codex"
    static let imageEdge = 256
    /// Under `AppPaths.cacheDirectory`, so the uninstaller removes it.
    static var imagesDirectory: URL {
        AppPaths.cacheDirectory.appendingPathComponent("notification-images", isDirectory: true)
    }

    private let catalog: RunnerCatalog?
    /// Rendered once per launch, so a new Clawd sprite or Codex/Slack icon update is picked up on the next launch.
    private var rendered: Set<NotificationSource> = []

    init(catalog: RunnerCatalog?) {
        self.catalog = catalog
    }

    /// `gorunner-<source>.aiff` when it's in the app bundle, otherwise the default sound (always so for the debug binary).
    static func sound(for source: NotificationSource) -> UNNotificationSound {
        let name = source.soundFileName
        guard Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "aiff") != nil else {
            return .default
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    /// A fresh attachment for one notification, or nil.
    func attachment(for source: NotificationSource) -> UNNotificationAttachment? {
        let fileManager = FileManager.default
        let directory = Self.imagesDirectory
        let master = directory.appendingPathComponent("\(source.rawValue).png")
        let copy = directory.appendingPathComponent("\(source.rawValue)-\(UUID().uuidString).png")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !rendered.contains(source) || !fileManager.fileExists(atPath: master.path) {
                guard let png = renderPNG(for: source) else { return nil }
                try png.write(to: master, options: .atomic)
                rendered.insert(source)
            }
            // The system moves an attachment's file into its own store, so give it a unique copy.
            try fileManager.copyItem(at: master, to: copy)
            return try UNNotificationAttachment(identifier: source.rawValue, url: copy,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch {
            try? fileManager.removeItem(at: copy)
            Log.app.error("Notification image for \(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `GoRunner --notification-images-probe=<dir>` (debug, headless): renders the three images into `dir` (not the
    /// cache) and prints their byte sizes plus whether each sound is bundled.
    static func probeCommand(arguments: [String] = CommandLine.arguments) -> Int32 {
        let prefix = "--notification-images-probe="
        guard let arg = arguments.first(where: { $0.hasPrefix(prefix) }), arg.count > prefix.count else { return 1 }
        let directory = URL(fileURLWithPath: (String(arg.dropFirst(prefix.count)) as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decor = NotificationDecor(catalog: RunnerCatalog(builtIns: RunnerArtCatalog.all))
        var images: [String: Any] = [:]
        for source in NotificationSource.allCases {
            if let png = decor.renderPNG(for: source),
               (try? png.write(to: directory.appendingPathComponent("\(source.rawValue).png"))) != nil {
                images[source.rawValue] = png.count
            } else {
                images[source.rawValue] = NSNull()
            }
        }
        var sounds: [String: Bool] = [:]
        for source in NotificationSource.allCases {
            sounds[source.rawValue] = Bundle.main.url(forResource: "gorunner-\(source.rawValue)", withExtension: "aiff") != nil
        }
        let report: [String: Any] = ["imageBytes": images, "soundsBundled": sounds, "directory": directory.path]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return 1
        }
        HeadlessRunner.printJSON(data)
        return 0
    }

    func renderPNG(for source: NotificationSource) -> Data? {
        switch source {
        case .claude:
            return runnerPNG(StatusMenuContent.claudeRunnerID)
        case .codex:
            // The Codex runner's first frame; the installed Codex app's icon if that sprite is missing.
            return runnerPNG(StatusMenuContent.codexRunnerID)
                ?? Self.appIconPNG(bundleID: Self.codexBundleID, edge: Self.imageEdge)
        case .slack:
            return Self.appIconPNG(bundleID: SlackDockBadgeReader.slackBundleID, edge: Self.imageEdge)
        }
    }

    /// First playback frame of a built-in runner, scaled up as pixel art.
    private func runnerPNG(_ id: String) -> Data? {
        guard let catalog, let frames = try? catalog.frames(for: id), !frames.images.isEmpty else { return nil }
        let first = frames.order.first ?? 0
        let index = frames.images.indices.contains(first) ? first : 0
        return Self.pixelArtPNG(frames.images[index], edge: Self.imageEdge)
    }

    /// Pixel art scaled up with nearest-neighbour (whole-number factor when it fits) onto a transparent square.
    static func pixelArtPNG(_ image: CGImage, edge: Int) -> Data? {
        guard image.width > 0, image.height > 0, let context = makeContext(edge: edge) else { return nil }
        context.interpolationQuality = .none
        let fit = min(Double(edge) / Double(image.width), Double(edge) / Double(image.height))
        let scale = fit >= 1 ? floor(fit) : fit
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: ((Double(edge) - width) / 2).rounded(), y: ((Double(edge) - height) / 2).rounded(),
                                       width: width, height: height))
        return context.makeImage().flatMap(pngData)
    }

    /// The installed app's full-color icon, or nil when the app isn't installed.
    static func appIconPNG(bundleID: String, edge: Int) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var proposed = CGRect(x: 0, y: 0, width: edge, height: edge)
        guard let cgImage = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = makeContext(edge: edge) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        return context.makeImage().flatMap(pngData)
    }

    private static func makeContext(edge: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
