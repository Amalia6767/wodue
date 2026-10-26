import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The app's deadline card covers foreground alerts; other timers keep their banners.
        let deadline = notification.request.identifier.hasPrefix("daylist.deadline.")
        if deadline {
            Task { @MainActor in
                DeadlineReminder.shared.refresh()
                completionHandler(NSApp.isActive && DeadlineReminder.shared.popupsEnabled ? [] : [.banner, .list, .sound])
            }
        } else { completionHandler([.banner, .list, .sound]) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = info["taskID"] as? String, let revision = info["revision"] as? String {
            let action = response.actionIdentifier
            Task { @MainActor in DeadlineReminder.shared.handleResponse(id: id, revision: revision, action: action) }
        }
        completionHandler()
    }
}

@MainActor
final class DeadlineReminder: ObservableObject {
    static let shared = DeadlineReminder()
    @Published private(set) var items: [DeadlineItem] = []
    @Published private(set) var presented: [DeadlineItem] = []
    @Published private(set) var popupsEnabled = true
    @Published private(set) var message = ""
    var presentationChanged: ((Bool) -> Void)?
    var openTask: ((Todo) -> Void)?
    private weak var store: TodoStore?
    private var tasks: [Todo] = []
    private var ledger = DeadlineLedger()
    private var fileURL: URL?
    private var writable = true
    private var subscriptions = Set<AnyCancellable>()
    private var timer: AnyCancellable?
    private let useSystem: Bool
    private var notificationsEnabled = false
    private var notificationGeneration = 0
    private var notificationTask: Task<Void, Never>?
    private var lastSchedule: Date = .distantPast
    private var queuedResponses: [(String, String, String)] = []

    init(fileURL: URL? = nil, runTimer: Bool = true) {
        useSystem = runTimer && !RuntimeMode.demo
        if let fileURL { load(fileURL) }
        if runTimer {
            timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] now in self?.refresh(now: now) }
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(); self?.scheduleNotifications() }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
    }
    func configure(store: TodoStore) {
        guard self.store == nil else { return }
        self.store = store
        if fileURL == nil { load(store.fileURL.deletingLastPathComponent().appendingPathComponent("deadline-reminders.json")) }
        if useSystem {
            let center = UNUserNotificationCenter.current()
            center.delegate = ReminderNotificationDelegate.shared
            let actions = [UNNotificationAction(identifier: "daylist.snooze", title: "30 分钟后提醒"),
                           UNNotificationAction(identifier: "daylist.complete", title: "标为已完成")]
            center.setNotificationCategories([UNNotificationCategory(identifier: "daylist.deadline", actions: actions, intentIdentifiers: [])])
            FocusClock.shared.$notificationsEnabled.removeDuplicates().sink { [weak self] enabled in
                self?.notificationsEnabled = enabled; self?.scheduleNotifications()
            }.store(in: &subscriptions)
        }
        store.$tasks.removeDuplicates().sink { [weak self] tasks in
            self?.tasks = tasks; self?.refresh(); self?.scheduleNotifications()
        }.store(in: &subscriptions)
        let queued = queuedResponses; queuedResponses = []
        for response in queued { handleResponse(id: response.0, revision: response.1, action: response.2) }
    }
    func refresh(now: Date = Date()) {
        items = DeadlineEngine.items(tasks, now: now)
        let visible = Set(presented.map(\.id))
        let pending = writable ? items.filter { ledger.shouldPresent($0, now: now) } : []
        let ids = visible.union(pending.map(\.id))
        presented = items.filter { ids.contains($0.id) }
        if !pending.isEmpty {
            ledger.acknowledge(pending, now: now); persist()
            if useSystem && pending.contains(where: { $0.stage.strong }) { NSSound.beep() }
        }
        presentationChanged?(false)
        if useSystem && now.timeIntervalSince(lastSchedule) >= 3600 { scheduleNotifications(now: now) }
    }
    func show() {
        items = DeadlineEngine.items(tasks, now: Date())
        presented = items
        ledger.acknowledge(presented, now: Date()); persist(); presentationChanged?(true)
    }
    func acknowledge(now: Date = Date()) {
        ledger.acknowledge(presented, now: now); presented = []; persist(); presentationChanged?(false); scheduleNotifications(now: now)
    }
    func snooze(now: Date = Date()) {
        ledger.snooze(presented, now: now); presented = []; persist(); presentationChanged?(false); scheduleNotifications(now: now)
    }
    func setPopups(_ enabled: Bool) {
        ledger.popupsEnabled = enabled; popupsEnabled = enabled
        if !enabled { presented = []; presentationChanged?(false) }
        persist(); refresh()
    }
    func complete(_ item: DeadlineItem) {
        guard let current = store?.tasks.first(where: { $0.id == item.id }), !current.completed else { return }
        store?.toggle(current.id)
    }
    func open(_ item: DeadlineItem) { openTask?(item.task) }
    func handleResponse(id: String, revision: String, action: String) {
        guard store != nil else { queuedResponses.append((id, revision, action)); return }
        guard let task = tasks.first(where: { $0.id.uuidString == id }) else { return }
        if action == UNNotificationDefaultActionIdentifier { openTask?(task); return }
        guard let item = DeadlineEngine.item(task, now: Date()), item.revision == revision else { return }
        if action == "daylist.complete" { complete(item) }
        else if action == "daylist.snooze" {
            ledger.snooze([item], now: Date()); presented.removeAll { $0.id == item.id }; persist(); presentationChanged?(false); scheduleNotifications()
        }
    }
    private func load(_ url: URL) {
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            ledger = try JSONDecoder().decode(DeadlineLedger.self, from: Data(contentsOf: url))
            guard ledger.version == 1, ledger.receipts.count <= 10_000 else { throw StoreError.invalidDocument("提醒记录版本不正确") }
            popupsEnabled = ledger.popupsEnabled
        } catch {
            writable = false; message = "提醒记录读取失败，已保留原文件。截止提示仍可查看；修复或移走 deadline-reminders.json 后再打开应用可恢复自动弹窗。"
        }
    }
    private func persist() {
        guard writable, let fileURL else { return }
        ledger.prune(tasks: tasks)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: fileURL, options: .atomic)
        } catch { message = "截止提醒状态未能保存：" + error.localizedDescription }
    }
    private func scheduleNotifications(now: Date = Date()) {
        guard useSystem else { return }
        lastSchedule = now
        notificationGeneration += 1; let generation = notificationGeneration
        var notices = DeadlineEngine.notices(tasks, now: now).filter { ledger.needsReminder($0.item, now: $0.date) }
        for task in tasks {
            guard let current = DeadlineEngine.item(task, now: now),
                  let until = ledger.receipts[current.revision]?.snoozedUntil, until > now,
                  let future = DeadlineEngine.item(task, now: until) else { continue }
            notices.append(.init(item: future, date: until, stage: future.stage))
        }
        var keys = Set<String>()
        notices = notices.sorted { $0.date < $1.date }.filter { keys.insert($0.identifier).inserted }
        let planned = Array(notices.prefix(32))
        let enabled = notificationsEnabled
        let validRevisions = Set(tasks.filter { !$0.completed && $0.resolvedKind == .deadline }.map {
            DeadlineItem(task: $0, stage: .soon, due: nil).revision
        })
        // Serialize replacements: an older asynchronous add cannot restore a cancelled deadline.
        let previous = notificationTask
        notificationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.notificationGeneration == generation else { return }
            let center = UNUserNotificationCenter.current()
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("daylist.deadline.") }
            guard self.notificationGeneration == generation else { return }
            center.removePendingNotificationRequests(withIdentifiers: old)
            let delivered = await center.deliveredNotifications()
            guard self.notificationGeneration == generation else { return }
            let stale = delivered.filter {
                $0.request.identifier.hasPrefix("daylist.deadline.") &&
                !validRevisions.contains($0.request.content.userInfo["revision"] as? String ?? "")
            }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: stale)
            guard enabled else { return }
            for notice in planned {
                guard self.notificationGeneration == generation else { return }
                let content = UNMutableNotificationContent()
                content.title = notice.stage.label + " · " + notice.item.task.title
                content.body = notice.item.exactLabel + "\n" + notice.item.countdown(at: notice.date)
                content.sound = .default; content.categoryIdentifier = "daylist.deadline"
                content.userInfo = ["taskID": notice.item.id.uuidString, "revision": notice.item.revision]
                let parts = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notice.date)
                let request = UNNotificationRequest(identifier: notice.identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                do { try await center.add(request) }
                catch { self.message = "系统截止提醒未能安排：" + error.localizedDescription }
            }
        }
    }
}
