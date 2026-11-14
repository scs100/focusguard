import CryptoKit
import Darwin
import Foundation
import Security

private struct SaveFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

private func consoleUID() -> uid_t {
  var info = stat()
  guard lstat("/dev/console", &info) == 0 else { return 0 }
  return info.st_uid
}

// Every path component is checked without following links. Writable app bundles
// cannot be pinned as a trusted root-helper client, even with a valid signature.
private func requireRootPath(_ url: URL, directory: Bool = false, allowApplicationsAnchor: Bool = false) throws {
  let path = url.standardizedFileURL.path
  guard path.hasPrefix("/") else { throw SaveFailure("保护文件路径不正确。") }
  var current = URL(fileURLWithPath: path)
  var leaf = true
  while true {
    var info = stat()
    // /Applications is normally root:admin 775. Only the fixed, immutable app
    // bundle is allowed to use this anchor; policy/helper paths never do.
    let allowedBits: mode_t = allowApplicationsAnchor && current.path == "/Applications" ? 0o002 : 0o022
    guard lstat(current.path, &info) == 0, info.st_uid == 0,
          info.st_mode & allowedBits == 0 else {
      throw SaveFailure("保护文件的所有者或权限不正确，请重新完成系统安装授权。")
    }
    let kind = info.st_mode & mode_t(S_IFMT)
    guard kind == mode_t((leaf && !directory) ? S_IFREG : S_IFDIR) else {
      throw SaveFailure("保护路径中不能有符号链接或特殊文件。")
    }
    if leaf && !directory && info.st_nlink != 1 {
      throw SaveFailure("保护文件不能有硬链接。")
    }
    if current.path == "/" { break }
    current.deleteLastPathComponent()
    leaf = false
  }
}

private func requireInstalledApp(_ app: URL) throws {
  guard app.standardizedFileURL.path == "/Applications/专注时间.app" else {
    throw SaveFailure("指纹保存只允许为已安装的专注时间授权。")
  }
  try requireRootPath(app, directory: true, allowApplicationsAnchor: true)
  try requireRootPath(app.appendingPathComponent("Contents/MacOS/FocusGuard"), allowApplicationsAnchor: true)
  var info = stat()
  guard lstat(app.path, &info) == 0, info.st_flags & UInt32(SF_IMMUTABLE) != 0 else {
    throw SaveFailure("已安装应用必须先锁定，才能启用指纹保存。")
  }
}

private func readEnrollmentKey(_ url: URL, owner: uid_t) throws -> Data {
  var before = stat()
  guard lstat(url.path, &before) == 0,
        before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
        before.st_size == 65, before.st_mode & mode_t(0o022) == 0,
        before.st_uid == 0 || before.st_uid == owner else {
    throw SaveFailure("指纹授权公钥文件不正确。")
  }
  let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard fd >= 0 else { throw SaveFailure("无法读取指纹授权公钥。") }
  defer { close(fd) }
  var opened = stat()
  guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
        opened.st_size == 65, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        opened.st_nlink == 1, opened.st_uid == before.st_uid,
        opened.st_mode & mode_t(0o022) == 0 else {
    throw SaveFailure("指纹授权公钥文件已改变，请重试。")
  }
  var data = Data(count: 66)
  let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
  guard count == 65 else { throw SaveFailure("指纹授权公钥长度不正确。") }
  data.removeLast()
  return data
}

private struct EnrollmentPolicy {
  let uid: uid_t
  let publicKeyData: Data
  let clientRequirement: String

  var publicKey: SecKey {
    get throws {
      var error: Unmanaged<CFError>?
      guard publicKeyData.count == 65, publicKeyData.first == 4,
            let key = SecKeyCreateWithData(publicKeyData as CFData, [
              kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
              kSecAttrKeyClass: kSecAttrKeyClassPublic,
              kSecAttrKeySizeInBits: 256,
            ] as CFDictionary, &error) else {
        throw SaveFailure("指纹授权公钥不正确，请重新进行系统授权配对。")
      }
      return key
    }
  }

  static func load() throws -> EnrollmentPolicy {
    try requireRootPath(SaveAuthorization.policyURL)
    let data = try Data(contentsOf: SaveAuthorization.policyURL)
    guard data.count <= 65_536,
          let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          plist["version"] as? Int == 1,
          let rawUID = plist["uid"] as? NSNumber, rawUID.uint64Value > 0,
          rawUID.uint64Value <= UInt64(uid_t.max),
          let key = plist["publicKey"] as? Data,
          let requirement = plist["clientRequirement"] as? String,
          !requirement.isEmpty, requirement.utf8.count < 16_384 else {
      throw SaveFailure("指纹授权配置损坏，请重新进行系统授权配对。")
    }
    let policy = EnrollmentPolicy(uid: rawUID.uint32Value, publicKeyData: key, clientRequirement: requirement)
    _ = try policy.publicKey
    var checked: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(rawValue: 0), &checked) == errSecSuccess else {
      throw SaveFailure("应用签名要求不正确。请重新安装。")
    }
    return policy
  }

  func store() throws {
    try requireRootPath(SaveAuthorization.baseURL, directory: true)
    let backup = SaveAuthorization.baseURL.appendingPathComponent(".backup", isDirectory: true)
    if !FileManager.default.fileExists(atPath: backup.path) {
      try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }
    try requireRootPath(backup, directory: true)
    let data = try PropertyListSerialization.data(fromPropertyList: [
      "version": 1, "uid": NSNumber(value: uid), "publicKey": publicKeyData,
      "clientRequirement": clientRequirement,
    ], format: .binary, options: 0)
    try writeLocked(data, to: SaveAuthorization.policyURL)
    try writeLocked(data, to: backup.appendingPathComponent("biometric-policy.plist"))
  }
}

private func writeLocked(_ data: Data, to destination: URL) throws {
  try requireRootPath(destination.deletingLastPathComponent(), directory: true)
  let temporary = destination.deletingLastPathComponent().appendingPathComponent(".biometric-policy-\(UUID().uuidString)")
  let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
  guard fd >= 0 else { throw SaveFailure("无法创建指纹授权配置。") }
  var renamed = false
  defer {
    close(fd)
    if !renamed { unlink(temporary.path) }
  }
  try data.withUnsafeBytes { bytes in
    var total = 0
    while total < bytes.count {
      let count = write(fd, bytes.baseAddress!.advanced(by: total), bytes.count - total)
      guard count > 0 else { throw SaveFailure("无法写入指纹授权配置。") }
      total += count
    }
  }
  guard fchmod(fd, mode_t(0o644)) == 0, fsync(fd) == 0 else {
    throw SaveFailure("无法保存指纹授权配置。")
  }
  var old = stat()
  if lstat(destination.path, &old) == 0 {
    try requireRootPath(destination)
    guard chflags(destination.path, old.st_flags & ~UInt32(SF_IMMUTABLE)) == 0 else {
      throw SaveFailure("无法更新指纹授权配置。")
    }
  }
  guard rename(temporary.path, destination.path) == 0 else {
    _ = chflags(destination.path, UInt32(SF_IMMUTABLE))
    throw SaveFailure("无法替换指纹授权配置。")
  }
  renamed = true
  guard chflags(destination.path, UInt32(SF_IMMUTABLE)) == 0 else {
    throw SaveFailure("无法锁定指纹授权配置。")
  }
}

private struct PendingSave {
  let nonce: Data
  let payload: Data
  let issuedAt: UInt64

  func valid(at now: UInt64) -> Bool {
    now >= issuedAt && now - issuedAt <= 60_000_000_000
  }

  func verify(signature: Data, key: SecKey, now: UInt64) -> Bool {
    guard valid(at: now), !signature.isEmpty, signature.count <= 256 else { return false }
    return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256,
      SaveAuthorization.challenge(nonce: nonce, payload: payload) as CFData,
      signature as CFData, nil)
  }
}

private struct PendingChallenge {
  var request: PendingSave?

  mutating func take() -> PendingSave? {
    let result = request
    request = nil
    return result
  }
}

// Spawn a separate process group so timeout also stops lockf and shell children.
// The unreaped child PID keeps this group identifier from being recycled.
private func runSaveCommand(installer: URL, config: URL, output: URL, timeoutNanoseconds: UInt64 = 20_000_000_000) throws -> Int32 {
  let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
  guard fd >= 0 else { throw SaveFailure("无法记录保存结果。") }
  defer { close(fd) }
  var attributes: posix_spawnattr_t?
  var actions: posix_spawn_file_actions_t?
  guard posix_spawnattr_init(&attributes) == 0 else { throw SaveFailure("无法启动保存服务。") }
  defer { posix_spawnattr_destroy(&attributes) }
  guard posix_spawn_file_actions_init(&actions) == 0 else { throw SaveFailure("无法启动保存服务。") }
  defer { posix_spawn_file_actions_destroy(&actions) }
  guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0,
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
        posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO) == 0 else {
    throw SaveFailure("无法启动保存服务。")
  }
  if fd > STDERR_FILENO { posix_spawn_file_actions_addclose(&actions, fd) }
  var arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/bash", installer.path, "--save-only", config.path].map { value in
    value.withCString { strdup($0) }
  }
  var environment: [UnsafeMutablePointer<CChar>?] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"].map { value in
    value.withCString { strdup($0) }
  }
  defer {
    arguments.forEach { free($0) }
    environment.forEach { free($0) }
  }
  guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
    throw SaveFailure("无法分配保存进程资源。")
  }
  arguments.append(nil)
  environment.append(nil)
  var pid: pid_t = 0
  let spawnStatus = arguments.withUnsafeBufferPointer { argv in
    environment.withUnsafeBufferPointer { env in
      posix_spawn(&pid, "/bin/bash", &actions, &attributes,
                  UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
    }
  }
  guard spawnStatus == 0 else { throw SaveFailure("无法启动保存服务（\(spawnStatus)）。") }
  let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
  var status: Int32 = 0
  while true {
    let waited = waitpid(pid, &status, WNOHANG)
    if waited == pid { return status }
    if waited < 0 && errno != EINTR { throw SaveFailure("无法确认保存结果。") }
    if DispatchTime.now().uptimeNanoseconds >= deadline {
      _ = kill(-pid, SIGKILL)
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      throw SaveFailure("保存超时，请检查保护服务后重试。")
    }
    usleep(20_000)
  }
}

private final class SaveCoordinator {
  let queue = DispatchQueue(label: "com.focusguard.save.operations")

  func apply(_ payload: Data) throws {
    try requireRootPath(SaveAuthorization.baseURL, directory: true)
    let installer = SaveAuthorization.baseURL.appendingPathComponent("install.sh")
    try requireRootPath(installer)
    let marker = SaveAuthorization.baseURL.appendingPathComponent(".installing")
    if FileManager.default.fileExists(atPath: marker.path) {
      try requireRootPath(marker)
      var info = stat()
      guard lstat(marker.path, &info) == 0 else { throw SaveFailure("无法检查当前安装状态。") }
      let age = Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec)
      if age >= 0 && age < 120 {
        throw SaveFailure("正在安装或更新专注时间，请稍后保存。")
      }
    }
    let temporary = SaveAuthorization.baseURL.appendingPathComponent(".biometric-save-\(UUID().uuidString)")
    guard mkdir(temporary.path, mode_t(0o700)) == 0 else {
      throw SaveFailure("无法创建保存目录。")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let config = temporary.appendingPathComponent("config.conf")
    try payload.write(to: config, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    let log = temporary.appendingPathComponent("result.log")
    guard try runSaveCommand(installer: installer, config: config, output: log) == 0 else {
      let handle = try FileHandle(forReadingFrom: log)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 4096) ?? Data()
      let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw SaveFailure(message.isEmpty ? "指纹已验证，但设置没有保存。" : message)
    }
  }
}

private final class SaveSession: NSObject, FocusGuardSaveProtocol {
  private weak var connection: NSXPCConnection?
  private let policy: EnrollmentPolicy
  private let coordinator: SaveCoordinator
  private var pending = PendingChallenge()

  init(connection: NSXPCConnection, policy: EnrollmentPolicy, coordinator: SaveCoordinator) {
    self.connection = connection
    self.policy = policy
    self.coordinator = coordinator
  }

  private func requireCaller() throws {
    guard let connection, connection.effectiveUserIdentifier == policy.uid,
          consoleUID() == policy.uid else {
      throw SaveFailure("只有当前登录并已授权的账户可以保存。")
    }
  }

  func enrollment(withReply reply: @escaping (Data?, String?) -> Void) {
    coordinator.queue.async {
      do {
        try self.requireCaller()
        reply(self.policy.publicKeyData, nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func challenge(for payload: Data, withReply reply: @escaping (Data?, String?) -> Void) {
    coordinator.queue.async {
      _ = self.pending.take()
      do {
        try self.requireCaller()
        guard !payload.isEmpty, payload.count <= SaveAuthorization.maxPayload,
              !payload.contains(0), String(data: payload, encoding: .utf8) != nil else {
          throw SaveFailure("配置内容为空、过大或格式不正确。")
        }
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SaveFailure("无法创建本次保存的验证信息。") }
        self.pending.request = PendingSave(nonce: nonce, payload: payload, issuedAt: DispatchTime.now().uptimeNanoseconds)
        reply(nonce, nil)
      } catch { reply(nil, error.localizedDescription) }
    }
  }

  func save(signature: Data, withReply reply: @escaping (String?) -> Void) {
    coordinator.queue.async {
      let request = self.pending.take() // Every attempt consumes it, including failures.
      do {
        try self.requireCaller()
        guard let request, request.verify(signature: signature, key: try self.policy.publicKey,
                                          now: DispatchTime.now().uptimeNanoseconds) else {
          throw SaveFailure("指纹验证无效或已过期，请重新保存。")
        }
        try self.coordinator.apply(request.payload)
        reply(nil)
      } catch { reply(error.localizedDescription) }
    }
  }
}

private final class SaveListener: NSObject, NSXPCListenerDelegate {
  let policy: EnrollmentPolicy
  let coordinator = SaveCoordinator()
  init(policy: EnrollmentPolicy) { self.policy = policy }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == policy.uid, consoleUID() == policy.uid else { return false }
    // This is enforced by XPC for every received message, avoiding PID-reuse checks.
    connection.setCodeSigningRequirement(policy.clientRequirement)
    connection.exportedInterface = NSXPCInterface(with: FocusGuardSaveProtocol.self)
    connection.exportedObject = SaveSession(connection: connection, policy: policy, coordinator: coordinator)
    connection.resume()
    return true
  }
}

private func selfTest() throws {
  var error: Unmanaged<CFError>?
  guard let privateKey = SecKeyCreateRandomKey([
    kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
  ] as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(privateKey) else {
    throw SaveFailure("selftest key creation")
  }
  let payload = Data("START=09:00\nWORD=example.com\n".utf8)
  let nonce = Data(repeating: 42, count: 32)
  let now: UInt64 = 123_000_000_000
  let request = PendingSave(nonce: nonce, payload: payload, issuedAt: now)
  let challenge = SaveAuthorization.challenge(nonce: nonce, payload: payload)
  guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
      challenge as CFData, &error) as Data? else { throw SaveFailure("selftest signing") }
  guard request.verify(signature: signature, key: publicKey, now: now + 1_000_000),
        !request.verify(signature: signature, key: publicKey, now: now + 60_000_000_001),
        !request.verify(signature: signature, key: publicKey, now: now - 1),
        !PendingSave(nonce: nonce, payload: payload + Data("WORD=other\n".utf8), issuedAt: now)
          .verify(signature: signature, key: publicKey, now: now),
        !PendingSave(nonce: Data(repeating: 43, count: 32), payload: payload, issuedAt: now)
          .verify(signature: signature, key: publicKey, now: now) else {
    throw SaveFailure("selftest expiry or payload binding")
  }
  var pending = PendingChallenge(request: request)
  let consumed = pending.take()
  guard consumed?.verify(signature: signature, key: publicKey, now: now) == true,
        pending.take() == nil else { throw SaveFailure("selftest replay consumption") }
  print("ok biometric challenge signature, payload binding, nonce, expiry, one-time consumption")
  try selfTestPathsAndProcess()
}

private func selfTestPathsAndProcess() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focusguard-helper-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  func rejects(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw SaveFailure("selftest should reject \(label)")
  }
  let keyFile = directory.appendingPathComponent("key")
  try Data(repeating: 4, count: 65).write(to: keyFile)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
  guard try readEnrollmentKey(keyFile, owner: getuid()).count == 65 else { throw SaveFailure("selftest enrollment key") }
  let symlinkFile = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: keyFile)
  try rejects("enrollment symlink") { _ = try readEnrollmentKey(symlinkFile, owner: getuid()) }
  let fifo = directory.appendingPathComponent("fifo")
  guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { throw SaveFailure("selftest FIFO creation") }
  try rejects("enrollment FIFO") { _ = try readEnrollmentKey(fifo, owner: getuid()) }
  if getuid() != 0 {
    try rejects("enrollment wrong owner") { _ = try readEnrollmentKey(keyFile, owner: getuid() + 1) }
    try rejects("user-owned root path") { try requireRootPath(keyFile) }
  }
  let hardlink = directory.appendingPathComponent("hardlink")
  try FileManager.default.linkItem(at: keyFile, to: hardlink)
  try rejects("enrollment hardlink") { _ = try readEnrollmentKey(keyFile, owner: getuid()) }
  try FileManager.default.removeItem(at: hardlink)
  try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: keyFile.path)
  try rejects("enrollment writable key") { _ = try readEnrollmentKey(keyFile, owner: getuid()) }
  try rejects("unexpected enrolled app") { try requireInstalledApp(directory) }
  var applications = stat()
  if lstat("/Applications", &applications) == 0, applications.st_uid == 0,
     applications.st_mode & mode_t(0o002) == 0 {
    try requireRootPath(URL(fileURLWithPath: "/Applications"), directory: true, allowApplicationsAnchor: true)
    if applications.st_mode & mode_t(0o020) != 0 {
      try rejects("generic group-writable Applications") {
        try requireRootPath(URL(fileURLWithPath: "/Applications"), directory: true)
      }
    }
  }
  print("ok enrollment file ownership, links, FIFO, permissions and Applications anchor")
  let installer = directory.appendingPathComponent("installer.sh")
  let config = directory.appendingPathComponent("written")
  let log = directory.appendingPathComponent("normal.log")
  try Data("#!/bin/bash\n[ \"$1\" = \"--save-only\" ] || exit 3\nprintf saved > \"$2\"\n".utf8).write(to: installer)
  guard try runSaveCommand(installer: installer, config: config, output: log) == 0,
        try String(contentsOf: config, encoding: .utf8) == "saved" else {
    throw SaveFailure("selftest fixed save subprocess")
  }
  try FileManager.default.removeItem(at: config)
  try Data("#!/bin/bash\n/bin/sleep 0.25\nprintf late > \"$2\"\n".utf8).write(to: installer)
  try rejects("save subprocess timeout") {
    _ = try runSaveCommand(installer: installer, config: config,
                           output: directory.appendingPathComponent("timeout.log"), timeoutNanoseconds: 50_000_000)
  }
  usleep(350_000)
  guard !FileManager.default.fileExists(atPath: config.path) else { throw SaveFailure("selftest orphan save subprocess") }
  print("ok fixed save command and timeout kills its process group")
}

@main
enum SaveHelperMain {
  static func main() {
    do {
      let args = CommandLine.arguments
      if args.count == 2, args[1] == "--selftest" {
        try selfTest()
        return
      }
      guard getuid() == 0, geteuid() == 0 else { throw SaveFailure("安装指纹保存服务需要 macOS 管理员授权。") }
      if args.count == 6, args[1] == "--enroll" {
        guard let uid = uid_t(args[3]), uid != 0, uid == consoleUID() else {
          throw SaveFailure("只能为当前登录账户启用指纹保存。")
        }
        let file = URL(fileURLWithPath: args[2])
        let key = try readEnrollmentKey(file, owner: uid)
        let expectedDigest = args[5]
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        guard expectedDigest.count == 64, expectedDigest == digest else {
          throw SaveFailure("指纹授权公钥已改变，请重新设置。")
        }
        let app = URL(fileURLWithPath: args[4], isDirectory: true)
        try requireInstalledApp(app)
        let policy = EnrollmentPolicy(uid: uid, publicKeyData: key,
          clientRequirement: try SaveAuthorization.codeRequirement(for: app))
        _ = try policy.publicKey
        try policy.store()
        print("ok biometric enrollment")
        return
      }
      if args.count == 3, args[1] == "--refresh-client" {
        let current = try EnrollmentPolicy.load()
        guard current.uid == consoleUID() else { throw SaveFailure("请登录已授权账户后更新。") }
        let app = URL(fileURLWithPath: args[2], isDirectory: true)
        try requireInstalledApp(app)
        try EnrollmentPolicy(uid: current.uid, publicKeyData: current.publicKeyData,
          clientRequirement: SaveAuthorization.codeRequirement(for: app)).store()
        print("ok biometric client refreshed")
        return
      }
      guard args.count == 1 else { throw SaveFailure("指纹保存服务参数不正确。") }
      try requireRootPath(URL(fileURLWithPath: CommandLine.arguments[0]))
      let delegate = SaveListener(policy: try EnrollmentPolicy.load())
      let listener = NSXPCListener(machServiceName: SaveAuthorization.serviceName)
      listener.delegate = delegate
      listener.resume()
      withExtendedLifetime(delegate) { RunLoop.current.run() }
    } catch {
      fputs(error.localizedDescription + "\n", stderr)
      exit(1)
    }
  }
}
