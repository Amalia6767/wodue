import Foundation

enum PlanKind: String, Codable, CaseIterable {
    case task = "待办", deadline = "提交 / 截止", event = "活动 / 行程", rest = "休息 / 放松"
}

struct PlanCategory: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var color: UInt32
    static let defaults: [PlanCategory] = [
        .init(id: "assignment", name: "作业", color: 0xB35E70),
        .init(id: "presentation", name: "Presentation", color: 0xB18A52),
        .init(id: "workshop", name: "Workshop", color: 0x5D8A94),
        .init(id: "exhibition", name: "展会", color: 0x8F79A8),
        .init(id: "travel", name: "旅行", color: 0x5B947E),
        .init(id: "home", name: "家庭事务", color: 0xAF8E6D),
        .init(id: "rest", name: "休息放松", color: 0x7E8C6D),
        .init(id: "fun", name: "娱乐", color: 0xBC8293)
    ]
}

struct TimeBlock: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var day: String
    var startMinute: Int
    var endMinute: Int
    var categoryID: String? = nil
    var taskID: UUID? = nil
    var completed = false
    var notes: String? = nil
    var rest: Bool? = nil
    var createdAt = Date()
    var duration: Int { endMinute - startMinute }
    var isRest: Bool { rest ?? (categoryID == "rest") }
    var timeLabel: String { ClockText.minute(startMinute) + " – " + ClockText.minute(endMinute) }
}

enum ClockText {
    static func minute(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时" + (minutes % 60 == 0 ? "" : " \(minutes % 60) 分钟")
    }
    static func minuteNow(_ now: Date = Date()) -> Int {
        Day.calendar.component(.hour, from: now) * 60 + Day.calendar.component(.minute, from: now)
    }
    static func date(_ day: String, _ minute: Int) -> Date? {
        Day.date(day).flatMap { Day.calendar.date(byAdding: .minute, value: minute, to: Day.calendar.startOfDay(for: $0)) }
    }
}

struct BusyInterval: Equatable {
    var start: Int
    var end: Int
    var title: String
}

enum PlanningEngine {
    static func busy(on day: String, tasks: [Todo], blocks: [TimeBlock], excluding blockID: UUID? = nil) -> [BusyInterval] {
        let planned = blocks.filter { $0.day == day && $0.id != blockID }.map { BusyInterval(start: $0.startMinute, end: $0.endMinute, title: $0.title) }
        let fixed = tasks.filter { $0.occurs(on: day) && $0.resolvedKind != .deadline }.compactMap { task -> BusyInterval? in
            guard let start = task.start(on: day), let end = task.end(on: day), end > start else { return nil }
            return BusyInterval(start: start, end: end, title: task.title)
        }
        return (planned + fixed).sorted { $0.start < $1.start }
    }
    static func conflicts(_ block: TimeBlock, tasks: [Todo], blocks: [TimeBlock]) -> [BusyInterval] {
        busy(on: block.day, tasks: tasks, blocks: blocks, excluding: block.id)
            .filter { $0.start < block.endMinute && $0.end > block.startMinute }
    }
    static func freeSlot(duration: Int, after start: Int, until end: Int = 1260, busy: [BusyInterval]) -> Range<Int>? {
        guard duration > 0 else { return nil }
        var cursor = ((max(0, start) + 14) / 15) * 15
        for interval in busy.sorted(by: { $0.start < $1.start }) {
            if interval.end <= cursor { continue }
            if cursor + duration <= min(interval.start, end) { return cursor..<(cursor + duration) }
            cursor = ((max(cursor, interval.end) + 14) / 15) * 15
        }
        return cursor + duration <= min(end, 1440) ? cursor..<(cursor + duration) : nil
    }
    static func urgency(_ task: Todo, now: Date = Date()) -> (rank: Int, label: String) {
        guard !task.completed else { return (100, "已完成") }
        let days = Day.calendar.dateComponents([.day], from: Day.calendar.startOfDay(for: now), to: Day.calendar.startOfDay(for: Day.date(task.day)!)).day ?? 0
        if task.resolvedKind == .deadline {
            if days < 0 { return (0, "已逾期 \(-days) 天") }
            if days == 0 {
                if let minute = task.startMinute, minute < ClockText.minuteNow(now) { return (0, "截止时间已过") }
                return (1, "今天截止")
            }
            if days == 1 { return (2, "明天截止") }
            if days <= 7 { return (3, "\(days) 天后截止") }
            return ((task.importance ?? 1) == 3 ? 4 : 6, "\(days) 天后截止")
        }
        if task.resolvedKind == .event && ((task.importance ?? 1) >= 2 || task.categoryID == "presentation" || task.estimatedMinutes != nil), days >= 0 {
            return (days == 0 ? 1 : (days == 1 ? 2 : (days <= 7 ? 3 : 6)), days == 0 ? "今天进行，留意准备" : (days == 1 ? "明天进行，留意准备" : "\(days) 天后进行"))
        }
        return ((task.importance ?? 1) == 3 ? 4 : 8, (task.importance ?? 1) == 3 ? "优先处理" : "按计划进行")
    }
    static func priorities(_ tasks: [Todo], now: Date = Date()) -> [Todo] {
        tasks.filter { !$0.completed && $0.resolvedKind != .rest && ($0.resolvedKind != .event || $0.day >= Day.key(now)) }.sorted {
            let a = urgency($0, now: now); let b = urgency($1, now: now)
            if a.rank != b.rank { return a.rank < b.rank }
            if ($0.importance ?? 1) != ($1.importance ?? 1) { return ($0.importance ?? 1) > ($1.importance ?? 1) }
            return ($0.day, $0.startMinute ?? 1440, $0.title) < ($1.day, $1.startMinute ?? 1440, $1.title)
        }
    }
}
