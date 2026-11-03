import Foundation
import Testing
@testable import LidIA

@Suite("Update signing")
struct UpdateSigningTests {

    @Test("Only a real 32-byte EdDSA public key enables updates")
    func publicKeyValidation() {
        let realKey = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": realKey]) == realKey)
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": " \(realKey)\n"]) == realKey)

        #expect(SparkleSigning.publicKey(in: nil) == nil)
        #expect(SparkleSigning.publicKey(in: [:]) == nil)
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": SparkleSigning.placeholderKey]) == nil)
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": ""]) == nil)
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": Data(repeating: 1, count: 16).base64EncodedString()]) == nil)
        #expect(SparkleSigning.publicKey(in: ["SUPublicEDKey": "not base64!"]) == nil)
    }

    @Test("The shipped Info.plist keeps verification on and holds no real key yet")
    func shippedPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/LidIA/Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        let key = try #require(plist["SUPublicEDKey"] as? String)
        // Either the documented placeholder or a well-formed key: never junk.
        #expect(key == SparkleSigning.placeholderKey || SparkleSigning.publicKey(in: plist) != nil)
    }
}
