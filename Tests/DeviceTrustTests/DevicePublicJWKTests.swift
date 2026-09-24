import CryptoKit
import Foundation
import Testing
@testable import DeviceTrust

struct DevicePublicJWKTests {
    @Test("x963 공개키에서 x y 좌표를 base64url로 뽑는다") func extractsCoordinatesFromX963() throws {
        // Arrange
        let signer = try TestKey.signer()

        // Act
        let jwk = try signer.publicJWK

        // Assert
        #expect(jwk.kty == "EC")
        #expect(jwk.crv == "P-256")
        #expect(jwk.x == TestKey.expectedX)
        #expect(jwk.y == TestKey.expectedY)
    }

    @Test("thumbprint는 사전순 공백없는 JSON의 SHA256이다") func thumbprintHashesCanonicalJSON() throws {
        // Arrange
        let jwk = try TestKey.signer().publicJWK

        // Act
        let input = jwk.thumbprintInput
        let thumbprint = jwk.thumbprint

        // Assert
        #expect(input == #"{"crv":"P-256","kty":"EC","x":"\#(TestKey.expectedX)","y":"\#(TestKey.expectedY)"}"#)
        #expect(thumbprint == TestKey.expectedThumbprint, "thumbprint was: \(thumbprint)")
        #expect(!thumbprint.contains("="), "no padding expected, was: \(thumbprint)")
        #expect(thumbprint.count == 43)
    }

    @Test("압축되거나 길이가 틀린 공개키는 거부한다") func rejectsMalformedPublicKeys() throws {
        let compressed = try TestKey.signer().privateKey.publicKey.compressedRepresentation
        #expect(throws: DeviceTrustError.invalidPublicKey) { try DevicePublicJWK(x963: compressed) }
        #expect(throws: DeviceTrustError.invalidPublicKey) {
            try DevicePublicJWK(x963: Data([0x04] + [UInt8](repeating: 1, count: 63)))
        }
    }

    @Test("base64url 왕복") func base64URLRoundTrip() {
        let samples = [Data(), Data([0xfb, 0xff]), Data([0x00, 0x01, 0x02, 0xfe, 0xff])]
        for sample in samples {
            let encoded = Base64URL.encode(sample)
            #expect(!(encoded.contains("+") || encoded.contains("/") || encoded.contains("=")), "encoded: \(encoded)")
            #expect(Base64URL.decode(encoded) == sample, "encoded: \(encoded)")
        }
    }
}
