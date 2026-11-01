import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

enum FocusPhase: String, Codable { case work, readyBreak, rest, readyWork }
struct FocusSession: Codable, Equatable {
    var id = UUID()
    var title: String
    var blockID: UUID?
    var taskID: UUID?
    var phase: FocusPhase = .work
    var remainingSeconds: Int
    var initialSeconds: Int
    var endsAt: Date?
    var hardStop: Date?
    var startedAt: Date
    var projectID: UUID? = nil
    var slices: [FocusSlice]? = nil
    var activeSince: Date? = nil
    var lastCheckpoint: Date? = nil
    func remaining(at now: Date) -> Int {
        endsAt.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? remainingSeconds
    }
}
struct FocusLog: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var seconds: Int
    var day: String
    var blockID: UUID?
    var taskID: UUID? = nil
    var projectID: UUID? = nil
    var slices: [FocusSlice]? = nil
    func seconds(on key: String) -> Int {
        if let slices { return slices.reduce(0) { $0 + $1.seconds(on: key) } }
        return day == key ? seconds : 0
    }
}
private struct FocusDocument: Codable {
    var session: FocusSession?
    var logs: [FocusLog]
    var workMinutes: Int
    var restMinutes: Int
}

@MainActor
final class FocusClock: ObservableObject {
    static let shared = FocusClock()
    @Published private(set) var session: FocusSession?
    @Published private(set) var remaining = 0
    @Published private(set) var logs: [FocusLog] = []
    @Published private(set) var workMinutes = 25
    @Published private(set) var restMinutes = 5
    @Published private(set) var message = ""
    @Published private(set) var notificationsEnabled = false
    private var fileURL: URL?
    private var timer: AnyCancellable?
    private let useSystem: Bool
    private let notificationID = "daylist.focus.end"
    private var writable = true
    private var blockSubscription: AnyCancellable?
    private var plannedBlocks: [TimeBlock] = []
    private var blockGeneration = 0
    private var projectGeneration = 0
    private var projectNoticeDay = ""
    private var reachedProjects = Set<UUID>()
    private var plannedProjects: [LifeProject] = []
    private weak var todoStore: TodoStore?
    private var lifecycle = Set<AnyCancellable>()

    func configure(store: TodoStore) {
        let directory = store.fileURL.deletingLastPathComponent()
        let target = directory.appendingPathComponent("focus-v2.json")
        let legacy = directory.appendingPathComponent("focus.json")
        if fileURL == nil && !FileManager.default.fileExists(atPath: target.path) && FileManager.default.fileExists(atPath: legacy.path) {
            do { try FileManager.default.copyItem(at: legacy, to: target) }
            catch { message = "专注历史迁移失败，旧记录已保留。"; writable = false; return }
        }
        configure(fileURL: target)
        todoStore = store
        guard blockSubscription == nil else { return }
        store.$projects.removeDuplicates().sink { [weak self] projects in
            self?.plannedProjects = projects; self?.scheduleProjectNotifications()
        }.store(in: &lifecycle)
        if useSystem {
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in self?.pause() }.store(in: &lifecycle)
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in self?.pause() }.store(in: &lifecycle)
        }
        blockSubscription = store.$timeBlocks.removeDuplicates().sink { [weak self] blocks in
            guard let self else { return }
            let previous = self.plannedBlocks; self.plannedBlocks = blocks
            if let id = self.session?.blockID {
                if let block = blocks.first(where: { $0.id == id }), !block.completed, !block.isRest {
                    if previous.first(where: { $0.id == id }) != block { self.updateBlock(block) }
                } else { self.end() }
            }
            self.scheduleBlockNotifications()
        }
    }

    init(fileURL: URL? = nil, runTimer: Bool = true) {
        useSystem = runTimer && !RuntimeMode.demo
        if let fileURL { configure(fileURL: fileURL) }
        if runTimer {
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] now in self?.tick(now: now) }
        }
    }
    func configure(fileURL: URL) {
        guard self.fileURL == nil else { return }
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let doc = try JSONDecoder().decode(FocusDocument.self, from: Data(contentsOf: fileURL))
                guard (5...120).contains(doc.workMinutes), (1...30).contains(doc.restMinutes),
                      doc.logs.allSatisfy({ $0.seconds >= 0 && $0.seconds <= 7200 && Day.date($0.day) != nil && Self.validSlices($0.slices, seconds: $0.seconds) }) && Set(doc.logs.map(\.id)).count == doc.logs.count,
                      doc.session.map({ $0.initialSeconds > 0 && $0.initialSeconds <= 7200 && $0.remainingSeconds >= 0 && $0.remainingSeconds <= $0.initialSeconds && Self.validSlices($0.slices, seconds: $0.slices?.reduce(0, { $0 + $1.seconds }) ?? 0) && ($0.slices?.reduce(0, { $0 + $1.seconds }) ?? 0) <= $0.initialSeconds }) ?? true
                else { throw StoreError.invalidDocument("专注记录不正确") }
                session = doc.session; logs = doc.logs; workMinutes = doc.workMinutes; restMinutes = doc.restMinutes
                if let running = session, running.endsAt != nil, running.slices != nil {
                    pause(now: min(Date(), running.lastCheckpoint ?? running.startedAt))
                    message = "已恢复上次专注并暂停；离线期间没有增加投入，点击继续。"
                } else { tick() }
            } catch { writable = false; message = "专注记录读取失败，已保留原文件；请先修复或移走当前专注记录文件。" }
        }
        if useSystem {
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                let enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                Task { @MainActor [weak self] in self?.notificationsEnabled = enabled; self?.scheduleNotification(); self?.scheduleBlockNotifications(); self?.scheduleProjectNotifications() }
            }
        }
    }
    var clockText: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    var running: Bool { session?.endsAt != nil }
    var canRequestNotifications: Bool { useSystem }
    var phaseText: String {
        switch session?.phase {
        case .work: return running ? "正在专注" : "专注已暂停"
        case .rest: return running ? "正在休息" : "休息已暂停"
        case .readyBreak: return "这一轮完成了"
        case .readyWork: return "休息结束了"
        case nil: return "留一段时间，专心做一件事"
        }
    }
    func seconds(on day: String) -> Int { accumulated(projectID: nil, day: day, now: Date()) }
    func projectSeconds(_ id: UUID, on day: String? = nil, now: Date = Date()) -> Int { accumulated(projectID: id, day: day, now: now) }
    private func accumulated(projectID: UUID?, day: String?, now: Date) -> Int {
        let saved = logs.filter { projectID == nil || $0.projectID == projectID }.reduce(0) { $0 + (day.map($1.seconds(on:)) ?? $1.seconds) }
        guard let current = session, current.phase == .work,
              projectID == nil || current.projectID == projectID,
              !logs.contains(where: { $0.id == current.id }) else { return saved }
        let log = focusLog(current, now: now)
        return saved + (day.map(log.seconds(on:)) ?? log.seconds)
    }
    private static func validSlices(_ slices: [FocusSlice]?, seconds: Int) -> Bool {
        guard let slices else { return true }
        guard slices.count <= 10000, slices.allSatisfy({ $0.end >= $0.start && $0.seconds <= 7200 }),
              slices.reduce(0, { $0 + $1.seconds }) == seconds else { return false }
        return zip(slices, slices.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    func updateBlock(_ block: TimeBlock, now: Date = Date()) {
        guard var current = session, current.blockID == block.id else { return }
        guard block.day == Day.key(now) else { end(now: now); message = "时间块已改期，当前专注已收尾。"; return }
        current.title = block.title; current.hardStop = ClockText.date(block.day, block.endMinute)
        session = current; tick(now: now); persist(); scheduleNotification(now: now)
    }
    func setDurations(work: Int, rest: Int) {
        workMinutes = min(120, max(5, work)); restMinutes = min(30, max(1, rest)); persist()
    }
    @discardableResult func start(title: String, blockID: UUID? = nil, taskID: UUID? = nil, projectID: UUID? = nil, hardStop: Date? = nil, now: Date = Date()) -> Bool {
        guard session == nil, writable else { return false }
        let seconds = min(workMinutes * 60, hardStop.map { max(0, Int($0.timeIntervalSince(now))) } ?? Int.max)
        guard seconds > 0 else { message = "这段安排已经结束，可以调整时间或开始自由专注。"; return false }
        session = FocusSession(title: title.isEmpty ? "专注一下" : title, blockID: blockID, taskID: taskID,
            remainingSeconds: seconds, initialSeconds: seconds, endsAt: now.addingTimeInterval(Double(seconds)), hardStop: hardStop, startedAt: now)
        session?.projectID = projectID ?? plannedBlocks.first(where: { $0.id == blockID })?.projectID ?? todoStore?.tasks.first(where: { $0.id == taskID })?.projectID
        session?.slices = []; session?.activeSince = now; session?.lastCheckpoint = now
        remaining = seconds; message = ""; persist(); scheduleNotification(now: now); return true
    }
    func pause(now: Date = Date()) {
        tick(now: now)
        guard var current = session, current.endsAt != nil else { return }
        closeSpan(&current, now: now)
        current.remainingSeconds = current.remaining(at: now); current.endsAt = nil; current.lastCheckpoint = now
        session = current; remaining = current.remainingSeconds; persist(); cancelNotification()
    }
    func resume(now: Date = Date()) {
        guard var current = session, current.endsAt == nil, [.work, .rest].contains(current.phase) else { return }
        if let stop = current.hardStop, stop <= now { end(now: now); message = "时间块已结束，留点余地再安排下一段。"; return }
        current.endsAt = now.addingTimeInterval(Double(current.remainingSeconds)); current.activeSince = now; current.lastCheckpoint = now; session = current
        persist(); tick(now: now); scheduleNotification(now: now)
    }
    func beginBreak(now: Date = Date()) {
        guard var current = session, current.phase == .readyBreak else { return }
        let seconds = min(restMinutes * 60, current.hardStop.map { max(0, Int($0.timeIntervalSince(now))) } ?? Int.max)
        guard seconds > 0 else { end(now: now); return }
        current.phase = .rest; current.remainingSeconds = seconds; current.initialSeconds = seconds
        current.endsAt = now.addingTimeInterval(Double(seconds)); current.startedAt = now
        current.slices = []; current.activeSince = nil; current.lastCheckpoint = now
        session = current; remaining = seconds; message = "站起来，喝点水，看看远处。"; persist(); scheduleNotification(now: now)
    }
    func nextRound(now: Date = Date()) {
        guard let old = session, [.readyWork, .readyBreak].contains(old.phase) else { return }
        session = nil
        _ = start(title: old.title, blockID: old.blockID, taskID: old.taskID, projectID: old.projectID, hardStop: old.hardStop, now: now)
    }
    func end(now: Date = Date()) {
        if let current = session { record(current, now: now) }
        session = nil; remaining = 0; message = "已结束这一段。事项是否完成，由你勾选。"; persist(); cancelNotification()
    }
    func tick(now: Date = Date()) {
        let day = Day.key(now)
        let reached = Set(plannedProjects.filter { project in
            let target = project.plan(on: day).minutes
            return target > 0 && projectSeconds(project.id, on: day, now: now) >= target * 60
        }.map(\.id))
        if day != projectNoticeDay || reached != reachedProjects {
            projectNoticeDay = day; reachedProjects = reached; scheduleProjectNotifications()
        }
        guard let current = session else { return }
        if let stop = current.hardStop, stop <= now {
            record(current, now: min(now, stop)); session = nil; remaining = 0
            message = "这段安排到时间了。可以收尾、休息，或重新安排。"
            persist(); cancelNotification(); if useSystem { NSSound.beep() }; return
        }
        remaining = current.remaining(at: now)
        guard current.endsAt != nil && remaining == 0 else {
            if current.endsAt != nil && now.timeIntervalSince(current.lastCheckpoint ?? now) >= 15 {
                var checkpoint = current; closeSpan(&checkpoint, now: now)
                checkpoint.activeSince = current.phase == .work ? now : nil
                checkpoint.lastCheckpoint = now; session = checkpoint; persist()
            }
            return
        }
        record(current, now: current.endsAt ?? now)
        var next = current; next.endsAt = nil
        next.phase = current.phase == .work ? .readyBreak : .readyWork
        next.remainingSeconds = 0; session = next
        message = current.phase == .work ? "完成一轮专注。休息 \(restMinutes) 分钟，再决定下一步。" : "休息好了，可以开始下一轮。"
        persist(); if useSystem { NSSound.beep() }
    }
    func requestNotifications() {
        guard useSystem else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                self?.notificationsEnabled = granted
                if let error { self?.message = "系统提醒未启用：" + error.localizedDescription }
                else if !granted { self?.message = "可到系统设置 → 通知 → 我Due！开启；计时仍可使用。" }
                self?.scheduleNotification()
                self?.scheduleBlockNotifications()
                self?.scheduleProjectNotifications()
            }
        }
    }
    private func closeSpan(_ current: inout FocusSession, now: Date) {
        guard current.phase == .work, current.slices != nil, let start = current.activeSince else { return }
        let finish = min(now, current.endsAt ?? now, current.hardStop ?? .distantFuture)
        if finish > start {
            if let last = current.slices?.last, abs(last.end.timeIntervalSince(start)) < 0.001 {
                current.slices![current.slices!.count - 1].end = finish
            } else { current.slices!.append(FocusSlice(start: start, end: finish)) }
        }
        current.activeSince = nil
    }
    private func focusLog(_ current: FocusSession, now: Date) -> FocusLog {
        var snapshot = current; closeSpan(&snapshot, now: now)
        let seconds = snapshot.slices.map { $0.reduce(0) { $0 + $1.seconds } }
            ?? max(0, min(current.initialSeconds, current.initialSeconds - current.remaining(at: now)))
        return FocusLog(id: current.id, title: current.title, seconds: seconds, day: Day.key(current.startedAt),
            blockID: current.blockID, taskID: current.taskID, projectID: current.projectID, slices: snapshot.slices)
    }
    private func record(_ current: FocusSession, now: Date) {
        guard current.phase == .work, !logs.contains(where: { $0.id == current.id }) else { return }
        let log = focusLog(current, now: now)
        guard log.seconds > 0 else { return }
        logs.append(log)
        scheduleProjectNotifications()
    }
    private func persist() {
        guard writable, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(FocusDocument(session: session, logs: logs, workMinutes: workMinutes, restMinutes: restMinutes)).write(to: fileURL, options: .atomic)
        } catch { message = "专注记录未能保存：" + error.localizedDescription }
    }
    private func cancelNotification() {
        guard useSystem else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
    private func scheduleNotification(now: Date = Date()) {
        guard useSystem, notificationsEnabled else { return }
        cancelNotification()
        guard let current = session, let end = current.endsAt else { return }
        let finish = min(end, current.hardStop ?? .distantFuture)
        if current.blockID != nil && finish == current.hardStop { return } // The block's end reminder covers this boundary.
        let interval = finish.timeIntervalSince(now)
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = current.hardStop.map { $0 <= end } == true ? "这一段安排到时间了" : (current.phase == .work ? "专注完成，休息一下" : "休息结束")
        content.body = current.title; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)) { [weak self] error in
            if let error { Task { @MainActor [weak self] in self?.message = "系统提醒未能安排：" + error.localizedDescription } }
        }
    }
    private func scheduleProjectNotifications() {
        guard useSystem else { return }
        projectGeneration += 1; let generation = projectGeneration
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            Task { @MainActor [weak self] in
                guard let self, self.projectGeneration == generation else { return }
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("daylist.project.") })
                guard self.notificationsEnabled else { return }
                let today = Day.today
                let finished = Set(self.plannedProjects.filter { project in
                    let target = project.plan(on: today).minutes
                    return target > 0 && self.projectSeconds(project.id, on: today) >= target * 60
                }.map(\.id))
                let notices = ProjectEngine.notices(self.plannedProjects, now: Date(), finishedToday: finished).prefix(ReminderBudget.projects)
                for notice in notices {
                    let content = UNMutableNotificationContent(); content.title = "给目标留一段时间"
                    content.body = notice.title + " · 今天计划 " + ClockText.duration(notice.minutes); content.sound = .default
                    let parts = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: notice.date)
                    let id = "daylist.project." + notice.projectID.uuidString + "." + Day.key(notice.date)
                    do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))) }
                    catch { self.message = "项目提醒未能安排：" + error.localizedDescription }
                    guard self.projectGeneration == generation else { return }
                }
            }
        }
    }
    private func scheduleBlockNotifications() {
        guard useSystem else { return }
        blockGeneration += 1; let generation = blockGeneration
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix("daylist.block.") }
            Task { @MainActor [weak self] in
                guard let self, self.blockGeneration == generation else { return }
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: old)
                guard self.notificationsEnabled else { return }
                let now = Date()
                let blocks = self.plannedBlocks.filter { !$0.completed && (ClockText.date($0.day, $0.endMinute) ?? .distantPast) > now }
                    .sorted { ($0.day, $0.startMinute) < ($1.day, $1.startMinute) }.prefix(ReminderBudget.blocks)
                for block in blocks {
                    for isStart in [true, false] {
                        guard let date = ClockText.date(block.day, isStart ? block.startMinute : block.endMinute), date > now else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = isStart ? (block.isRest ? "给自己一点休息时间" : "该开始这一段了") : "这段安排到时间了"
                        content.body = block.timeLabel + " · " + block.title; content.sound = .default
                        let parts = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                        let id = "daylist.block." + block.id.uuidString + (isStart ? ".start" : ".end")
                        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
                        catch { self.message = "时段提醒未能安排：" + error.localizedDescription }
                        guard self.blockGeneration == generation else { return }
                    }
                }
            }
        }
    }
}
