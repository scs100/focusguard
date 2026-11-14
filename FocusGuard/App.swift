import AppKit
import CoreServices
import Darwin
import SwiftUI

// shortcut: SIGKILL and crash signals still die. The relaunch job brings the window back.
private func ignoreStopSignals() {
  let stop: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGUSR1, SIGUSR2, SIGPIPE, SIGALRM, SIGPROF, SIGVTALRM, SIGXCPU, SIGXFSZ]
  for sig in stop {
    signal(sig, SIG_IGN)
  }
}

private var lettingSystemQuit = false

private enum BackgroundUI {
  static func hideWindows(in application: NSApplication = NSApp) {
    for window in application.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
      window.orderOut(nil)
    }
    application.hide(nil)
  }

  static func showWindows(in application: NSApplication) {
    application.unhide(nil)
    // canBecomeMain is false while a window is ordered out on some macOS versions.
    for window in application.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    application.activate(ignoringOtherApps: true)
  }
}

private func isPowerQuit(_ reason: OSType) -> Bool {
  reason == kAEShutDown || reason == kAERestart || reason == kAEReallyLogOut || reason == kAELogOut
}

private func systemPowerQuit() -> Bool {
  guard let why = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return false }
  return isPowerQuit(why.enumCodeValue)
}

private let installedConfig = "/Library/Application Support/FocusGuard/config.conf"
private let focusLockText = "到结束之前，只能添加，不能删。"
private let editLockText = "修改时间外只能加网站，不能减，也不能改关机时间。"

private func clock(_ hour: Int, _ minute: Int) -> Date {
  Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
}

private func hhmm(_ date: Date) -> String {
  let c = Calendar.current.dateComponents([.hour, .minute], from: date)
  return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

private func human(_ date: Date) -> String {
  let c = Calendar.current.dateComponents([.hour, .minute], from: date)
  return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
}

private func humanDeadline(_ date: Date, from now: Date) -> String {
  let calendar = Calendar.current
  if calendar.isDate(date, inSameDayAs: now) { return human(date) }
  if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
    return "明日 \(human(date))"
  }
  let c = calendar.dateComponents([.year, .month, .day], from: date)
  return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 \(human(date))"
}

private func hhmmValue(_ date: Date) -> Int {
  let c = Calendar.current.dateComponents([.hour, .minute], from: date)
  return (c.hour ?? 0) * 100 + (c.minute ?? 0)
}

private func activeAt(start: Int, end: Int, now: Int) -> Bool {
  if start == end { return false }
  if start < end { return now >= start && now < end }
  return now >= start || now < end
}

private func appleQuote(_ s: String) -> String {
  "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func clean(_ s: String) -> String {
  s.replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\r", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isSystemApp(_ name: String) -> Bool {
  let blocked = [
    "Finder", "Dock", "loginwindow", "WindowServer", "专注时间", "FocusGuard",
    "系统设置", "System Settings", "系统偏好设置", "System Preferences", "启动台", "Launchpad",
  ]
  return blocked.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
}

private func already(_ list: [String], _ name: String) -> Bool {
  list.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
}

private let dayTitles = ["一", "二", "三", "四", "五", "六", "日"]

private func daysString(_ days: Set<Int>) -> String {
  days.sorted().map(String.init).joined()
}

private func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
  let w = calendar.component(.weekday, from: date)
  return w == 1 ? 7 : w - 1
}

private func isOn(start: Int, end: Int, days: Set<Int>, quick: Int, weekday: Int, hhmm: Int, epoch: Int) -> Bool {
  if quick > epoch { return true }
  guard activeAt(start: start, end: end, now: hhmm) else { return false }
  // Both halves of an overnight window belong to the selected starting day.
  let yesterday = weekday == 1 ? 7 : weekday - 1
  let startingDay = start > end && hhmm < end ? yesterday : weekday
  return days.contains(startingDay)
}

// Morning half of an overnight window belongs to the previous day.
private func sleepWindow(on: Bool, start: Int, end: Int, days: Set<Int>, weekday: Int, hhmm: Int) -> Bool {
  if !on || start == end || days.isEmpty { return false }
  let yesterday = weekday == 1 ? 7 : weekday - 1
  if start < end { return days.contains(weekday) && hhmm >= start && hhmm < end }
  if hhmm >= start { return days.contains(weekday) }
  if hhmm < end { return days.contains(yesterday) }
  return false
}

private func endMoment(_ end: Date, from now: Date, calendar: Calendar = .current) -> Date {
  let parts = calendar.dateComponents([.hour, .minute], from: end)
  let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) ?? now
  if today <= now { return calendar.date(byAdding: .day, value: 1, to: today) ?? today }
  return today
}

struct AllowRule: Equatable {
  var name: String
  var use: Int
  var cool: Int
  var since: Int
  var line: String { "ALLOW=\(name)|\(use)|\(cool)|\(since)" }
}

private func beijingDay(_ date: Date) -> String {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
  let c = cal.dateComponents([.year, .month, .day], from: date)
  return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

private func allowOpen(since: Int, use: Int, cool: Int, now: Int) -> Bool {
  guard (1...1440).contains(use), (1...1440).contains(cool), since > 0, now >= since else { return false }
  let period = (use + cool) * 60
  return period > 0 && (now - since) % period < use * 60
}

private func parseAllow(_ raw: String) -> AllowRule? {
  let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
  guard parts.count == 4 else { return nil }
  let name = parts[0]
  guard !name.isEmpty, name.count <= 100 else { return nil }
  guard let use = Int(parts[1]), let cool = Int(parts[2]), let since = Int(parts[3]) else { return nil }
  guard (1...1440).contains(use), (1...1440).contains(cool), since >= 0 else { return nil }
  return AllowRule(name: name, use: use, cool: cool, since: since)
}

// shortcut: one word matches the address or the title. Split them if a pure domain list is needed.
private func renderConfig(
  start: String, end: String, days: String, quick: Int, apps: [String], words: [String],
  sleepOn: Bool, sleepStart: String, sleepEnd: String, sleepDays: String,
  modifyStart: String, modifyEnd: String,
  allows: [AllowRule] = [], allowDay: String = ""
) -> String {
  var lines = ["START=\(start)", "END=\(end)", "INTERVAL=5", "DAYS=\(days)", "MSTART=\(modifyStart)", "MEND=\(modifyEnd)"]
  if quick > 0 { lines.append("QUICK=\(quick)") }
  if sleepOn {
    lines += ["SLEEP=1", "SSTART=\(sleepStart)", "SEND=\(sleepEnd)", "SDAYS=\(sleepDays)"]
  }
  lines += apps.map { "APP=\($0)" }
  lines += words.map { "WORD=\($0)" }
  if !allowDay.isEmpty { lines.append("ALLOWDAY=\(allowDay)") }
  lines += allows.map(\.line)
  return lines.joined(separator: "\n") + "\n"
}

private func runningAppNames() -> [String] {
  let names = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
    guard app.activationPolicy == .regular, let name = app.localizedName, !name.isEmpty else { return nil }
    if app.bundleIdentifier == "com.focusguard.app" || isSystemApp(name) { return nil }
    return name
  }
  return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

private func selfTest() -> Bool {
  guard activeAt(start: 900, end: 1800, now: 900) else { return false }
  guard activeAt(start: 900, end: 1800, now: 1200) else { return false }
  guard !activeAt(start: 900, end: 1800, now: 800) else { return false }
  guard !activeAt(start: 900, end: 1800, now: 1800) else { return false }
  guard activeAt(start: 2200, end: 700, now: 2300) else { return false }
  guard activeAt(start: 2200, end: 700, now: 300) else { return false }
  guard !activeAt(start: 2200, end: 700, now: 1200) else { return false }
  guard !activeAt(start: 900, end: 900, now: 900) else { return false }
  guard isOn(start: 2200, end: 700, days: [4], quick: 0, weekday: 4, hhmm: 2300, epoch: 10) else { return false }
  guard !isOn(start: 2200, end: 700, days: [4], quick: 0, weekday: 5, hhmm: 2300, epoch: 10) else { return false }
  guard !isOn(start: 2200, end: 700, days: [1], quick: 0, weekday: 1, hhmm: 300, epoch: 10) else { return false }
  guard isOn(start: 2200, end: 700, days: [1], quick: 0, weekday: 1, hhmm: 2200, epoch: 10) else { return false }
  guard isOn(start: 2200, end: 700, days: [1], quick: 0, weekday: 2, hhmm: 0, epoch: 10) else { return false }
  guard isOn(start: 2200, end: 700, days: [1], quick: 0, weekday: 2, hhmm: 659, epoch: 10) else { return false }
  guard !isOn(start: 2200, end: 700, days: [1], quick: 0, weekday: 2, hhmm: 700, epoch: 10) else { return false }
  guard isOn(start: 2200, end: 700, days: [7], quick: 0, weekday: 1, hhmm: 300, epoch: 10) else { return false }
  guard !isOn(start: 2200, end: 700, days: [7], quick: 0, weekday: 7, hhmm: 300, epoch: 10) else { return false }
  guard isOn(start: 900, end: 1800, days: [], quick: 50, weekday: 1, hhmm: 800, epoch: 10) else { return false }
  guard !isOn(start: 900, end: 1800, days: [], quick: 50, weekday: 1, hhmm: 800, epoch: 50) else { return false }
  guard isOn(start: 2200, end: 700, days: [], quick: 50, weekday: 2, hhmm: 300, epoch: 49) else { return false }
  guard !isOn(start: 2200, end: 700, days: [], quick: 50, weekday: 2, hhmm: 300, epoch: 50) else { return false }
  guard sleepWindow(on: true, start: 2300, end: 700, days: [1, 2, 3, 4, 5, 6, 7], weekday: 4, hhmm: 2300) else { return false }
  guard sleepWindow(on: true, start: 2300, end: 700, days: [1, 2, 3, 4, 5, 6, 7], weekday: 5, hhmm: 300) else { return false }
  guard !sleepWindow(on: true, start: 2300, end: 700, days: [5], weekday: 5, hhmm: 300) else { return false }
  guard sleepWindow(on: true, start: 2300, end: 700, days: [5], weekday: 5, hhmm: 2300) else { return false }
  guard !sleepWindow(on: true, start: 2300, end: 700, days: [4], weekday: 4, hhmm: 1200) else { return false }
  guard !sleepWindow(on: false, start: 2300, end: 700, days: [4], weekday: 4, hhmm: 2300) else { return false }
  guard appleQuote("a\"b\\c") == "\"a\\\"b\\\\c\"" else { return false }
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(secondsFromGMT: 0)!
  let monday = cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2024, month: 1, day: 1))!
  let sunday = cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2024, month: 1, day: 7))!
  guard isoWeekday(monday, calendar: cal) == 1 else { return false }
  guard isoWeekday(sunday, calendar: cal) == 7 else { return false }
  let late = cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2024, month: 1, day: 1, hour: 23))!
  let morning = cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2024, month: 1, day: 1, hour: 7))!
  let landed = endMoment(morning, from: late, calendar: cal)
  guard cal.component(.day, from: landed) == 2 && cal.component(.hour, from: landed) == 7 else { return false }
  let sample = renderConfig(start: "09:00", end: "18:00", days: "137", quick: 0, apps: ["微信"], words: ["hello world"], sleepOn: false, sleepStart: "", sleepEnd: "", sleepDays: "", modifyStart: "00:00", modifyEnd: "23:59")
  guard sample == "START=09:00\nEND=18:00\nINTERVAL=5\nDAYS=137\nMSTART=00:00\nMEND=23:59\nAPP=微信\nWORD=hello world\n" else { return false }
  let quickSample = renderConfig(start: "09:00", end: "18:00", days: "1", quick: 100, apps: [], words: [], sleepOn: true, sleepStart: "23:00", sleepEnd: "07:00", sleepDays: "1234567", modifyStart: "00:00", modifyEnd: "23:59")
  guard quickSample == "START=09:00\nEND=18:00\nINTERVAL=5\nDAYS=1\nMSTART=00:00\nMEND=23:59\nQUICK=100\nSLEEP=1\nSSTART=23:00\nSEND=07:00\nSDAYS=1234567\n" else { return false }
  guard isPowerQuit(kAEShutDown) && isPowerQuit(kAERestart) && isPowerQuit(kAEReallyLogOut) && isPowerQuit(kAELogOut) else { return false }
  guard allowOpen(since: 1000, use: 1, cool: 1, now: 1000) else { return false }
  guard allowOpen(since: 1000, use: 1, cool: 1, now: 1059) else { return false }
  guard !allowOpen(since: 1000, use: 1, cool: 1, now: 1060) else { return false }
  guard allowOpen(since: 1000, use: 1, cool: 1, now: 1120) else { return false }
  guard !allowOpen(since: 1000, use: 1, cool: 1, now: 999) else { return false }
  let allowSample = renderConfig(start: "09:00", end: "18:00", days: "1", quick: 0, apps: [], words: ["bilibili"], sleepOn: false, sleepStart: "", sleepEnd: "", sleepDays: "", modifyStart: "00:00", modifyEnd: "23:59", allows: [AllowRule(name: "bilibili", use: 25, cool: 60, since: 0)], allowDay: "20231115")
  guard allowSample.hasSuffix("ALLOWDAY=20231115\nALLOW=bilibili|25|60|0\n") else { return false }
  let allowModel = PageModel()
  allowModel.allowDay = "20231115"
  var shanghai = Calendar(identifier: .gregorian)
  shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  let sameDay = shanghai.date(from: DateComponents(timeZone: shanghai.timeZone, year: 2023, month: 11, day: 15, hour: 12))!
  let nextDay = shanghai.date(from: DateComponents(timeZone: shanghai.timeZone, year: 2023, month: 11, day: 16, hour: 0))!
  guard !allowModel.allowSlotOpen(now: sameDay) else { return false }
  guard allowModel.allowSlotOpen(now: nextDay) else { return false }
  allowModel.allows = [AllowRule(name: "a", use: 1, cool: 1, since: 0)]
  guard !allowModel.allowSlotOpen(now: nextDay) else { return false }
  return !isPowerQuit(kAEQuitAll) && selfTestSavedStatus() && selfTestOvernightStatus() && BiometricSave.selfTestStorage()
}

private func selfTestSavedStatus() -> Bool {
  let model = PageModel()
  let now = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 12))!
  guard !model.isActive(at: now) else { return false }
  model.installed = true
  model.savedStart = clock(9, 0)
  model.savedEnd = clock(18, 0)
  model.savedDays = [1]
  let activeStatus = model.status(at: now)
  guard model.isActive(at: now), hhmm(model.until(at: now)) == "18:00" else { return false }
  // Editing the form or opening an unsaved quick session cannot change live status.
  model.start = clock(20, 0)
  model.end = clock(21, 0)
  model.days = []
  model.pendingQuick = now.addingTimeInterval(12 * 3600)
  guard model.status(at: now) == activeStatus, hhmm(model.until(at: now)) == "18:00" else { return false }
  model.savedDays = []
  guard !model.isActive(at: now) else { return false }
  let inactiveStatus = model.status(at: now)
  model.start = clock(0, 0)
  model.end = clock(23, 59)
  model.days = [1]
  guard model.status(at: now) == inactiveStatus else { return false }
  let quickEnd = now.addingTimeInterval(60 * 60)
  model.savedQuick = quickEnd
  guard model.isActive(at: now), model.until(at: now) == quickEnd else { return false }
  guard !model.isActive(at: quickEnd) else { return false }
  model.installed = false
  return !model.isActive(at: now) && model.status(at: now) == "还没开始。"
}

private func selfTestOvernightStatus() -> Bool {
  let calendar = Calendar.current
  func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2024, month: 1, day: day, hour: hour, minute: minute))!
  }
  let model = PageModel()
  model.installed = true
  model.savedStart = clock(22, 0)
  model.savedEnd = clock(7, 0)
  model.savedDays = [1]
  let mondayNight = moment(1, 23)
  let tuesdayMorning = moment(2, 3)
  let tuesdayEnd = moment(2, 7)
  guard !model.isActive(at: moment(1, 3)), model.isActive(at: mondayNight), model.isActive(at: tuesdayMorning) else { return false }
  guard model.until(at: mondayNight) == tuesdayEnd, model.until(at: tuesdayMorning) == tuesdayEnd else { return false }
  guard model.status(at: mondayNight) == "生效中，到 明日 7:00。", model.status(at: tuesdayMorning) == "生效中，到 7:00。" else { return false }
  guard !model.isActive(at: tuesdayEnd), !model.isActive(at: moment(2, 22)) else { return false }
  // The lock still covers the morning half, including attempts to shorten it.
  model.start = model.savedStart
  model.end = clock(6, 0)
  model.days = model.savedDays
  guard model.locked(at: tuesdayMorning), model.weakened(at: tuesdayMorning) else { return false }
  model.savedDays = [7]
  guard model.isActive(at: moment(8, 3)), model.until(at: moment(7, 23)) == moment(8, 7) else { return false }
  model.savedDays = [1]
  model.savedQuick = moment(2, 4)
  guard model.until(at: tuesdayMorning) == tuesdayEnd else { return false }
  model.savedQuick = moment(2, 9)
  guard model.until(at: tuesdayMorning) == moment(2, 9), model.isActive(at: moment(2, 8)) else { return false }
  guard !model.isActive(at: moment(2, 9)) else { return false }
  // An overnight QUICK remains independent of scheduled weekdays.
  model.savedDays = []
  model.savedQuick = moment(2, 1)
  guard model.status(at: mondayNight) == "生效中，到 明日 1:00。" else { return false }
  return !model.isActive(at: moment(2, 1))
}

final class PageModel: ObservableObject {
  @Published var start = clock(9, 0)
  @Published var end = clock(18, 0)
  @Published var days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  @Published var apps: [String] = []
  @Published var words: [String] = []
  @Published var allows: [AllowRule] = []
  @Published var appText = ""
  @Published var wordText = ""
  @Published var allowText = ""
  @Published var allowUseText = "25"
  @Published var allowCoolText = "60"
  var allowDay = ""
  @Published var quickHours = 0
  @Published var quickMinutes = 25
  @Published var quickUntil: Date?
  @Published var sleepOn = false
  @Published var sleepStart = clock(23, 0)
  @Published var sleepEnd = clock(7, 0)
  @Published var sleepDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  @Published var modifyStart = clock(0, 0)
  @Published var modifyEnd = clock(23, 59)
  @Published var installed = false
  @Published var saving = false
  @Published var fingerprintReady = BiometricSave.isProvisioned
  @Published var provisioningFingerprint = false
  @Published var error = ""
  @Published var showSameTime = false
  @Published var showEmpty = false
  @Published var showShortWord = false
  @Published var pendingWord = ""
  var pendingQuick: Date?

  func load() {
    guard let text = try? String(contentsOfFile: installedConfig, encoding: .utf8) else {
      installed = false
      return
    }
    installed = true
    var newApps: [String] = []
    var newWords: [String] = []
    var newAllows: [AllowRule] = []
    var newAllowDay = ""
    var newDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    var sawDays = false
    var newQuick: Date?
    var newSleep = false
    var newSleepDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    var sawSleepDays = false
    for line in text.split(whereSeparator: \.isNewline) {
      let s = String(line)
      if s.hasPrefix("MSTART="), let d = clock(s.dropFirst(7)) { modifyStart = d }
      else if s.hasPrefix("MEND="), let d = clock(s.dropFirst(5)) { modifyEnd = d }
      else if s.hasPrefix("SSTART="), let d = clock(s.dropFirst(7)) { sleepStart = d }
      else if s.hasPrefix("SEND="), let d = clock(s.dropFirst(5)) { sleepEnd = d }
      else if s.hasPrefix("SDAYS=") {
        sawSleepDays = true
        newSleepDays = Set(s.dropFirst(6).compactMap { Int(String($0)) }.filter { (1...7).contains($0) })
      } else if s.hasPrefix("SLEEP=") {
        newSleep = s.dropFirst(6) == "1"
      } else if s.hasPrefix("START="), let d = clock(s.dropFirst(6)) { start = d }
      else if s.hasPrefix("END="), let d = clock(s.dropFirst(4)) { end = d }
      else if s.hasPrefix("DAYS=") {
        sawDays = true
        newDays = Set(s.dropFirst(5).compactMap { Int(String($0)) }.filter { (1...7).contains($0) })
      } else if s.hasPrefix("QUICK="), let n = TimeInterval(String(s.dropFirst(6))) {
        let d = Date(timeIntervalSince1970: n)
        if d > Date() { newQuick = d }
      } else if s.hasPrefix("APP=") {
        let n = String(s.dropFirst(4))
        if !n.isEmpty { newApps.append(n) }
      } else if s.hasPrefix("ALLOWDAY=") {
        let day = String(s.dropFirst(9))
        if day.count == 8, day.allSatisfy(\.isNumber) { newAllowDay = day }
      } else if s.hasPrefix("ALLOW="), let rule = parseAllow(String(s.dropFirst(6))) {
        newAllows.append(rule)
      } else if s.hasPrefix("WORD=") {
        let n = String(s.dropFirst(5))
        if !n.isEmpty { newWords.append(n) }
      }
    }
    if sawDays { days = newDays }
    if sawSleepDays { sleepDays = newSleepDays }
    sleepOn = newSleep
    apps = newApps
    words = newWords
    allows = newAllows
    allowDay = newAllowDay
    quickUntil = newQuick
    savedStart = start
    savedEnd = end
    savedDays = days
    savedApps = newApps
    savedWords = newWords
    savedAllows = newAllows
    savedQuick = newQuick
    savedSleepOn = sleepOn
    savedSleepStart = sleepStart
    savedSleepEnd = sleepEnd
    savedSleepDays = sleepDays
    savedModifyStart = modifyStart
    savedModifyEnd = modifyEnd
  }

  var savedStart = clock(9, 0)
  var savedEnd = clock(18, 0)
  var savedDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  var savedApps: [String] = []
  var savedWords: [String] = []
  var savedAllows: [AllowRule] = []
  var savedQuick: Date?
  var savedSleepOn = false
  var savedSleepStart = clock(23, 0)
  var savedSleepEnd = clock(7, 0)
  var savedSleepDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  var savedModifyStart = clock(0, 0)
  var savedModifyEnd = clock(23, 59)

  func locked(at now: Date = Date()) -> Bool {
    guard installed else { return false }
    return isOn(
      start: hhmmValue(savedStart), end: hhmmValue(savedEnd), days: savedDays,
      quick: savedQuick.map { Int($0.timeIntervalSince1970) } ?? 0,
      weekday: isoWeekday(now), hhmm: hhmmValue(now), epoch: Int(now.timeIntervalSince1970)
    )
  }

  func sleeping(at now: Date) -> Bool {
    guard installed else { return false }
    return sleepWindow(
      on: savedSleepOn, start: hhmmValue(savedSleepStart), end: hhmmValue(savedSleepEnd),
      days: savedSleepDays, weekday: isoWeekday(now), hhmm: hhmmValue(now)
    )
  }

  func modifyOpen(at now: Date = Date()) -> Bool {
    guard installed else { return true }
    return activeAt(start: hhmmValue(savedModifyStart), end: hhmmValue(savedModifyEnd), now: hhmmValue(now))
  }

  func status(at now: Date) -> String {
    if !installed { return "还没开始。" }
    if sleeping(at: now) { return "关机中，到 \(humanDeadline(endMoment(savedSleepEnd, from: now), from: now))。" }
    if isActive(at: now) { return "生效中，到 \(humanDeadline(until(at: now), from: now))。" }
    if hhmm(savedStart) == hhmm(savedEnd) { return "起止相同，不会生效。" }
    if !savedDays.contains(isoWeekday(now)) { return "今天不生效。" }
    return "未生效，\(human(savedStart)) 开始。"
  }

  func isActive(at now: Date = Date()) -> Bool {
    locked(at: now)
  }

  func until(at now: Date) -> Date {
    var best: Date?
    if isOn(start: hhmmValue(savedStart), end: hhmmValue(savedEnd), days: savedDays,
            quick: 0, weekday: isoWeekday(now), hhmm: hhmmValue(now), epoch: Int(now.timeIntervalSince1970)) {
      best = endMoment(savedEnd, from: now)
    }
    if let q = savedQuick, q > now {
      if best == nil || q > best! { best = q }
    }
    return best ?? savedEnd
  }

  func quickEpoch(now: Date = Date()) -> Int {
    let q = pendingQuick ?? quickUntil
    guard let q, q > now else { return 0 }
    return Int(q.timeIntervalSince1970)
  }

  func toggleDay(_ d: Int) {
    var next = days
    if next.contains(d) {
      if locked() && savedDays.contains(d) {
        error = focusLockText
        return
      }
      next.remove(d)
    } else {
      next.insert(d)
    }
    error = ""
    days = next
  }

  func setSleepOn(_ on: Bool) {
    if !modifyOpen() {
      error = editLockText
      return
    }
    error = ""
    sleepOn = on
  }

  func toggleSleepDay(_ d: Int) {
    if !modifyOpen() {
      error = editLockText
      return
    }
    var next = sleepDays
    if next.contains(d) { next.remove(d) } else { next.insert(d) }
    error = ""
    sleepDays = next
  }

  func addAppName(_ raw: String) {
    let name = clean(raw)
    guard !name.isEmpty else {
      error = "先在框里写上软件名字，再点添加。"
      return
    }
    guard name.count <= 100 else {
      error = "名字太长了。短一点再添加。"
      return
    }
    if isSystemApp(name) {
      error = "「\(name)」不能关，不然电脑会没法用。"
      return
    }
    error = ""
    if !already(apps, name) { apps.append(name) }
    appText = ""
  }

  func addWord() {
    let word = clean(wordText)
    guard !word.isEmpty else {
      error = "先在框里写上词，再点添加。"
      return
    }
    guard word.count <= 100 else {
      error = "这个词太长了。短一点再添加。"
      return
    }
    if word.count < 2 {
      pendingWord = word
      showShortWord = true
      return
    }
    commitWord(word)
  }

  func commitWord(_ word: String) {
    error = ""
    if !already(words, word) { words.append(word) }
    wordText = ""
    pendingWord = ""
  }

  func sameAllow(_ a: AllowRule, _ b: AllowRule) -> Bool {
    a.use == b.use && a.cool == b.cool && a.name.caseInsensitiveCompare(b.name) == .orderedSame
  }

  func freshAllowCount() -> Int {
    var keys: [String] = []
    for rule in allows {
      if savedAllows.contains(where: { sameAllow($0, rule) }) { continue }
      let key = "\(rule.name.lowercased())|\(rule.use)|\(rule.cool)"
      if !keys.contains(key) { keys.append(key) }
    }
    return keys.count
  }

  func allowSlotOpen(now: Date = Date()) -> Bool {
    if freshAllowCount() >= 1 { return false }
    if allowDay.isEmpty { return true }
    return allowDay < beijingDay(now)
  }

  func addAllow(now: Date = Date()) {
    let name = clean(allowText)
    guard !name.isEmpty else {
      error = "先写上网站或软件，再点添加。"
      return
    }
    guard name.count <= 100, !name.contains("|") else {
      error = "这个名字不能用。换一个再添加。"
      return
    }
    let use = Int(allowUseText.trimmingCharacters(in: .whitespaces)) ?? 0
    let cool = Int(allowCoolText.trimmingCharacters(in: .whitespaces)) ?? 0
    guard (1...1440).contains(use), (1...1440).contains(cool) else {
      error = "使用和停用都要在 1 到 1440 分钟。"
      return
    }
    let rule = AllowRule(name: name, use: use, cool: cool, since: 0)
    if allows.contains(where: { sameAllow($0, rule) }) {
      allowText = ""
      error = ""
      return
    }
    if let saved = savedAllows.first(where: { sameAllow($0, rule) }) {
      allows.append(saved)
      allowText = ""
      error = ""
      return
    }
    guard allowSlotOpen(now: now) else {
      error = "一天只能加一条白名单。"
      return
    }
    allows.append(rule)
    allowText = ""
    error = ""
  }

  func removeAllow(at index: Int) {
    guard allows.indices.contains(index) else { return }
    allows.remove(at: index)
    error = ""
  }

  func startQuick() {
    let secs = quickHours * 3600 + quickMinutes * 60
    guard secs >= 60 else {
      error = "先填一段时间。"
      return
    }
    let end = Date().addingTimeInterval(TimeInterval(secs))
    if let old = savedQuick, locked(), end < old {
      error = focusLockText
      return
    }
    pendingQuick = end
    saveTapped()
  }

  func weakened(at now: Date = Date()) -> Bool {
    if hhmm(start) != hhmm(savedStart) || hhmm(end) != hhmm(savedEnd) { return true }
    if savedDays.contains(where: { !days.contains($0) }) { return true }
    if let old = savedQuick, old > now {
      let new = (pendingQuick ?? quickUntil)?.timeIntervalSince1970 ?? 0
      if new + 0.5 < old.timeIntervalSince1970 { return true }
    }
    return false
  }

  func editWeakened(at now: Date = Date()) -> Bool {
    guard installed, !modifyOpen(at: now) else { return false }
    if savedApps.contains(where: { !already(apps, $0) }) { return true }
    if savedWords.contains(where: { !already(words, $0) }) { return true }
    if sleepOn != savedSleepOn || sleepDays != savedSleepDays { return true }
    if hhmm(sleepStart) != hhmm(savedSleepStart) || hhmm(sleepEnd) != hhmm(savedSleepEnd) { return true }
    if hhmm(modifyStart) != hhmm(savedModifyStart) || hhmm(modifyEnd) != hhmm(savedModifyEnd) { return true }
    return false
  }

  func saveTapped(provisionFingerprint: Bool = false) {
    guard !saving else { return }
    provisioningFingerprint = provisionFingerprint
    error = ""
    var focusBlocked = false
    if locked() && weakened() {
      start = savedStart
      end = savedEnd
      days = savedDays
      pendingQuick = nil
      focusBlocked = true
    }
    let editBlocked = editWeakened()
    if editBlocked {
      for name in savedApps where !already(apps, name) { apps.append(name) }
      for word in savedWords where !already(words, word) { words.append(word) }
      sleepOn = savedSleepOn
      sleepStart = savedSleepStart
      sleepEnd = savedSleepEnd
      sleepDays = savedSleepDays
      modifyStart = savedModifyStart
      modifyEnd = savedModifyEnd
    }
    if focusBlocked || editBlocked {
      error = editBlocked ? editLockText : focusLockText
      return
    }
    if hhmm(start) == hhmm(end) || hhmm(modifyStart) == hhmm(modifyEnd) || (sleepOn && hhmm(sleepStart) == hhmm(sleepEnd)) {
      pendingQuick = nil
      showSameTime = true
      return
    }
    if apps.isEmpty && words.isEmpty {
      showEmpty = true
      return
    }
    commitSave()
  }

  func commitSave() {
    guard let script = Bundle.main.resourceURL?.appendingPathComponent("install.sh").path else {
      error = "这个窗口不完整。关掉后，重新双击「专注时间」。"
      return
    }
    let payload = renderConfig(
      start: hhmm(start), end: hhmm(end), days: daysString(days), quick: quickEpoch(), apps: apps, words: words,
      sleepOn: sleepOn, sleepStart: hhmm(sleepStart), sleepEnd: hhmm(sleepEnd), sleepDays: daysString(sleepDays),
      modifyStart: hhmm(modifyStart), modifyEnd: hhmm(modifyEnd),
      allows: allows, allowDay: allowDay
    )
    saving = true
    error = ""
    let provision = provisioningFingerprint
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.global(qos: .userInitiated).async {
      let problem = provision ? BiometricSave.provision(script: script, payload: payload) : BiometricSave.save(payload: payload)
      DispatchQueue.main.async {
        self.saving = false
        self.provisioningFingerprint = false
        self.fingerprintReady = BiometricSave.isProvisioned
        self.pendingQuick = nil
        if let problem {
          self.error = problem
        } else {
          self.error = ""
          self.load()
        }
      }
    }
  }
}

private func clock(_ hhmm: Substring) -> Date? {
  let p = hhmm.split(separator: ":")
  guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), h >= 0, h < 24, m >= 0, m < 60 else { return nil }
  return clock(h, m)
}

func runAdministratorInstall(script: String, payload: String, enrollmentPublicKey: Data) -> String? {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("focusguard-\(UUID().uuidString).conf")
  do {
    try payload.write(to: url, atomically: true, encoding: .utf8)
  } catch {
    return "没记下你填的内容。再点一次。"
  }
  defer { try? FileManager.default.removeItem(at: url) }
  let publicKeyURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusguard-\(UUID().uuidString).pub")
  do {
    try enrollmentPublicKey.write(to: publicKeyURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: publicKeyURL.path)
  } catch { return "无法准备指纹保存授权。设置未保存。" }
  defer { try? FileManager.default.removeItem(at: publicKeyURL) }
  let publicKeyHash = BiometricSave.publicKeyHash(enrollmentPublicKey)
  let source = """
  do shell script "/bin/bash " & quoted form of \(appleQuote(script)) & " " & quoted form of \(appleQuote(url.path)) & " " & quoted form of \(appleQuote(publicKeyURL.path)) & " " & quoted form of \(appleQuote(publicKeyHash)) with prompt "首次启用指纹保存需要 macOS 管理员授权；之后每次保存只用 Touch ID" with administrator privileges
  """
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  proc.arguments = ["-e", source]
  let errPipe = Pipe()
  proc.standardError = errPipe
  proc.standardOutput = Pipe()
  do {
    try proc.run()
  } catch {
    return "没能打开 macOS 安装授权窗口。请重试。"
  }
  proc.waitUntilExit()
  if proc.terminationStatus == 0 { return nil }
  let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  try? errText.write(toFile: "/tmp/focusguard.ui.log", atomically: true, encoding: .utf8)
  if errText.contains("User canceled") || errText.contains("-128") {
    return "已取消系统安装授权。指纹保存尚未启用。"
  }
  if errText.contains("incorrect") || errText.contains("不正确") || errText.contains("-60005") {
    return "这不是开机密码。填开机、装软件时用的那个，不要填 Apple ID。"
  }
  if errText.contains("修改时间外") { return editLockText }
  if errText.contains("只能添加") { return focusLockText }
  if errText.contains("一天只能加一条") { return "一天只能加一条白名单。" }
  if errText.contains("白名单要写上") { return "白名单要写上名字，并填使用分钟和停用分钟。" }
  if errText.contains("屏蔽服务没有起来") {
    return "网站写上了，屏蔽服务没起来。"
  }
  return "安装或指纹授权没有完成，请检查保护服务后重试。"
}

struct ContentView: View {
  @StateObject private var model = PageModel()
  @State private var tab = 0
  @State private var showHelp = false
  @State private var showEditWindow = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      VStack(spacing: 0) {
        header(at: context.date)
        Picker("设置分类", selection: $tab) {
          Text("网站").tag(0)
          Text("应用").tag(1)
          Text("白名单").tag(2)
          Text("时间").tag(3)
          Text("关机").tag(4)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 520)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)

        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            switch tab {
            case 0: wordPage
            case 1: appPage
            case 2: allowPage(now: context.date)
            case 3: timePage
            default: sleepPage
            }
          }
          .padding(28)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        footer
      }
    }
    .frame(minWidth: 640, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(WindowLock())
    .onAppear { model.load() }
    .alert("起止时间不能相同", isPresented: $model.showSameTime) {
      Button("返回修改", role: .cancel) {}
    } message: {
      Text("请为专注、允许修改和关机时段设置不同的开始与结束时间。")
    }
    .alert("还没有屏蔽内容", isPresented: $model.showEmpty) {
      Button("仍然保存") { model.commitSave() }
      Button("返回添加", role: .cancel) { model.pendingQuick = nil }
    } message: {
      Text("添加网站或应用后，才能在专注时段关闭它们。")
    }
    .alert("这个关键词很短", isPresented: $model.showShortWord) {
      Button("仍然添加") { model.commitWord(model.pendingWord) }
      Button("取消", role: .cancel) {}
    } message: {
      Text("短词容易匹配无关网页，建议使用完整域名或更具体的词。")
    }
  }

  private func header(at now: Date) -> some View {
    VStack(spacing: 12) {
      Text("专注时间")
        .font(.system(size: 32, weight: .bold))
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      Label(model.status(at: now), systemImage: model.locked(at: now) ? "shield.lefthalf.filled" : "clock")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(model.sleeping(at: now) ? Color.orange : (model.locked(at: now) ? Color.accentColor : Color.secondary))
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 56)
    .padding(.top, 26)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .topTrailing) {
      HStack(spacing: 8) {
        Button("后台运行") { BackgroundUI.hideWindows() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("隐藏窗口，后台继续运行；点击程序坞图标可重新打开")
        Button { showHelp = true } label: {
          Image(systemName: "questionmark.circle")
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看当前页面说明")
        .help("使用说明")
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 10) {
            Text("使用说明").font(.headline)
            Text(helpText(tab)).font(.system(size: 13))
          }
          .padding(18)
          .frame(width: 300, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
    }
  }

  private var hasChanges: Bool {
    hhmm(model.start) != hhmm(model.savedStart) || hhmm(model.end) != hhmm(model.savedEnd)
      || model.days != model.savedDays || model.apps != model.savedApps || model.words != model.savedWords
      || model.sleepOn != model.savedSleepOn || model.sleepDays != model.savedSleepDays
      || hhmm(model.sleepStart) != hhmm(model.savedSleepStart) || hhmm(model.sleepEnd) != hhmm(model.savedSleepEnd)
      || hhmm(model.modifyStart) != hhmm(model.savedModifyStart) || hhmm(model.modifyEnd) != hhmm(model.savedModifyEnd)
      || model.allows != model.savedAllows
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !model.error.isEmpty {
        Label(model.error, systemImage: "exclamationmark.circle.fill")
          .font(.system(size: 13))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.saving ? (model.provisioningFingerprint ? "系统授权中…" : "等待指纹验证…") : (!model.installed ? "未启用" : (hasChanges ? "未保存" : "已保存")))
            .font(.system(size: 13, weight: .medium))
          Text(model.fingerprintReady ? "每次保存使用 Touch ID" : "首次启用需 macOS 管理员授权")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .help("首次系统授权可能要求账户密码；日常保存没有密码备用入口。")
        }
        Spacer(minLength: 8)
        if model.saving { ProgressView().controlSize(.small) }
        Menu {
          Button("重新启用指纹保存…") { model.saveTapped(provisionFingerprint: true) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.saving)
        .accessibilityLabel("指纹保存设置")
        .help("重新配对指纹或安装更新，需要一次 macOS 系统授权")
        Button { model.saveTapped(provisionFingerprint: !model.fingerprintReady) } label: {
          Text(model.saving ? "保存中" : (model.fingerprintReady ? "指纹保存" : "启用指纹保存"))
            .frame(minWidth: 102)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.saving)
        .keyboardShortcut("s", modifiers: .command)
        .help(BiometricSave.explanation)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 18)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .top) { Divider() }
  }

  private func sectionHeading(_ title: String, help: String, locked: Bool = false) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      if locked {
        Image(systemName: "lock")
          .foregroundStyle(.secondary)
          .accessibilityLabel("已锁定")
      }
      Spacer()
      InfoButton(text: help)
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14, content: content)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
  }

  private func allowPhase(_ rule: AllowRule, now: Date) -> String {
    let t = Int(now.timeIntervalSince1970)
    if rule.since <= 0 || t < rule.since { return "保存后开始计时" }
    let period = (rule.use + rule.cool) * 60
    let pos = (t - rule.since) % period
    if pos < rule.use * 60 {
      let left = max(1, (rule.use * 60 - pos + 59) / 60)
      return "使用中，约 \(left) 分钟后停"
    }
    let left = max(1, (period - pos + 59) / 60)
    return "停用中，约 \(left) 分钟后再用"
  }

  private func allowPage(now: Date) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        TextField("网站或应用", text: $model.allowText)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .accessibilityLabel("白名单名称")
          .onSubmit { model.addAllow(now: now) }
        Button("添加") { model.addAllow(now: now) }.controlSize(.large)
      }
      HStack(spacing: 8) {
        Text("使用")
        TextField("25", text: $model.allowUseText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 64)
          .accessibilityLabel("使用分钟")
        Text("分钟，然后停")
        TextField("60", text: $model.allowCoolText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 64)
          .accessibilityLabel("停用分钟")
        Text("分钟")
        Spacer(minLength: 0)
        InfoButton(text: "一天只能新加一条。删掉随时可以，名额不退回。改分钟数也算新加一条。")
      }
      .font(.system(size: 13))
      Text(model.allowSlotOpen(now: now) ? "今天还能加 1 条。" : "今天的名额已经用过。已有的可以删。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      HStack {
        Text("白名单 · \(model.allows.count)").font(.system(size: 13, weight: .semibold))
        Spacer()
      }
      VStack(spacing: 0) {
        if model.allows.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "checkmark.shield").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("暂无").font(.system(size: 13)).foregroundStyle(.secondary)
          }
          .padding(26)
          .frame(maxWidth: .infinity)
        } else {
          ForEach(Array(model.allows.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14)).textSelection(.enabled)
                Text("使用 \(item.use) 分钟，停 \(item.cool) 分钟 · \(allowPhase(item, now: now))")
                  .font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              Button { model.removeAllow(at: index) } label: {
                Image(systemName: "minus.circle")
                  .frame(width: 28, height: 28).contentShape(Rectangle())
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .accessibilityLabel("移除白名单 \(item.name)")
              .help("移除 \(item.name)")
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            if index < model.allows.count - 1 { Divider().padding(.horizontal, 16) }
          }
        }
      }
      .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
  }

  private var wordPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        TextField("域名或关键词", text: $model.wordText)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .accessibilityLabel("网站域名或关键词")
          .onSubmit { model.addWord() }
        Button("添加") { model.addWord() }.controlSize(.large)
      }
      listHeading("屏蔽词", count: model.words.count)
      lines(model.words, canRemove: model.modifyOpen(), symbol: "globe") { name in
        model.words.removeAll { $0 == name }
      }
    }
  }

  private var appPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        TextField("应用名称", text: $model.appText)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .accessibilityLabel("应用名称")
          .onSubmit { model.addAppName(model.appText) }
        Button("添加") { model.addAppName(model.appText) }.controlSize(.large)
      }
      Menu {
        let running = runningAppNames()
        if running.isEmpty {
          Button("没有可添加的应用") {}.disabled(true)
        } else {
          ForEach(running, id: \.self) { name in
            Button(name) { model.addAppName(name) }
          }
        }
      } label: {
        Label("已打开的应用", systemImage: "plus.app")
      }
      .fixedSize()
      listHeading("应用", count: model.apps.count)
      lines(model.apps, canRemove: model.modifyOpen(), symbol: "app.dashed") { name in
        model.apps.removeAll { $0 == name }
      }
    }
  }

  private var timePage: some View {
    VStack(alignment: .leading, spacing: 20) {
      card {
        sectionHeading("固定时段", help: "结束早于开始时，持续到第二天。专注生效后，当前时段不能缩短或取消。", locked: model.locked())
        timeRange(start: $model.start, end: $model.end, prefix: "专注", disabled: model.locked())
        dayButtons(model.days, toggle: model.toggleDay)
      }
      card {
        sectionHeading("临时专注", help: "立即保存当前设置并开始，不受所选星期限制。")
        HStack(spacing: 12) {
          Stepper(value: $model.quickHours, in: 0...23) { Text("\(model.quickHours) 小时").monospacedDigit() }
            .fixedSize().accessibilityLabel("临时专注小时")
          Stepper(value: $model.quickMinutes, in: 0...59) { Text("\(model.quickMinutes) 分钟").monospacedDigit() }
            .fixedSize().accessibilityLabel("临时专注分钟")
          Spacer(minLength: 0)
          Button("开始") { model.startQuick() }
            .disabled(model.saving || (model.quickHours == 0 && model.quickMinutes == 0))
        }
        if let until = model.savedQuick, until > Date() {
          Label("到 \(humanDeadline(until, from: Date()))", systemImage: "timer")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
      }
      card {
        DisclosureGroup(isExpanded: $showEditWindow) {
          HStack(spacing: 8) {
            timeRange(start: $model.modifyStart, end: $model.modifyEnd, prefix: "允许修改", disabled: !model.modifyOpen())
            InfoButton(text: "仅在这段时间内能删网站、删应用或调整关机计划。白名单随时可以删。")
          }.padding(.top, 12)
        } label: {
          HStack {
            Text("修改时段").font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(human(model.modifyStart))–\(human(model.modifyEnd))")
              .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
          }
        }
      }
    }
  }

  private var sleepPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      card {
        HStack(spacing: 10) {
          Toggle("定时关机", isOn: Binding(get: { model.sleepOn }, set: { model.setSleepOn($0) }))
            .font(.headline)
            .toggleStyle(.switch)
            .disabled(!model.modifyOpen())
          InfoButton(text: "到点前 30 秒弹出置顶提醒。只有点击「我马上保存并关机」才能解除弹窗，点击后才开始 30 秒关机倒计时，请及时保存工作。", symbol: "exclamationmark.triangle", tint: model.sleepOn ? .orange : .secondary)
          if !model.modifyOpen() {
            InfoButton(text: "修改时段外不能调整关机计划。", symbol: "lock")
          }
        }
        if model.sleepOn {
          Divider()
          timeRange(start: $model.sleepStart, end: $model.sleepEnd, prefix: "关机", disabled: !model.modifyOpen())
          dayButtons(model.sleepDays, toggle: model.toggleSleepDay)
        }
      }
    }
  }

  private func timeRange(start: Binding<Date>, end: Binding<Date>, prefix: String, disabled: Bool) -> some View {
    HStack(spacing: 12) {
      DatePicker("\(prefix)开始", selection: start, displayedComponents: .hourAndMinute)
        .labelsHidden().datePickerStyle(.field)
        .accessibilityLabel("\(prefix)开始时间")
      Text("至").foregroundStyle(.secondary)
      DatePicker("\(prefix)结束", selection: end, displayedComponents: .hourAndMinute)
        .labelsHidden().datePickerStyle(.field)
        .accessibilityLabel("\(prefix)结束时间")
      Spacer(minLength: 0)
    }.disabled(disabled)
  }

  private func helpText(_ tab: Int) -> String {
    let tail = "日常保存只使用 Touch ID；取消或验证失败就不保存。首次启用和安装更新需要 macOS 管理员授权。修改时段外不能删网站、删应用或改关机计划。白名单随时可以删。"
    switch tab {
    case 0: return "关键词按字面匹配网页地址或标题，不区分大小写。使用时间内每约 5 秒检查一次，命中就立即关闭网页。标签无法关闭时会退出整个浏览器。\n\n" + tail
    case 1: return "应用名称以程序坞中显示的为准。系统必需的应用不会关闭，名单中的应用在专注时段一到就关闭。\n\n" + tail
    case 2: return "白名单在使用分钟里放过黑名单。应用要和程序坞里的名字一致；网站是地址或标题里含有这个词就不关。保存后先用你填的分钟，再停用另一段分钟，然后重复。一天只能新加一条，删掉不退回名额。改使用或停用分钟也算新加。日历日按北京时间。\n\n" + tail
    case 3: return "结束早于开始时会跨夜。临时专注立即保存并生效。允许修改的时段默认是 0:00–23:59，可展开调整。\n\n" + tail
    default: return "到点前 30 秒弹出置顶大窗口，点击「我马上保存并关机」后才开始 30 秒倒计时。未点击不会自动关机；确认后在关机时段内每 10 秒重试关机。结束早于开始时跨夜，默认每天。\n\n" + tail
    }
  }

  private func dayButtons(_ days: Set<Int>, toggle: @escaping (Int) -> Void) -> some View {
    HStack(spacing: 6) {
      ForEach(1...7, id: \.self) { day in
        let on = days.contains(day)
        Button("周\(dayTitles[day - 1])") { toggle(day) }
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: on ? .semibold : .regular))
          .frame(maxWidth: .infinity, minHeight: 32)
          .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor : Color(nsColor: .windowBackgroundColor)))
          .foregroundStyle(on ? Color.white : Color.primary)
          .accessibilityLabel("星期\(dayTitles[day - 1])")
          .accessibilityValue(on ? "已选择" : "未选择")
      }
    }
  }

  private func listHeading(_ title: String, count: Int) -> some View {
    HStack {
      Text("\(title) · \(count)").font(.system(size: 13, weight: .semibold))
      Spacer()
      if !model.modifyOpen() {
        InfoButton(text: "修改时段外只能添加，不能删除。", symbol: "lock")
      }
    }
  }

  private func lines(_ items: [String], canRemove: Bool, symbol: String, remove: @escaping (String) -> Void) -> some View {
    VStack(spacing: 0) {
      if items.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
          Text("暂无").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(maxWidth: .infinity)
      } else {
        ForEach(Array(items.enumerated()), id: \.element) { index, item in
          HStack(spacing: 12) {
            Text(item).font(.system(size: 14)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            if canRemove {
              Button { remove(item) } label: {
                Image(systemName: "minus.circle")
                  .frame(width: 28, height: 28).contentShape(Rectangle())
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .accessibilityLabel("移除 \(item)")
              .help("移除 \(item)")
            }
          }
          .padding(.horizontal, 16).padding(.vertical, 7)
          if index < items.count - 1 { Divider().padding(.horizontal, 16) }
        }
      }
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
  }
}

private struct InfoButton: View {
  let text: String
  var symbol = "info.circle"
  var tint: Color = .secondary
  @State private var isPresented = false

  var body: some View {
    Button { isPresented = true } label: {
      Image(systemName: symbol)
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("说明")
    .accessibilityHint(text)
    .help(text)
    .popover(isPresented: $isPresented) {
      Text(text)
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

final class AppModel: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    ignoreStopSignals()
    DispatchQueue.main.async { ignoreStopSignals() }
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    BackgroundUI.showWindows(in: sender)
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if systemPowerQuit() {
      lettingSystemQuit = true
      return .terminateNow
    }
    BackgroundUI.hideWindows(in: sender)
    return .terminateCancel
  }
}

struct WindowLock: NSViewRepresentable {
  func makeCoordinator() -> Lock { Lock() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { context.coordinator.attach(view.window) }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { context.coordinator.attach(nsView.window) }
  }

  final class Lock: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    func attach(_ window: NSWindow?) {
      guard let window else { return }
      if window.delegate !== self {
        original = window.delegate
        window.delegate = self
      }
      if let button = window.standardWindowButton(.closeButton) {
        button.isHidden = false
        button.toolTip = "后台运行"
        button.setAccessibilityLabel("后台运行")
        button.setAccessibilityHelp("隐藏窗口，后台继续运行")
      }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if lettingSystemQuit || systemPowerQuit() { return true }
      BackgroundUI.hideWindows()
      return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
      super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
      if original?.responds(to: aSelector) == true { return original }
      return super.forwardingTarget(for: aSelector)
    }
  }
}

// This runs in a separate process so waiting for confirmation never blocks the guard.
private final class ShutdownWarningWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func cancelOperation(_ sender: Any?) {}
  override func performClose(_ sender: Any?) {}
  override func performMiniaturize(_ sender: Any?) {}
}

private struct ShutdownWarningView: View {
  let message: String
  let acknowledge: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      ScrollView {
        VStack(spacing: 20) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 52))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("请保存工作，准备关机")
            .font(.system(size: 32, weight: .bold))
            .multilineTextAlignment(.center)
          Text("点击下方按钮后，提醒窗口会关闭，\n并开始 30 秒关机倒计时。")
            .font(.system(size: 20, weight: .medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Text("未确认前不会开始倒计时，请先做好保存准备。")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Text(message)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
      }
      Button("我马上保存并关机", action: acknowledge)
        .font(.system(size: 20, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("关闭提醒，并开始 30 秒关机倒计时")
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private final class ShutdownWarningController: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let message: String
  private let requestFile: String?
  private var window: ShutdownWarningWindow?
  private var timer: Timer?
  private var keyMonitor: Any?

  private init(message: String, requestFile: String?) {
    self.message = message
    self.requestFile = requestFile
  }

  static func run(message: String, requestFile: String?) -> Never {
    let application = NSApplication.shared
    let controller = ShutdownWarningController(message: message, requestFile: requestFile)
    application.setActivationPolicy(.accessory)
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
    // An interrupted process is never an acknowledgment.
    exit(2)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard requestIsCurrent else { exit(2) }
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
    let size = NSSize(width: min(760, max(1, available.width - 40)),
                      height: min(500, max(1, available.height - 40)))
    let window = ShutdownWarningWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.title = "专注时间 · 关机提醒"
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.hidesOnDeactivate = false
    window.canHide = false
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = true
    }
    window.contentView = NSHostingView(rootView: ShutdownWarningView(message: message) { [weak self] in
      self?.acknowledge()
    })
    window.setFrameOrigin(NSPoint(x: available.midX - window.frame.width / 2,
                                 y: available.midY - window.frame.height / 2))
    self.window = window
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
      if event.keyCode == 53 { return nil } // Escape cannot dismiss this reminder.
      if event.modifierFlags.contains(.command) && ["w", "q", "h", "m"].contains(key) { return nil }
      return event
    }
    bringForward()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self else { return }
      // The guard removes its private request file when the plan changes or it exits.
      guard self.requestIsCurrent else { exit(2) }
      self.window?.orderFrontRegardless()
    }
  }

  private var requestIsCurrent: Bool {
    requestFile.map { FileManager.default.fileExists(atPath: $0) } ?? true
  }

  private func bringForward() {
    NSApp.unhide(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.orderFrontRegardless()
  }

  private func acknowledge() {
    guard requestIsCurrent else { exit(2) }
    // Round up so polling and integer timestamps can never shorten the 30-second grace period.
    print(Int(ceil(Date().timeIntervalSince1970)))
    fflush(stdout)
    exit(0)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { false }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if systemPowerQuit() { exit(2) }
    bringForward()
    return .terminateCancel
  }

  func applicationDidHide(_ notification: Notification) { bringForward() }
  func applicationDidResignActive(_ notification: Notification) { window?.orderFrontRegardless() }
}

@main
enum MainEntry {
  static func main() {
    let arguments = CommandLine.arguments
    if arguments.count >= 3 && arguments[1] == "--shutdown-warning" {
      ShutdownWarningController.run(message: arguments[2], requestFile: arguments.count > 3 ? arguments[3] : nil)
    }
    ignoreStopSignals()
    if CommandLine.arguments.contains("--selftest") {
      if !selfTest() {
        fputs("FAIL\n", stderr)
        exit(1)
      }
      print("ok")
      exit(0)
    }
    FocusGuardApp.main()
  }
}

struct FocusGuardApp: App {
  @NSApplicationDelegateAdaptor(AppModel.self) var appModel

  var body: some Scene {
    WindowGroup("专注时间") {
      ContentView()
    }
    .windowResizability(.contentMinSize)
    .defaultSize(width: 680, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appTermination) {
        Button("后台运行") { BackgroundUI.hideWindows() }
          .keyboardShortcut("q", modifiers: .command)
      }
    }
  }
}
