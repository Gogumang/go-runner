import CryptoKit
import Foundation
@testable import DeviceTrust

// swift-testing instead of XCTest: the Command Line Tools toolchain ships Testing.framework but not XCTest,
// so these tests also run on machines without Xcode.

/// Software P-256 key standing in for the Secure Enclave.
struct SoftwareDeviceSigner: DeviceSigner {
    let privateKey: P256.Signing.PrivateKey

    var publicKeyX963: Data { privateKey.publicKey.x963Representation }

    func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}

enum TestKey {
    /// RFC 6979 A.2.5 P-256 private key, so the public key is a published value.
    static let privateScalarHex = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
    static let expectedX = "YP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Y"
    static let expectedY = "eQP-EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk"
    /// base64url(SHA-256({"crv":"P-256","kty":"EC","x":…,"y":…})), computed independently with Python `cryptography` + hashlib.
    static let expectedThumbprint = "DOvxvJiAdIqVWIkFt5hDtCunXLF0BV4-JGv4f-ALSm0"

    static func signer() throws -> SoftwareDeviceSigner {
        SoftwareDeviceSigner(privateKey: try P256.Signing.PrivateKey(rawRepresentation: hexData(privateScalarHex)))
    }

    static func hexData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }
}

struct UndecodableSegment: Error {
    let segment: String
}

func decodeSegment(_ base64URL: Substring) throws -> Data {
    guard let data = Base64URL.decode(String(base64URL)) else { throw UndecodableSegment(segment: String(base64URL)) }
    return data
}

func jsonObject(_ base64URL: Substring) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: decodeSegment(base64URL)) as? [String: Any] ?? [:]
}

func httpResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}
