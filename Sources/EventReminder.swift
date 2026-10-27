import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

@MainActor
final class EventReminder: ObservableObject {
    static let shared = EventReminder()
    @Published private(set) var items: [EventItem] = []
    @Published private(set) var presented: [EventItem] = []
    @Published private(set) var scheduled: Set<String> = []
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var popupsEnabled = true
    @Published private(set) var message = ""
    var presentationChanged: ((Bool) -> Void)?
    var openTask: ((Todo) -> Void)?
    private weak var store: TodoStore?
    private var tasks: [Todo] = []
    private var ledger = EventLedger()
    private var fileURL: URL?
    private var writable = true
    private var subscriptions = Set<AnyCancellable>()
    private let useSystem: Bool
    private var generation = 0
    private var notificationTask: Task<Void, Never>?
    private var lastSchedule: Date = .distantPast
    private var queuedResponses: [(String, String, String)] = []

    init(fileURL: URL? = nil, runTimer: Bool = true) {
        useSystem = runTimer && !RuntimeMode.demo
        if let fileURL { load(fileURL) }
        if runTimer {
            Timer.publish(every: 5, on: .main, in: .common).autoconnect()
                .sink { [weak self] now in self?.refresh(now: now) }.store(in: &subscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(); self?.scheduleNotifications() }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
    }
    func configure(store: TodoStore) {
        guard self.store == nil else { return }
        self.store = store
        if fileURL == nil { load(store.fileURL.deletingLastPathComponent().appendingPathComponent("event-reminders.json")) }
        if useSystem {
            FocusClock.shared.$notificationsEnabled.removeDuplicates().sink { [weak self] enabled in
                self?.notificationsEnabled = enabled; self?.scheduleNotifications()
            }.store(in: &subscriptions)
        }
        store.$tasks.removeDuplicates().sink { [weak self] value in
            self?.tasks = value; self?.refresh(); self?.scheduleNotifications()
        }.store(in: &subscriptions)
        let queued = queuedResponses; queuedResponses = []
        for response in queued { handleResponse(id: response.0, revision: response.1, action: response.2) }
    }
    func refresh(now: Date = Date()) {
        items = EventEngine.items(tasks, now: now)
        let visible = Set(presented.map(\.id))
        let pending = writable ? items.filter { ledger.shouldPresent($0, now: now) } : []
        let ids = visible.union(pending.map(\.id))
        presented = items.filter { ids.contains($0.id) }
        if !pending.isEmpty {
            ledger.acknowledge(pending, now: now); persist()
            if useSystem { NSSound.beep() }
        }
        presentationChanged?(false)
        if useSystem && now.timeIntervalSince(lastSchedule) >= 3600 { scheduleNotifications(now: now) }
    }
    func show(id: UUID? = nil) {
        items = EventEngine.items(tasks, now: Date())
        presented = id.map { selected in items.filter { $0.id == selected } } ?? Array(items.prefix(20))
        ledger.acknowledge(presented, now: Date()); persist(); presentationChanged?(true)
    }
    func acknowledge(now: Date = Date()) {
        ledger.acknowledge(presented, now: now); presented = []; persist(); presentationChanged?(false)
        scheduleNotifications(now: now)
    }
    func snooze(now: Date = Date()) {
        ledger.snooze(presented, now: now); presented = []; persist(); presentationChanged?(false)
        scheduleNotifications(now: now)
    }
    func setPopups(_ enabled: Bool) {
        ledger.popupsEnabled = enabled; popupsEnabled = enabled
        if !enabled { presented = []; presentationChanged?(false) }
        persist(); refresh()
    }
    func complete(_ item: EventItem) {
        guard let current = store?.tasks.first(where: { $0.id == item.id }), !current.completed else { return }
        store?.toggle(item.id)
    }
    func open(_ item: EventItem) { openTask?(item.task) }
    func openLink(_ item: EventItem) {
        // Always use the current task, never a stale URL embedded in a notification.
        guard let current = tasks.first(where: { $0.id == item.id }), let url = EventEngine.item(current)?.link else { return }
        NSWorkspace.shared.open(url)
    }
    func scheduleLabel(_ item: EventItem, now: Date = Date()) -> String {
        if RuntimeMode.demo { return "演示模式 · 不发送系统通知" }
        if !notificationsEnabled { return "提前 15 分钟提醒 · 请开启系统通知" }
        let before = EventNotice(item: item, date: item.reminderDate, stage: .preparing)
        let start = EventNotice(item: item, date: item.start, stage: .starting)
        if item.reminderDate > now {
            let time = Day.formatted(Day.key(item.reminderDate), "M月d日") + " " + ClockText.minute(ClockText.minuteNow(item.reminderDate))
            return time + (scheduled.contains(before.identifier) ? " 提醒 · 已排定系统通知" : " 提醒 · 等待排定系统通知")
        }
        return scheduled.contains(start.identifier) ? "即将开始 · 开始时再提醒" : "提前 15 分钟进入紧急提醒"
    }
    func handleResponse(id: String, revision: String, action: String) {
        guard store != nil else { queuedResponses.append((id, revision, action)); return }
        guard let task = tasks.first(where: { $0.id.uuidString == id }),
              let item = EventEngine.item(task), item.revision == revision, item.expires > Date() else { return }
        if action == "daylist.event.join" { openLink(item) }
        else if action == "daylist.event.snooze" {
            guard item.stage(at: Date()) != nil else { return }
            ledger.snooze([item], now: Date()); presented.removeAll { $0.id == item.id }
            persist(); presentationChanged?(false); scheduleNotifications()
        } else { show(id: item.id) }
    }
    private func load(_ url: URL) {
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            ledger = try JSONDecoder().decode(EventLedger.self, from: Data(contentsOf: url))
            guard ledger.version == 1, ledger.receipts.count <= 10_000 else { throw StoreError.invalidDocument("活动提醒记录版本不正确") }
            popupsEnabled = ledger.popupsEnabled
        } catch {
            writable = false; message = "活动提醒记录读取失败，原文件已保留；活动和系统提醒仍可查看。请修复或移走 event-reminders.json 后重新打开。"
        }
    }
    private func persist() {
        guard writable, let fileURL else { return }
        ledger.prune(tasks: tasks)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
        } catch { message = "活动提醒状态未能保存：" + error.localizedDescription }
    }
    private func scheduleNotifications(now: Date = Date()) {
        guard useSystem else { return }
        lastSchedule = now; generation += 1; let token = generation
        var notices = EventEngine.notices(tasks, now: now).filter { ledger.needsReminder($0.item, stage: $0.stage, now: $0.date) }
        for item in EventEngine.items(tasks, now: now) {
            guard let until = ledger.receipts[item.revision]?.snoozedUntil, until > now,
                  let stage = item.stage(at: until) else { continue }
            notices.append(EventNotice(item: item, date: until, stage: stage))
        }
        var ids = Set<String>()
        let planned = Array(notices.sorted { $0.date < $1.date }.filter { ids.insert($0.identifier).inserted }.prefix(ReminderBudget.events))
        let enabled = notificationsEnabled
        let valid = Set(EventEngine.items(tasks, now: now).map(\.revision))
        let previous = notificationTask
        notificationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token else { return }
            let center = UNUserNotificationCenter.current()
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("daylist.event.") }
            guard self.generation == token else { return }
            center.removePendingNotificationRequests(withIdentifiers: old)
            self.scheduled = []
            let delivered = await center.deliveredNotifications()
            guard self.generation == token else { return }
            let stale = delivered.filter { $0.request.identifier.hasPrefix("daylist.event.") &&
                !valid.contains($0.request.content.userInfo["revision"] as? String ?? "") }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: stale)
            guard enabled else { return }
            for notice in planned {
                guard self.generation == token else { return }
                let content = UNMutableNotificationContent()
                content.title = (notice.stage == .preparing ? notice.item.countdown(at: notice.date) + " · " : "活动已开始 · ") + notice.item.task.title
                content.body = notice.item.exactLabel + (notice.item.link == nil ? "" : "\n已保存活动链接，点开提醒即可查看。")
                content.sound = .default; content.categoryIdentifier = notice.item.link == nil ? "daylist.event" : "daylist.event.link"
                content.userInfo = ["reminderType": "event", "taskID": notice.item.id.uuidString, "revision": notice.item.revision]
                let parts = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notice.date)
                let request = UNNotificationRequest(identifier: notice.identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                do { try await center.add(request) }
                catch { self.message = "系统活动提醒未能安排：" + error.localizedDescription }
            }
            let actual = await center.pendingNotificationRequests()
            guard self.generation == token else { return }
            let expected = Set(planned.map(\.identifier))
            self.scheduled = Set(actual.map(\.identifier)).intersection(expected)
            if self.scheduled.count < planned.count { self.message = "部分活动提醒尚未排入系统，请保持应用运行并检查通知设置。" }
        }
    }
}
