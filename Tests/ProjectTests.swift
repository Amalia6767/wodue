import Foundation

@MainActor
enum ProjectTests {
    static func run(root: URL) throws {
        func check(_ value: @autoclosure () -> Bool, _ text: String) {
            if !value() { fatalError("FAIL: " + text) }; print("PASS: " + text)
        }
        var project = LifeProject(title: "Example long-term goal", startDay: "2026-11-01", dueDay: "2026-11-10")
        check(project.valid && project.plannedMinutes() == 1200, "Ten selected days of two hours preview twenty planned hours")
        project.overrides["2026-11-03"] = ProjectDayPlan(minutes: 180)
        check(project.plannedMinutes() == 1260, "A single day can override the default without changing other dates")
        project.overrides["2026-11-04"] = ProjectDayPlan(minutes: 0)
        check(project.plan(on: "2026-11-04").minutes == 0 && project.plannedMinutes() == 1140, "A rest-day override removes only that day's planned effort")
        project.weekdays = [2,3,4,5,6]
        check(project.plan(on: "2026-11-01").minutes == 0 && project.plan(on: "2026-11-03").minutes == 180, "Weekdays and explicit exceptions are independent")
        check(project.plan(on: "2026-10-31").minutes == 0 && project.plan(on: "2026-11-11").minutes == 0, "A project never generates work outside its selected date range")
        var invalid = project; invalid.dueDay = "2026-10-30"
        check(!invalid.valid && invalid.days.isEmpty, "Invalid date ranges cannot expand into a schedule")
        invalid = project; invalid.defaultStartMinute = 1400
        check(!invalid.valid, "A default work interval cannot extend beyond midnight")
        let now = ClockText.date("2026-11-01", 480)!
        check(project.countdown(on: "2026-11-01").contains("9 天"), "A long-term countdown is available more than three days before the target")
        project.weekdays = Set(1...7); project.reminderMinute = 540
        let notices = ProjectEngine.notices([project], now: now)
        check(notices.first?.date == ClockText.date("2026-11-01", 540), "Daily project reminders begin from the project start rather than a fixed three-day window")
        check(!ProjectEngine.notices([project], now: now, finishedToday: [project.id]).contains { Day.key($0.date) == "2026-11-01" }, "Reaching today's effort target suppresses only today's future reminder")
        var limited = project; limited.reminderLeadDays = 2
        check(ProjectEngine.notices([limited], now: now).first.map { Day.key($0.date) } == "2026-11-08", "Reminder lead time is configurable per project")
        limited.completed = true
        check(ProjectEngine.notices([limited], now: now).isEmpty, "Completed projects do not keep scheduling reminders")
        check(ProjectEngine.notices([project], now: ClockText.date("2026-11-11", 0)!).isEmpty, "Reminders stop at the project's end date")
        let store = TodoStore(fileURL: root.appendingPathComponent("project-model.json"), seedIfMissing: false)
        check(store.upsertProject(project), "A project and its exceptions can be saved")
        let reload = TodoStore(fileURL: store.fileURL, seedIfMissing: false)
        check(reload.projects == [project], "Project plans persist across restart")
        var child = Todo(title: "Example milestone", day: project.dueDay); child.projectID = project.id; child.kind = .deadline
        check(store.saveEdits(child, original: nil), "A project can own a new deadline milestone")
        store.toggle(child.id)
        check(store.projects[0].completed == false && store.tasks[0].completed, "Completing a milestone does not automatically complete its parent project")
        let copy = TodoStore(fileURL: root.appendingPathComponent("project-import.json"), seedIfMissing: false)
        try copy.importData(store.exportData()); try copy.importData(store.exportData())
        check(copy.projects == [project] && copy.tasks.count == 1 && copy.tasks[0].projectID == project.id, "Backup import retains project identity and links without duplication")
        check(store.setProjectPlan(project.id, day: "2026-11-02", plan: ProjectDayPlan(minutes: 90)), "A day target can be adjusted independently")
        check(store.setProjectPlan(project.id, day: "2026-11-02", plan: nil) && store.projects[0].plan(on: "2026-11-02").minutes == 120, "Restoring a day removes its exception and resumes the default rhythm")
        let before = store.projects
        invalid = project; invalid.dailyMinutes = -1
        check(!store.upsertProject(invalid) && store.projects == before, "Invalid goals cannot overwrite an existing project")
        let legacy = try JSONEncoder().encode(TodoDocument(version: 3, tasks: [child]))
        _ = try TodoStore.decode(legacy)
        check(true, "Existing version-three task documents remain readable")
        var scheduledProject = LifeProject(title: "Scheduled example", startDay: Day.today, dueDay: Day.adding(10, to: Day.today))
        let futureDay = Day.adding(1, to: Day.today)
        scheduledProject.defaultStartMinute = 600
        _ = store.upsertProject(scheduledProject)
        check(store.setProjectPlan(scheduledProject.id, day: futureDay, plan: ProjectDayPlan(minutes: 60, startMinute: 600), schedule: true), "A daily plan and its timeline block are saved together")
        let scheduledID = store.timeBlocks.first { $0.projectID == scheduledProject.id }!.id
        _ = store.setProjectPlan(scheduledProject.id, day: futureDay, plan: ProjectDayPlan(minutes: 90, startMinute: 780))
        check(store.timeBlocks.first { $0.id == scheduledID }?.startMinute == 780 && store.timeBlocks.first { $0.id == scheduledID }?.endMinute == 870, "Editing an added daily plan updates its existing timeline block instead of duplicating it")
        _ = store.setProjectPlan(scheduledProject.id, day: futureDay, plan: ProjectDayPlan(minutes: 90, startMinute: 780), schedule: true)
        check(store.timeBlocks.filter { $0.projectID == scheduledProject.id }.count == 1, "Repeatedly adding a project day to the timeline is idempotent")
        store.toggleBlock(scheduledID)
        _ = store.setProjectPlan(scheduledProject.id, day: futureDay, plan: ProjectDayPlan(minutes: 120, startMinute: 900))
        check(store.timeBlocks.first { $0.id == scheduledID }?.startMinute == 780 && store.timeBlocks.first { $0.id == scheduledID }?.completed == true, "Plan changes never rewrite a completed timeline block")
        let file = root.appendingPathComponent("project-focus.json")
        let clock = FocusClock(fileURL: file, runTimer: false)
        clock.configure(store: store); clock.setDurations(work: 5, rest: 1)
        check(clock.start(title: project.title, projectID: project.id, now: now), "A project can start focus without creating a time block")
        clock.tick(now: now.addingTimeInterval(60))
        check(clock.projectSeconds(project.id, on: "2026-11-01", now: now.addingTimeInterval(60)) == 60, "Running effort appears live before the round finishes")
        clock.pause(now: now.addingTimeInterval(90))
        check(clock.projectSeconds(project.id, now: now.addingTimeInterval(1000)) == 90, "Paused time never increases a project's effort")
        clock.resume(now: now.addingTimeInterval(190)); clock.tick(now: now.addingTimeInterval(400))
        check(clock.logs.count == 1 && clock.projectSeconds(project.id, now: now.addingTimeInterval(400)) == 300, "A round accumulates real work on both sides of a pause exactly once")
        clock.beginBreak(now: now.addingTimeInterval(400)); clock.tick(now: now.addingTimeInterval(460))
        check(clock.projectSeconds(project.id, now: now.addingTimeInterval(460)) == 300, "Project effort excludes rest phases")
        clock.nextRound(now: now.addingTimeInterval(460)); clock.end(now: now.addingTimeInterval(610))
        check(clock.projectSeconds(project.id, now: now.addingTimeInterval(610)) == 450 && clock.logs.count == 2, "Multiple rounds continue accumulating into the same stable project identity")
        var renamed = store.projects[0]; renamed.title = "Renamed example"; renamed.dailyMinutes = 60; renamed.outcomeTarget = 10000; renamed.outcomeProgress = 500
        _ = store.upsertProject(renamed)
        let loadedClock = FocusClock(fileURL: file, runTimer: false)
        check(loadedClock.projectSeconds(project.id) == 450 && store.projects[0].outcomeProgress == 500 && !store.projects[0].completed, "Restart, renaming and planning changes preserve effort independently of outcomes and completion")
        let midnight = ClockText.date("2026-11-01", 1438)!
        let nightClock = FocusClock(fileURL: root.appendingPathComponent("project-midnight.json"), runTimer: false)
        nightClock.setDurations(work: 5, rest: 1)
        _ = nightClock.start(title: "Night work", projectID: project.id, now: midnight)
        nightClock.tick(now: midnight.addingTimeInterval(300))
        check(nightClock.projectSeconds(project.id, on: "2026-11-01") == 120 && nightClock.projectSeconds(project.id, on: "2026-11-02") == 180, "A round crossing midnight is allocated to each actual calendar day")
        let interruptedFile = root.appendingPathComponent("project-interrupted.json")
        let interrupted = FocusClock(fileURL: interruptedFile, runTimer: false)
        let past = Date().addingTimeInterval(-3600)
        _ = interrupted.start(title: "Interrupted", projectID: project.id, now: past)
        interrupted.tick(now: past.addingTimeInterval(60))
        let recovered = FocusClock(fileURL: interruptedFile, runTimer: false)
        check(!recovered.running && recovered.projectSeconds(project.id) == 60, "Restart restores a paused checkpoint without inventing an hour of offline effort")
        recovered.end(); recovered.end()
        check(recovered.logs.count == 1 && recovered.projectSeconds(project.id) == 60, "Recovery and repeated stop cannot double-count an interrupted round")
        var linked = TimeBlock(title: "Project work", day: "2026-11-01", startMinute: 600, endMinute: 660); linked.projectID = project.id
        _ = store.upsertBlock(linked)
        let linkedClock = FocusClock(fileURL: root.appendingPathComponent("project-linked.json"), runTimer: false)
        linkedClock.configure(store: store)
        _ = linkedClock.start(title: linked.title, blockID: linked.id, now: now); linkedClock.end(now: now.addingTimeInterval(30))
        store.removeBlock(linked.id)
        check(linkedClock.logs.first?.projectID == project.id && linkedClock.projectSeconds(project.id) == 30, "Deleting a time block cannot erase or detach its recorded project effort")
        let oldFocus = root.appendingPathComponent("project-legacy-focus.json")
        let oldLogID = UUID().uuidString
        let oldJSON = "{\"logs\":[{\"id\":\"\(oldLogID)\",\"title\":\"Legacy focus\",\"seconds\":60,\"day\":\"2026-11-01\"}],\"workMinutes\":25,\"restMinutes\":5}"
        try Data(oldJSON.utf8).write(to: oldFocus)
        let oldClock = FocusClock(fileURL: oldFocus, runTimer: false)
        check(oldClock.logs.count == 1 && oldClock.projectSeconds(project.id) == 0, "Legacy logs are kept but are never guessed into a project from their title")
        let migrationDirectory = root.appendingPathComponent("focus-migration", isDirectory: true)
        try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        let migrationLegacy = migrationDirectory.appendingPathComponent("focus.json")
        let oldBytes = Data(oldJSON.utf8); try oldBytes.write(to: migrationLegacy)
        let migrationStore = TodoStore(fileURL: migrationDirectory.appendingPathComponent("tasks.json"), seedIfMissing: false)
        let migrationClock = FocusClock(runTimer: false); migrationClock.configure(store: migrationStore)
        check(migrationClock.logs.count == 1 && FileManager.default.fileExists(atPath: migrationDirectory.appendingPathComponent("focus-v2.json").path), "Legacy focus history is migrated to a separate file before project-aware writing")
        _ = migrationClock.start(title: "New round", projectID: project.id, now: now); migrationClock.end(now: now.addingTimeInterval(30))
        let legacyAfter = try Data(contentsOf: migrationLegacy)
        check(legacyAfter == oldBytes, "Project-aware focus writes keep the legacy focus file unchanged")
        check(ReminderBudget.deadlines + ReminderBudget.events + 2 * ReminderBudget.blocks + ReminderBudget.projects + 1 <= 64, "Project reminders fit within the shared system-notification budget")
    }
}
