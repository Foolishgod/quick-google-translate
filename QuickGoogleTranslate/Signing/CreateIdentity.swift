import Foundation
import Security
import CryptoKit

// This tool creates a dedicated code-signing identity in the login keychain.
// Only the PUBLIC certificate and fingerprints are written to the workspace.
// Private-key external representation, PEM, PKCS#12 and exports are never used.
let label = "QuickGoogleTranslate Personal Code Signing"
let tag = Data("local.quickgoogletranslate.mac.codesigning.v1".utf8)
func fail(_ message: String) -> Never { fputs("Signing identity: \(message)\n", stderr); exit(1) }
func status(_ code: OSStatus, _ operation: String) {
    guard code == errSecSuccess else { fail("\(operation): \(SecCopyErrorMessageString(code, nil) as String? ?? String(code))") }
}
func der(_ type: UInt8, _ bytes: Data) -> Data {
    var length = bytes.count
    var encoded: [UInt8] = []
    if length < 128 { encoded = [UInt8(length)] }
    else {
        while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
        encoded.insert(0x80 | UInt8(encoded.count), at: 0)
    }
    return Data([type] + encoded) + bytes
}
func sequence(_ values: Data...) -> Data { der(0x30, values.reduce(Data(), +)) }
func oid(_ value: String) -> Data {
    let parts = value.split(separator: ".").map { UInt64($0)! }
    var bytes: [UInt8] = []
    for number in [parts[0] * 40 + parts[1]] + Array(parts.dropFirst(2)) {
        var n = number; var encoded = [UInt8(n & 127)]; n >>= 7
        while n > 0 { encoded.insert(UInt8(n & 127) | 128, at: 0); n >>= 7 }
        bytes += encoded
    }
    return der(0x06, Data(bytes))
}
func integer(_ bytes: Data) -> Data {
    var value = bytes
    if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
    return der(0x02, value)
}
func certificateFor(_ key: SecKey) -> SecCertificate {
    guard let publicKey = SecKeyCopyPublicKey(key) else { fail("Missing public key") }
    var error: Unmanaged<CFError>?
    // This export operates exclusively on the PUBLIC key.
    guard let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { fail("Cannot read public key") }
    let null = der(0x05, Data())
    let algorithm = sequence(oid("1.2.840.113549.1.1.11"), null)
    let name = sequence(der(0x31, sequence(oid("2.5.4.3"), der(0x0c, Data(label.utf8)))))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    let now = Date()
    let end = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: now)!
    let validity = sequence(der(0x18, Data(formatter.string(from: now.addingTimeInterval(-300)).utf8)), der(0x18, Data(formatter.string(from: end).utf8)))
    var serial = [UInt8](repeating: 0, count: 16)
    status(SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial), "Create certificate serial")
    serial[0] &= 0x7f; serial[0] |= 1
    let publicInfo = sequence(sequence(oid("1.2.840.113549.1.1.1"), null), der(0x03, Data([0]) + publicData))
    func ext(_ identifier: String, _ value: Data, critical: Bool = false) -> Data {
        var bytes = oid(identifier)
        if critical { bytes += der(0x01, Data([0xff])) }
        return der(0x30, bytes + der(0x04, value))
    }
    let extensions = sequence(
        ext("2.5.29.19", sequence(), critical: true),
        ext("2.5.29.15", der(0x03, Data([7, 0x80])), critical: true),
        ext("2.5.29.37", sequence(oid("1.3.6.1.5.5.7.3.3")))
    )
    let body = sequence(der(0xa0, integer(Data([2]))), integer(Data(serial)), algorithm, name, validity, name, publicInfo, der(0xa3, extensions))
    guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, &error) as Data? else {
        fail("Certificate signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
    }
    guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, signature as CFData, &error),
          let certificate = SecCertificateCreateWithData(nil, sequence(body, algorithm, der(0x03, Data([0]) + signature)) as CFData) else { fail("Certificate self-signature invalid") }
    return certificate
}
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--create" else { fail("Usage: create-identity --create <public configuration directory>") }
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let pinFile = folder.appendingPathComponent("identity.json")
var result: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label, kSecReturnRef as String: true]
let found = SecItemCopyMatching(query as CFDictionary, &result)
let certificate: SecCertificate
if found == errSecSuccess {
    guard let result, CFGetTypeID(result) == SecCertificateGetTypeID() else { fail("Unexpected certificate item") }
    certificate = (result as! SecCertificate)
} else {
    guard found == errSecItemNotFound else { status(found, "Find existing certificate"); exit(1) }
    guard !FileManager.default.fileExists(atPath: pinFile.path) else { fail("Pinned identity is missing from Keychain; will not silently replace it") }
    var keyResult: CFTypeRef?
    let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrApplicationTag as String: tag, kSecReturnRef as String: true]
    let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)
    let key: SecKey
    if keyStatus == errSecSuccess {
        guard let keyResult, CFGetTypeID(keyResult) == SecKeyGetTypeID() else { fail("Unexpected key item") }
        key = (keyResult as! SecKey)
    } else {
        guard keyStatus == errSecItemNotFound else { status(keyStatus, "Find existing key"); exit(1) }
        var current: SecTrustedApplication?, signer: SecTrustedApplication?, access: SecAccess?
        status(SecTrustedApplicationCreateFromPath(nil, &current), "Identify certificate setup tool")
        status(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &signer), "Identify system codesign tool")
        status(SecAccessCreate(label as CFString, [current!, signer!] as CFArray, &access), "Create dedicated key access list")
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrLabel as String: label, kSecAttrApplicationTag as String: tag, kSecAttrIsExtractable as String: false, kSecAttrAccess as String: access!]
        ]
        guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { fail("Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")") }
        key = generated
    }
    certificate = certificateFor(key)
    status(SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecAttrLabel as String: label] as CFDictionary, nil), "Store public certificate")
}
var identity: SecIdentity?
status(SecIdentityCreateWithCertificate(nil, certificate, &identity), "Match certificate to its private key")
let publicDER = SecCertificateCopyData(certificate) as Data
let sha1 = Insecure.SHA1.hash(data: publicDER).map { String(format: "%02X", $0) }.joined()
if FileManager.default.fileExists(atPath: pinFile.path) {
    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: pinFile)) as! [String: String]
    guard previous["sha1"] == sha1 else { fail("Existing certificate differs from pinned identity") }
}
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try publicDER.write(to: folder.appendingPathComponent("certificate.der"), options: .atomic)
let publicConfiguration = ["label": label, "sha1": sha1, "sha256": SHA256.hash(data: publicDER).map { String(format: "%02X", $0) }.joined()]
try JSONSerialization.data(withJSONObject: publicConfiguration, options: [.prettyPrinted, .sortedKeys]).write(to: pinFile, options: .atomic)
print("Ready: fixed personal signing identity \(sha1). Private key stays in Keychain; configuration contains only public certificate metadata.")
