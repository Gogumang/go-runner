// "어드민 열기": proves this Mac to the collector with its Secure Enclave key, hands the one-time code to grep-admin in the
// browser, then keeps the device session alive with heartbeats. Contract: collector <-> go-runner <-> grep-admin device trust.

import AppKit
import DeviceTrust
import GoRunnerCore

@MainActor
final class DeviceTrustController: ObservableObject {
    /// The collector invalidates a device's sessions after 3 minutes without a heartbeat, so 60 s leaves two retries.
    static let heartbeatIntervalSeconds: UInt64 = 60
    /// Matches the collector's absolute device-session lifetime; heartbeats after that would keep nothing alive.
    static let heartbeatDuration: TimeInterval = 12 * 60 * 60

    @Published private(set) var thumbprint: String?
    @Published private(set) var thumbprintError: String?
    @Published private(set) var isOpeningAdmin = false
    @Published private(set) var connection: AdminConnection = .disconnected
    @Published private(set) var isRequestingEnrollment = false
    /// Result line under the "이 Mac 등록 요청" button; nil until the first request.
    @Published private(set) var enrollmentMessage: String?

    private let settingsStore: SettingsStore
    private let client: DeviceTrustClient
    private let keyStore: SecureEnclaveDeviceKeyStore
    private var heartbeatTask: Task<Void, Never>?

    init(settingsStore: SettingsStore, client: DeviceTrustClient = .live, keyStore: SecureEnclaveDeviceKeyStore = .standard) {
        self.settingsStore = settingsStore
        self.client = client
        self.keyStore = keyStore
    }

    /// Creates the Secure Enclave key on first call.
    func loadThumbprint() {
        guard thumbprint == nil else { return }
        do {
            thumbprint = try keyStore.loadOrCreateSigner().publicJWK.thumbprint
            thumbprintError = nil
        } catch {
            thumbprintError = error.localizedDescription
            Log.app.error("Device thumbprint unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyThumbprint() {
        guard let thumbprint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(thumbprint, forType: .string)
    }

    func openAdmin() {
        guard !isOpeningAdmin else { return }
        isOpeningAdmin = true
        let previousConnection = connection
        connection = .connecting
        let addresses = settingsStore.settings.deviceTrust
        let client = client
        Task { @MainActor in
            defer { isOpeningAdmin = false }
            do {
                let handoff = try await client.openSession(collectorBaseURL: addresses.effectiveCollectorBaseURL)
                let url = try DeviceTrustEndpoints.adminConnectURL(adminBase: addresses.effectiveAdminBaseURL, handoffCode: handoff.handoffCode)
                NSWorkspace.shared.open(url)
                connection = .connected(lastSignalAt: Date())
                startHeartbeats(collectorBaseURL: addresses.effectiveCollectorBaseURL)
            } catch {
                // Heartbeats from an earlier session may still be running; don't claim it dropped because a reopen failed.
                connection = previousConnection
                Log.app.error("Open admin failed: \(error.localizedDescription, privacy: .public)")
                showError(error)
            }
        }
    }

    /// Asks the collector to add this Mac. Nothing opens until an already registered Mac approves it on the admin 기기 page.
    func requestEnrollment() {
        guard !isRequestingEnrollment else { return }
        isRequestingEnrollment = true
        let collectorBaseURL = settingsStore.settings.deviceTrust.effectiveCollectorBaseURL
        let deviceName = Host.current().localizedName ?? "Mac"
        let client = client
        Task { @MainActor in
            defer { isRequestingEnrollment = false }
            do {
                switch try await client.requestEnrollment(collectorBaseURL: collectorBaseURL, deviceName: deviceName) {
                case .registered:
                    enrollmentMessage = Loc.t("이미 등록된 Mac이에요. 메뉴의 '어드민 열기'를 쓰면 돼요.",
                                              "This Mac is already registered. Use 'Open Admin' in the menu.")
                case .pending:
                    enrollmentMessage = Loc.t("요청했어요. 등록된 Mac에서 어드민 → 관리 → 기기를 열어 10분 안에 승인하세요.",
                                              "Requested. Approve it within 10 minutes from a registered Mac: Admin > 관리 > 기기.")
                }
            } catch {
                enrollmentMessage = error.localizedDescription
            }
        }
    }

    /// Restarts the 12-hour window on every successful "어드민 열기". A failed heartbeat is not alerted (the admin page
    /// says to reopen when the session is gone); it only turns the menu's connection row red until the next success.
    private func startHeartbeats(collectorBaseURL: String) {
        heartbeatTask?.cancel()
        let client = client
        let interval = Self.heartbeatIntervalSeconds
        let deadline = Date().addingTimeInterval(Self.heartbeatDuration)
        heartbeatTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled, Date() < deadline else { break }
                do {
                    try await client.sendHeartbeat(collectorBaseURL: collectorBaseURL)
                    await self?.recordHeartbeat(failure: nil)
                } catch {
                    Log.app.error("Device heartbeat failed: \(error.localizedDescription, privacy: .public)")
                    await self?.recordHeartbeat(failure: error.localizedDescription)
                }
            }
            if !Task.isCancelled { await self?.markDisconnected() }
            Log.app.info("Device heartbeats stopped")
        }
    }

    private func recordHeartbeat(failure: String?) {
        guard !Task.isCancelled else { return }
        switch (failure, connection) {
        case (nil, _):
            connection = .connected(lastSignalAt: Date())
        case (let reason?, .connected(let lastSignalAt)), (let reason?, .unstable(let lastSignalAt, _)):
            connection = .unstable(lastSignalAt: lastSignalAt, reason: reason)
        case (_?, _):
            break
        }
    }

    private func markDisconnected() {
        connection = .disconnected
    }

    /// Stops heartbeats; the collector closes this Mac's admin sessions within 3 minutes.
    func disconnect() {
        stop()
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection = .disconnected
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Loc.t("어드민을 열지 못했습니다", "Couldn't open the admin")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Loc.t("확인", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
