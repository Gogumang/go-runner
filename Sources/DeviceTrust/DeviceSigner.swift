import CryptoKit
import Foundation
import GoRunnerCore

/// The device's P-256 signing capability. The live implementation is backed by the Secure Enclave; tests use a software key.
public protocol DeviceSigner: Sendable {
    /// Uncompressed public key: 0x04 || x (32 bytes) || y (32 bytes).
    var publicKeyX963: Data { get }
    /// ES256 signature over `message` (SHA-256 is applied by the signer), as raw r || s (64 bytes).
    func sign(_ message: Data) throws -> Data
}

extension DeviceSigner {
    public var publicJWK: DevicePublicJWK {
        get throws { try DevicePublicJWK(x963: publicKeyX963) }
    }
}

/// Signer backed by a key that never leaves the Secure Enclave.
public struct SecureEnclaveDeviceSigner: DeviceSigner {
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey

    init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKeyX963: Data { privateKey.publicKey.x963Representation }

    public func sign(_ message: Data) throws -> Data {
        do {
            return try privateKey.signature(for: message).rawRepresentation
        } catch {
            throw DeviceTrustError.signingFailed(error.localizedDescription)
        }
    }
}

/// Creates the Secure Enclave key on first use and loads it afterwards. The file holds only
/// `dataRepresentation`, an encrypted handle that is useless outside this Mac's Secure Enclave.
public final class SecureEnclaveDeviceKeyStore: @unchecked Sendable {
    public static let standard = SecureEnclaveDeviceKeyStore(fileURL: AppPaths.deviceSigningKeyFile)

    private let fileURL: URL
    private let lock = NSLock()
    private var cachedSigner: SecureEnclaveDeviceSigner?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadOrCreateSigner() throws -> SecureEnclaveDeviceSigner {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSigner { return cachedSigner }
        guard SecureEnclave.isAvailable else { throw DeviceTrustError.secureEnclaveUnavailable }

        let signer = SecureEnclaveDeviceSigner(privateKey: try loadOrCreateKey())
        cachedSigner = signer
        return signer
    }

    private func loadOrCreateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            } catch {
                // Not regenerated silently: a new key means a new thumbprint that the collector does not know.
                throw DeviceTrustError.keyStorageFailed(
                    Loc.t("기기 키 파일을 읽지 못했습니다 (\(fileURL.path)): \(error.localizedDescription)",
                          "Could not read the device key file (\(fileURL.path)): \(error.localizedDescription)"))
            }
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try key.dataRepresentation.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            Log.app.notice("Created Secure Enclave device key")
            return key
        } catch {
            throw DeviceTrustError.keyStorageFailed(
                Loc.t("기기 키를 만들지 못했습니다: \(error.localizedDescription)",
                      "Could not create the device key: \(error.localizedDescription)"))
        }
    }
}
