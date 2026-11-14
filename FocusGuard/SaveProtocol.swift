import CryptoKit
import Foundation
import Security

@objc(FocusGuardSaveProtocol)
protocol FocusGuardSaveProtocol {
  func enrollment(withReply reply: @escaping (Data?, String?) -> Void)
  func challenge(for payload: Data, withReply reply: @escaping (Data?, String?) -> Void)
  func save(signature: Data, withReply reply: @escaping (String?) -> Void)
}

enum SaveAuthorization {
  static let serviceName = "com.focusguard.save"
  static let basePath = "/Library/Application Support/FocusGuard"
  static let baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
  static let maxPayload = 262_144
  static let helperExecutableName = "SaveHelper"
  static let policyURL = baseURL.appendingPathComponent("biometric-policy.plist")

  static func challenge(nonce: Data, payload: Data) -> Data {
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    return Data("focusguard-save-v1\n\(nonce.base64EncodedString())\n\(digest)\n".utf8)
  }

  static func codeRequirement(for url: URL) throws -> String {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var result: CFString?
    let flags = SecCSFlags(rawValue: 0)
    var status = SecStaticCodeCreateWithPath(url as CFURL, flags, &code)
    guard status == errSecSuccess, let code else { throw securityError(status) }
    status = SecStaticCodeCheckValidity(code, flags, nil)
    guard status == errSecSuccess else { throw securityError(status) }
    status = SecCodeCopyDesignatedRequirement(code, flags, &requirement)
    guard status == errSecSuccess, let requirement else { throw securityError(status) }
    status = SecRequirementCopyString(requirement, flags, &result)
    guard status == errSecSuccess, let result else { throw securityError(status) }
    return result as String
  }

  private static func securityError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: "应用签名验证失败（\(status)）。请重新安装完整的专注时间。",
    ])
  }
}
