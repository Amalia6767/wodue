import Foundation

@main
struct ModelTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let store = TodoStore(fileURL: file, seedIfMissing: true)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError("FAIL: " + message) }
            print("PASS: " + message)
        }
        check(store.tasks.count == 10, "All 10 fictional fixture tasks are present")
        let emptyInstall = TodoStore(fileURL: root.appendingPathComponent("fresh-install.json"))
        check(emptyInstall.tasks.isEmpty, "A normal fresh installation starts empty instead of loading development fixtures")
        check(store.tasks(on: "2026-10-26").first?.timeLabel == "10:00 – 11:00", "The fictional morning walk uses its explicit time range")
        let coffee = store.tasks(on: "2026-10-26")[0]
        store.toggle(coffee.id)
        check(store.tasks(on: coffee.day)[0].completed, "Completing a task keeps it in its original position")
        check(store.tasks.count == 10, "Completed content remains in the list")
        let reloaded = TodoStore(fileURL: file)
        check(reloaded.tasks.first(where: { $0.id == coffee.id })?.completed == true, "Completion persists across app restarts")
        store.toggle(coffee.id)
        check(store.tasks.first(where: { $0.id == coffee.id })?.completed == false, "A completed task can be restored")

        let early = Todo(title: "早上的事项", day: "2026-10-26", startMinute: 540, endMinute: 570)
        check(store.upsert(early), "Adding a timed task succeeds")
        check(store.tasks(on: early.day).first?.id == early.id, "Timed tasks are sorted chronologically")
        var edited = early
        edited.title = "  修改后的事项  "
        edited.day = "2026-10-28"
        edited.startMinute = nil; edited.endMinute = nil
        check(store.upsert(edited), "Editing and moving a task succeeds")
        check(!store.tasks(on: early.day).contains(where: { $0.id == early.id }), "Moving a task removes it from the previous date")
        check(store.tasks.first(where: { $0.id == early.id })?.title == "修改后的事项", "Titles are trimmed without losing content")
        store.remove(early.id)
        check(store.tasks.count == 10, "Deleting a task persists")
        store.restore(edited)
        check(store.tasks.count == 11, "Undo restores the deleted task")

        let backup = try store.exportData()
        let importFile = root.appendingPathComponent("imported.json")
        let imported = TodoStore(fileURL: importFile, seedIfMissing: false)
        try imported.importData(backup)
        try imported.importData(backup)
        check(imported.tasks.count == 11, "Repeated import does not duplicate tasks")
        let before = imported.tasks
        do {
            try imported.importData(Data("{}".utf8))
            fatalError("Malformed JSON should be rejected")
        } catch { check(imported.tasks == before, "Malformed backups do not change existing tasks") }

        let invalid = Todo(title: "invalid", day: "2026-02-30")
        check(!store.upsert(invalid), "Impossible calendar dates are rejected")
        let badTime = Todo(title: "invalid time", day: "2026-10-26", startMinute: 700, endMinute: 600)
        check(!store.upsert(badTime), "End times before start times are rejected")
        check(!store.upsert(Todo(title: "  ", day: "2026-10-26")), "Empty titles are rejected")

        let broken = root.appendingPathComponent("broken.json")
        let brokenData = Data("broken original data".utf8)
        try brokenData.write(to: broken)
        let brokenStore = TodoStore(fileURL: broken)
        check(!brokenStore.canSave, "Unreadable data disables writes")
        check(!brokenStore.upsert(early), "Unreadable data cannot be accidentally overwritten")
        let unchanged = try Data(contentsOf: broken)
        check(unchanged == brokenData, "An unreadable original file remains untouched")
        check(Day.adding(1, to: "2026-12-31") == "2027-01-01", "Date navigation works across year boundaries")
        let oldDocument = TodoDocument(version: 1, tasks: [Todo(title: "旧数据", day: "2026-10-26")])
        let oldEncoder = JSONEncoder()
        let oldData = try oldEncoder.encode(oldDocument)
        let oldRestored = try TodoStore.decode(oldData)
        check(oldRestored[0].notes == nil && oldRestored[0].calendarSource == nil, "Existing lists remain compatible with optional calendar and note fields")

        let email = """
        Thank you for your registration for the Example University Project Workshop.
        💡 Example University Project Workshop
        Date: 28 October 2026 (Wednesday)
        Time: 10:30-11:30
        Language: English
        Please join the online session via below link:
        https://example.org/meet?pwd=a%2Bb.1
        Webinar ID: 123 4567 8901
        Passcode: demo-only
        Best regards,
        Example University Events Team
        """
        let parsed = EventParser.parse(email, reference: Day.date("2026-10-26")!)
        check(parsed.task.title == "Example University Project Workshop", "Email parsing selects the event title instead of the greeting")
        check(parsed.task.day == "2026-10-28" && parsed.task.startMinute == 630 && parsed.task.endMinute == 690, "Email date and 10:30–11:30 range are parsed exactly")
        check(parsed.task.link == "https://example.org/meet?pwd=a%2Bb.1", "Meeting URL query parameters are preserved")
        check(parsed.task.notes?.contains("Passcode: demo-only") == true, "Meeting IDs and passcodes remain in the notes")
        let chinese = EventParser.parse("主题：小组讨论\n日期：2026年10月29日\n时间：下午2:30-3:30", reference: Day.date("2026-10-26")!)
        check(chinese.task.day == "2026-10-29" && chinese.task.startMinute == 870 && chinese.task.endMinute == 930, "Chinese dates and afternoon time ranges are supported")
        let american = EventParser.parse("Workshop\nDate: October 28, 2026\nTime: 2-3pm")
        check(american.task.day == "2026-10-28" && american.task.startMinute == 840 && american.task.endMinute == 900, "Month-first English dates and pm ranges are supported")
        let missing = EventParser.parse("主题：买咖啡", reference: Day.date("2026-10-26")!)
        check(!missing.foundDate && missing.task.startMinute == nil && !missing.warnings.isEmpty, "Missing dates are flagged for review rather than silently inferred")
        let ambiguous = EventParser.parse("Meeting\nDate: 10/11/2026\nTime: 14:00-15:00", reference: Day.date("2026-10-26")!)
        check(!ambiguous.foundDate, "Ambiguous slash dates require the user's choice")
        let misleading = EventParser.parse("Meeting\nDate: 28 October 2026\nWebinar ID: 123 4567 8901\nPasscode: 10-11")
        check(misleading.task.startMinute == nil, "Meeting credentials are not mistaken for event times")
        check(WebLink.safe("javascript:alert(1)") == nil && WebLink.safe("file:///tmp/a") == nil, "Only ordinary web links are offered for opening")

        let c = Day.calendar
        let from = c.startOfDay(for: Day.date("2026-10-01")!)
        let to = c.startOfDay(for: Day.date("2026-11-01")!)
        let allDay = CalendarOccurrence(identity: "all-day", calendarID: "calendar-1", calendarName: "学习", title: "博览会",
            start: c.startOfDay(for: Day.date("2026-10-27")!), end: c.startOfDay(for: Day.date("2026-10-29")!), allDay: true, notes: nil, link: nil)
        let allDayTasks = allDay.tasks(from: from, to: to)
        check(allDayTasks.map(\.day) == ["2026-10-27", "2026-10-28"], "Multi-day all-day events honor the exclusive end date")
        check(allDayTasks.allSatisfy { $0.timeLabel == "全天" }, "All-day events remain visibly distinct from timed events")
        let firstMidnight = c.startOfDay(for: Day.date("2026-10-27")!)
        let overnight = CalendarOccurrence(identity: "overnight", calendarID: "calendar-1", calendarName: "学习", title: "跨天活动",
            start: c.date(byAdding: .minute, value: 1410, to: firstMidnight)!,
            end: c.date(byAdding: .minute, value: 1500, to: firstMidnight)!, allDay: false, notes: nil, link: nil)
        let overnightTasks = overnight.tasks(from: from, to: to)
        check(overnightTasks.count == 2 && overnightTasks[0].startMinute == 1410 && overnightTasks[1].endMinute == 60, "Overnight events appear on both dates with correct local times")
        let syncStore = TodoStore(fileURL: root.appendingPathComponent("sync.json"), seedIfMissing: false)
        let local = Todo(title: "自己的待办", day: "2026-10-26")
        _ = syncStore.upsert(local)
        _ = syncStore.reconcileCalendar(allDayTasks, selectedIDs: ["calendar-1"], from: "2026-10-01", to: "2026-11-01")
        let mirrored = syncStore.tasks.first { $0.calendarSource != nil }!
        syncStore.toggle(mirrored.id)
        var changed = allDayTasks
        changed[0].title = "改名后的博览会"
        changed[0].day = "2026-10-26"
        _ = syncStore.reconcileCalendar(changed, selectedIDs: ["calendar-1"], from: "2026-10-01", to: "2026-11-01")
        let updated = syncStore.tasks.first { $0.id == mirrored.id }!
        check(updated.completed && updated.title == "改名后的博览会" && updated.day == "2026-10-26", "Calendar changes preserve locally checked completion and stable IDs")
        _ = syncStore.reconcileCalendar(changed, selectedIDs: ["calendar-1"], from: "2026-10-01", to: "2026-11-01")
        check(syncStore.tasks.count == 3, "Repeated synchronization does not duplicate occurrences")
        _ = syncStore.reconcileCalendar([], selectedIDs: ["calendar-1"], from: "2026-10-01", to: "2026-11-01")
        check(syncStore.tasks == [local], "Cancelled source events disappear while manually added tasks remain")
        _ = syncStore.reconcileCalendar(allDayTasks, selectedIDs: ["calendar-1"], from: "2026-10-01", to: "2026-11-01")
        _ = syncStore.reconcileCalendar([], selectedIDs: [], from: "2026-10-01", to: "2026-11-01")
        check(syncStore.tasks == [local], "Deselecting a calendar only removes its mirrored entries")
        _ = syncStore.upsert(parsed.task)
        check(syncStore.duplicate(of: parsed.task) != nil, "Pasting the same event twice is detected before adding")
        let reference = Day.date("2026-10-26")!
        let canvasStore = TodoStore(fileURL: root.appendingPathComponent("canvas.json"), seedIfMissing: false)
        func notice(_ due: String, _ posted: String, id: String = "2002", course: String = "101") -> String {
            "| [Assignment Due Date Changed: Assignment 2: Prototype Review](https://canvas.example.org/courses/\(course)/assignments/\(id)) | \(posted) |\nNew due date: \(due)\n"
        }
        let oldNotice = notice("Nov 20 at 11:59pm", "Oct 15 at 11:26am")
        let newNotice = notice("Nov 30 at 11:59pm", "Oct 16 at 11:31am")
        let oldCandidate = CanvasParser.parse(oldNotice, reference: reference)[0]
        let latest = CanvasParser.parse(newNotice, reference: reference)[0]
        check(latest.day == "2026-11-30" && latest.minute == 1439, "Canvas due date is distinct from the notification publication time")
        check(Day.key(latest.source.notifiedAt!) == "2026-10-16", "Canvas notification publication date is retained for ordering")
        let merged = CanvasParser.parse(newNotice + oldNotice, reference: reference)
        check(merged.count == 1 && merged[0].day == "2026-11-30", "Unordered notifications for the same assignment merge using the latest publication date")
        check(CanvasParser.parse(oldNotice + newNotice, reference: reference)[0].day == "2026-11-30", "Paste order does not override notification chronology")
        _ = canvasStore.importCanvas([oldCandidate])
        let canvasID = canvasStore.tasks[0].id
        canvasStore.toggle(canvasID)
        _ = canvasStore.importCanvas([latest])
        check(canvasStore.tasks.count == 1 && canvasStore.tasks[0].id == canvasID && canvasStore.tasks[0].completed && canvasStore.tasks[0].day == "2026-11-30", "Deadline updates preserve original task identity and completed state")
        _ = canvasStore.importCanvas([oldCandidate])
        check(canvasStore.tasks[0].day == "2026-11-30" && canvasStore.canvasDisposition(oldCandidate) == .older, "Re-pasting an old notification cannot roll a deadline back")
        let protected = try canvasStore.exportData()
        _ = canvasStore.importCanvas([latest])
        let repeatedCanvas = try canvasStore.exportData()
        check(repeatedCanvas == protected, "Repeated latest notification import is idempotent")
        let sameDueNewerNotice = CanvasParser.parse(notice("Nov 30 at 11:59pm", "Oct 20 at 12:00pm"), reference: reference)[0]
        _ = canvasStore.importCanvas([sameDueNewerNotice])
        let intermediate = CanvasParser.parse(notice("Nov 25 at 11:59pm", "Oct 18 at 12:00pm"), reference: reference)[0]
        _ = canvasStore.importCanvas([intermediate])
        check(canvasStore.tasks[0].day == "2026-11-30", "A newer notice with an unchanged deadline still advances the chronology guard")
        let restoredCanvas = TodoStore(fileURL: canvasStore.fileURL, seedIfMissing: false)
        check(restoredCanvas.tasks[0].canvasSource?.notifiedAt == sameDueNewerNotice.source.notifiedAt, "Notification chronology persists across restarts")
        let broughtForward = CanvasParser.parse(notice("Nov 18 at 5:30pm", "Oct 22 at 9:00am"), reference: reference)[0]
        _ = canvasStore.importCanvas([broughtForward])
        check(canvasStore.tasks[0].day == "2026-11-18" && canvasStore.tasks[0].startMinute == 1050, "The latest notice wins even when it brings the deadline forward")
        _ = canvasStore.importCanvas([sameDueNewerNotice])
        check(canvasStore.tasks[0].day == "2026-11-18", "A later deadline in an older notice never overrides the latest notification")
        let distinctCourse = CanvasParser.parse(notice("Dec 1 at 11:59pm", "Oct 21 at 10:00am", course: "70000"), reference: reference)[0]
        check(canvasStore.canvasMatch(distinctCourse.source) == nil, "Assignment 2 in a different course is never merged")
        let missingDue = CanvasParser.parse("[Assignment Due Date Changed: Assignment 2](https://canvas.example.org/courses/101/assignments/2002) | Oct 22 at 11:31am |", reference: reference)[0]
        check(missingDue.day == nil && !missingDue.selected, "A due-change notification without a new date is not scheduled at its publication time")
        let unresolvedLatest = CanvasParser.parse(newNotice + notice("", "Oct 23 at 11:31am"), reference: reference)[0]
        check(unresolvedLatest.day == nil && !unresolvedLatest.selected, "A latest notice with missing deadline data stays pending instead of reusing an older deadline")
        let missingMarkdown = CanvasParser.parse("[Mid Term Group Assignment](https://canvas.example.org/courses/102/assignments/3001)\n**Available until** &#x20;\n**Due** &#x20;\nNo submission for this assignment.", reference: reference)[0]
        check(missingMarkdown.day == nil && !missingMarkdown.selected, "Missing dates in the user's copied assignment table require confirmation")
        let midterm = CanvasParser.parse("DEMO101 (Group A)\n[Mid Term Group Assignment](https://canvas.example.org/courses/102/assignments/3001)\nAvailable until Oct 29 at 11:59pm | Due Oct 28 at 11:59pm", reference: reference)[0]
        check(midterm.day == "2026-10-28" && midterm.minute == 1439, "Available-until dates never replace the actual Due date")
        let announcement = "[Updates to Assignment 2 and Assignment 3: both now due Nov 30](https://canvas.example.org/courses/101/announcements/4001) | Oct 16 at 11:38am |\n"
        let announced = CanvasParser.parse(announcement + newNotice, reference: reference)
        check(announced.count == 2 && announced.allSatisfy { $0.day == "2026-11-30" && $0.minute == nil && !$0.selected }, "A newer announcement updates both assignments without inventing an unspecified time")
        check(announced.contains { $0.source.assignmentIdentity?.hasSuffix("2002") == true }, "An announcement mentioning Assignment 2 links to the assignment's stable source identity")
        let noAction = CanvasParser.parse("[Q&A sections are now open for Assignment 2 and Assignment 3](https://canvas.example.org/courses/101/announcements/4002) | Oct 16 at 11:49am |", reference: reference)[0]
        check(noAction.informational && noAction.day == nil && !noAction.selected, "Informational announcements do not become deadline tasks")
        let classChange = CanvasParser.parse("[Class starts at 7pm today](https://canvas.example.org/courses/101/announcements/4003) | Sep 29 at 6:03pm |", reference: reference)[0]
        check(classChange.day == "2026-09-29" && classChange.minute == 1140 && !classChange.selected, "Today in an old announcement resolves against its publication day, not the import day")
        let closedAssignment = CanvasParser.parse("[Workshop Case Study 3](https://canvas.example.org/courses/102/assignments/3002)\nClosed | Due Oct 24 at 11:59pm", reference: reference)[0]
        check(closedAssignment.closed && !closedAssignment.selected, "Closed past assignments are not selected by default")
        let html = "<table><tr><td><a href=\"https://canvas.example.org/courses/102/assignments/3001\">Mid Term Group Assignment</a></td><td>Due Oct 28 at 11:59pm</td></tr></table>"
        check(CanvasParser.parse(html, reference: reference)[0].day == "2026-10-28", "Rich clipboard HTML retains assignment anchors and deadlines")
        let unknownDate = CanvasParser.parse("[Assignment 2](https://canvas.example.org/courses/101/assignments/2002)\nDue Dec 2 at 11:59pm", reference: reference)[0]
        check(canvasStore.canvasDisposition(unknownDate) == .unknownOrder, "An undated notification cannot automatically overwrite a known newer notice")
        let conflict = CanvasParser.parse(notice("Dec 1 at 11:59pm", "Oct 22 at 9:00am"), reference: reference)[0]
        check(canvasStore.canvasDisposition(conflict) == .conflict, "Conflicting deadlines with identical notification times require review")
        let ics = CanvasCalendarExport.make([latest], now: reference)
        check(ics.contains("BEGIN:VALARM") && ics.contains("TRIGGER:-PT24H") && ics.contains("TRIGGER:-PT1H"), "Timed calendar exports include 24-hour and 1-hour reminders")
        check(ics.contains("DTSTART:20261130T155900Z"), "Calendar export uses the local deadline converted to UTC")
        check(!CanvasCalendarExport.make(announced).contains("BEGIN:VALARM"), "Date-only exports do not invent a reminder time")
        check(ics.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "Calendar export folds Unicode lines by UTF-8 octet length")
        let planner = TodoStore(fileURL: root.appendingPathComponent("planner.json"), seedIfMissing: false)
        let custom = PlanCategory(name: "电子硬件", color: 0x5D8A94)
        check(planner.saveCategory(custom), "A custom activity category can be created")
        check(!planner.saveCategory(PlanCategory(name: "电子硬件", color: 0)), "A duplicate category name is rejected rather than creating ambiguous labels")
        var goal = Todo(title: "提交硬件作业", day: "2026-11-02", startMinute: 1439)
        goal.kind = .deadline; goal.categoryID = custom.id; goal.importance = 3; goal.estimatedMinutes = 300
        _ = planner.upsert(goal)
        let hardware = TimeBlock(title: "课程项目原型制作", day: "2026-10-26", startMinute: 780, endMinute: 1080, categoryID: custom.id, taskID: goal.id)
        check(planner.upsertBlock(hardware), "A five-hour work block is stored separately from its assignment deadline")
        planner.toggleBlock(hardware.id)
        check(planner.timeBlocks[0].completed && planner.tasks[0].day == "2026-11-02" && !planner.tasks[0].completed, "Completing a work block never marks the linked submission complete or moves its deadline")
        planner.toggleBlock(hardware.id)
        var renamed = custom; renamed.name = "硬件制作"
        _ = planner.saveCategory(renamed)
        check(planner.category(planner.tasks[0].categoryID)?.name == "硬件制作", "Renaming a category updates every linked item without changing its identity")
        let restoredPlanner = TodoStore(fileURL: planner.fileURL, seedIfMissing: false)
        check(restoredPlanner.categories == planner.categories && restoredPlanner.timeBlocks == planner.timeBlocks, "Categories and time blocks survive reopening the application")
        let planBackup = try planner.exportData()
        let planImport = TodoStore(fileURL: root.appendingPathComponent("plan-import.json"), seedIfMissing: false)
        try planImport.importData(planBackup); try planImport.importData(planBackup)
        check(planImport.tasks.count == 1 && planImport.timeBlocks.count == 1 && planImport.category(custom.id) != nil, "Backups include categories and work blocks and repeated imports do not duplicate them")
        _ = planner.removeCategory(custom.id)
        check(planner.tasks.count == 1 && planner.timeBlocks.count == 1 && planner.tasks[0].categoryID == nil && planner.timeBlocks[0].categoryID == nil, "Removing a category preserves the underlying tasks and blocks")
        check(!planner.saveCategory(PlanCategory(name: "  ", color: 0)), "Blank categories are rejected without corrupting the list")
        let invalidBlock = TimeBlock(title: "反向", day: "2026-10-26", startMinute: 800, endMinute: 700)
        check(!planner.upsertBlock(invalidBlock), "Work blocks must finish after they start")
        let midnightBlock = TimeBlock(title: "收尾", day: "2026-10-26", startMinute: 1380, endMinute: 1440)
        check(planner.upsertBlock(midnightBlock), "A work block can finish exactly at 24:00")
        var travel = Todo(title: "未来的旅行", day: "2026-12-01")
        travel.kind = .event; travel.endDay = "2026-12-07"
        _ = planner.upsert(travel)
        check(planner.tasks(on: "2026-12-04").contains { $0.id == travel.id } && planner.tasks(on: "2026-12-07").contains { $0.id == travel.id }, "Multi-day travel appears on all days including the selected final day")
        check(!planner.tasks(on: "2026-12-08").contains { $0.id == travel.id } && planner.days.contains("2026-12-06"), "Multi-day travel ends at the chosen date and contributes the covered dates to the calendar")
        var overnightTrip = Todo(title: "夜间出行", day: "2026-12-01", startMinute: 1380, endMinute: 120)
        overnightTrip.kind = .event; overnightTrip.endDay = "2026-12-02"
        check(planner.upsert(overnightTrip) && overnightTrip.end(on: "2026-12-01") == 1440 && overnightTrip.start(on: "2026-12-02") == 0, "An overnight activity retains the correct first- and last-day boundaries")
        var invalidSpan = travel; invalidSpan.endDay = "2026-11-30"
        check(!planner.upsert(invalidSpan), "An end date before the start date is rejected")
        let work = TimeBlock(title: "做作业", day: "2026-10-26", startMinute: 660, endMinute: 720)
        let adjacent = TimeBlock(title: "午饭休息", day: "2026-10-26", startMinute: 720, endMinute: 780, rest: true)
        let overlap = TimeBlock(title: "另一个安排", day: "2026-10-26", startMinute: 700, endMinute: 750)
        check(PlanningEngine.conflicts(adjacent, tasks: [], blocks: [work, hardware]).isEmpty, "Adjacent work and rest blocks do not falsely overlap")
        check(PlanningEngine.conflicts(overlap, tasks: [], blocks: [work]).count == 1, "Overlapping work blocks are identified for review")
        var dueAtNoon = Todo(title: "中午提交", day: "2026-10-26", startMinute: 710); dueAtNoon.kind = .deadline
        check(PlanningEngine.conflicts(work, tasks: [dueAtNoon], blocks: []).isEmpty, "A submission deadline is a point and does not occupy a preparation time block")
        let busy = PlanningEngine.busy(on: work.day, tasks: [], blocks: [work, hardware])
        check(PlanningEngine.freeSlot(duration: 60, after: 615, busy: busy) == 720..<780, "Free-slot suggestions skip occupied time and use a real gap")
        check(PlanningEngine.freeSlot(duration: 240, after: 1080, busy: busy) == nil, "No suggestion silently extends a work block past the selected planning boundary")
        var todayDeadline = goal; todayDeadline.id = UUID(); todayDeadline.day = "2026-10-26"; todayDeadline.startMinute = nil; todayDeadline.importance = 1
        var overdueDeadline = goal; overdueDeadline.id = UUID(); overdueDeadline.day = "2026-10-25"
        var completedGoal = goal; completedGoal.id = UUID(); completedGoal.completed = true
        let orderedGoals = PlanningEngine.priorities([goal, todayDeadline, overdueDeadline, completedGoal], now: reference)
        check(orderedGoals.map(\.id) == [overdueDeadline.id, todayDeadline.id, goal.id], "Deadline urgency precedes future importance and completed goals are excluded from recommendations")
        var presentation = Todo(title: "Presentation", day: "2026-10-27", startMinute: 840)
        presentation.kind = .event; presentation.categoryID = "presentation"
        check(PlanningEngine.urgency(presentation, now: reference).rank == 2, "An upcoming presentation is highlighted for preparation even though it is an event rather than a submission deadline")
        let focusFile = root.appendingPathComponent("test-focus.json")
        let clock = FocusClock(fileURL: focusFile, runTimer: false)
        clock.setDurations(work: 5, rest: 1)
        let t0 = ClockText.date("2026-10-26", 600)!
        check(clock.start(title: "硬件组装", blockID: hardware.id, taskID: goal.id, hardStop: t0.addingTimeInterval(600), now: t0), "A focus round can be tied to a work block and a hard stop")
        check(!clock.start(title: "不能覆盖当前专注", now: t0), "Starting another task never silently replaces a running focus round")
        clock.tick(now: t0.addingTimeInterval(120))
        check(clock.remaining == 180, "Focus remaining time uses elapsed wall-clock time rather than counting timer ticks")
        clock.pause(now: t0.addingTimeInterval(120)); clock.tick(now: t0.addingTimeInterval(180))
        check(clock.remaining == 180 && !clock.running, "Pausing preserves the remaining duration")
        clock.resume(now: t0.addingTimeInterval(180)); clock.tick(now: t0.addingTimeInterval(360))
        check(clock.session?.phase == .readyBreak && clock.logs.first?.seconds == 300, "Work completion excludes paused time and offers a break without starting it automatically")
        clock.tick(now: t0.addingTimeInterval(361))
        check(clock.logs.count == 1, "Repeated timer callbacks never duplicate a completed focus log")
        clock.beginBreak(now: t0.addingTimeInterval(360)); clock.tick(now: t0.addingTimeInterval(420))
        check(clock.session?.phase == .readyWork && clock.logs.count == 1, "Rest does not count as focused work")
        clock.nextRound(now: t0.addingTimeInterval(420))
        check(clock.remaining == 180, "A next round is shortened to the remaining scheduled work time")
        clock.tick(now: t0.addingTimeInterval(600))
        check(clock.session == nil && clock.seconds(on: "2026-10-26") == 480, "The time-block boundary stops focus and records only the permitted duration")
        let pausedClock = FocusClock(fileURL: root.appendingPathComponent("paused-focus.json"), runTimer: false)
        let recent = Date()
        _ = pausedClock.start(title: "保存专注", now: recent)
        pausedClock.pause(now: recent.addingTimeInterval(60))
        let resumedClock = FocusClock(fileURL: root.appendingPathComponent("paused-focus.json"), runTimer: false)
        check(resumedClock.session?.title == "保存专注" && resumedClock.remaining == 1440 && !resumedClock.running, "A paused focus round survives application restart")
        var movedBlock = hardware; movedBlock.day = "2026-10-27"
        clock.setDurations(work: 25, rest: 5)
        _ = clock.start(title: "原安排", blockID: hardware.id, hardStop: t0.addingTimeInterval(3600), now: t0)
        clock.updateBlock(movedBlock, now: t0.addingTimeInterval(30))
        check(clock.session == nil, "Moving a running work block to another day safely ends its current timer")
        check(planner.tasks.first(where: { $0.id == goal.id })?.completed == false, "Focus and break completion never check off the linked assignment automatically")
        let focusBrokenFile = root.appendingPathComponent("broken-focus.json")
        let focusBrokenData = Data("original broken focus file".utf8)
        try focusBrokenData.write(to: focusBrokenFile)
        let focusBroken = FocusClock(fileURL: focusBrokenFile, runTimer: false)
        check(!focusBroken.start(title: "保护原记录", now: t0), "Unreadable focus records cannot be overwritten by starting a timer")
        let focusStillBroken = try Data(contentsOf: focusBrokenFile)
        check(focusStillBroken == focusBrokenData, "The unreadable focus source file remains untouched")
        let deadlineNow = ClockText.date("2026-10-26", 600)!
        func deadline(_ day: String, _ minute: Int? = nil) -> Todo {
            var value = Todo(title: "提交演示作业", day: day, startMinute: minute)
            value.kind = .deadline
            return value
        }
        let threeDays = deadline("2026-10-29", 600)
        let outsideThreeDays = deadline("2026-10-29", 601)
        check(DeadlineEngine.item(threeDays, now: deadlineNow)?.stage == .soon, "An exact deadline enters urgent reminders at the 72-hour boundary")
        check(DeadlineEngine.item(outsideThreeDays, now: deadlineNow) == nil, "A timed deadline more than 72 hours away is not prematurely marked urgent")
        check(DeadlineEngine.item(deadline("2026-10-27", 1200), now: deadlineNow)?.stage == .tomorrow, "Tomorrow's deadline has its own reminder stage")
        check(DeadlineEngine.item(deadline("2026-10-26", 1200), now: deadlineNow)?.stage == .today, "Today's deadline is highlighted before the last two hours")
        let twoHours = deadline("2026-10-26", 720)
        let halfHour = deadline("2026-10-26", 630)
        let expired = deadline("2026-10-26", 600)
        check(DeadlineEngine.item(twoHours, now: deadlineNow)?.stage == .twoHours, "The final two hours escalate the reminder")
        check(DeadlineEngine.item(halfHour, now: deadlineNow)?.stage == .halfHour, "The final thirty minutes escalate again")
        check(DeadlineEngine.item(expired, now: deadlineNow)?.stage == .overdue, "The exact cutoff changes an unfinished deadline to overdue")
        check(DeadlineEngine.item(expired, now: deadlineNow)?.countdown(at: deadlineNow) == "截止时间刚过", "The cutoff label does not falsely claim a full minute has already elapsed")
        let dateOnly = deadline("2026-10-26")
        check(DeadlineEngine.item(dateOnly, now: ClockText.date("2026-10-26", 1439)!)?.stage == .today && DeadlineEngine.item(dateOnly, now: deadlineNow)?.due == nil, "A date-only deadline stays due today without inventing a cutoff clock")
        check(DeadlineEngine.item(dateOnly, now: ClockText.date("2026-10-27", 0)!)?.stage == .overdue, "A date-only deadline becomes overdue on the following calendar day")
        check(DeadlineEngine.item(deadline("2026-10-29"), now: deadlineNow)?.stage == .soon && DeadlineEngine.item(deadline("2026-10-30"), now: deadlineNow) == nil, "Date-only deadlines use a three-calendar-day reminder window")
        var finishedDeadline = halfHour; finishedDeadline.completed = true
        var regularTask = halfHour; regularTask.kind = .task
        check(DeadlineEngine.items([finishedDeadline, regularTask], now: deadlineNow).isEmpty, "Completed deadlines and ordinary work tasks never generate deadline alarms")
        let sortedDeadlines = DeadlineEngine.items([threeDays, twoHours, halfHour, expired], now: deadlineNow)
        check(sortedDeadlines.map(\.id) == [expired.id, halfHour.id, twoHours.id, threeDays.id], "The radar puts overdue and imminent deadlines before less urgent ones")
        let inferred = Todo(title: "ddl Demo Project", day: "2026-10-28", startMinute: 1439)
        check(inferred.resolvedKind == .deadline && DeadlineEngine.item(inferred, now: deadlineNow) != nil, "Explicit DDL wording in an existing title can enter the reminder radar")
        var override = inferred; override.kind = .event
        check(DeadlineEngine.item(override, now: deadlineNow) == nil && !DeadlineEngine.titleSignalsDeadline("paddle workshop"), "An explicit activity choice overrides inference and unrelated title substrings do not become deadlines")
        var preparation = Todo(title: "准备 paper outline (deadline: 28 Oct, 11:59pm)", day: "2026-10-26", startMinute: 540)
        preparation.calendarSource = CalendarReference(key: "preparation", calendarID: "demo", calendarName: "演示", allDay: false, eventStart: deadlineNow)
        check(preparation.resolvedKind == .event && DeadlineEngine.item(preparation, now: deadlineNow) == nil, "A preparation event merely mentioning a future deadline never uses its own earlier calendar date as the cutoff")
        let item72 = DeadlineEngine.item(threeDays, now: deadlineNow)!
        var ledger = DeadlineLedger()
        check(ledger.shouldPresent(item72, now: deadlineNow), "A newly urgent deadline requests a desktop card")
        ledger.acknowledge([item72], now: deadlineNow)
        check(!ledger.shouldPresent(item72, now: deadlineNow.addingTimeInterval(60)), "Acknowledging a reminder prevents repeated popups in the same stage")
        let escalated = DeadlineEngine.item(threeDays, now: ClockText.date("2026-10-28", 600)!)!
        check(ledger.shouldPresent(escalated, now: ClockText.date("2026-10-28", 600)!), "A later urgency stage can alert again after an earlier acknowledgment")
        var changedDue = threeDays; changedDue.day = "2026-10-28"
        let changedItem = DeadlineEngine.item(changedDue, now: deadlineNow)!
        check(item72.revision != changedItem.revision && ledger.shouldPresent(changedItem, now: deadlineNow), "Rescheduling the same task creates a fresh reminder revision instead of inheriting its old dismissal")
        let halfItem = DeadlineEngine.item(halfHour, now: deadlineNow)!
        ledger.snooze([halfItem], now: deadlineNow)
        check(!ledger.shouldPresent(halfItem, now: deadlineNow.addingTimeInterval(1799)) && ledger.shouldPresent(DeadlineEngine.item(halfHour, now: deadlineNow.addingTimeInterval(1800))!, now: deadlineNow.addingTimeInterval(1800)), "Snoozing suppresses a card until the requested time and then alerts again")
        let almostDue = DeadlineEngine.item(deadline("2026-10-26", 610), now: deadlineNow)!
        ledger.snooze([almostDue], now: deadlineNow)
        check(ledger.receipts[almostDue.revision]?.snoozedUntil == ClockText.date("2026-10-26", 610), "A thirty-minute snooze never hides a deadline past its exact cutoff")
        let savedLedger = try JSONDecoder().decode(DeadlineLedger.self, from: JSONEncoder().encode(ledger))
        check(savedLedger.receipts == ledger.receipts && !savedLedger.shouldPresent(item72, now: deadlineNow), "Reminder dismissals and snooze timestamps survive serialization and restart")
        ledger.popupsEnabled = false
        check(!ledger.shouldPresent(changedItem, now: deadlineNow) && ledger.needsReminder(changedItem, now: deadlineNow), "Turning off desktop cards leaves system reminders independently available")
        var eveningDeadline = threeDays; eveningDeadline.startMinute = 1200
        let scheduled = DeadlineEngine.notices([eveningDeadline], now: deadlineNow.addingTimeInterval(-1))
        check(Set(scheduled.map(\.stage)).isSuperset(of: [.soon, .tomorrow, .today, .twoHours, .halfHour, .overdue]), "A precise future deadline schedules preparation, day-of, imminent and overdue notification stages")
        check(Set(scheduled.map(\.identifier)).count == scheduled.count && scheduled.allSatisfy { $0.date > deadlineNow.addingTimeInterval(-1) }, "Future notification stages have stable unique identities and never schedule in the past")
        let changedSchedule = DeadlineEngine.notices([changedDue], now: deadlineNow.addingTimeInterval(-1))
        check(Set(scheduled.map(\.identifier)).isDisjoint(with: changedSchedule.map(\.identifier)), "Changed deadlines cannot reuse pending notification identifiers from the old cutoff")
        let allDayNotices = DeadlineEngine.notices([deadline("2026-10-29")], now: ClockText.date("2026-10-25", 600)!)
        check(allDayNotices.allSatisfy { $0.item.due == nil && ClockText.minuteNow($0.date) == 540 } && allDayNotices.count == 4, "Date-only reminders use explicit morning reminder times without manufacturing a submission deadline")
        check(DeadlineEngine.notices([finishedDeadline, regularTask], now: deadlineNow).isEmpty, "Completing or reclassifying a task produces no future deadline requests")
        let yearEnd = ClockText.date("2026-12-31", 600)!
        check(DeadlineEngine.item(deadline("2027-01-01", 600), now: yearEnd)?.stage == .tomorrow, "Deadline urgency crosses month and year boundaries correctly")
        let reminderStore = TodoStore(fileURL: root.appendingPathComponent("reminder-tasks.json"), seedIfMissing: false)
        let realNow = Date()
        var reminderGoal = deadline(Day.key(realNow), nil)
        reminderGoal.title = "测试截止提醒"
        _ = reminderStore.upsert(reminderGoal)
        let reminderFile = root.appendingPathComponent("deadline-reminders.json")
        let reminder = DeadlineReminder(fileURL: reminderFile, runTimer: false)
        reminder.configure(store: reminderStore)
        check(reminder.presented.count == 1, "A newly urgent stored task opens a reminder in the isolated controller")
        reminder.snooze(now: realNow)
        let afterRestart = DeadlineReminder(fileURL: reminderFile, runTimer: false)
        afterRestart.configure(store: reminderStore)
        check(afterRestart.items.count == 1 && afterRestart.presented.isEmpty, "A snoozed deadline remains on the radar without popping up again on restart")
        reminderStore.toggle(reminderGoal.id)
        check(reminder.items.isEmpty && afterRestart.items.isEmpty, "Completing a task immediately clears all observing deadline radars")
        let brokenReminderFile = root.appendingPathComponent("broken-deadline-reminders.json")
        let originalReminderData = Data("keep this original reminder state".utf8)
        try originalReminderData.write(to: brokenReminderFile)
        let brokenReminder = DeadlineReminder(fileURL: brokenReminderFile, runTimer: false)
        brokenReminder.configure(store: reminderStore); brokenReminder.setPopups(false)
        let keptReminderData = try Data(contentsOf: brokenReminderFile)
        check(keptReminderData == originalReminderData && !brokenReminder.message.isEmpty, "Unreadable reminder records are preserved and reported rather than overwritten")
        print("All model, planning, focus, deadline, Canvas and synchronization checks passed.")
    }
}
