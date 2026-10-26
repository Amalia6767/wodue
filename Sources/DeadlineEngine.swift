import Foundation

enum DeadlineStage: String, Codable, CaseIterable {
    case soon, tomorrow, today, twoHours, halfHour, overdue
    var rank: Int { Self.allCases.count - Self.allCases.firstIndex(of: self)! }
    var label: String {
        switch self {
        case .soon: return "三天内截止"
        case .tomorrow: return "明天截止"
        case .today: return "今天截止"
        case .twoHours: return "两小时内截止"
        case .halfHour: return "半小时内截止"
        case .overdue: return "已逾期"
        }
    }
    var strong: Bool { ![.soon, .tomorrow].contains(self) }
}

struct DeadlineItem: Identifiable, Equatable {
    var task: Todo
    var stage: DeadlineStage
    var due: Date?
    var id: UUID { task.id }
    // A deadline change, including a removed clock time, creates a new reminder revision.
    var revision: String { task.id.uuidString + ":" + task.day + ":" + (task.startMinute.map(String.init) ?? "date") }
    var exactLabel: String { task.dateLabel + " · " + (task.startMinute.map(ClockText.minute) ?? "具体时刻待确认") }
    func countdown(at now: Date) -> String {
        guard let due else { return stage == .overdue ? "截止日期已过" : (stage == .today ? "今天截止 · 时刻待确认" : stage.label + " · 时刻待确认") }
        let seconds = due.timeIntervalSince(now)
        if seconds <= 0 && seconds > -60 { return "截止时间刚过" }
        let minutes = max(1, Int(ceil(abs(seconds) / 60)))
        let duration: String
        if minutes < 60 { duration = "\(minutes) 分钟" }
        else if minutes < 1440 { duration = "\(minutes / 60) 小时" + (minutes % 60 == 0 ? "" : " \(minutes % 60) 分钟") }
        else { duration = "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        return seconds <= 0 ? "已逾期 " + duration : "还剩 " + duration
    }
}

struct DeadlineNotice: Equatable {
    var item: DeadlineItem
    var date: Date
    var stage: DeadlineStage
    var identifier: String { "daylist.deadline." + item.revision + "." + stage.rawValue }
}

enum DeadlineEngine {
    // Only explicit deadline language is inferred. An explicit activity/rest choice overrides it.
    static func titleSignalsDeadline(_ title: String) -> Bool {
        title.range(of: #"(?i)^\s*(?:[【\[(（]\s*)?(?:ddl|deadline)\b"#, options: .regularExpression) != nil
    }
    static func item(_ task: Todo, now: Date) -> DeadlineItem? {
        guard !task.completed, task.resolvedKind == .deadline, let day = Day.date(task.day) else { return nil }
        let days = Day.calendar.dateComponents([.day], from: Day.calendar.startOfDay(for: now), to: Day.calendar.startOfDay(for: day)).day ?? 0
        let due = task.startMinute.flatMap { ClockText.date(task.day, $0) }
        let stage: DeadlineStage
        if let due {
            let remaining = due.timeIntervalSince(now)
            guard remaining <= 72 * 3600 else { return nil }
            if remaining <= 0 { stage = .overdue }
            else if remaining <= 30 * 60 { stage = .halfHour }
            else if remaining <= 2 * 3600 { stage = .twoHours }
            else if days == 0 { stage = .today }
            else if days == 1 { stage = .tomorrow }
            else { stage = .soon }
        } else {
            guard days <= 3 else { return nil }
            stage = days < 0 ? .overdue : (days == 0 ? .today : (days == 1 ? .tomorrow : .soon))
        }
        return DeadlineItem(task: task, stage: stage, due: due)
    }
    static func items(_ tasks: [Todo], now: Date) -> [DeadlineItem] {
        tasks.compactMap { item($0, now: now) }.sorted {
            if $0.stage.rank != $1.stage.rank { return $0.stage.rank < $1.stage.rank }
            return ($0.task.day, $0.task.startMinute ?? 1440, $0.task.title) < ($1.task.day, $1.task.startMinute ?? 1440, $1.task.title)
        }
    }
    static func notices(_ tasks: [Todo], now: Date) -> [DeadlineNotice] {
        var result: [DeadlineNotice] = []
        for task in tasks where !task.completed && task.resolvedKind == .deadline {
            var dates: [Date] = []
            if let due = task.startMinute.flatMap({ ClockText.date(task.day, $0) }) {
                dates = [due.addingTimeInterval(-72 * 3600), due.addingTimeInterval(-24 * 3600), due.addingTimeInterval(-2 * 3600), due.addingTimeInterval(-30 * 60), due]
                if let morning = ClockText.date(task.day, 540), morning < due { dates.append(morning) }
            } else {
                // These are reminder times, never fabricated submission times.
                dates = [-3, -1, 0].compactMap { ClockText.date(Day.adding($0, to: task.day), 540) }
                if let overdue = ClockText.date(Day.adding(1, to: task.day), 540) { dates.append(overdue) }
            }
            var seen = Set<DeadlineStage>()
            for date in dates.sorted() where date > now {
                guard let item = item(task, now: date), seen.insert(item.stage).inserted else { continue }
                result.append(DeadlineNotice(item: item, date: date, stage: item.stage))
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}

struct DeadlineReceipt: Codable, Equatable {
    var stage: DeadlineStage?
    var snoozedUntil: Date?
    var touchedAt: Date
}

struct DeadlineLedger: Codable {
    var version = 1
    var popupsEnabled = true
    var receipts: [String: DeadlineReceipt] = [:]
    func shouldPresent(_ item: DeadlineItem, now: Date) -> Bool {
        popupsEnabled && needsReminder(item, now: now)
    }
    func needsReminder(_ item: DeadlineItem, now: Date) -> Bool {
        guard let receipt = receipts[item.revision] else { return true }
        if let snooze = receipt.snoozedUntil { return now >= snooze }
        return receipt.stage != item.stage
    }
    mutating func acknowledge(_ items: [DeadlineItem], now: Date) {
        for item in items { receipts[item.revision] = .init(stage: item.stage, touchedAt: now) }
    }
    mutating func snooze(_ items: [DeadlineItem], minutes: Int = 30, now: Date) {
        for item in items {
            let later = now.addingTimeInterval(Double(minutes * 60))
            let until = item.due.map { $0 > now ? min(later, $0) : later } ?? later
            receipts[item.revision] = .init(stage: item.stage, snoozedUntil: until, touchedAt: now)
        }
    }
    mutating func prune(tasks: [Todo]) {
        let ids = Set(tasks.map { $0.id.uuidString })
        receipts = receipts.filter { ids.contains(String($0.key.prefix(36))) }
        if receipts.count > 3000 {
            receipts = Dictionary(uniqueKeysWithValues: receipts.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(3000).map { ($0.key, $0.value) })
        }
    }
}
