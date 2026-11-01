import Foundation

struct ProjectDayPlan: Codable, Equatable {
    var minutes: Int
    var startMinute: Int? = nil
    var valid: Bool { (0...1440).contains(minutes) && (startMinute.map { (0..<1440).contains($0) && $0 + minutes <= 1440 } ?? true) }
}

struct LifeProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var startDay: String
    var dueDay: String
    var dailyMinutes = 120
    var weekdays: Set<Int> = Set(1...7)
    var defaultStartMinute: Int? = nil
    var overrides: [String: ProjectDayPlan] = [:]
    var estimatedMinutes: Int? = nil
    var outcomeTarget: Int? = nil
    var outcomeUnit = "字"
    var outcomeProgress = 0
    var reminderEnabled = true
    var reminderMinute = 540
    var reminderLeadDays: Int? = nil
    var completed = false
    var createdAt = Date()

    var valid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              Day.date(startDay) != nil, Day.date(dueDay) != nil, dueDay >= startDay,
              dueDay <= Day.adding(1095, to: startDay), ProjectDayPlan(minutes: dailyMinutes, startMinute: defaultStartMinute).valid,
              weekdays.isSubset(of: Set(1...7)), overrides.count <= 5000,
              overrides.allSatisfy({ Day.date($0.key) != nil && $0.value.valid }),
              estimatedMinutes.map({ (1...1_000_000).contains($0) }) ?? true,
              outcomeTarget.map({ (1...1_000_000_000).contains($0) }) ?? true,
              (0...1_000_000_000).contains(outcomeProgress), !outcomeUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              outcomeUnit.count <= 12, (0..<1440).contains(reminderMinute),
              reminderLeadDays.map({ (0...1095).contains($0) }) ?? true else { return false }
        return true
    }
    func plan(on day: String) -> ProjectDayPlan {
        guard startDay <= day, day <= dueDay else { return ProjectDayPlan(minutes: 0) }
        if let override = overrides[day] { return override }
        guard let date = Day.date(day), weekdays.contains(Day.calendar.component(.weekday, from: date)) else { return ProjectDayPlan(minutes: 0) }
        return ProjectDayPlan(minutes: dailyMinutes, startMinute: defaultStartMinute)
    }
    var days: [String] {
        guard Day.date(startDay) != nil, Day.date(dueDay) != nil, dueDay >= startDay, dueDay <= Day.adding(1095, to: startDay) else { return [] }
        var result: [String] = []; var day = startDay
        for _ in 0...1095 { result.append(day); if day == dueDay { break }; day = Day.adding(1, to: day) }
        return result
    }
    func plannedMinutes(from day: String? = nil) -> Int {
        days.filter { day == nil || $0 >= day! }.reduce(0) { $0 + plan(on: $1).minutes }
    }
    func countdown(on day: String = Day.today) -> String {
        guard let date = Day.date(day), let due = Day.date(dueDay) else { return "" }
        let count = Day.calendar.dateComponents([.day], from: date, to: due).day ?? 0
        if completed { return "项目已完成" }
        if count < 0 { return "目标日期已过 \(-count) 天" }
        return count == 0 ? "今天到目标日" : "距离目标还有 \(count) 天"
    }
}

struct FocusSlice: Codable, Equatable {
    var start: Date
    var end: Date
    var seconds: Int { max(0, Int(end.timeIntervalSince(start))) }
    func seconds(on day: String) -> Int {
        guard let date = Day.date(day) else { return 0 }
        let lower = Day.calendar.startOfDay(for: date)
        guard let upper = Day.calendar.date(byAdding: .day, value: 1, to: lower) else { return 0 }
        return max(0, Int(min(end, upper).timeIntervalSince(max(start, lower))))
    }
}

struct ProjectNotice: Equatable {
    var projectID: UUID
    var date: Date
    var title: String
    var minutes: Int
}

enum ProjectEngine {
    static func notices(_ projects: [LifeProject], now: Date, finishedToday: Set<UUID> = []) -> [ProjectNotice] {
        let today = Day.key(now)
        var result: [ProjectNotice] = []
        for project in projects where project.valid && !project.completed && project.reminderEnabled {
            for offset in 0..<32 {
                let day = Day.adding(offset, to: today)
                guard day >= project.startDay, day <= project.dueDay,
                      project.reminderLeadDays.map({ day >= Day.adding(-$0, to: project.dueDay) }) ?? true,
                      !(day == today && finishedToday.contains(project.id)),
                      let date = ClockText.date(day, project.reminderMinute), date > now else { continue }
                let plan = project.plan(on: day)
                guard plan.minutes > 0 else { continue }
                result.append(ProjectNotice(projectID: project.id, date: date, title: project.title, minutes: plan.minutes))
            }
        }
        return result.sorted { $0.date == $1.date ? $0.projectID.uuidString < $1.projectID.uuidString : $0.date < $1.date }
    }
    static func busy(_ projects: [LifeProject], on day: String, excluding id: UUID? = nil) -> [BusyInterval] {
        projects.filter { !$0.completed && $0.id != id }.compactMap { project in
            let plan = project.plan(on: day)
            guard plan.minutes > 0, let start = plan.startMinute else { return nil }
            return BusyInterval(start: start, end: start + plan.minutes, title: project.title)
        }
    }
}
