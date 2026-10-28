import Foundation

@MainActor
enum CalendarEditTests {
    static func run(root: URL) throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { fatalError("FAIL: " + message) }
            print("PASS: " + message)
        }
        let file = root.appendingPathComponent("calendar-edits.json")
        let store = TodoStore(fileURL: file, seedIfMissing: false)
        let reference = CalendarReference(key: "demo|day:0", calendarID: "demo", calendarName: "Example", allDay: false,
            eventStart: ClockText.date("2026-10-30", 540)!)
        let source = Todo(title: "Example workshop", day: "2026-10-30", startMinute: 540, endMinute: 600,
            notes: "Original notes", link: "https://example.org/original", calendarSource: reference)
        func sync(_ incoming: [Todo]) {
            check(store.reconcileCalendar(incoming, selectedIDs: ["demo"], from: "2026-10-01", to: "2027-01-01"), "Calendar reconciliation succeeds")
        }
        sync([source])
        var draft = source
        draft.day = "2027-01-10"; draft.startMinute = 780; draft.endMinute = 840
        draft.title = "Local workshop"; draft.link = "https://example.org/local"
        draft.categoryID = "study"; draft.importance = 3; draft.estimatedMinutes = 60
        check(store.saveEdits(draft, original: source), "A calendar item can be corrected locally, including moving outside the sync window")
        let corrected = store.tasks[0]
        check(corrected.id == source.id && corrected.calendarSource == source.calendarSource && corrected.calendarEdits?.fields == [.title, .time, .link], "Corrections preserve source identity and record only changed fields")
        check(EventEngine.item(corrected)?.reminderDate == ClockText.date("2027-01-10", 765), "Corrected calendar dates schedule the fifteen-minute reminder on the new date")
        check(EventEngine.item(corrected)?.revision != EventEngine.item(source)?.revision, "Corrected start times invalidate the old reminder revision")
        store.toggle(source.id)
        var remote = source; remote.title = "Remote workshop"; remote.notes = "New remote notes"
        remote.startMinute = 600; remote.endMinute = 660; remote.link = "https://example.org/new"
        sync([remote, remote])
        let merged = store.tasks[0]
        check(store.tasks.count == 1 && merged.day == draft.day && merged.startMinute == 780 && merged.title == draft.title && merged.link == draft.link, "Refreshes and duplicate source records cannot overwrite local corrections or duplicate an event")
        check(merged.notes == remote.notes && merged.completed && merged.categoryID == "study" && merged.importance == 3 && merged.estimatedMinutes == 60, "Untouched source fields still update while local metadata and completion are retained")
        check(merged.calendarEdits?.source == CalendarContent(remote), "The latest calendar version is retained for restoration")
        let reloaded = TodoStore(fileURL: file, seedIfMissing: false)
        check(reloaded.tasks == store.tasks && reloaded.canSave, "Corrections survive an application restart")
        var matchingRemote = remote; matchingRemote.title = draft.title
        sync([matchingRemote]); sync([remote])
        check(store.tasks[0].title == draft.title, "An override remains protected even if the calendar briefly catches up to it")
        sync([])
        check(store.tasks.count == 1, "A locally corrected event is retained when temporarily missing from its source")
        _ = store.reconcileCalendar([], selectedIDs: [], from: "2026-10-01", to: "2027-01-01")
        check(store.tasks.count == 1, "Deselecting a calendar does not discard saved local corrections")
        sync([remote])
        let beforeRestore = store.tasks[0]
        var restoredDraft = beforeRestore
        beforeRestore.calendarEdits!.source.apply(to: &restoredDraft)
        var latest = remote; latest.day = "2026-11-02"; latest.notes = "Latest while editor open"
        sync([latest])
        check(store.saveEdits(restoredDraft, original: restoredDraft, restoreCalendar: true), "Restoring the calendar version can be saved")
        let restored = store.tasks[0]
        check(restored.calendarEdits == nil && restored.day == latest.day && restored.startMinute == latest.startMinute && restored.notes == latest.notes, "Restore uses the latest source even when it changes while the editor is open")
        check(restored.completed && restored.categoryID == "study" && restored.importance == 3, "Restoration keeps completion, category and priority")
        var staleDraft = restored; staleDraft.endMinute = 720
        var newer = latest; newer.title = "New title while editing"
        sync([newer]); store.toggle(source.id)
        check(store.saveEdits(staleDraft, original: restored), "A draft can be saved after a concurrent refresh")
        let concurrent = store.tasks[0]
        check(concurrent.title == newer.title && concurrent.endMinute == 720 && !concurrent.completed, "Saving an old editor changes only edited fields and preserves concurrent completion and source updates")
        var restoreAndEdit = concurrent
        concurrent.calendarEdits!.source.apply(to: &restoreAndEdit)
        let restoreBaseline = restoreAndEdit
        restoreAndEdit.notes = "Local note after restore"
        check(store.saveEdits(restoreAndEdit, original: restoreBaseline, restoreCalendar: true) && store.tasks[0].calendarEdits?.fields == [.notes], "Restoring and then editing one field releases old overrides and protects the new edit")
        var allDay = source; allDay.id = UUID(); allDay.calendarSource!.key = "all-day"; allDay.calendarSource!.allDay = true
        allDay.startMinute = nil; allDay.endMinute = nil
        _ = store.upsert(allDay)
        var timed = allDay; timed.startMinute = 600; timed.endMinute = 660
        check(store.saveEdits(timed, original: allDay), "An all-day calendar item can receive an explicit local time")
        check(EventEngine.item(store.tasks.first { $0.id == allDay.id }!)?.reminderDate == ClockText.date(allDay.day, 585), "An explicit correction overrides all-day reminder suppression")
        var cleared = store.tasks.first { $0.id == allDay.id }!; let timedBaseline = cleared
        cleared.startMinute = nil; cleared.endMinute = nil
        check(store.saveEdits(cleared, original: timedBaseline) && EventEngine.item(store.tasks.first { $0.id == allDay.id }!) == nil, "Clearing a specific time withdraws timed reminders")
        var manual = Todo(title: "Example manual task", day: "2026-10-30")
        _ = store.upsert(manual); let manualOriginal = manual; manual.day = "2026-11-03"
        check(store.saveEdits(manual, original: manualOriginal) && store.tasks.first { $0.id == manual.id }?.day == manual.day, "Regular tasks remain editable")
        store.remove(manual.id)
        check(!store.saveEdits(manual, original: manualOriginal), "Saving a deleted task cannot silently resurrect it")
        var bad = source
        bad.calendarEdits = CalendarEdits(source: CalendarContent(source), fields: [.notes])
        bad.day = "2026-12-01"
        let before = store.tasks
        check(!store.upsert(bad) && store.tasks == before, "Inconsistent correction records cannot overwrite existing data")
        let legacy = try JSONEncoder().encode(TodoDocument(version: 2, tasks: [source]))
        let legacyTasks = try TodoStore.decode(legacy)
        check(legacyTasks == [source], "Existing version-two calendar data is migrated without changing its content")
        let document = try JSONDecoder().decode(TodoDocument.self, from: store.exportData())
        check(document.version == 3, "Backups use a new schema version so older apps refuse to overwrite corrections")
    }
}
