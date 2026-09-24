import Foundation
import GoRunnerCore

/// go-runner side of the device-trust contract: every request carries only a DPoP proof (no token, no body).
public struct DeviceTrustClient: Sendable {
    public typealias SignerLoader = @Sendable () throws -> DeviceSigner
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let requestTimeout: TimeInterval = 15
    static let method = "POST"

    var loadSigner: SignerLoader
    var transport: Transport
    var now: @Sendable () -> Date
    var makeJTI: @Sendable () -> String

    public init(loadSigner: @escaping SignerLoader, transport: @escaping Transport,
                now: @escaping @Sendable () -> Date = { Date() },
                makeJTI: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.loadSigner = loadSigner
        self.transport = transport
        self.now = now
        self.makeJTI = makeJTI
    }

    /// POST /api/device/sessions and returns the one-time handoff code for grep-admin.
    public func openSession(collectorBaseURL: String) async throws -> DeviceSessionHandoff {
        let (status, body) = try await post(collectorBaseURL: collectorBaseURL, path: DeviceTrustEndpoints.sessionsPath)
        return try DeviceTrustResponseParser.parseSession(status: status, body: body)
    }

    /// POST /api/device/heartbeat. Keeps this Mac's sessions alive (the collector drops them after 3 minutes of silence).
    public func sendHeartbeat(collectorBaseURL: String) async throws {
        let (status, body) = try await post(collectorBaseURL: collectorBaseURL, path: DeviceTrustEndpoints.heartbeatPath)
        try DeviceTrustResponseParser.parseHeartbeat(status: status, body: body)
    }

    func makeRequest(collectorBaseURL: String, path: String) throws -> URLRequest {
        let url = try DeviceTrustEndpoints.url(base: collectorBaseURL, path: path)
        let proof = try DPoPProof.make(signer: try loadSigner(), method: Self.method, url: url, jti: makeJTI(), issuedAt: now())
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = Self.method
        request.httpShouldHandleCookies = false
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GoRunner/\(AppIdentity.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func post(collectorBaseURL: String, path: String) async throws -> (Int, Data) {
        let request = try makeRequest(collectorBaseURL: collectorBaseURL, path: path)
        do {
            let (data, response) = try await transport(request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError where error.code == .timedOut {
            throw DeviceTrustError.timedOut
        } catch {
            throw DeviceTrustError.network(error.localizedDescription)
        }
    }
}

extension DeviceTrustClient {
    /// Ephemeral session: no cookies, no URL cache, nothing persisted under HTTPStorages.
    static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    /// Secure Enclave key from `AppPaths.deviceSigningKeyFile` and the ephemeral URL session.
    public static var live: DeviceTrustClient {
        DeviceTrustClient(loadSigner: { try SecureEnclaveDeviceKeyStore.standard.loadOrCreateSigner() },
                          transport: { request in try await liveSession.data(for: request) })
    }
}
