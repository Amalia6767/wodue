import SwiftUI
import AppKit

private typealias PlanState<Value> = SwiftUI.State<Value>

/// One thing placed on the day's line: a time block, a timed task or calendar
/// event, or a long-term project's planned slot.
private struct AgendaItem: Identifiable {
    enum Kind { case block, task, project, focus }
    var kind: Kind
    var id: UUID
    var start: Int
    var end: Int?
    var title: String
    var categoryID: String?
    var completed: Bool
    var isRest: Bool
    var block: TimeBlock? = nil
    var task: Todo? = nil
    var project: LifeProject? = nil
    var span: FocusSpan? = nil
    var finish: Int { end ?? start + 15 }
    var projectID: UUID? { project?.id ?? block?.projectID ?? task?.projectID ?? span?.projectID }
}

enum Workbench {
    /// Past-dated open to-dos and deadlines whose time has passed. Calendar
    /// events are history, not debt, so they never count.
    static func isOverdue(_ task: Todo) -> Bool {
        guard !task.completed else { return false }
        switch task.resolvedKind {
        case .deadline: return task.lastDay < Day.today || PlanningEngine.urgency(task).rank == 0
        case .task: return task.lastDay < Day.today
        default: return false
        }
    }
    /// Minutes covered by the union of the given ranges.
    static func covered(_ ranges: [(Int, Int)]) -> Int {
        var total = 0, start = -1, end = -1
        for (s, e) in ranges.sorted(by: { $0.0 < $1.0 }) {
            if s > end { total += max(0, end - start); start = s; end = e } else { end = max(end, e) }
        }
        return total + max(0, end - start)
    }
    static func shortDuration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时" + (minutes % 60 == 0 ? "" : " \(minutes % 60) 分")
    }
    static func days(from a: String, to b: String) -> Int {
        guard let x = Day.date(a), let y = Day.date(b) else { return 0 }
        return Day.calendar.dateComponents([.day], from: Day.calendar.startOfDay(for: x), to: Day.calendar.startOfDay(for: y)).day ?? 0
    }
}

private struct HeroPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 20).frame(height: 44)
            .foregroundColor(.white)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SpeechLine {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

struct DailyPlannerView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var focus = FocusClock.shared
    @ObservedObject private var deadlines = DeadlineReminder.shared
    let day: String
    let onDay: (String) -> Void
    let onEdit: (Todo) -> Void
    let onAddTask: () -> Void
    var onOpenHorizon: () -> Void = {}
    @PlanState private var editor: BlockEditorItem?
    @PlanState private var projectEditor: ProjectDaySelection?
    @PlanState private var selectedID: UUID?
    @PlanState private var overdueOpen = false
    @PlanState private var categories = false
    @PlanState private var filter = ""
    @PlanState private var customRhythm = false
    @PlanState private var freeTitle = ""

    private var isToday: Bool { day == Day.today }
    private var agenda: [AgendaItem] {
        let blocks = store.blocks(on: day)
        var items = blocks.map {
            AgendaItem(kind: .block, id: $0.id, start: $0.startMinute, end: $0.endMinute, title: $0.title,
                       categoryID: $0.categoryID, completed: $0.completed, isRest: $0.isRest, block: $0)
        }
        items += store.tasks(on: day).filter { $0.start(on: day) != nil && $0.resolvedKind != .deadline }.map {
            AgendaItem(kind: .task, id: $0.id, start: $0.start(on: day)!, end: $0.end(on: day), title: $0.title,
                       categoryID: $0.categoryID, completed: $0.completed, isRest: $0.resolvedKind == .rest, task: $0)
        }
        for project in store.projects where !project.completed {
            let plan = project.plan(on: day)
            guard plan.minutes > 0, let start = plan.startMinute,
                  !blocks.contains(where: { $0.projectID == project.id && $0.projectPlanDay == day }) else { continue }
            let spent = focus.projectSeconds(project.id, on: day) / 60
            items.append(AgendaItem(kind: .project, id: project.id, start: start, end: start + plan.minutes, title: project.title,
                                    categoryID: nil, completed: spent >= plan.minutes, isRest: false, project: project))
        }
        return items.filter { filter.isEmpty || $0.categoryID == filter }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
    /// Real focus time from any entry point: timeline, hero, project card or menu.
    private var focusItems: [AgendaItem] {
        focus.spans(on: day).map { span in
            AgendaItem(kind: .focus, id: span.id, start: span.start, end: span.end, title: span.title, categoryID: nil,
                       completed: !span.live, isRest: false, project: store.projects.first { $0.id == span.projectID }, span: span)
        }
    }
    /// Long-term projects with a daily target but no fixed time: shown as a goal, not a slot.
    private var targets: [LifeProject] {
        guard filter.isEmpty else { return [] }
        return store.projects.filter { !$0.completed && $0.plan(on: day).minutes > 0 && $0.plan(on: day).startMinute == nil }
            .sorted { ($0.dueDay, $0.title) < ($1.dueDay, $1.title) }
    }
    private func tone(_ item: AgendaItem) -> UInt32? { store.projects.first { $0.id == item.projectID }.flatMap { ProjectTone.of($0.colorID)?.hex } }
    private func canRetime(_ item: AgendaItem) -> Bool {
        switch item.kind {
        case .block, .project: return true
        case .task: return item.task.map { $0.calendarSource == nil && $0.lastDay == $0.day && $0.endMinute != nil } ?? false
        case .focus: return false
        }
    }
    private func retime(_ item: AgendaItem, _ start: Int, _ end: Int) {
        switch item.kind {
        case .block:
            guard var block = item.block else { return }
            block.startMinute = start; block.endMinute = end
            if store.upsertBlock(block) { focus.updateBlock(block) }
        case .project:
            if let project = item.project { _ = store.setProjectPlan(project.id, day: day, plan: ProjectDayPlan(minutes: end - start, startMinute: start)) }
        case .task:
            guard var task = item.task, end < 1440 else { return }
            task.startMinute = start; task.endMinute = end
            _ = store.upsert(task)
        case .focus: break
        }
    }
    private func edit(_ item: AgendaItem) {
        switch item.kind {
        case .block: if let block = item.block { editor = BlockEditorItem(block: block, day: day) }
        case .task: if let task = item.task { onEdit(task) }
        case .project: if let project = item.project { projectEditor = ProjectDaySelection(projectID: project.id, day: day) }
        case .focus: break
        }
    }
    private func delete(_ item: AgendaItem) {
        switch item.kind {
        case .block: store.deleteBlock(item.id)
        case .task: store.deleteTask(item.id)
        default: break
        }
    }
    private var points: [Todo] {
        store.tasks(on: day).filter { ($0.resolvedKind == .deadline || $0.start(on: day) == nil) && (filter.isEmpty || $0.categoryID == filter) }
    }
    private func live(_ item: AgendaItem, _ now: Int) -> Bool { isToday && item.start <= now && now < item.finish }
    private func target(_ items: [AgendaItem], now: Int) -> AgendaItem? {
        if let id = selectedID, let hit = items.first(where: { $0.id == id }) { return hit }
        if let current = items.first(where: { live($0, now) && !$0.completed && !$0.isRest }) { return current }
        return items.first { !$0.completed && !$0.isRest && (!isToday || $0.finish > now) }
    }
    // Overlapping segments count once, so the cup never plans more hours than
    // the day has. Real focus time counts as both planned and done.
    private func plannedRanges(_ items: [AgendaItem]) -> [(Int, Int)] {
        items.filter { !$0.isRest && ($0.kind == .block || $0.kind == .project) }.map { ($0.start, $0.finish) }
    }
    private func planned(_ items: [AgendaItem], _ focusItems: [AgendaItem]) -> Int {
        Workbench.covered(plannedRanges(items) + focusItems.map { ($0.start, $0.finish) })
    }
    private func finished(_ items: [AgendaItem], _ focusItems: [AgendaItem]) -> Int {
        let done = items.filter { !$0.isRest && $0.completed && ($0.kind == .block || $0.kind == .project) }.map { ($0.start, $0.finish) }
        return min(planned(items, focusItems), Workbench.covered(done + focusItems.map { ($0.start, $0.finish) }))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = ClockText.minuteNow(context.date)
            let items = agenda
            let spans = focusItems
            let chosen = target(items, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        hero(chosen, items: items, now: now)
                        CupCard(planned: planned(items, spans), done: finished(items, spans),
                                extra: planned(items, spans) - Workbench.covered(plannedRanges(items)),
                                milestone: items.filter { $0.completed && !$0.isRest }.count + spans.filter(\.completed).count)
                            .frame(width: 272)
                    }.fixedSize(horizontal: false, vertical: true)
                    DayRibbon(items: items, focus: spans, isToday: isToday, now: now, selectedID: chosen?.id,
                              tone: tone, canRetime: canRetime,
                              onSelect: { selectedID = $0 },
                              onAdd: { start, end in
                                  editor = BlockEditorItem(block: TimeBlock(title: "", day: day, startMinute: start, endMinute: end), day: day)
                              },
                              onEdit: edit, onDelete: delete, onRetime: retime)
                    HStack(alignment: .top, spacing: 16) {
                        agendaList(items, now: now, selected: chosen?.id)
                        VStack(spacing: 12) {
                            nodesCard
                            projectsCard
                        }.frame(width: 312)
                    }
                }.padding(.horizontal, 32).padding(.vertical, 24)
            }.quietScroll()
        }
        .sheet(item: $editor) { BlockEditor(store: store, item: $0) }
        .sheet(item: $projectEditor) { ProjectDayEditor(store: store, selection: $0) }
        .sheet(isPresented: $categories) { CategoryManagerView(store: store) }
        .onChange(of: day) { _, _ in selectedID = nil; filter = "" }
        .onChange(of: store.categories) { _, _ in if store.category(filter) == nil { filter = "" } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日节奏").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundColor(Palette.coralText)
                HStack(spacing: 10) {
                    Text(Day.formatted(day, "M 月 d 日 · EEEE")).font(.system(size: 24, weight: .bold, design: .rounded))
                    dayStep("chevron.left", label: "前一天") { onDay(Day.adding(-1, to: day)) }
                    dayStep("chevron.right", label: "后一天") { onDay(Day.adding(1, to: day)) }
                    if !isToday {
                        Button("回到今天") { onDay(Day.today) }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.coralText)
                    }
                }
            }
            Spacer()
            Button("+ 新事项", action: onAddTask).buttonStyle(GlassButtonStyle())
            Button("安排时间") { editor = BlockEditorItem(day: day) }.buttonStyle(GlassButtonStyle())
        }
    }
    private func dayStep(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.ink(0.1)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    // MARK: Hero

    private func hero(_ item: AgendaItem?, items: [AgendaItem], now: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let session = focus.session { sessionHero(session) }
                else if let item { targetHero(item, items: items, now: now) }
                else { emptyHero }
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            Spacer(minLength: 0)
            if isToday { speechStrip(speech(now: now)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }
    private func heroTop(chip: String, hot: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Text(chip).font(.system(size: 11, weight: .bold)).padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundColor(hot ? .white : Color(hex: 0x4A4252))
                .background(hot ? Palette.coral : Palette.ink(0.08), in: RoundedRectangle(cornerRadius: 7))
            Text(detail).font(.system(size: 12)).foregroundColor(Palette.secondary).lineLimit(1)
            Spacer(minLength: 8)
            rhythmControl
        }
    }
    private var rhythmControl: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                rhythmButton("25 / 5", work: 25, rest: 5)
                rhythmButton("50 / 10", work: 50, rest: 10)
            }.padding(3).background(Palette.ink(0.06), in: RoundedRectangle(cornerRadius: 9))
            Menu {
                Button("自由专注（不关联时段）") { _ = focus.start(title: "自由专注") }.disabled(focus.session != nil || !isToday)
                let active = store.projects.filter { !$0.completed }
                if !active.isEmpty {
                    Menu("专注某个长期项目") {
                        ForEach(active) { project in Button(project.title) { _ = focus.start(title: project.title, projectID: project.id) } }
                    }.disabled(focus.session != nil || !isToday)
                }
                Divider()
                Button("自定义节奏（现在 \(focus.workMinutes) / \(focus.restMinutes)）…") { customRhythm = true }
                Toggle("临近截止时弹出卡片", isOn: Binding(get: { deadlines.popupsEnabled }, set: deadlines.setPopups))
                if !focus.notificationsEnabled { Button("开启时段与专注提醒") { focus.requestNotifications() } }
                Divider()
                Button("管理分类…") { categories = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.secondary).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多专注选项")
        }
        .popover(isPresented: $customRhythm, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("自定义节奏").font(.system(size: 13, weight: .semibold))
                Stepper("专注 \(focus.workMinutes) 分钟", value: Binding(get: { focus.workMinutes }, set: { focus.setDurations(work: $0, rest: focus.restMinutes) }), in: 5...120, step: 5)
                Stepper("休息 \(focus.restMinutes) 分钟", value: Binding(get: { focus.restMinutes }, set: { focus.setDurations(work: focus.workMinutes, rest: $0) }), in: 1...30)
                Text("每轮结束后，由你决定休息或继续；到时间不会自动划掉事项。")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(width: 260)
        }
    }
    private func rhythmButton(_ title: String, work: Int, rest: Int) -> some View {
        let on = focus.workMinutes == work && focus.restMinutes == rest
        return Button(title) { focus.setDurations(work: work, rest: rest) }
            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 26)
            .foregroundColor(on ? Palette.ink : Palette.secondary)
            .background(on ? Color.white.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .shadow(color: on ? Palette.ink(0.1) : .clear, radius: 2, y: 1)
    }

    private func sessionHero(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heroTop(chip: session.phase == .work ? "专注中" : "休息时间", hot: session.phase == .work, detail: focus.phaseText)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(session.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(focus.clockText).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 12) {
                switch session.phase {
                case .readyBreak:
                    Button("休息 \(focus.restMinutes) 分钟") { focus.beginBreak() }.buttonStyle(HeroPrimaryStyle())
                    Button("再来一轮") { focus.nextRound() }.buttonStyle(GlassButtonStyle(height: 44))
                case .readyWork:
                    Button("开始下一轮") { focus.nextRound() }.buttonStyle(HeroPrimaryStyle())
                default:
                    Button { if focus.running { focus.pause() } else { focus.resume() } } label: {
                        Label(focus.running ? "暂停" : "继续", systemImage: focus.running ? "pause.fill" : "play.fill")
                    }.buttonStyle(HeroPrimaryStyle())
                }
                Button("结束") { focus.end() }.buttonStyle(GlassButtonStyle(height: 44))
                if let stop = session.hardStop {
                    Text("本时段最晚到 " + stop.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundColor(Palette.secondary)
                }
            }
            if !focus.message.isEmpty { Text(focus.message).font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(2) }
        }
    }

    private func targetHero(_ item: AgendaItem, items: [AgendaItem], now: Int) -> some View {
        let isLive = live(item, now)
        let past = isToday ? item.finish <= now : day < Day.today
        let chip = item.completed ? "已完成" : isLive ? "现在" : past ? "已过" : "稍后"
        let next = items.first { $0.start >= item.finish && $0.id != item.id }
        let meta: String = {
            if item.completed { return "这段已完成，杯子满了一点" }
            if isLive { return "还剩 " + ClockText.duration(item.finish - now) + (next.map { $0.start > item.finish ? "，之后留白 " + ClockText.duration($0.start - item.finish) : "" } ?? "") }
            if past { return "时间已过，没做完也可以划掉或改期" }
            if isToday { return ClockText.duration(item.start - now) + "后开始，可以提前" }
            return "到当天再开始专注"
        }()
        let canFocus = isToday && !item.completed && !item.isRest && item.kind != .task && item.finish > now
        let minutes = min(focus.workMinutes, isLive ? item.finish - now : item.finish - item.start)
        return VStack(alignment: .leading, spacing: 12) {
            heroTop(chip: chip, hot: isLive && !item.completed,
                    detail: ClockText.minute(item.start) + (item.end.map { "–" + ClockText.minute($0) } ?? "") + " · " + tag(item))
            Text(item.title.isEmpty ? "未命名的一段" : item.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
            HStack(spacing: 14) {
                if canFocus {
                    Button { startFocus(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill").font(.system(size: 12))
                            Text("开始专注")
                            Text(String(format: "%02d:00", minutes)).monospacedDigit().foregroundColor(.white.opacity(0.62))
                        }
                    }.buttonStyle(HeroPrimaryStyle())
                }
                switch item.kind {
                case .block:
                    Button(item.completed ? "恢复未完成" : "完成这段") { toggle(item) }.buttonStyle(GlassButtonStyle(height: 44))
                case .task:
                    Button("查看详情") { if let task = item.task { onEdit(task) } }.buttonStyle(GlassButtonStyle(height: 44))
                case .project:
                    Button("调整这天") { if let project = item.project { projectEditor = ProjectDaySelection(projectID: project.id, day: day) } }
                        .buttonStyle(GlassButtonStyle(height: 44))
                case .focus:
                    EmptyView()
                }
                Text(meta).font(.system(size: 12)).foregroundColor(Palette.secondary).lineLimit(2)
            }
        }
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroTop(chip: isToday ? "现在" : "这一天", hot: false, detail: isToday ? "还没有排时间" : Day.formatted(day, "M 月 d 日"))
            Text(isToday ? "现在想专注做点什么？" : "这一天还没有安排。").font(.system(size: 22, weight: .bold))
            HStack(spacing: 12) {
                if isToday {
                    TextField("这一轮想做什么？", text: $freeTitle).textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(width: 220, height: 44)
                        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink(0.12)))
                    Button {
                        let title = freeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = focus.start(title: title.isEmpty ? "自由专注" : title)
                    } label: { Label("开始专注", systemImage: "play.fill") }.buttonStyle(HeroPrimaryStyle())
                }
                Button("安排第一段") { editor = BlockEditorItem(day: day) }.buttonStyle(GlassButtonStyle(height: 44))
            }
        }
    }

    private func speechStrip(_ line: SpeechLine) -> some View {
        HStack(spacing: 10) {
            BrandSymbol().frame(width: 18, height: 18)
            Text(line.text).font(.system(size: 13)).foregroundColor(Color(hex: 0x7A2E22)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let title = line.actionTitle, let action = line.action {
                Button(title, action: action).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: 0x8E3524))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.coral(0.28)))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.coral(0.07), in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
        .overlay(alignment: .top) { Rectangle().fill(Palette.coral(0.12)).frame(height: 1) }
    }

    /// What the app says today, most pressing first.
    private func speech(now: Int) -> SpeechLine {
        if let task = store.tasks.filter(Workbench.isOverdue).sorted(by: { $0.lastDay < $1.lastDay }).first {
            if let planned = PlanningEngine.pendingBlock(taskID: task.id, on: Day.today, at: now, blocks: store.timeBlocks) {
                if planned.startMinute <= now {
                    return SpeechLine(text: "现在是处理「\(task.title)」的时段，到 \(ClockText.minute(planned.endMinute))。",
                                      actionTitle: "查看这段", action: { selectedID = planned.id })
                }
                let reminder = focus.notificationsEnabled ? "，到点会提醒你。" : "；开启提醒后，到点会通知你。"
                return SpeechLine(text: "已经排在 \(ClockText.minute(planned.startMinute)) 处理「\(task.title)」" + reminder,
                                  actionTitle: "查看这段", action: { selectedID = planned.id })
            }
            if let elapsed = store.blocks(on: Day.today).last(where: { $0.taskID == task.id && !$0.completed && !$0.isRest && $0.endMinute <= now }) {
                return SpeechLine(text: "处理「\(task.title)」的时段已经结束，还没做完可以调整时间。",
                                  actionTitle: "调整时间", action: { editor = BlockEditorItem(block: elapsed, day: Day.today) })
            }
            let late = Workbench.days(from: task.lastDay, to: Day.today)
            return SpeechLine(text: late > 0 ? "「\(task.title)」已经过了 \(late) 天，要不先花 15 分钟处理掉？" : "「\(task.title)」的截止时间已经过了，要不先花 15 分钟处理掉？",
                              actionTitle: "排 15 分钟处理", action: { schedule15(for: task, now: now) })
        }
        if let due = store.tasks.first(where: { !$0.completed && $0.resolvedKind == .deadline && $0.lastDay == Day.today }) {
            return SpeechLine(text: "今天" + (due.startMinute.map { " " + ClockText.minute($0) + " " } ?? "") + "要交「\(due.title)」，留一段时间给它。",
                              actionTitle: "安排时间", action: { editor = BlockEditorItem(task: due, day: Day.today) })
        }
        if let next = store.tasks.filter({ !$0.completed && $0.resolvedKind == .deadline && $0.day > Day.today }).min(by: { $0.day < $1.day }) {
            let days = Workbench.days(from: Day.today, to: next.day)
            if days <= 7 {
                return SpeechLine(text: "离「\(next.title)」还有 \(days) 天，今天推进一点就好。",
                                  actionTitle: "安排时间", action: { editor = BlockEditorItem(task: next, day: Day.today) })
            }
        }
        if !focus.notificationsEnabled {
            return SpeechLine(text: "开启提醒后，时段开始和专注结束都会提醒你。", actionTitle: "开启提醒", action: { focus.requestNotifications() })
        }
        let busy = PlanningEngine.busy(on: Day.today, tasks: store.tasks, blocks: store.timeBlocks) + ProjectEngine.busy(store.projects, on: Day.today)
        if let slot = PlanningEngine.freeSlot(duration: 30, after: now, busy: busy) {
            return SpeechLine(text: "\(ClockText.minute(slot.lowerBound)) 之后有空，可以排一段，也可以留给休息。")
        }
        return SpeechLine(text: "今天排得挺满了，记得给自己留一点余地。")
    }

    private func schedule15(for task: Todo, now: Int) {
        let busy = PlanningEngine.busy(on: Day.today, tasks: store.tasks, blocks: store.timeBlocks) + ProjectEngine.busy(store.projects, on: Day.today)
        guard let slot = PlanningEngine.freeSlot(duration: 15, after: now, until: 1440, busy: busy) else {
            editor = BlockEditorItem(task: task, day: Day.today); return
        }
        let block = TimeBlock(title: "处理：" + task.title, day: Day.today, startMinute: slot.lowerBound, endMinute: slot.upperBound,
                              categoryID: task.categoryID, taskID: task.id)
        if store.upsertBlock(block) { selectedID = block.id }
    }

    private func startFocus(_ item: AgendaItem) {
        selectedID = item.id
        switch item.kind {
        case .block:
            if let block = item.block {
                _ = focus.start(title: block.title, blockID: block.id, taskID: block.taskID, projectID: block.projectID, hardStop: ClockText.date(day, block.endMinute))
            }
        case .project:
            if let project = item.project { _ = focus.start(title: project.title, projectID: project.id, hardStop: ClockText.date(day, item.finish)) }
        case .task, .focus: break
        }
    }

    private func toggle(_ item: AgendaItem) {
        switch item.kind {
        case .block:
            guard let block = item.block else { return }
            if !block.completed && focus.session?.blockID == block.id { focus.end() }
            store.toggleBlock(block.id)
        case .task: store.toggle(item.id)
        case .project, .focus: break
        }
    }

    private func tag(_ item: AgendaItem) -> String {
        switch item.kind {
        case .project: return "长期项目"
        case .focus: return "专注"
        case .task: return store.category(item.categoryID)?.name ?? (item.task?.calendarSource != nil ? "日历" : "事项")
        case .block: return store.category(item.categoryID)?.name ?? (item.isRest ? "休息" : "时间块")
        }
    }

    // MARK: Agenda list

    private func agendaList(_ items: [AgendaItem], now: Int, selected: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(isToday ? "今天的安排" : "这一天的安排").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button("所有分类") { filter = "" }
                    ForEach(store.categories) { category in Button(category.name) { filter = category.id } }
                } label: {
                    Text(store.category(filter)?.name ?? "所有分类").font(.system(size: 12)).foregroundColor(Palette.secondary)
                }.menuStyle(.borderlessButton).fixedSize()
                Text("完成 \(items.filter(\.completed).count) / \(items.count) 段").font(.system(size: 12)).foregroundColor(Palette.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 8)
            if items.isEmpty {
                Text("还没有时间安排。点上面动线的空白处，或用「安排时间」排第一段。")
                    .font(.system(size: 12)).foregroundColor(Palette.secondary).padding(.horizontal, 10).padding(.vertical, 12)
            }
            // Keep the timeline chronological; the checklist puts open work first.
            ForEach(items.filter { !$0.completed } + items.filter(\.completed)) { item in
                agendaRow(item, now: now, selected: item.id == selected)
            }
            if !targets.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(isToday ? "长期项目 · 今天的目标" : "长期项目 · 这天的目标").font(.system(size: 11)).foregroundColor(Palette.secondary)
                    Spacer()
                    Text("不用排时段，专注会自动记进动线").font(.system(size: 11)).foregroundColor(Palette.secondary)
                }.padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                ForEach(targets) { project in targetRow(project) }
            }
            if !points.isEmpty {
                Text(isToday ? "今天要交 · 不限时间" : "当天要交 · 不限时间").font(.system(size: 11)).foregroundColor(Palette.secondary)
                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                ForEach(points) { task in pointRow(task) }
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private func agendaRow(_ item: AgendaItem, now: Int, selected: Bool) -> some View {
        let isLive = live(item, now) && !item.completed && !item.isRest
        let overlap = item.block.map { !PlanningEngine.conflicts($0, tasks: store.tasks, blocks: store.timeBlocks).isEmpty } ?? false
        return HStack(spacing: 12) {
            Text(ClockText.minute(item.start) + (item.end.map { " – " + ClockText.minute($0) } ?? ""))
                .font(.system(size: 12)).monospacedDigit().foregroundColor(Palette.secondary).frame(width: 96, alignment: .leading)
            checkMark(done: item.completed, faint: item.isRest) { toggle(item) }
                .disabled(item.kind == .project)
                .help(item.kind == .project ? "长期项目按专注时间自动累计" : (item.completed ? "恢复未完成" : "完成这一段"))
                .accessibilityLabel((item.completed ? "标为未完成：" : "完成：") + item.title)
            Button { selectedID = item.id } label: {
                HStack(spacing: 8) {
                    if let hex = tone(item) { Circle().fill(Color(hex: hex)).frame(width: 8, height: 8) }
                    Text(item.title.isEmpty ? "未命名的一段" : item.title).font(.system(size: 13, weight: selected ? .bold : .medium))
                        .strikethrough(item.completed).foregroundColor(item.completed ? Palette.ink(0.45) : Palette.ink).lineLimit(1)
                    if isLive {
                        Text("现在").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Palette.coral, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if overlap {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)).foregroundColor(Palette.coralText)
                            .help("这段与其他安排有重叠，可调整时间。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(tag(item)).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 2)
                .foregroundColor(item.kind == .project ? Color(hex: 0x8E3524) : Color(hex: 0x4A4252))
                .background(item.kind == .project ? Palette.coral(0.1) : Palette.ink(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text(item.end.map { Workbench.shortDuration($0 - item.start) } ?? "时间点").font(.system(size: 12)).foregroundColor(Palette.secondary)
                .lineLimit(1).frame(width: 84, alignment: .trailing)
            Menu {
                switch item.kind {
                case .block:
                    Button("编辑") { edit(item) }
                    Divider()
                    Button("删除时间块", role: .destructive) { delete(item) }
                case .task:
                    Button("编辑") { edit(item) }
                    if item.task?.calendarSource == nil {
                        Divider()
                        Button("删除事项", role: .destructive) { delete(item) }
                    }
                case .project:
                    Button("调整这天的安排") { edit(item) }
                case .focus:
                    EmptyView()
                }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(Palette.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(selected ? Palette.ink(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pointRow(_ task: Todo) -> some View {
        HStack(spacing: 12) {
            Text(task.resolvedKind == .deadline ? (task.startMinute.map { "截止 " + ClockText.minute($0) } ?? "当天截止") : "不限时间")
                .font(.system(size: 12)).foregroundColor(Palette.secondary).frame(width: 96, alignment: .leading)
            checkMark(done: task.completed, faint: false) { store.toggle(task.id) }
                .accessibilityLabel((task.completed ? "标为未完成：" : "完成：") + task.title)
            Button { onEdit(task) } label: {
                Text(task.title).font(.system(size: 13, weight: .medium)).strikethrough(task.completed)
                    .foregroundColor(task.completed ? Palette.ink(0.45) : Palette.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !task.completed && task.resolvedKind != .rest {
                Button("安排时间") { editor = BlockEditorItem(task: task, day: day) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.coralText)
            }
            Menu {
                Button("编辑") { onEdit(task) }
                if task.calendarSource == nil {
                    Divider()
                    Button("删除事项", role: .destructive) { store.deleteTask(task.id) }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(Palette.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        }.padding(.horizontal, 10).frame(height: 40)
    }

    private func targetRow(_ project: LifeProject) -> some View {
        let goal = project.plan(on: day).minutes
        let spent = focus.projectSeconds(project.id, on: day) / 60
        let reached = spent >= goal
        let running = focus.session?.projectID == project.id
        let color = ProjectTone.of(project.colorID).map { Color(hex: $0.hex) } ?? Palette.coral
        return HStack(spacing: 12) {
            Text("目标 " + Workbench.shortDuration(goal)).font(.system(size: 12)).monospacedDigit().foregroundColor(Palette.secondary)
                .frame(width: 96, alignment: .leading)
            ZStack {
                Circle().stroke(Palette.ink(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: goal > 0 ? min(1, Double(spent) / Double(goal)) : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                if reached { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(color) }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(.system(size: 13, weight: .medium)).foregroundColor(Palette.ink).lineLimit(1)
                Text(reached ? "已专注 \(ClockText.duration(spent))，今天的目标达成了"
                             : "已专注 \(ClockText.duration(spent)) · 还差 \(ClockText.duration(goal - spent))")
                    .font(.system(size: 11)).foregroundColor(reached ? Palette.coralText : Palette.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if running {
                Text("专注中").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.coralText)
            } else if isToday {
                Button(reached ? "再专注一轮" : "开始专注") { _ = focus.start(title: project.title, projectID: project.id) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.coralText)
                    .disabled(focus.session != nil)
            }
            Menu {
                Button("调整这一天") { projectEditor = ProjectDaySelection(projectID: project.id, day: day) }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(Palette.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        }.padding(.horizontal, 10).frame(height: 44)
    }

    private func checkMark(done: Bool, faint: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(done ? Palette.ink : Color.white.opacity(0.6))
                Circle().stroke(done ? Palette.ink : Palette.ink(faint ? 0.22 : 0.55), lineWidth: 2)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundColor(.white) }
            }.frame(width: 22, height: 22).contentShape(Circle())
        }.buttonStyle(.plain)
    }

    // MARK: Nodes and projects

    private var overdueTasks: [Todo] { store.tasks.filter(Workbench.isOverdue).sorted { $0.lastDay < $1.lastDay } }
    /// Overdue items fold into one line so they never push future nodes away.
    private var futureNodes: [Todo] {
        let rest = PlanningEngine.priorities(store.tasks).filter { !Workbench.isOverdue($0) && ($0.resolvedKind == .deadline || $0.resolvedKind == .event) }
        return Array(rest.prefix(overdueTasks.isEmpty ? 4 : 3))
    }

    private var nodesCard: some View {
        let overdue = overdueTasks
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("接下来的节点").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("全部", action: onOpenHorizon).buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Palette.secondary)
            }.padding(.bottom, 6)
            if overdue.isEmpty && futureNodes.isEmpty {
                Text("近期没有节点，安心推进手头的事。").font(.system(size: 12)).foregroundColor(Palette.secondary).padding(.vertical, 10)
            }
            if overdue.count == 1 {
                Rectangle().fill(Palette.ink(0.06)).frame(height: 1)
                nodeRow(overdue[0])
            } else if overdue.count > 1 {
                Rectangle().fill(Palette.ink(0.06)).frame(height: 1)
                Button { withAnimation(.easeOut(duration: 0.2)) { overdueOpen.toggle() } } label: {
                    HStack(spacing: 12) {
                        VStack(spacing: 2) {
                            Text("\(overdue.count)").font(.system(size: 17, weight: .bold)).monospacedDigit()
                            Text("项").font(.system(size: 10))
                        }.frame(width: 46, height: 42).foregroundColor(.white).background(Palette.coral, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(overdue.count) 项已逾期").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.ink)
                            Text(overdueOpen ? "完成、改期，或删掉不再需要的" : "点开处理，不挤占后面的节点").font(.system(size: 11)).foregroundColor(Palette.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: overdueOpen ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.secondary)
                    }.padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if overdueOpen {
                    ForEach(overdue) { task in nodeRow(task).padding(.leading, 12) }
                }
            }
            ForEach(futureNodes) { task in
                Rectangle().fill(Palette.ink(0.06)).frame(height: 1)
                nodeRow(task)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private func nodeRow(_ task: Todo) -> some View {
        let over = Workbench.isOverdue(task)
        let days = Workbench.days(from: Day.today, to: over ? task.lastDay : task.day)
        let (number, unit): (String, String) = over ? (days < 0 ? ("\(-days)", "天前") : ("已", "过时")) : (days == 0 ? ("今", "天") : ("\(days)", "天后"))
        let near = !over && days <= 7
        let meta = Day.formatted(task.day, "M 月 d 日") + (task.startMinute.map { " " + ClockText.minute($0) } ?? "")
            + " · " + (store.category(task.categoryID)?.name ?? task.resolvedKind.rawValue) + (over ? " · 已逾期" : "")
        return Button { onEdit(task) } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(number).font(.system(size: 17, weight: .bold)).monospacedDigit()
                    Text(unit).font(.system(size: 10))
                }
                .frame(width: 46, height: 42)
                .foregroundColor(over ? .white : (near ? Color(hex: 0x8E3524) : Color(hex: 0x4A4252)))
                .background(over ? Palette.coral : (near ? Palette.coral(0.12) : Palette.ink(0.06)), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.ink).lineLimit(1)
                    Text(meta).font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu { nodeMenu(task) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(Palette.secondary).frame(width: 18, height: 22)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).help("完成、改期或删除")
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu { nodeMenu(task) }
    }
    @ViewBuilder private func nodeMenu(_ task: Todo) -> some View {
        Button("编辑 / 改期") { onEdit(task) }
        Button(task.completed ? "标为未完成" : "标为完成") { store.toggle(task.id) }
        if task.calendarSource == nil {
            Divider()
            Button("删除", role: .destructive) { store.deleteTask(task.id) }
        }
    }

    @ViewBuilder private var projectsCard: some View {
        let active = Array(store.projects.filter { !$0.completed }.sorted { $0.dueDay < $1.dueDay }.prefix(2))
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(active) { project in
                    let plan = project.plan(on: day).minutes
                    let spent = focus.projectSeconds(project.id, on: day) / 60
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(project.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(project.countdown(on: day)).font(.system(size: 11)).foregroundColor(Palette.secondary).lineLimit(1)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.ink(0.07))
                                Capsule().fill(Palette.coral).frame(width: proxy.size.width * (plan > 0 ? min(1, Double(spent) / Double(plan)) : 0))
                            }
                        }.frame(height: 6)
                        Text(plan > 0 ? "今天 \(spent) / \(plan) 分钟" : "今天不安排").font(.system(size: 11)).foregroundColor(Palette.secondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassCard()
        }
    }
}

// MARK: - u cup

private struct CupCard: View {
    let planned: Int
    let done: Int
    var extra = 0
    var milestone = 0
    @PlanState private var drops = 0
    private var progress: Double { planned > 0 ? min(1, Double(done) / Double(planned)) : 0 }
    private var planLines: [String] {
        let scheduled = planned - extra
        if scheduled > 0 { return ["计划 " + ClockText.duration(scheduled)] + (extra > 0 ? ["另专注 " + ClockText.duration(extra)] : []) }
        return [extra > 0 ? "没排计划，专注也算数" : "还没有计划"]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天的 u 杯").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("完成一段，满一点").font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
            HStack(spacing: 16) {
                UCup(progress: progress, drops: drops).frame(width: 100, height: 112)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int((progress * 100).rounded()))").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("%").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundColor(Palette.secondary)
                    }
                    (Text("已完成 ") + Text(ClockText.duration(done)).fontWeight(.semibold).foregroundColor(Palette.ink))
                        .font(.system(size: 12)).foregroundColor(Palette.secondary)
                    ForEach(planLines, id: \.self) { line in
                        Text(line).font(.system(size: 12)).foregroundColor(Palette.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
            }.frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
        .onChange(of: milestone) { old, new in if new > old { drops += 1 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今天已完成 \(ClockText.duration(done))，占计划的 \(Int((progress * 100).rounded()))%")
    }
}

/// The u of the wordmark as a glass cup. Coral liquid rises with the day's
/// completed time; a drop falls each time a segment is finished.
private struct UCup: View {
    let progress: Double
    let drops: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PlanState private var dropY: CGFloat = -26
    @PlanState private var dropOpacity = 0.0
    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / 140
            ZStack(alignment: .topLeading) {
                CupInterior().fill(Color.white.opacity(0.55))
                TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { context in
                    let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        CupWave(level: progress, phase: -t * 26, lift: 6).fill(Palette.coral(0.32))
                        CupWave(level: progress, phase: t * 19, lift: 0).fill(Palette.coral)
                    }
                    .animation(.spring(response: 0.9, dampingFraction: 0.75), value: progress)
                }
                .clipShape(CupInterior())
                CupOutline().stroke(Palette.ink, style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
                CupHighlight().stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
                CupDrop().fill(Palette.coral).offset(y: dropY * s).opacity(dropOpacity)
            }
        }
        .onChange(of: drops) { _, _ in
            guard !reduceMotion else { return }
            dropY = -26; dropOpacity = 1
            withAnimation(.easeIn(duration: 0.75)) { dropY = 60; dropOpacity = 0 }
        }
    }
}

/// Maps the cup's 140 x 156 design grid (y from -28) into a rect.
private struct CupGrid {
    let rect: CGRect
    var s: CGFloat { rect.width / 140 }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + (y + 28) * s) }
}

private struct CupInterior: Shape {
    func path(in rect: CGRect) -> Path {
        let g = CupGrid(rect: rect); var path = Path()
        path.move(to: g.p(27, 10)); path.addLine(to: g.p(27, 66))
        path.addCurve(to: g.p(70, 109), control1: g.p(27, 89.75), control2: g.p(46.25, 109))
        path.addCurve(to: g.p(113, 66), control1: g.p(93.75, 109), control2: g.p(113, 89.75))
        path.addLine(to: g.p(113, 10)); path.closeSubpath()
        return path
    }
}

private struct CupOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let g = CupGrid(rect: rect); var path = Path()
        path.move(to: g.p(22, 8)); path.addLine(to: g.p(22, 66))
        path.addCurve(to: g.p(70, 114), control1: g.p(22, 92.5), control2: g.p(43.5, 114))
        path.addCurve(to: g.p(118, 66), control1: g.p(96.5, 114), control2: g.p(118, 92.5))
        path.addLine(to: g.p(118, 8))
        return path
    }
}

private struct CupHighlight: Shape {
    func path(in rect: CGRect) -> Path {
        let g = CupGrid(rect: rect); var path = Path()
        path.move(to: g.p(34, 16)); path.addLine(to: g.p(34, 62))
        return path
    }
}

private struct CupDrop: Shape {
    func path(in rect: CGRect) -> Path {
        let g = CupGrid(rect: rect); var path = Path()
        path.move(to: g.p(70, -8))
        path.addCurve(to: g.p(62, 9), control1: g.p(64, 1), control2: g.p(62, 5))
        path.addCurve(to: g.p(70, 17), control1: g.p(62, 13.4), control2: g.p(65.6, 17))
        path.addCurve(to: g.p(78, 9), control1: g.p(74.4, 17), control2: g.p(78, 13.4))
        path.addCurve(to: g.p(70, -8), control1: g.p(78, 5), control2: g.p(76, 1))
        path.closeSubpath()
        return path
    }
}

private struct CupWave: Shape {
    var level: Double
    var phase: Double
    var lift: CGFloat
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let g = CupGrid(rect: rect)
        let top = 10 + (1 - level) * 104 - Double(lift)
        var path = Path()
        path.move(to: g.p(0, 140))
        for x in stride(from: 0.0, through: 140.0, by: 2.0) {
            let y = top + sin((x + phase) / 70 * 2 * .pi) * 4
            path.addLine(to: g.p(CGFloat(x), CGFloat(y)))
        }
        path.addLine(to: g.p(140, 140)); path.closeSubpath()
        return path
    }
}

// MARK: - Day ribbon

/// One native tracking area for the whole strip. Overlapping SwiftUI shapes
/// must not compete for mouse-enter/mouse-exit events.
private struct RibbonPointerArea: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) { view.onMove = onMove }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.onMove = nil }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                      owner: self, userInfo: nil)
            addTrackingArea(next)
            area = next
        }
        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }
    }
}

/// The day as one line. Segments only show state; the title appears on hover.
/// Real focus time sits on top as inset coral pieces. Segment edges can be
/// dragged to change the length, the middle to move it, and dragging across
/// empty space draws a new segment.
private struct DayRibbon: View {
    let items: [AgendaItem]
    let focus: [AgendaItem]
    let isToday: Bool
    let now: Int
    let selectedID: UUID?
    let tone: (AgendaItem) -> UInt32?
    let canRetime: (AgendaItem) -> Bool
    let onSelect: (UUID) -> Void
    let onAdd: (Int, Int) -> Void
    let onEdit: (AgendaItem) -> Void
    let onDelete: (AgendaItem) -> Void
    let onRetime: (AgendaItem, Int, Int) -> Void
    @PlanState private var hovered: UUID?
    @PlanState private var ghost: Range<Int>?
    @PlanState private var drag: RibbonDrag?

    private enum DragMode: Equatable { case create, move, leading, trailing }
    private struct RibbonDrag: Equatable {
        var id: UUID?
        var mode: DragMode
        var originStart: Int
        var originEnd: Int
        var start: Int
        var end: Int
        var moved = false
    }

    private var startHour: Int { min(8, ((items + focus).map(\.start).min() ?? 480) / 60) }
    private let endHour = 24
    private var span: Double { Double((endHour - startHour) * 60) }
    private var showNow: Bool { isToday && now >= startHour * 60 && now <= endHour * 60 }
    private func x(_ minute: Int, _ width: CGFloat) -> CGFloat { CGFloat(Double(minute - startHour * 60) / span) * width }
    private func minutes(_ dx: CGFloat, _ width: CGFloat) -> Int { width > 0 ? Int((Double(dx / width) * span / 5).rounded()) * 5 : 0 }
    private func minuteAt(_ px: CGFloat, _ width: CGFloat) -> Int { min(1440, max(0, startHour * 60 + minutes(px, width))) }
    private var segments: [RibbonLayout.Segment] { items.map { .init(id: $0.id, start: $0.start, end: $0.finish) } }
    private var styles: [UUID: RibbonLayout.Style] { RibbonLayout.styles(segments) }
    private var layered: [AgendaItem] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return RibbonLayout.ordered(segments).compactMap { byID[$0.id] }
    }
    private var trackHeight: CGFloat { max(40, 30 + CGFloat(styles.values.map(\.level).max() ?? 0) * 6) }
    private func range(_ item: AgendaItem) -> (Int, Int) {
        if let drag, drag.id == item.id { return (drag.start, drag.end) }
        return (item.start, item.finish)
    }
    private func rect(_ item: AgendaItem, width: CGFloat) -> CGRect {
        let (start, end) = range(item)
        if item.kind == .focus {
            let height = trackHeight - 18
            return CGRect(x: x(start, width) + 1, y: (trackHeight - height) / 2, width: max(3, x(end, width) - x(start, width) - 2), height: height)
        }
        let height = trackHeight - 8 - CGFloat(styles[item.id]?.level ?? 0) * 6
        return CGRect(x: x(start, width) + 2, y: (trackHeight - height) / 2,
                      width: max(4, x(end, width) - x(start, width) - 4), height: height)
    }
    private func isLive(_ item: AgendaItem) -> Bool { isToday && item.start <= now && now < item.finish }
    // Opaque event tones stay distinct even when several events are live.
    private static let liveTones: [UInt32] = [0x332D3D, 0x9B87AD, 0x554B67, 0xB6A4C6, 0x746380, 0x887A98]
    private static let pendingTones: [UInt32] = [0xA298AD, 0xD0C4DB, 0xB3A4C0, 0xDFD5E7, 0x91849F, 0xBFB5CC]
    private static let quietTones: [UInt32] = [0xDED8E4, 0xEFEAF2, 0xD5CEDD, 0xE8E1ED, 0xDAD3E1, 0xE4DDE9]
    private static let pending = Color(hex: 0x96929A)
    private static let quiet = Color(hex: 0xDAD7D9)
    /// A project colour washed toward white, still opaque so overlaps read cleanly.
    private static func wash(_ hex: UInt32, _ amount: Double) -> Color {
        func channel(_ shift: UInt32) -> Double { Double((hex >> shift) & 255) / 255 * amount + (1 - amount) }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
    private func fill(_ item: AgendaItem) -> Color {
        if item.kind == .focus { return tone(item).map { Color(hex: $0) } ?? Palette.coral }
        if let hex = tone(item) {
            if item.completed || item.isRest { return Self.wash(hex, 0.3) }
            return isLive(item) ? Color(hex: hex) : Self.wash(hex, 0.62)
        }
        let tone = styles[item.id]?.tone ?? 0
        if item.completed || item.isRest { return Color(hex: Self.quietTones[tone]) }
        return Color(hex: (isLive(item) ? Self.liveTones : Self.pendingTones)[tone])
    }
    private func hit(_ point: CGPoint, width w: CGFloat) -> AgendaItem? {
        focus.reversed().first { rect($0, width: w).contains(point) } ?? layered.reversed().first { rect($0, width: w).contains(point) }
    }
    private func edge(_ point: CGPoint, of item: AgendaItem, width w: CGFloat) -> DragMode {
        let box = rect(item, width: w)
        let grip = min(8, box.width / 3)
        if point.x <= box.minX + grip { return .leading }
        if point.x >= box.maxX - grip { return .trailing }
        return .move
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("一天的动线").font(.system(size: 13, weight: .semibold))
                legend(Palette.ink, "进行中")
                legend(Self.pending, "待做")
                legend(Self.quiet, "已完成 / 休息")
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.coral)
                        .overlay(FocusHatch(gap: 4).stroke(.white.opacity(0.5), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 3)))
                        .frame(width: 14, height: 8)
                    Text("实际专注")
                }.font(.system(size: 11)).foregroundColor(Palette.secondary).help("斜纹 = 真实专注过的时间，颜色跟随长期项目")
                if isToday {
                    HStack(spacing: 6) {
                        Capsule().fill(Palette.coral).frame(width: 2, height: 12)
                        Text("现在")
                    }.font(.system(size: 11)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Text("拖动两端改时长 · 空白处拖出一段").font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.ink(0.045))
                    if showNow {
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Palette.ink(0.035))
                            .frame(width: max(0, x(now, w)))
                    }
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("ribbon"))
                            .onChanged { value in
                                guard drag != nil || abs(value.translation.width) >= 4 else { return }
                                let a = minuteAt(value.startLocation.x, w), b = minuteAt(value.location.x, w)
                                drag = RibbonDrag(id: nil, mode: .create, originStart: a, originEnd: a, start: min(a, b), end: max(max(a, b), min(a, b) + 5), moved: true)
                                ghost = nil; hovered = nil
                            }
                            .onEnded { value in
                                if let current = drag, current.mode == .create {
                                    drag = nil
                                    if current.end - current.start >= 10 { onAdd(current.start, current.end) }
                                } else if let slot = slot(at: value.location.x, width: w) {
                                    onAdd(slot.lowerBound, slot.upperBound)
                                }
                                drag = nil
                            })
                        .accessibilityHidden(true)
                    if let ghost, hovered == nil, drag == nil {
                        RoundedRectangle(cornerRadius: 8).fill(Palette.coral(0.08))
                            .overlay(Text("+ 排一段").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.coralText).lineLimit(1))
                            .frame(width: max(0, x(ghost.upperBound, w) - x(ghost.lowerBound, w) - 2), height: trackHeight - 10)
                            .offset(x: x(ghost.lowerBound, w) + 1, y: 5)
                            .allowsHitTesting(false)
                    }
                    if let drag, drag.mode == .create {
                        RoundedRectangle(cornerRadius: 8).fill(Palette.coral(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.coral, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .frame(width: max(4, x(drag.end, w) - x(drag.start, w) - 2), height: trackHeight - 10)
                            .offset(x: x(drag.start, w) + 1, y: 5)
                            .allowsHitTesting(false)
                    }
                    ForEach(layered) { item in
                        let box = rect(item, width: w)
                        RoundedRectangle(cornerRadius: 8).fill(fill(item))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 2))
                            .overlay(alignment: .trailing) {
                                if box.width >= 22 {
                                    if item.completed {
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                            .foregroundColor(Palette.secondary).padding(.trailing, 5)
                                    } else if isLive(item) && !item.isRest {
                                        Circle().fill(.white.opacity(0.9)).frame(width: 4, height: 4).padding(.trailing, 5)
                                    }
                                }
                            }
                            .shadow(color: drag?.id == item.id ? Palette.ink(0.25) : .clear, radius: 6, y: 3)
                            .frame(width: box.width, height: box.height)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .gesture(segmentDrag(item, width: w))
                            .contextMenu { segmentMenu(item) }
                            .offset(x: box.minX, y: box.minY)
                            .accessibilityElement()
                            .accessibilityLabel(timeLine(item) + "，" + item.title)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { hovered = item.id; ghost = nil; onSelect(item.id) }
                    }
                    ForEach(focus) { item in
                        let box = rect(item, width: w)
                        RoundedRectangle(cornerRadius: 6).fill(fill(item))
                            .overlay(FocusHatch().stroke(.white.opacity(0.42), lineWidth: 1.5).clipShape(RoundedRectangle(cornerRadius: 6)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.95), lineWidth: 1.5))
                            .overlay {
                                if !item.completed && box.width >= 12 { Circle().fill(.white).frame(width: 4, height: 4) }
                            }
                            .frame(width: box.width, height: box.height)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { hovered = item.id; ghost = nil }
                            .offset(x: box.minX, y: box.minY)
                            .accessibilityElement()
                            .accessibilityLabel(timeLine(item) + "，" + item.title)
                    }
                    if let item = items.first(where: { $0.id == selectedID }) {
                        let box = rect(item, width: w)
                        RoundedRectangle(cornerRadius: 11).stroke(Palette.ink, lineWidth: 2)
                            .frame(width: box.width + 6, height: box.height + 6)
                            .offset(x: box.minX - 3, y: box.minY - 3)
                            .allowsHitTesting(false)
                    }
                    if showNow {
                        Capsule().fill(Palette.coral).frame(width: 2, height: trackHeight + 4).offset(x: x(now, w) - 1, y: -2).allowsHitTesting(false)
                        Circle().fill(Palette.coral).frame(width: 8, height: 8).offset(x: x(now, w) - 4, y: -6).allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "ribbon")
                // A tooltip must not change the track's layout or move its hover
                // targets out from under the pointer when it appears.
                .frame(width: w, height: trackHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .background(RibbonPointerArea { point in
                    guard drag == nil else { return }
                    if let point {
                        // One tracking region resolves overlaps in the same order
                        // as drawing, rather than competing enter/exit callbacks.
                        let found = hit(point, width: w)
                        hovered = found?.id
                        ghost = found == nil ? slot(at: point.x, width: w) : nil
                        if let found, canRetime(found) {
                            (edge(point, of: found, width: w) == .move ? NSCursor.openHand : NSCursor.resizeLeftRight).set()
                        } else { NSCursor.arrow.set() }
                    } else {
                        hovered = nil; ghost = nil; NSCursor.arrow.set()
                    }
                })
                .overlay(alignment: .bottomLeading) {
                    if let drag {
                        bubble(ClockText.minute(drag.start) + "–" + ClockText.minute(drag.end), ClockText.duration(drag.end - drag.start),
                               center: (x(drag.start, w) + x(drag.end, w)) / 2, width: w, tipWidth: 180)
                            .offset(y: -trackHeight - 8)
                    } else if let id = hovered, let item = (focus + items).first(where: { $0.id == id }) {
                        bubble(timeLine(item), item.title.isEmpty ? "未命名的一段" : item.title,
                               center: (x(item.start, w) + x(item.finish, w)) / 2, width: w, tipWidth: min(360, w))
                            .offset(y: -trackHeight - 8)
                    }
                }
            }
            .frame(height: trackHeight).padding(.top, 16).zIndex(1)
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: startHour + startHour % 2, through: endHour, by: 2)), id: \.self) { hour in
                        if !(showNow && abs(hour * 60 - now) < 40) {
                            Text("\(hour)").font(.system(size: 11)).monospacedDigit().foregroundColor(Palette.secondary).fixedSize()
                                .alignmentGuide(.leading) { d in hour == endHour ? d.width : (hour == startHour ? 0 : d.width / 2) }
                                .offset(x: x(hour * 60, w))
                        }
                    }
                    if showNow {
                        Text(ClockText.minute(now)).font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundColor(.white)
                            .padding(.horizontal, 6).background(Palette.coral, in: RoundedRectangle(cornerRadius: 6)).fixedSize()
                            .alignmentGuide(.leading) { $0.width / 2 }
                            .offset(x: x(now, w))
                    }
                }
            }
            .frame(height: 16).padding(.top, 7)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        .glassCard()
        .zIndex(10)
        .onChange(of: items.map(\.id)) { _, _ in hovered = nil; ghost = nil }
    }

    private func segmentDrag(_ item: AgendaItem, width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("ribbon"))
            .onChanged { value in
                if drag?.id != item.id {
                    drag = RibbonDrag(id: item.id, mode: edge(value.startLocation, of: item, width: w),
                                      originStart: item.start, originEnd: item.finish, start: item.start, end: item.finish)
                }
                guard var current = drag else { return }
                if abs(value.translation.width) >= 3 { current.moved = true }
                guard current.moved, canRetime(item) else { drag = current; return }
                let delta = minutes(value.translation.width, w)
                switch current.mode {
                case .move:
                    let length = current.originEnd - current.originStart
                    let start = min(max(0, current.originStart + delta), 1440 - length)
                    current.start = start; current.end = start + length
                case .leading: current.start = min(max(0, current.originStart + delta), current.originEnd - 10)
                case .trailing: current.end = max(min(1440, current.originEnd + delta), current.originStart + 10)
                case .create: break
                }
                drag = current; hovered = nil; ghost = nil
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                guard let current = drag else { return }
                drag = nil
                if !current.moved { hovered = item.id; ghost = nil; onSelect(item.id) }
                else if canRetime(item) && (current.start != current.originStart || current.end != current.originEnd) {
                    onRetime(item, current.start, current.end)
                }
                NSCursor.arrow.set()
            }
    }

    @ViewBuilder private func segmentMenu(_ item: AgendaItem) -> some View {
        switch item.kind {
        case .block:
            Button("编辑") { onEdit(item) }
            Button("删除时间块", role: .destructive) { onDelete(item) }
        case .task:
            Button("编辑") { onEdit(item) }
            if item.task?.calendarSource == nil { Button("删除事项", role: .destructive) { onDelete(item) } }
        case .project:
            Button("调整这一天") { onEdit(item) }
        case .focus:
            EmptyView()
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 8)
            Text(title)
        }.font(.system(size: 11)).foregroundColor(Palette.secondary)
    }

    private func timeLine(_ item: AgendaItem) -> String {
        let state: String
        if item.kind == .focus { state = item.completed ? "已专注" : "专注中" }
        else { state = item.completed ? "已完成" : (item.isRest ? "休息" : (isLive(item) ? "进行中" : (isToday && item.finish <= now ? "已过" : "待做"))) }
        return ClockText.minute(item.start) + "–" + ClockText.minute(item.finish) + " · " + ClockText.duration(item.finish - item.start) + " · " + state
    }

    private func bubble(_ line: String, _ title: String, center: CGFloat, width w: CGFloat, tipWidth: CGFloat) -> some View {
        let left = min(max(0, center - tipWidth / 2), max(0, w - tipWidth))
        return VStack(alignment: .leading, spacing: 2) {
            Text(line).font(.system(size: 11)).monospacedDigit().foregroundColor(.white.opacity(0.66))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 8)
        .frame(width: tipWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: Palette.ink(0.22), radius: 10, y: 6)
        .offset(x: left)
        .allowsHitTesting(false)
    }

    /// The free stretch under the pointer, snapped to 15 minutes, up to an hour.
    private func slot(at px: CGFloat, width w: CGFloat) -> Range<Int>? {
        guard w > 0 else { return nil }
        let taken = items + focus
        let minute = startHour * 60 + Int(Double(px / w) * span)
        if taken.contains(where: { $0.start <= minute && minute < $0.finish }) { return nil }
        let previous = taken.map { $0.finish }.filter { $0 <= minute }.max() ?? startHour * 60
        let next = taken.map { $0.start }.filter { $0 > minute }.min() ?? endHour * 60
        let start = max((minute / 15) * 15, previous)
        let end = min(start + 60, next, 1440)
        return end - start >= 15 ? start..<end : nil
    }
}

/// Diagonal lines that mark real focus time, whatever its colour.
private struct FocusHatch: Shape {
    var gap: CGFloat = 6
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += gap
        }
        return path
    }
}

// MARK: - Sidebar

struct SidebarNavRow: View {
    let icon: String
    let title: String
    let badge: String?
    let alert: Bool
    let selected: Bool
    let action: () -> Void
    @PlanState private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                    .foregroundColor(selected ? Color(hex: 0xF3A193) : Palette.ink)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 11, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundColor(selected ? .white : (alert ? Color(hex: 0x8E3524) : Color(hex: 0x4A4252)))
                        .background(selected ? Color.white.opacity(0.16) : (alert ? Palette.coral(0.12) : Palette.ink(0.07)), in: Capsule())
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .foregroundColor(selected ? .white : Palette.ink)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.ink).shadow(color: Palette.ink(0.18), radius: 8, y: 5)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.ink(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HorizonView: View {
    @ObservedObject var store: TodoStore
    let onEdit: (Todo) -> Void
    let onAdd: () -> Void
    @PlanState private var category = ""
    @PlanState private var horizon = 180
    @PlanState private var showCompleted = false
    @PlanState private var editor: BlockEditorItem?
    @PlanState private var categories = false
    private var filtered: [Todo] {
        store.tasks.filter {
            (category.isEmpty || $0.categoryID == category) && (showCompleted || !$0.completed)
            && (horizon == 0 || $0.day <= Day.adding(horizon, to: Day.today))
        }
    }
    private var upcoming: [Todo] {
        filtered.filter { $0.lastDay >= Day.today || (!$0.completed && $0.resolvedKind == .deadline) }
            .sorted { ($0.day, $0.startMinute ?? 1440, $0.title) < ($1.day, $1.startMinute ?? 1440, $1.title) }
    }
    private var priorities: [Todo] { Array(PlanningEngine.priorities(filtered).filter { $0.resolvedKind == .deadline || $0.resolvedKind == .task || ($0.resolvedKind == .event && (($0.importance ?? 1) >= 2 || $0.categoryID == "presentation" || $0.estimatedMinutes != nil)) }.prefix(5)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MAKE ROOM FOR WHAT MATTERS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundColor(Palette.coral)
                        Text("重要的节点，先看见。").font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("作业与 presentation、线上线下活动、展会与旅行，都放进自己的节奏里。")
                            .font(.system(size: 12)).foregroundColor(Palette.secondary)
                    }
                    Spacer()
                    Button("新节点 / 活动", action: onAdd).buttonStyle(PrimaryActionStyle())
                }
                HStack(spacing: 14) {
                    Picker("范围", selection: $horizon) {
                        Text("未来 7 天").tag(7); Text("未来 30 天").tag(30); Text("未来半年").tag(180); Text("全部未来").tag(0)
                    }.frame(width: 170)
                    Picker("分类", selection: $category) { Text("全部分类").tag(""); ForEach(store.categories) { Text($0.name).tag($0.id) } }.frame(width: 180)
                    Toggle("显示已完成", isOn: $showCompleted).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Button("管理分类") { categories = true }
                }.font(.system(size: 11))
                if !priorities.isEmpty {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text("接下来，先准备这些。").font(.system(size: 14, weight: .medium)); Spacer(); Text("按截止紧急程度与优先级排序").font(.system(size: 10)).foregroundColor(Palette.secondary) }
                        ForEach(priorities) { task in horizonRow(task, priority: true) }
                    }.padding(20).background(Palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
                }
                Text("未来的日子").font(.system(size: 15, weight: .medium))
                if upcoming.isEmpty {
                    Text("这个范围里还没有安排。可以先放入一个截止节点、活动或旅行。")
                        .font(.system(size: 12)).foregroundColor(Palette.secondary).padding(.vertical, 30)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(upcoming.prefix(200))) { task in horizonRow(task, priority: false) }
                    }
                    if upcoming.count > 200 { Text("当前显示前 200 项，可以缩短范围或选择分类。").font(.system(size: 10)).foregroundColor(Palette.secondary) }
                }
            }.padding(30)
        }.quietScroll()
            .sheet(item: $editor) { BlockEditor(store: store, item: $0) }
            .sheet(isPresented: $categories) { CategoryManagerView(store: store) }
            .onChange(of: store.categories) { _, _ in if store.category(category) == nil { category = "" } }
    }
    private func horizonRow(_ task: Todo, priority: Bool) -> some View {
        let urgent = PlanningEngine.urgency(task)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.dateLabel).font(.system(size: 12, weight: .medium, design: .rounded))
                Text(task.timeLabel ?? task.resolvedKind.rawValue).font(.system(size: 9)).foregroundColor(Palette.secondary)
            }.frame(width: 125, alignment: .leading)
            Rectangle().fill(Color(hex: store.category(task.categoryID)?.color ?? 0xC6B4AA)).frame(width: 3).padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 7) {
                Button { onEdit(task) } label: { Text(task.title).font(.system(size: 12, weight: .medium)).strikethrough(task.completed).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                HStack(spacing: 10) {
                    CategoryBadge(category: store.category(task.categoryID))
                    if task.resolvedKind == .deadline || priority {
                        Text(urgent.label).font(.system(size: 9)).foregroundColor(urgent.rank <= 2 ? Palette.error : Palette.secondary)
                    }
                    if let estimate = task.estimatedMinutes { Text("预计 " + ClockText.duration(estimate)).font(.system(size: 9)).foregroundColor(Palette.secondary) }
                    let planned = store.timeBlocks.filter { $0.taskID == task.id && !$0.completed }.count
                    if planned > 0 { Text("已排 \(planned) 段").font(.system(size: 9)).foregroundColor(Palette.secondary) }
                }
            }
            Spacer(minLength: 4)
            if !task.completed && task.resolvedKind != .rest {
                Button(task.resolvedKind == .event ? "安排准备" : "安排时间") { editor = BlockEditorItem(task: task, day: Day.today) }.font(.system(size: 10))
            }
            Button { store.toggle(task.id) } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").foregroundColor(task.completed ? Palette.green : Palette.secondary) }.buttonStyle(.plain).help("划掉或恢复原事项")
            Menu {
                Button("编辑 / 改期") { onEdit(task) }
                if task.calendarSource == nil {
                    Divider()
                    Button("删除", role: .destructive) { store.deleteTask(task.id) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(Palette.secondary).frame(width: 18, height: 22)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).help("编辑或删除")
        }.padding(15).frame(minHeight: 76).background(Palette.card.opacity(priority ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}
