import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

private struct BiometricFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

// The stored bytes are a device-bound, encrypted Secure Enclave key reference.
// They contain no password or extractable private key. Every signature requires
// the current enrolled fingerprint set; changing the file cannot forge a save.
enum BiometricSave {
  private static let keyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("FocusGuard", isDirectory: true).appendingPathComponent("touchid-key-v1")

  static var isProvisioned: Bool {
    guard let data = try? Data(contentsOf: SaveAuthorization.policyURL), data.count <= 65_536,
          let policy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          policy["version"] as? Int == 1,
          (policy["uid"] as? NSNumber)?.uint32Value == getuid() else { return false }
    return true
  }

  static var explanation: String {
    isProvisioned ? "使用 Touch ID 验证后保存" : "首次启用需一次 macOS 系统授权"
  }

  static func publicKeyHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func provision(script: String, payload: String) -> String? {
    do {
      let context = try newContext()
      defer { context.invalidate() }
      try prepareKeyDirectory()
      let key = try createKey(context: context)
      let pending = pendingKeyURL(for: key.publicKey.x963Representation)
      // Persist before root enrollment: if this UI exits during authorization,
      // the next instance can recover the matching device-bound key reference.
      try storeKey(key.dataRepresentation, at: pending)
      if let problem = runAdministratorInstall(script: script, payload: payload, enrollmentPublicKey: key.publicKey.x963Representation) {
        if enrolledPublicKey() != key.publicKey.x963Representation { try? FileManager.default.removeItem(at: pending) }
        return problem
      }
      try promoteKey(from: pending)
      return nil
    } catch { return readableError(error) }
  }

  static func save(payload: String) -> String? {
    do {
      let bytes = Data(payload.utf8)
      guard !bytes.isEmpty, bytes.count <= SaveAuthorization.maxPayload, !bytes.contains(0) else {
        throw BiometricFailure("配置内容为空、过大或格式不正确。")
      }
      guard isProvisioned else { throw BiometricFailure("请先启用指纹保存。首次安装需要一次 macOS 系统授权。") }
      let context = try newContext()
      defer { context.invalidate() }
      let key = try loadKey(context: context)
      let client = try SaveClient()
      defer { client.invalidate() }
      let publicKey = try client.enrollment()
      guard publicKey == key.publicKey.x963Representation else {
        throw BiometricFailure("指纹授权与本机密钥不一致，请重新启用指纹保存。")
      }
      let nonce = try client.challenge(for: bytes)
      guard nonce.count == 32 else { throw BiometricFailure("保存服务返回了无效的验证信息。") }
      // A fresh LAContext and zero reuse duration require authentication for this
      // operation. The root helper verifies this signature, never a GUI Boolean.
      let signature = try key.signature(for: SaveAuthorization.challenge(nonce: nonce, payload: bytes))
      try client.save(signature: signature.derRepresentation)
      return nil
    } catch { return readableError(error) }
  }

  private static func newContext() throws -> LAContext {
    let context = LAContext()
    context.localizedReason = "保存专注时间的设置"
    context.localizedCancelTitle = "取消保存"
    context.localizedFallbackTitle = ""
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
          context.biometryType == .touchID, SecureEnclave.isAvailable else {
      context.invalidate()
      if let error { throw error }
      throw BiometricFailure("这台 Mac 当前不能使用 Touch ID。请在系统设置中检查指纹。")
    }
    return context
  }

  private static func enrolledPublicKey() -> Data? {
    guard let data = try? Data(contentsOf: SaveAuthorization.policyURL), data.count <= 65_536,
          let policy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          (policy["uid"] as? NSNumber)?.uint32Value == getuid() else { return nil }
    return policy["publicKey"] as? Data
  }

  private static func pendingKeyURL(for publicKey: Data) -> URL {
    keyURL.deletingLastPathComponent().appendingPathComponent("touchid-pending-\(publicKeyHash(publicKey))")
  }

  private static func loadKey(context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
    guard let expected = enrolledPublicKey() else { throw BiometricFailure("指纹授权配置缺失，请重新启用指纹保存。") }
    for candidate in [keyURL, pendingKeyURL(for: expected)] {
      guard let data = try? readKeyData(at: candidate),
            let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context),
            key.publicKey.x963Representation == expected else { continue }
      if candidate != keyURL { try promoteKey(from: candidate) }
      return key
    }
    throw BiometricFailure("指纹设置或本机密钥已变更，需要重新启用指纹保存。")
  }

  private static func readKeyData(at url: URL) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw BiometricFailure("找不到本机指纹密钥，请重新启用指纹保存。") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
            info.st_mode & mode_t(0o077) == 0, info.st_nlink == 1, info.st_size > 0, info.st_size < 65_536 else {
        throw BiometricFailure("本机指纹密钥文件的权限或类型不正确。")
    }
    return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65_536) ?? Data()
  }

  private static func createKey(context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage, .biometryCurrentSet], &accessError) else {
      throw accessError?.takeRetainedValue() as Error? ?? BiometricFailure("无法设置指纹密钥保护。")
    }
    return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
  }

  private static func prepareKeyDirectory(_ directory: URL = keyURL.deletingLastPathComponent()) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw BiometricFailure("本机指纹密钥目录的类型不正确。") }
    defer { close(fd) }
    var parent = stat()
    guard fstat(fd, &parent) == 0, parent.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          parent.st_uid == getuid(), fchmod(fd, mode_t(0o700)) == 0 else {
      throw BiometricFailure("本机指纹密钥目录的权限不正确。")
    }
  }

  private static func promoteKey(from pending: URL, to destination: URL = keyURL) throws {
    _ = try readKeyData(at: pending)
    guard rename(pending.path, destination.path) == 0 else {
      throw BiometricFailure("指纹配对已保留，下次保存会自动恢复本机密钥。")
    }
    syncDirectory(destination.deletingLastPathComponent())
  }

  private static func syncDirectory(_ directory: URL) {
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if fd >= 0 { _ = fsync(fd); close(fd) }
  }

  private static func storeKey(_ data: Data, at destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".touchid-key-\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw BiometricFailure("无法创建本机指纹密钥文件。") }
    var complete = false
    defer {
      close(fd)
      if !complete { unlink(temporary.path) }
    }
    try data.withUnsafeBytes { bytes in
      var total = 0
      while total < bytes.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: total), bytes.count - total)
        guard count > 0 else { throw BiometricFailure("无法保存本机指纹密钥。") }
        total += count
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, destination.path) == 0 else {
      throw BiometricFailure("指纹服务已启用，但本机密钥未保存。请重新启用指纹保存。")
    }
    complete = true
    syncDirectory(directory)
  }

  static func selfTestStorage() -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focusguard-key-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      try prepareKeyDirectory(directory)
      let active = directory.appendingPathComponent("active")
      let pending = directory.appendingPathComponent("pending")
      let old = Data("old-encrypted-reference".utf8)
      let candidate = Data("new-encrypted-reference".utf8)
      try storeKey(old, at: active)
      try storeKey(candidate, at: pending)
      // During a canceled install or a UI crash, old key and durable pending key
      // both remain available. Only a matched, enrolled pending key is promoted.
      guard try readKeyData(at: active) == old, try readKeyData(at: pending) == candidate else { return false }
      try promoteKey(from: pending, to: active)
      guard try readKeyData(at: active) == candidate, !FileManager.default.fileExists(atPath: pending.path) else { return false }
      let fifo = directory.appendingPathComponent("fifo")
      guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { return false }
      do { _ = try readKeyData(at: fifo); return false } catch {}
      let link = directory.appendingPathComponent("link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: active)
      do { _ = try readKeyData(at: link); return false } catch {}
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: active.path)
      do { _ = try readKeyData(at: active); return false } catch {}
      print("ok biometric key staging, crash recovery and file validation")
      return true
    } catch { return false }
  }

  private static func readableError(_ error: Error) -> String {
    let problem = error as NSError
    if problem.domain == LAError.errorDomain || problem.domain == NSOSStatusErrorDomain {
      switch problem.code {
      case LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue, Int(errSecUserCanceled):
        return "已取消指纹验证，设置未保存。"
      case LAError.biometryLockout.rawValue:
        return "Touch ID 已锁定，请先按 macOS 提示解锁，再回来保存。"
      case LAError.biometryNotEnrolled.rawValue, LAError.biometryNotAvailable.rawValue:
        return "Touch ID 当前不可用，请在系统设置中检查指纹。"
      default: break
      }
    }
    return problem.localizedDescription
  }
}

// XPC failures never cause a password fallback or an unsigned config write.
private final class SaveClient {
  private let connection: NSXPCConnection
  init() throws {
    guard let executable = Bundle.main.resourceURL?.appendingPathComponent(SaveAuthorization.helperExecutableName),
          FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw BiometricFailure("指纹保存组件缺失，请重新安装完整的专注时间。")
    }
    connection = NSXPCConnection(machServiceName: SaveAuthorization.serviceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: FocusGuardSaveProtocol.self)
    connection.setCodeSigningRequirement(try SaveAuthorization.codeRequirement(for: executable))
    connection.resume()
  }
  func invalidate() { connection.invalidate() }

  func enrollment() throws -> Data {
    try request { proxy, finish in
      proxy.enrollment { value, problem in finish(value, problem) }
    }
  }
  func challenge(for payload: Data) throws -> Data {
    try request { proxy, finish in
      proxy.challenge(for: payload) { value, problem in finish(value, problem) }
    }
  }
  func save(signature: Data) throws {
    let _: Data = try request(timeout: 30) { proxy, finish in
      proxy.save(signature: signature) { problem in finish(Data(), problem) }
    }
  }

  private func request(timeout: TimeInterval = 5,
    _ call: (FocusGuardSaveProtocol, @escaping (Data?, String?) -> Void) -> Void) throws -> Data {
    let reply = SaveReply()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
      reply.finish(nil, "无法连接指纹保存服务。请检查安装授权，或重新启用指纹保存。")
    }) as? FocusGuardSaveProtocol else {
      throw BiometricFailure("无法连接指纹保存服务。")
    }
    call(proxy) { value, problem in reply.finish(value, problem) }
    guard reply.semaphore.wait(timeout: .now() + timeout) == .success else {
      throw BiometricFailure("保存服务未及时回复，结果尚未确认。请重新打开窗口核对设置。")
    }
    return try reply.result()
  }
}

private final class SaveReply {
  let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var completed = false
  private var value: Data?
  private var problem: String?

  func finish(_ value: Data?, _ problem: String?) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    self.value = value
    self.problem = problem
    lock.unlock()
    semaphore.signal()
  }
  func result() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    if let problem { throw BiometricFailure(problem) }
    guard let value else { throw BiometricFailure("保存服务返回了无效结果。") }
    return value
  }
}
