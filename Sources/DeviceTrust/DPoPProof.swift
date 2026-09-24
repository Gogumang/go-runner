import Foundation

/// RFC 9449 DPoP proof as a compact ES256 JWS: base64url(header).base64url(payload).base64url(r || s).
public enum DPoPProof {
    public static let type = "dpop+jwt"
    public static let algorithm = "ES256"

    struct Header: Codable, Equatable {
        let typ: String
        let alg: String
        let jwk: DevicePublicJWK
    }

    struct Payload: Codable, Equatable {
        let jti: String
        let htm: String
        let htu: String
        let iat: Int
    }

    /// `url` must be exactly the request URL (no query, no trailing slash); the collector compares it to `htu`.
    public static func make(signer: DeviceSigner, method: String, url: URL, jti: String, issuedAt: Date) throws -> String {
        let header = Header(typ: type, alg: algorithm, jwk: try signer.publicJWK)
        let payload = Payload(jti: jti, htm: method.uppercased(), htu: url.absoluteString,
                              iat: Int(issuedAt.timeIntervalSince1970.rounded(.down)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signingInput = Base64URL.encode(try encoder.encode(header)) + "." + Base64URL.encode(try encoder.encode(payload))
        let signature = try signer.sign(Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature)
    }
}
