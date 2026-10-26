import Foundation
import Combine

struct CalendarReference: Codable, Equatable {
    var key: String
    var calendarID: String
    var calendarName: String
    var allDay: Bool
    var eventStart: Date
}

struct Todo: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var day: String
    var startMinute: Int? = nil
    var endMinute: Int? = nil
    var completed: Bool = false
    var createdAt: Date = Date()
    var notes: String? = nil
    var link: String? = nil
    var calendarSource: CalendarReference? = nil
    var canvasSource: CanvasReference? = nil
    var categoryID: String? = nil
    var kind: PlanKind? = nil
    var importance: Int? = nil
    var estimatedMinutes: Int? = nil
    var endDay: String? = nil

    var resolvedKind: PlanKind {
        kind ?? (canvasSource?.isDeadline == true || (lastDay == day && DeadlineEngine.titleSignalsDeadline(title))
            ? .deadline : (calendarSource != nil ? .event : .task))
    }
    var lastDay: String { endDay ?? day }
    func occurs(on key: String) -> Bool { day <= key && key <= lastDay }
    func start(on key: String) -> Int? { guard occurs(on: key) else { return nil }; return key == day ? startMinute : (startMinute == nil ? nil : 0) }
    func end(on key: String) -> Int? { guard occurs(on: key) else { return nil }; return key == lastDay ? endMinute : (startMinute == nil ? nil : 1440) }
    var dateLabel: String {
        let pattern = day.prefix(4) == Day.today.prefix(4) && lastDay.prefix(4) == Day.today.prefix(4) ? "M月d日" : "yyyy年M月d日"
        return day == lastDay ? Day.formatted(day, pattern) : Day.formatted(day, pattern) + " – " + Day.formatted(lastDay, pattern)
    }

    var timeLabel: String? {
        guard let startMinute else {
            if resolvedKind == .deadline { return "截止当天" }
            return calendarSource?.allDay == true ? "全天" : nil
        }
        let start = (resolvedKind == .deadline ? "截止 " : "") + String(format: "%02d:%02d", startMinute / 60, startMinute % 60)
        if resolvedKind == .deadline { return start }
        guard let endMinute else { return start }
        return start + " – " + (day == lastDay ? "" : Day.formatted(lastDay, "M月d日 ")) + String(format: "%02d:%02d", endMinute / 60, endMinute % 60)
    }
}

struct TodoDocument: Codable {
    var version: Int = 2
    var tasks: [Todo]
    var categories: [PlanCategory]? = nil
    var timeBlocks: [TimeBlock]? = nil
}

enum Day {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        return c
    }
    static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        let dc = DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)
        guard let d = calendar.date(from: dc), self.key(d) == key else { return nil }
        return d
    }
    static func adding(_ amount: Int, to key: String) -> String {
        guard let d = date(key), let next = calendar.date(byAdding: .day, value: amount, to: d) else { return key }
        return self.key(next)
    }
    static func formatted(_ key: String, _ pattern: String) -> String {
        guard let date = date(key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.calendar = calendar
        f.dateFormat = pattern
        return f.string(from: date)
    }
    static var today: String { key(Date()) }
}

enum StoreError: LocalizedError {
    case invalidDocument(String)
    var errorDescription: String? {
        switch self {
        case .invalidDocument(let message): return message
        }
    }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var tasks: [Todo] = []
    @Published private(set) var categories: [PlanCategory] = PlanCategory.defaults
    @Published private(set) var timeBlocks: [TimeBlock] = []
    @Published var errorMessage: String? = nil
    @Published var toast: String? = nil
    private(set) var canSave = true
    let fileURL: URL

    init(fileURL: URL? = nil, seedIfMissing: Bool = false) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let position = CommandLine.arguments.firstIndex(of: "--data-dir"), position + 1 < CommandLine.arguments.count {
            self.fileURL = URL(fileURLWithPath: CommandLine.arguments[position + 1], isDirectory: true).appendingPathComponent("tasks.json")
        } else if let directory = ProcessInfo.processInfo.environment["WODUE_DATA_DIR"], !directory.isEmpty {
            self.fileURL = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("tasks.json")
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            let identifier = Bundle.main.bundleIdentifier ?? "io.github.amalia6767.wodue"
            self.fileURL = support.appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("tasks.json")
        }
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL)
                tasks = try Self.decode(data)
                let doc = try JSONDecoder().decode(TodoDocument.self, from: data)
                categories = doc.categories ?? PlanCategory.defaults
                timeBlocks = doc.timeBlocks ?? []
            } else {
                tasks = seedIfMissing ? Self.seed() : []
                try persist(tasks)
            }
        } catch {
            canSave = false
            errorMessage = "读取清单失败，原文件已保留。请检查数据文件或文件夹权限。\n" + error.localizedDescription
        }
    }

    // Fictional, deterministic fixtures, used only when seedIfMissing is explicitly requested.
    // Normal first launch starts with an empty list.
    static func seed() -> [Todo] {
        let groups: [(String, [String])] = [
            ("2026-10-25", ["整理文献卡片", "准备演讲提纲", "练习题与测验"]),
            ("2026-10-26", ["晨间散步", "修改写作草稿", "图书馆还书"]),
            ("2026-10-27", ["完成交互原型", "准备演讲提纲", "周末创意市集"]),
            ("2026-10-28", ["整理学习笔记"])
        ]
        var result: [Todo] = []
        for (day, titles) in groups {
            for title in titles {
                result.append(Todo(title: title, day: day,
                    startMinute: title == "晨间散步" ? 600 : nil,
                    endMinute: title == "晨间散步" ? 660 : nil,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600 + Double(result.count))))
            }
        }
        return result
    }

    static func decode(_ data: Data) throws -> [Todo] {
        let doc = try JSONDecoder().decode(TodoDocument.self, from: data)
        guard (1...2).contains(doc.version) else { throw StoreError.invalidDocument("这个备份的版本暂不支持。") }
        var ids = Set<UUID>()
        for t in doc.tasks {
            guard ids.insert(t.id).inserted,
                  !t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  t.title.count <= 2000, Day.date(t.day) != nil,
                  (t.notes?.count ?? 0) <= 100_000,
                  t.importance.map({ (0...3).contains($0) }) ?? true,
                  t.estimatedMinutes.map({ (5...1440).contains($0) }) ?? true,
                  t.endDay.map({ Day.date($0) != nil && $0 >= t.day && $0 <= Day.adding(366, to: t.day) }) ?? true,
                  t.resolvedKind != .deadline || t.lastDay == t.day,
                  t.startMinute.map({ (0..<1440).contains($0) }) ?? true,
                  t.endMinute.map({ end in t.startMinute.map { (t.lastDay > t.day || end > $0) && (0..<1440).contains(end) } ?? false }) ?? true
            else { throw StoreError.invalidDocument("备份包含不正确的日期、时间或重复事项，请检查文件。") }
        }
        let categories = doc.categories ?? []
        guard Set(categories.map(\.id)).count == categories.count,
              categories.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && $0.color <= 0xFFFFFF })
        else { throw StoreError.invalidDocument("分类名称或颜色不正确。") }
        let blocks = doc.timeBlocks ?? []
        guard Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 2000 && Day.date($0.day) != nil && (0..<1440).contains($0.startMinute) && $0.endMinute > $0.startMinute && $0.endMinute <= 1440 && ($0.notes?.count ?? 0) <= 100_000 })
        else { throw StoreError.invalidDocument("时间块的日期或起止时间不正确。") }
        return doc.tasks
    }

    func tasks(on day: String) -> [Todo] {
        tasks.filter { $0.occurs(on: day) }.sorted {
            if ($0.start(on: day) ?? 1440) != ($1.start(on: day) ?? 1440) {
                return ($0.start(on: day) ?? 1440) < ($1.start(on: day) ?? 1440)
            }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var days: [String] {
        var all = Set(tasks.map(\.day) + timeBlocks.map(\.day))
        for task in tasks where task.lastDay > task.day {
            var day = task.day
            for _ in 0..<367 { all.insert(day); if day >= task.lastDay { break }; day = Day.adding(1, to: day) }
        }
        return all.sorted()
    }
    func category(_ id: String?) -> PlanCategory? { categories.first { $0.id == id } }
    func blocks(on day: String) -> [TimeBlock] { timeBlocks.filter { $0.day == day }.sorted { ($0.startMinute, $0.createdAt) < ($1.startMinute, $1.createdAt) } }
    @discardableResult func saveCategory(_ category: PlanCategory) -> Bool {
        var clean = category; clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if categories.contains(where: { $0.id != clean.id && $0.name.lowercased() == clean.name.lowercased() }) {
            errorMessage = "已有同名分类，可以直接使用或修改原分类。"; return false
        }
        var next = categories
        if let i = next.firstIndex(where: { $0.id == clean.id }) { next[i] = clean } else { next.append(clean) }
        return commit(tasks, categories: next)
    }
    @discardableResult func removeCategory(_ id: String) -> Bool {
        var next = tasks; var blocks = timeBlocks
        for i in next.indices where next[i].categoryID == id { next[i].categoryID = nil }
        for i in blocks.indices where blocks[i].categoryID == id { blocks[i].categoryID = nil }
        return commit(next, categories: categories.filter { $0.id != id }, blocks: blocks)
    }
    @discardableResult func upsertBlock(_ block: TimeBlock) -> Bool {
        var clean = block; clean.title = clean.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = timeBlocks
        if let i = next.firstIndex(where: { $0.id == clean.id }) { next[i] = clean } else { next.append(clean) }
        return commit(tasks, blocks: next)
    }
    func toggleBlock(_ id: UUID) { guard var block = timeBlocks.first(where: { $0.id == id }) else { return }; block.completed.toggle(); _ = upsertBlock(block) }
    func removeBlock(_ id: UUID) { _ = commit(tasks, blocks: timeBlocks.filter { $0.id != id }) }

    func duplicate(of task: Todo) -> Todo? {
        let normalized = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks.first {
            $0.day == task.day && $0.startMinute == task.startMinute &&
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    func canvasMatch(_ source: CanvasReference) -> Todo? {
        tasks.first { task in
            guard task.calendarSource == nil else { return false }
            if let old = task.canvasSource { return !Set(old.identities).isDisjoint(with: source.identities) }
            return task.link.flatMap(CanvasParser.assignmentIdentity) == source.assignmentIdentity
                && source.assignmentIdentity != nil
        }
    }

    func canvasDisposition(_ candidate: CanvasCandidate) -> CanvasDisposition {
        guard candidate.day != nil else { return .needsDate }
        guard let old = canvasMatch(candidate.source), let previous = old.canvasSource else { return .add }
        switch (candidate.source.notifiedAt, previous.notifiedAt) {
        case let (newDate?, oldDate?) where newDate < oldDate: return .older
        case (nil, .some): return .unknownOrder
        case let (newDate?, oldDate?) where newDate == oldDate:
            if oldTaskMatches(old, candidate) { return .unchanged }
            return .conflict
        default:
            return oldTaskMatches(old, candidate) ? .unchanged : .update
        }
    }

    private func oldTaskMatches(_ old: Todo, _ candidate: CanvasCandidate) -> Bool {
        old.day == candidate.day && old.startMinute == candidate.minute
    }

    @discardableResult
    func importCanvas(_ candidates: [CanvasCandidate]) -> Bool {
        var next = tasks
        for candidate in CanvasParser.collapse(candidates) {
            guard let task = candidate.task else { continue }
            let disposition = canvasDisposition(candidate)
            guard disposition == .add || disposition == .update || disposition == .unchanged else { continue }
            var updated = task
            updated.categoryID = category("assignment")?.id
            updated.kind = candidate.source.isDeadline ? .deadline : .event
            if let old = canvasMatch(candidate.source), let i = next.firstIndex(where: { $0.id == old.id }) {
                updated.id = old.id; updated.completed = old.completed; updated.createdAt = old.createdAt
                updated.categoryID = old.categoryID; updated.importance = old.importance; updated.estimatedMinutes = old.estimatedMinutes; updated.kind = old.kind
                updated.canvasSource?.identities = Array(Set((old.canvasSource?.identities ?? []) + candidate.source.identities)).sorted()
                let oldTime = old.startMinute.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "未指定时间"
                let history = "此前截止：\(old.day) \(oldTime)"
                if updated.canvasSource == old.canvasSource && updated.day == old.day && updated.startMinute == old.startMinute { continue }
                var revisedNotes = updated.notes ?? ""
                revisedNotes.append("\n\n")
                revisedNotes.append(history)
                revisedNotes.append("\n")
                revisedNotes.append(old.notes ?? "")
                updated.notes = String(revisedNotes.prefix(100_000))
                next[i] = updated
            } else { next.append(updated) }
        }
        return next == tasks || commit(next)
    }

    @discardableResult
    func reconcileCalendar(_ incoming: [Todo], selectedIDs: Set<String>, from startDay: String, to endDay: String) -> Bool {
        let valid = incoming.filter { $0.calendarSource.map { selectedIDs.contains($0.calendarID) } ?? false }
        let byKey = Dictionary(valid.compactMap { task in task.calendarSource.map { ($0.key, task) } }, uniquingKeysWith: { first, _ in first })
        var next: [Todo] = []
        var handled = Set<String>()
        for old in tasks {
            guard let source = old.calendarSource else { next.append(old); continue }
            guard selectedIDs.contains(source.calendarID) else { continue }
            if var updated = byKey[source.key] {
                guard handled.insert(source.key).inserted else { continue }
                updated.id = old.id
                updated.completed = old.completed
                updated.createdAt = old.createdAt
                updated.categoryID = old.categoryID; updated.importance = old.importance; updated.estimatedMinutes = old.estimatedMinutes; updated.kind = old.kind
                next.append(updated)
            } else if old.day < startDay || old.day >= endDay {
                next.append(old)
            }
        }
        for task in valid {
            guard let source = task.calendarSource, handled.insert(source.key).inserted else { continue }
            next.append(task)
        }
        return next == tasks || commit(next)
    }

    @discardableResult
    func upsert(_ task: Todo) -> Bool {
        var clean = task
        clean.title = clean.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = tasks
        if let i = next.firstIndex(where: { $0.id == clean.id }) { next[i] = clean }
        else { next.append(clean) }
        return commit(next)
    }
    func toggle(_ id: UUID) {
        var next = tasks
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        next[i].completed.toggle()
        _ = commit(next)
    }
    func remove(_ id: UUID) {
        _ = commit(tasks.filter { $0.id != id })
    }
    func restore(_ task: Todo) { _ = upsert(task) }

    func importData(_ data: Data) throws {
        let incoming = try Self.decode(data)
        let doc = try JSONDecoder().decode(TodoDocument.self, from: data)
        var next = tasks
        for t in incoming {
            if let i = next.firstIndex(where: { $0.id == t.id }) { next[i] = t }
            else { next.append(t) }
        }
        var nextCategories = categories
        for category in doc.categories ?? [] {
            if let i = nextCategories.firstIndex(where: { $0.id == category.id }) { nextCategories[i] = category } else { nextCategories.append(category) }
        }
        var nextBlocks = timeBlocks
        for block in doc.timeBlocks ?? [] {
            if let i = nextBlocks.firstIndex(where: { $0.id == block.id }) { nextBlocks[i] = block } else { nextBlocks.append(block) }
        }
        guard commit(next, categories: nextCategories, blocks: nextBlocks) else { throw StoreError.invalidDocument(errorMessage ?? "保存失败") }
        toast = "已导入 \(incoming.count) 件事项"
    }
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(TodoDocument(tasks: tasks, categories: categories, timeBlocks: timeBlocks))
    }
    @discardableResult
    private func commit(_ next: [Todo], categories newCategories: [PlanCategory]? = nil, blocks newBlocks: [TimeBlock]? = nil) -> Bool {
        guard canSave else {
            errorMessage = "数据文件暂时无法读取。为保护原文件，请先修复文件，再重新打开应用。"
            return false
        }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(TodoDocument(tasks: next, categories: newCategories ?? categories, timeBlocks: newBlocks ?? timeBlocks))
            _ = try Self.decode(data)
            try persist(next, categories: newCategories, blocks: newBlocks)
            tasks = next
            if let newCategories { categories = newCategories }
            if let newBlocks { timeBlocks = newBlocks }
            return true
        } catch {
            errorMessage = "保存失败，刚才的修改没有写入。\n" + error.localizedDescription
            return false
        }
    }
    private func persist(_ tasks: [Todo], categories newCategories: [PlanCategory]? = nil, blocks newBlocks: [TimeBlock]? = nil) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(TodoDocument(tasks: tasks, categories: newCategories ?? categories, timeBlocks: newBlocks ?? timeBlocks)).write(to: fileURL, options: .atomic)
    }
}
