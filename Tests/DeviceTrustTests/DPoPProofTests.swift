import CryptoKit
import Foundation
import Testing
@testable import DeviceTrust

struct DPoPProofTests {
    let url = URL(string: "https://airflow.gogumang.com/collector/api/device/sessions")!
    let jti = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    let issuedAt = Date(timeIntervalSince1970: 1_790_000_000.9)

    @Test("헤더와 페이로드가 계약의 필드를 담는다") func headerAndPayloadCarryContractFields() throws {
        // Act
        let proof = try DPoPProof.make(signer: TestKey.signer(), method: "post", url: url, jti: jti, issuedAt: issuedAt)

        // Assert
        let parts = proof.split(separator: ".", omittingEmptySubsequences: false)
        try #require(parts.count == 3, "proof was: \(proof)")
        let header = try jsonObject(parts[0])
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        let jwk = try #require(header["jwk"] as? [String: String], "header was: \(header)")
        #expect(jwk == ["kty": "EC", "crv": "P-256", "x": TestKey.expectedX, "y": TestKey.expectedY])

        let payload = try jsonObject(parts[1])
        #expect(payload["jti"] as? String == jti)
        #expect(payload["htm"] as? String == "POST")
        #expect(payload["htu"] as? String == "https://airflow.gogumang.com/collector/api/device/sessions")
        #expect(payload["iat"] as? Int == 1_790_000_000, "iat must be whole epoch seconds, payload was: \(payload)")
        #expect(Set(payload.keys) == ["jti", "htm", "htu", "iat"])
    }

    @Test("htu의 슬래시는 이스케이프하지 않는다") func htuSlashesAreNotEscaped() throws {
        let proof = try DPoPProof.make(signer: TestKey.signer(), method: "POST", url: url, jti: jti, issuedAt: issuedAt)
        let payloadText = String(decoding: try decodeSegment(proof.split(separator: ".")[1]), as: UTF8.self)
        #expect(payloadText.contains(#""htu":"https://airflow.gogumang.com/collector/api/device/sessions""#),
                "payload was: \(payloadText)")
    }

    @Test("서명은 r s 64바이트이고 공개키로 검증된다") func signatureIsRawAndVerifies() throws {
        // Arrange
        let signer = try TestKey.signer()

        // Act
        let proof = try DPoPProof.make(signer: signer, method: "POST", url: url, jti: jti, issuedAt: issuedAt)

        // Assert
        let parts = proof.split(separator: ".")
        let signatureBytes = try decodeSegment(parts[2])
        #expect(signatureBytes.count == 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        #expect(signer.privateKey.publicKey.isValidSignature(signature, for: signingInput))

        let otherKey = P256.Signing.PrivateKey().publicKey
        #expect(!otherKey.isValidSignature(signature, for: signingInput), "a different key must not verify")
        #expect(!signer.privateKey.publicKey.isValidSignature(signature, for: Data("\(parts[0]).x".utf8)))
    }
}
