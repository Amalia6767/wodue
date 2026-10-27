import Foundation

enum ReminderBudget {
    // Each owner removes only its own requests; leave room for all four owners.
    static let deadlines = 24
    static let events = 16
    static let blocks = 10
}

enum EventStage: String, Codable {
    case preparing, starting
    var label: String { self == .preparing ? "15 分钟内开始" : "活动已开始" }
}

struct EventItem: Identifiable, Equatable {
    var task: Todo
    var start: Date
    var expires: Date
    var id: UUID { task.id }
    var revision: String { id.uuidString + ":" + String(Int(start.timeIntervalSince1970)) }
    var reminderDate: Date { start.addingTimeInterval(-15 * 60) }
    var link: URL? { WebLink.safe(task.link) ?? WebLink.first(in: task.notes ?? "") }
    var exactLabel: String { task.dateLabel + " · " + (task.timeLabel ?? "") }
    func stage(at now: Date) -> EventStage? {
        guard now >= reminderDate, now < expires else { return nil }
        return now < start ? .preparing : .starting
    }
    func countdown(at now: Date) -> String {
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        return minutes > 0 ? "还有 \(minutes) 分钟开始" : "已经开始，留意参加"
    }
}

struct EventNotice: Equatable {
    var item: EventItem
    var date: Date
    var stage: EventStage
    var identifier: String { "daylist.event." + item.revision + "." + stage.rawValue }
}

enum EventEngine {
    static func item(_ task: Todo) -> EventItem? {
        guard !task.completed, task.resolvedKind != .deadline, task.resolvedKind != .rest,
              task.calendarSource?.allDay != true, let minute = task.startMinute,
              let start = ClockText.date(task.day, minute) else { return nil }
        // Calendar mirrors split an overnight event into days. Remind only at its real start.
        if let source = task.calendarSource, Day.key(source.eventStart) != task.day { return nil }
        let end = task.endMinute.flatMap { ClockText.date(task.lastDay, $0) }
        let expires = min(start.addingTimeInterval(15 * 60), end ?? .distantFuture)
        return EventItem(task: task, start: start, expires: expires)
    }
    static func items(_ tasks: [Todo], now: Date) -> [EventItem] {
        tasks.compactMap(item).filter { $0.expires > now }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func notices(_ tasks: [Todo], now: Date) -> [EventNotice] {
        items(tasks, now: now).flatMap { item in
            [EventNotice(item: item, date: item.reminderDate, stage: .preparing),
             EventNotice(item: item, date: item.start, stage: .starting)].filter { $0.date > now }
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.identifier < $1.identifier
        }
    }
}

struct EventReceipt: Codable, Equatable {
    var stage: EventStage
    var snoozedUntil: Date?
    var touchedAt: Date
}

struct EventLedger: Codable {
    var version = 1
    var popupsEnabled = true
    var receipts: [String: EventReceipt] = [:]
    func needsReminder(_ item: EventItem, stage: EventStage, now: Date) -> Bool {
        guard let receipt = receipts[item.revision] else { return true }
        if let until = receipt.snoozedUntil, now < until { return false }
        return receipt.snoozedUntil != nil || receipt.stage != stage
    }
    func shouldPresent(_ item: EventItem, now: Date) -> Bool {
        guard popupsEnabled, let stage = item.stage(at: now) else { return false }
        return needsReminder(item, stage: stage, now: now)
    }
    mutating func acknowledge(_ items: [EventItem], now: Date) {
        for item in items {
            guard let stage = item.stage(at: now) else { continue }
            receipts[item.revision] = .init(stage: stage, touchedAt: now)
        }
    }
    mutating func snooze(_ items: [EventItem], now: Date) {
        for item in items {
            guard let stage = item.stage(at: now) else { continue }
            let later = now.addingTimeInterval(5 * 60)
            let until = item.start > now ? min(later, item.start) : min(later, item.expires)
            receipts[item.revision] = .init(stage: stage, snoozedUntil: until, touchedAt: now)
        }
    }
    mutating func prune(tasks: [Todo]) {
        let revisions = Set(tasks.compactMap(EventEngine.item).map(\.revision))
        receipts = receipts.filter { revisions.contains($0.key) }
        if receipts.count > 3000 {
            receipts = Dictionary(uniqueKeysWithValues: receipts.sorted { $0.value.touchedAt > $1.value.touchedAt }
                .prefix(3000).map { ($0.key, $0.value) })
        }
    }
}
