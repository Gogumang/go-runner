import CryptoKit
import Foundation

/// Public half of the device key as an EC JWK, plus its RFC 7638 thumbprint (the device's registration id).
public struct DevicePublicJWK: Codable, Equatable, Sendable {
    static let uncompressedPointPrefix: UInt8 = 0x04
    static let coordinateLength = 32

    public let kty: String
    public let crv: String
    public let x: String
    public let y: String

    public init(x963: Data) throws {
        let bytes = [UInt8](x963)
        guard bytes.count == 1 + 2 * Self.coordinateLength, bytes[0] == Self.uncompressedPointPrefix else {
            throw DeviceTrustError.invalidPublicKey
        }
        kty = "EC"
        crv = "P-256"
        x = Base64URL.encode(Data(bytes[1...Self.coordinateLength]))
        y = Base64URL.encode(Data(bytes[(1 + Self.coordinateLength)...]))
    }

    /// RFC 7638 input: required members only, keys in lexicographic order, no whitespace.
    /// Built by hand because the collector hashes exactly these bytes; x and y are base64url so need no escaping.
    public var thumbprintInput: String {
        #"{"crv":"\#(crv)","kty":"\#(kty)","x":"\#(x)","y":"\#(y)"}"#
    }

    /// base64url(SHA-256(thumbprintInput)) without padding. This is the value listed in COLLECTOR_DEVICE_KEYS.
    public var thumbprint: String {
        Base64URL.encode(Data(SHA256.hash(data: Data(thumbprintInput.utf8))))
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
