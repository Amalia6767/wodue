import Foundation
import EventKit
import AppKit
import Combine

struct CalendarOption: Identifiable, Sendable {
    var id: String
    var title: String
    var account: String
    var color: UInt32
    var suggested: Bool
}

struct CalendarOccurrence {
    var identity: String
    var calendarID: String
    var calendarName: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var notes: String?
    var link: String?

    func tasks(from rangeStart: Date, to rangeEnd: Date) -> [Todo] {
        let cal = Day.calendar
        let originalDay = cal.startOfDay(for: start)
        var cursor = max(originalDay, cal.startOfDay(for: rangeStart))
        let last = min(end, rangeEnd)
        var result: [Todo] = []
        while cursor < last && result.count < 400 {
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            let ordinal = cal.dateComponents([.day], from: originalDay, to: cursor).day ?? 0
            let reference = CalendarReference(key: identity + "|day:\(ordinal)", calendarID: calendarID,
                calendarName: calendarName, allDay: allDay, eventStart: start)
            let segmentStart = max(start, cursor)
            let minute = cal.component(.hour, from: segmentStart) * 60 + cal.component(.minute, from: segmentStart)
            var endMinute: Int? = nil
            if !allDay && end < next {
                let e = cal.component(.hour, from: end) * 60 + cal.component(.minute, from: end)
                if e > minute { endMinute = e }
            }
            var details = notes ?? ""
            if !allDay && (start < cursor || end >= next) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 HH:mm"
                details = "跨天日程：\(formatter.string(from: start)) — \(formatter.string(from: end))\n" + details
            }
            result.append(Todo(title: title.isEmpty ? "未命名日程" : String(title.prefix(2000)),
                day: Day.key(cursor), startMinute: allDay ? nil : minute, endMinute: endMinute,
                notes: details.isEmpty ? nil : String(details.prefix(100_000)), link: WebLink.safe(link)?.absoluteString,
                calendarSource: reference))
            cursor = next
        }
        return result
    }
}

private struct CalendarFetch {
    var calendars: [CalendarOption]
    var selected: Set<String>
    var tasks: [Todo]
    var startDay: String
    var endDay: String
}

private final class CalendarReader: @unchecked Sendable {
    private let eventStore = EKEventStore()
    private let queue = DispatchQueue(label: "io.github.wodue.calendar", qos: .userInitiated)

    func requestAccess() async throws -> Bool { try await eventStore.requestFullAccessToEvents() }

    func fetch(selectedIDs: Set<String>?, includeEvents: Bool) async -> CalendarFetch {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let calendars = eventStore.calendars(for: .event)
                let options = calendars.map { calendar in
                    let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB)
                    let hex: UInt32 = color.map {
                        (UInt32($0.redComponent * 255) << 16) | (UInt32($0.greenComponent * 255) << 8) | UInt32($0.blueComponent * 255)
                    } ?? 0x839DA4
                    return CalendarOption(id: calendar.calendarIdentifier, title: calendar.title,
                        account: calendar.source.title, color: hex,
                        suggested: calendar.allowsContentModifications && calendar.type != .birthday)
                }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
                let selected = selectedIDs ?? Set(options.filter(\.suggested).map(\.id))
                let startDay = Day.adding(-30, to: Day.today)
                let endDay = Day.adding(181, to: Day.today)
                let start = Day.calendar.startOfDay(for: Day.date(startDay)!)
                let end = Day.calendar.startOfDay(for: Day.date(endDay)!)
                let chosen = calendars.filter { selected.contains($0.calendarIdentifier) }
                var snapshots: [Todo] = []
                if includeEvents && !chosen.isEmpty {
                    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: chosen)
                    let events = eventStore.events(matching: predicate)
                    var seen = Set<String>()
                    for event in events where event.status != .canceled {
                        guard let calendar = event.calendar, let eventStart = event.startDate, let eventEnd = event.endDate else { continue }
                        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? event.calendarItemIdentifier
                        var identity = calendar.calendarIdentifier + "|" + base
                        if event.hasRecurrenceRules || event.isDetached {
                            identity += "|occ:\(Int((event.occurrenceDate ?? eventStart).timeIntervalSince1970))"
                        }
                        guard seen.insert(identity).inserted else { continue }
                        let occurrence = CalendarOccurrence(identity: identity, calendarID: calendar.calendarIdentifier,
                            calendarName: calendar.title, title: event.title ?? "未命名日程", start: eventStart, end: eventEnd,
                            allDay: event.isAllDay, notes: event.notes, link: event.url?.absoluteString ?? WebLink.first(in: event.notes ?? "")?.absoluteString)
                        snapshots.append(contentsOf: occurrence.tasks(from: start, to: end))
                    }
                }
                continuation.resume(returning: CalendarFetch(calendars: options, selected: selected, tasks: snapshots, startDay: startDay, endDay: endDay))
            }
        }
    }
}

@MainActor
final class CalendarSyncManager: ObservableObject {
    static let shared = CalendarSyncManager()
    @Published private(set) var calendars: [CalendarOption] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var enabled = false
    @Published private(set) var hasAccess = false
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未连接 Mac 日历"
    @Published private(set) var lastSync: Date? = nil
    private let reader = CalendarReader()
    private var store: TodoStore?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshJob: DispatchWorkItem?
    private var generation = 0
    private var configured = false

    func configure(store: TodoStore) {
        self.store = store
        guard !configured else { return }
        configured = true
        guard !RuntimeMode.demo else { status = "演示模式：只显示虚构数据，不连接真实日历"; return }
        enabled = UserDefaults.standard.bool(forKey: "CalendarSyncEnabled")
        selectedIDs = Set(UserDefaults.standard.stringArray(forKey: "CalendarSyncSelection") ?? [])
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        if hasAccess { refresh() }
        else if enabled { status = "需要在系统设置中允许日历访问" }
    }

    func connect() {
        guard !RuntimeMode.demo else { status = "演示模式不连接真实日历"; return }
        guard !busy else { return }
        busy = true
        Task {
            do {
                hasAccess = try await reader.requestAccess()
                if hasAccess {
                    enabled = true
                    UserDefaults.standard.set(true, forKey: "CalendarSyncEnabled")
                    busy = false
                    refresh()
                } else {
                    status = "尚未获得授权。请在系统设置 → 隐私与安全性 → 日历中允许我Due！。"
                    busy = false
                }
            } catch {
                status = "连接失败：" + error.localizedDescription
                busy = false
            }
        }
    }

    func setEnabled(_ value: Bool) {
        guard !RuntimeMode.demo else { return }
        enabled = value
        generation += 1
        busy = false
        UserDefaults.standard.set(value, forKey: "CalendarSyncEnabled")
        if value && !hasAccess { connect() }
        else if value { refresh() }
        else { status = "自动同步已暂停，已有日程仍保留" }
    }
    func select(_ id: String, selected: Bool) {
        guard !RuntimeMode.demo else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        UserDefaults.standard.set(Array(selectedIDs), forKey: "CalendarSyncSelection")
        generation += 1
        busy = false
        scheduleRefresh()
    }
    func scheduleRefresh() {
        guard enabled else { return }
        refreshJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: job)
    }
    func refresh() {
        guard !RuntimeMode.demo else { return }
        guard !busy else { return }
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else {
            if enabled { status = "日历访问尚未允许，请到系统设置中开启" }
            return
        }
        busy = true
        let token = generation
        let requested = UserDefaults.standard.array(forKey: "CalendarSyncSelection") == nil ? nil : selectedIDs
        let readEvents = enabled
        Task {
            let snapshot = await reader.fetch(selectedIDs: requested, includeEvents: readEvents)
            guard token == generation else { busy = false; scheduleRefresh(); return }
            busy = false
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { hasAccess = false; status = "日历授权已变更"; return }
            calendars = snapshot.calendars
            selectedIDs = snapshot.selected
            UserDefaults.standard.set(Array(selectedIDs), forKey: "CalendarSyncSelection")
            if readEvents {
                if store?.reconcileCalendar(snapshot.tasks, selectedIDs: selectedIDs, from: snapshot.startDay, to: snapshot.endDay) == true {
                    lastSync = Date()
                    status = selectedIDs.isEmpty ? "请选择至少一个日历" : "已同步 \(snapshot.tasks.count) 条日程"
                } else { status = "保存日程失败，请检查清单的数据文件夹" }
            } else { status = "已连接，自动同步暂时关闭" }
        }
    }
}

@MainActor
enum CalendarNavigation {
    static func open(_ task: Todo) {
        let date = task.calendarSource?.eventStart ?? Day.date(task.day) ?? Date()
        if let url = URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)") { NSWorkspace.shared.open(url) }
    }
}
