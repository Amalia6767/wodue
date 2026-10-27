import Foundation

@MainActor
enum EventTests {
    static func run(root: URL) throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fatalError("FAIL: " + message) }
            print("PASS: " + message)
        }
        let now = ClockText.date("2026-10-27", 1080)!
        let meeting = Todo(title: "Example University Information Session", day: "2026-10-28", startMinute: 630, endMinute: 690,
            link: "https://example.org/meeting/demo")
        let item = EventEngine.item(meeting)!
        let before = ClockText.date("2026-10-28", 615)!
        check(item.reminderDate == before, "A 10:30 meeting reminds at 10:15 on the same date")
        let notices = EventEngine.notices([meeting], now: now)
        check(notices.map(\.date) == [before, item.start] && notices.map(\.stage) == [.preparing, .starting], "Meetings schedule both the fifteen-minute warning and the start reminder")
        check(item.stage(at: before.addingTimeInterval(-1)) == nil && item.stage(at: before) == .preparing, "The urgent window starts exactly fifteen minutes before an event")
        check(item.stage(at: item.start) == .starting && item.stage(at: item.start.addingTimeInterval(900)) == nil, "A start reminder expires instead of alarming indefinitely about past meetings")
        check(EventEngine.notices([meeting], now: before.addingTimeInterval(60)).map(\.stage) == [.starting], "Adding a meeting late schedules only future notification times")
        check(EventEngine.items([meeting], now: item.expires).isEmpty, "Expired events leave the meeting radar")
        var point = meeting; point.endMinute = nil
        check(EventEngine.item(point)?.expires == item.start.addingTimeInterval(900), "A point-in-time event has a bounded reminder window")
        var short = meeting; short.endMinute = 635
        check(EventEngine.item(short)?.expires == ClockText.date(short.day, 635), "A short event stops alarming when its actual end passes")
        var done = meeting; done.completed = true
        var due = meeting; due.kind = .deadline
        var rest = meeting; rest.kind = .rest
        var undated = meeting; undated.startMinute = nil; undated.endMinute = nil
        check(EventEngine.notices([done, due, rest, undated], now: now).isEmpty, "Completed tasks, deadlines, rest and date-only events do not generate meeting alarms")
        var inferredDeadline = meeting; inferredDeadline.title = "DDL Example assignment"
        check(EventEngine.item(inferredDeadline) == nil, "An inferred deadline does not also generate a meeting reminder")
        var allDay = meeting
        allDay.calendarSource = CalendarReference(key: "all-day", calendarID: "example", calendarName: "Demo", allDay: true, eventStart: item.start)
        check(EventEngine.item(allDay) == nil, "All-day calendar items never manufacture a timed meeting alarm")
        var continuation = meeting; continuation.day = "2026-10-29"; continuation.startMinute = 0; continuation.endMinute = 60
        continuation.calendarSource = CalendarReference(key: "overnight", calendarID: "example", calendarName: "Demo", allDay: false, eventStart: item.start)
        check(EventEngine.item(continuation) == nil, "The continuation day of an overnight calendar event does not create a second meeting alarm")
        var crossDay = meeting; crossDay.day = "2027-01-01"; crossDay.startMinute = 5; crossDay.endMinute = 65
        check(EventEngine.item(crossDay)?.reminderDate == ClockText.date("2026-12-31", 1430), "The fifteen-minute offset correctly crosses midnight and the year boundary")
        var trip = meeting; trip.endDay = "2026-10-30"
        check(EventEngine.notices([trip], now: now).count == 2, "A multi-day trip reminds at the first start instead of on every day")
        var changed = meeting; changed.startMinute = 660; changed.endMinute = 720
        let changedItem = EventEngine.item(changed)!
        check(changedItem.revision != item.revision && Set(EventEngine.notices([changed], now: now).map(\.identifier)).isDisjoint(with: notices.map(\.identifier)), "A rescheduled event replaces all old notification identifiers")
        var noteLink = meeting; noteLink.link = nil; noteLink.notes = "Join via https://example.org/meeting/demo"
        check(EventEngine.item(noteLink)?.link?.host == "example.org", "A meeting link can be recovered from its saved notes")
        var unsafe = meeting; unsafe.link = "javascript:alert(1)"; unsafe.notes = nil
        check(EventEngine.item(unsafe)?.link == nil, "Meeting buttons do not expose unsafe URL schemes")
        var ledger = EventLedger()
        check(ledger.shouldPresent(item, now: before) && !ledger.shouldPresent(item, now: now), "A future event waits until its urgent window before popping up")
        ledger.acknowledge([item], now: before)
        check(!ledger.shouldPresent(item, now: before.addingTimeInterval(60)), "Acknowledging a meeting warning suppresses repeat popups in that stage")
        check(ledger.shouldPresent(item, now: item.start), "An acknowledged fifteen-minute warning still allows a fresh start reminder")
        ledger.snooze([item], now: before)
        check(ledger.receipts[item.revision]?.snoozedUntil == before.addingTimeInterval(300), "Meeting snooze is five minutes")
        check(!ledger.shouldPresent(item, now: before.addingTimeInterval(299)) && ledger.shouldPresent(item, now: before.addingTimeInterval(300)), "A meeting snooze suppresses alerts only until its due time")
        ledger.snooze([item], now: item.start.addingTimeInterval(-60))
        check(ledger.receipts[item.revision]?.snoozedUntil == item.start, "Snoozing a pre-meeting reminder never hides the start time")
        let restored = try JSONDecoder().decode(EventLedger.self, from: JSONEncoder().encode(ledger))
        check(restored.receipts == ledger.receipts, "Meeting acknowledgment and snooze state survive restart")
        ledger.popupsEnabled = false
        check(!ledger.shouldPresent(item, now: item.start) && ledger.needsReminder(item, stage: .starting, now: item.start), "Disabling meeting popups does not disable system notifications")
        ledger.prune(tasks: [changed])
        check(ledger.receipts.isEmpty, "Rescheduling prunes stale meeting acknowledgment state")
        var other = meeting; other.id = UUID()
        let concurrent = EventEngine.notices([meeting, other], now: now)
        check(Set(concurrent.map(\.identifier)).count == 4, "Concurrent meetings retain independent notification identities")
        check(ReminderBudget.deadlines + ReminderBudget.events + 2 * ReminderBudget.blocks + 1 <= 64, "Deadline, meeting, time-block and focus schedules share a bounded notification budget")
        let store = TodoStore(fileURL: root.appendingPathComponent("event-tasks.json"), seedIfMissing: false)
        let liveNow = Date()
        let liveStart = liveNow.addingTimeInterval(5 * 60)
        let live = Todo(title: "Isolated meeting", day: Day.key(liveStart), startMinute: ClockText.minuteNow(liveStart))
        _ = store.upsert(live)
        let file = root.appendingPathComponent("event-reminders.json")
        let reminder = EventReminder(fileURL: file, runTimer: false)
        reminder.configure(store: store)
        check(reminder.presented.count == 1, "An isolated controller immediately warns about a meeting added inside the fifteen-minute window")
        let afterRestart = EventReminder(fileURL: file, runTimer: false)
        afterRestart.configure(store: store)
        check(afterRestart.items.count == 1 && afterRestart.presented.isEmpty, "Restarting does not repeatedly present an acknowledged meeting stage")
        store.toggle(live.id)
        check(reminder.items.isEmpty && reminder.presented.isEmpty && afterRestart.items.isEmpty, "Completing a meeting clears all observing meeting reminders immediately")
        let brokenFile = root.appendingPathComponent("broken-event-reminders.json")
        let original = Data("preserve this unreadable meeting state".utf8)
        try original.write(to: brokenFile)
        let broken = EventReminder(fileURL: brokenFile, runTimer: false)
        broken.configure(store: store); broken.setPopups(false)
        let kept = try Data(contentsOf: brokenFile)
        check(kept == original && !broken.message.isEmpty, "Unreadable meeting reminder files are preserved instead of overwritten")
    }
}
