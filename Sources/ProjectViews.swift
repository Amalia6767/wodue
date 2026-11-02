import SwiftUI

private typealias ProjectState<Value> = SwiftUI.State<Value>

struct ProjectsView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var clock = FocusClock.shared
    @ProjectState private var editing: LifeProject?
    @ProjectState private var detail: LifeProject?
    @ProjectState private var showCompleted = false
    private var visible: [LifeProject] {
        store.projects.filter { showCompleted || !$0.completed }.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            return ($0.dueDay, $0.createdAt) < ($1.dueDay, $1.createdAt)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ONE DAY AT A TIME").font(.system(size: 10, design: .monospaced)).tracking(2).foregroundColor(Palette.coral)
                        Text("每一段投入，都在积累。").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("把长远的目标，落实成今天可以开始的一小段。").font(.system(size: 12)).foregroundColor(Palette.secondary)
                    }
                    Spacer()
                    Button("新建项目") { editing = LifeProject(title: "", startDay: Day.today, dueDay: Day.adding(14, to: Day.today)) }
                        .buttonStyle(PrimaryActionStyle())
                }
                Toggle("显示已完成项目", isOn: $showCompleted).toggleStyle(.checkbox).font(.system(size: 11))
                if visible.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "leaf").font(.system(size: 28)).foregroundColor(Palette.green)
                        Text("给一件想坚持的事，留个位置。").font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("备考、写作、Presentation、作品集……设置每天投入多久，专注会自动累计到这个项目。").font(.system(size: 12)).foregroundColor(Palette.secondary)
                        Button("建立第一个项目") { editing = LifeProject(title: "", startDay: Day.today, dueDay: Day.adding(14, to: Day.today)) }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 18)], spacing: 18) {
                    ForEach(visible) { project in
                        ProjectCard(project: project, clock: clock, onEdit: { editing = project }, onDetail: { detail = project })
                    }
                }
                if clock.session != nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(clock.phaseText + " · " + clock.clockText).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                            Text(clock.session?.title ?? "").font(.system(size: 12)).foregroundColor(Palette.secondary)
                        }
                        Spacer()
                        FocusControls(clock: clock).frame(maxWidth: 280)
                    }.padding(20).background(Palette.selection.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("时间记录的是投入，成果由你确认。达到预估时长不会自动完成项目。").font(.system(size: 11)).foregroundColor(Palette.secondary)
            }.padding(28)
        }.quietScroll()
            .sheet(item: $editing) { ProjectEditor(store: store, initial: $0) }
            .sheet(item: $detail) { ProjectDetailView(store: store, id: $0.id) }
    }
}

private struct ProjectCard: View {
    let project: LifeProject
    @ObservedObject var clock: FocusClock
    let onEdit: () -> Void
    let onDetail: () -> Void
    private var actual: Int { clock.projectSeconds(project.id) / 60 }
    private var today: Int { clock.projectSeconds(project.id, on: Day.today) / 60 }
    private var target: Int { project.plan(on: Day.today).minutes }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.title).font(.system(size: 19, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text(project.countdown()).font(.system(size: 11, weight: .medium)).foregroundColor(project.dueDay < Day.today && !project.completed ? Palette.error : Palette.secondary)
                }
                Spacer()
                Button("编辑目标", action: onEdit).font(.system(size: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("今天"); Spacer(); Text(target > 0 ? "\(ClockText.duration(today)) / \(ClockText.duration(target))" : "\(ClockText.duration(today)) · 今天不设投入量") }
                    .font(.system(size: 11))
                ProgressView(value: target > 0 ? min(1, Double(today) / Double(target)) : 0).tint(Palette.green)
                Text(target > today ? "再投入 \(ClockText.duration(target - today))，就达到今天的计划。" : (target > 0 ? "今天的计划已达到，每一段都算数。" : "可以休息，也可以自由投入。"))
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(ClockText.duration(actual)).font(.system(size: 23, weight: .medium, design: .rounded))
                Text("累计投入").font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            if let estimate = project.estimatedMinutes {
                ProgressView(value: min(1, Double(actual) / Double(estimate))).tint(Palette.accent)
                Text("预估投入 \(ClockText.duration(estimate)) · 还安排了 \(ClockText.duration(project.plannedMinutes(from: Day.adding(1, to: Day.today))))")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                let future = max(0, target - today) + project.plannedMinutes(from: Day.adding(1, to: Day.today))
                if actual + future < estimate {
                    Text("按现有安排，距预估投入还差 \(ClockText.duration(estimate - actual - future))。可在每日计划中调整。")
                        .font(.system(size: 10)).foregroundColor(Palette.accent).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let outcome = project.outcomeTarget {
                Text("成果 \(project.outcomeProgress) / \(outcome) \(project.outcomeUnit)").font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            Divider().opacity(0.5)
            HStack {
                Button("开始 \(clock.workMinutes) 分钟") { _ = clock.start(title: project.title, projectID: project.id) }
                    .buttonStyle(PrimaryActionStyle()).disabled(project.completed || clock.session != nil)
                Spacer()
                Button("每日计划与记录", action: onDetail)
            }.font(.system(size: 11))
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.8)))
    }
}

struct ProjectEditor: View {
    @ObservedObject var store: TodoStore
    let initial: LifeProject
    @Environment(\.dismiss) private var dismiss
    @ProjectState private var draft: LifeProject
    @ProjectState private var budget = false
    @ProjectState private var budgetHours: Double
    @ProjectState private var hasOutcome: Bool
    @ProjectState private var fixed: Bool
    @ProjectState private var limited: Bool
    init(store: TodoStore, initial: LifeProject) {
        self.store = store; self.initial = initial
        _draft = State(initialValue: initial); _budget = State(initialValue: initial.estimatedMinutes != nil)
        _budgetHours = State(initialValue: Double(initial.estimatedMinutes ?? 1200) / 60)
        _hasOutcome = State(initialValue: initial.outcomeTarget != nil)
        _fixed = State(initialValue: initial.defaultStartMinute != nil); _limited = State(initialValue: initial.reminderLeadDays != nil)
    }
    private var value: LifeProject {
        var result = draft
        result.estimatedMinutes = budget && budgetHours.isFinite && (0.02...16666).contains(budgetHours) ? Int((budgetHours * 60).rounded()) : nil
        result.defaultStartMinute = fixed ? (draft.defaultStartMinute ?? 540) : nil
        result.outcomeTarget = hasOutcome ? (draft.outcomeTarget ?? 10000) : nil
        result.reminderLeadDays = limited ? (draft.reminderLeadDays ?? 14) : nil
        return result
    }
    private var valid: Bool { value.valid && (!budget || (budgetHours.isFinite && (0.02...16666).contains(budgetHours))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("给目标，安排一点每天。").font(.system(size: 24, weight: .semibold, design: .rounded))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("项目名称，例如备考、论文或作品集", text: $draft.title).textFieldStyle(.roundedBorder).accessibilityLabel("项目名称")
                    HStack {
                        DatePicker("开始", selection: Binding(get: { Day.date(draft.startDay) ?? Date() }, set: { draft.startDay = Day.key($0) }), displayedComponents: .date)
                        DatePicker("目标日期", selection: Binding(get: { Day.date(draft.dueDay) ?? Date() }, set: { draft.dueDay = Day.key($0) }), displayedComponents: .date)
                    }.datePickerStyle(.field).environment(\.locale, Locale(identifier: "zh_CN"))
                    if draft.dueDay < draft.startDay || draft.dueDay > Day.adding(1095, to: draft.startDay) { Text("目标日期需晚于或等于开始日期，最长三年。").foregroundColor(Palette.accent) }
                    HStack { Text("每天计划"); TextField("分钟", value: $draft.dailyMinutes, format: .number).frame(width: 70).textFieldStyle(.roundedBorder); Text("分钟，可在每天的详情里单独调整。").foregroundColor(Palette.secondary) }
                    HStack(spacing: 7) {
                        ForEach(Array(zip([2,3,4,5,6,7,1], ["一","二","三","四","五","六","日"])), id: \.0) { day, title in
                            Button("周" + title) { if draft.weekdays.contains(day) { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) } }
                                .buttonStyle(.bordered).tint(draft.weekdays.contains(day) ? Palette.accent : Palette.secondary)
                        }
                    }
                    Toggle("默认安排到具体时段", isOn: $fixed)
                    if fixed {
                        DatePicker("开始时间", selection: Binding(get: { ClockText.date(Day.today, draft.defaultStartMinute ?? 540)! }, set: { draft.defaultStartMinute = ClockText.minuteNow($0) }), displayedComponents: .hourAndMinute).datePickerStyle(.field)
                        if (draft.defaultStartMinute ?? 540) + draft.dailyMinutes > 1440 { Text("默认时段不能超过当天 24:00，请缩短或分日安排。").foregroundColor(Palette.accent) }
                    }
                    Text("未指定时段时，当天可分几次完成。目标日期当天也计入计划；如需休息，可在每日计划中设为 0 分钟。")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这份计划，能积累多少？").fontWeight(.medium)
                        Text("\(value.days.filter { value.plan(on: $0).minutes > 0 }.count) 个投入日 · 合计 \(ClockText.duration(value.plannedMinutes()))")
                            .font(.system(size: 19, weight: .medium, design: .rounded)).foregroundColor(Palette.accent)
                        if !draft.overrides.isEmpty { Text("已保留 \(draft.overrides.count) 天的单独安排；修改默认节奏不会覆盖它们。").font(.system(size: 10)).foregroundColor(Palette.secondary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    Toggle("预估项目总投入", isOn: $budget)
                    if budget { HStack { TextField("小时", value: $budgetHours, format: .number).frame(width: 80).textFieldStyle(.roundedBorder); Text("小时；用于比较安排，不代表成果已完成。") } }
                    Toggle("记录成果数量", isOn: $hasOutcome)
                    if hasOutcome {
                        HStack {
                            Text("目标"); TextField("数量", value: Binding(get: { draft.outcomeTarget ?? 10000 }, set: { draft.outcomeTarget = $0 }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder)
                            TextField("单位：字、章、题…", text: $draft.outcomeUnit).textFieldStyle(.roundedBorder)
                        }
                    }
                    Divider()
                    Toggle("每天提醒我投入这个项目", isOn: $draft.reminderEnabled)
                    if draft.reminderEnabled {
                        DatePicker("提醒时间", selection: Binding(get: { ClockText.date(Day.today, draft.reminderMinute)! }, set: { draft.reminderMinute = ClockText.minuteNow($0) }), displayedComponents: .hourAndMinute).datePickerStyle(.field)
                        Toggle("只在临近目标时提醒", isOn: $limited)
                        if limited { Stepper("提前 \(draft.reminderLeadDays ?? 14) 天开始", value: Binding(get: { draft.reminderLeadDays ?? 14 }, set: { draft.reminderLeadDays = $0 }), in: 0...1095) }
                        Text("默认从项目开始日提醒。倒计时始终可见；需在“每日计划与记录”中开启系统通知。").font(.system(size: 10)).foregroundColor(Palette.secondary)
                    }
                    Toggle("项目已完成（历史投入仍保留）", isOn: $draft.completed)
                }.font(.system(size: 12)).padding(.trailing, 6)
            }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存项目") { if store.upsertProject(value) { dismiss() } }.buttonStyle(PrimaryActionStyle()).disabled(!valid) }
        }.padding(26).frame(width: 600, height: 710).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.accent)
    }
}

struct ProjectDetailView: View {
    @ObservedObject var store: TodoStore
    let id: UUID
    @ObservedObject private var clock = FocusClock.shared
    @Environment(\.dismiss) private var dismiss
    @ProjectState private var selectedDay = Day.today
    @ProjectState private var planEditor: ProjectDaySelection?
    @ProjectState private var taskEditor: EditorItem?
    @ProjectState private var outcome = 0
    private var project: LifeProject? { store.projects.first { $0.id == id } }
    private var milestones: [Todo] {
        store.tasks.filter { $0.projectID == id }.sorted {
            if $0.completed != $1.completed { return !$0.completed }
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.title < $1.title
        }
    }
    private var recentLogs: [FocusLog] {
        Array(clock.logs.filter { $0.projectID == id }.suffix(30).reversed())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let project {
                ScrollView { contents(project).padding(.trailing, 6) }
            }
        }.padding(26).frame(width: 730, height: 720).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.accent)
            .onAppear { if let p = project { selectedDay = min(max(Day.today, p.startDay), p.dueDay); outcome = p.outcomeProgress } }
            .sheet(item: $planEditor) { ProjectDayEditor(store: store, selection: $0) }
            .sheet(item: $taskEditor) { item in TaskEditor(store: store, item: item) { _ in } }
    }
    private var header: some View {
        HStack {
            Text(project?.title ?? "项目记录").font(.system(size: 23, weight: .semibold, design: .rounded))
            Spacer()
            Button("关闭") { dismiss() }
        }
    }
    private func contents(_ project: LifeProject) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(project.countdown() + " · 累计投入 " + ClockText.duration(clock.projectSeconds(id) / 60)).foregroundColor(Palette.accent)
            Text("剩余计划 \(ClockText.duration(project.plannedMinutes(from: Day.today))) · 修改未来计划不会改变已投入时间。")
                .font(.system(size: 11)).foregroundColor(Palette.secondary)
            scheduleSection(project)
            outcomeSection(project)
            milestoneSection(project)
            Divider()
            historySection
            reminderSection
        }
    }
    private func scheduleSection(_ project: LifeProject) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                DatePicker("选择日期", selection: Binding(get: { Day.date(selectedDay)! }, set: { selectedDay = Day.key($0) }), in: Day.date(project.startDay)!...Day.date(project.dueDay)!, displayedComponents: .date).datePickerStyle(.field)
                Button("调整这一天") { planEditor = ProjectDaySelection(projectID: id, day: selectedDay) }
            }.environment(\.locale, Locale(identifier: "zh_CN"))
            Text("每天的安排与实际投入").font(.system(size: 15, weight: .medium))
            LazyVStack(spacing: 0) {
                ForEach(Array(project.days.filter { $0 >= selectedDay }.prefix(21)), id: \.self) { day in
                    dayRow(day, project: project)
                    Divider().opacity(0.4)
                }
            }
        }
    }
    private func planDescription(_ plan: ProjectDayPlan) -> String {
        guard plan.minutes > 0 else { return "休息 / 不安排" }
        let timing = plan.startMinute.map { " · " + ClockText.minute($0) + "–" + ClockText.minute($0 + plan.minutes) } ?? " · 灵活完成"
        return "计划 " + ClockText.duration(plan.minutes) + timing
    }
    private func dayRow(_ day: String, project: LifeProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(Day.formatted(day, "M月d日 EEE")).font(.system(size: 12, weight: .medium))
                Text(planDescription(project.plan(on: day))).font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            Spacer()
            Text("实际 " + ClockText.duration(clock.projectSeconds(id, on: day) / 60)).font(.system(size: 11)).foregroundColor(Palette.green)
            Button("调整") { planEditor = ProjectDaySelection(projectID: id, day: day) }.font(.system(size: 11))
        }.padding(.vertical, 12)
    }
    @ViewBuilder private func outcomeSection(_ project: LifeProject) -> some View {
        if let target = project.outcomeTarget {
            HStack {
                Text("成果进度")
                TextField("已完成", value: $outcome, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("/ \(target) \(project.outcomeUnit)")
                Button("记录成果") {
                    if var latest = self.project { latest.outcomeProgress = outcome; _ = store.upsertProject(latest) }
                }.disabled(!(0...1_000_000_000).contains(outcome))
            }
        }
    }
    private func milestoneSection(_ project: LifeProject) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("项目节点").font(.system(size: 15, weight: .medium))
                Spacer()
                Button("添加节点") {
                    var task = Todo(title: "", day: project.dueDay)
                    task.kind = .deadline; task.projectID = id
                    taskEditor = EditorItem(task: task, day: task.day)
                }
            }
            ForEach(milestones) { task in milestoneRow(task) }
        }
    }
    private func milestoneRow(_ task: Todo) -> some View {
        HStack {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.plain)
            Button(task.title) { taskEditor = EditorItem(task: task, day: task.day) }.buttonStyle(.plain).strikethrough(task.completed)
            Spacer()
            Text(task.dateLabel).font(.system(size: 10)).foregroundColor(Palette.secondary)
        }
    }
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("最近的专注记录").font(.system(size: 15, weight: .medium))
            ForEach(recentLogs) { log in
                HStack {
                    Text(Day.formatted(log.day, "M月d日"))
                    Text(log.title).lineLimit(1)
                    Spacer()
                    Text(ClockText.duration(log.seconds / 60))
                }.font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            if recentLogs.isEmpty {
                Text("第一次专注后，记录会留在这里。运行中的投入会实时显示在项目卡片。")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
        }
    }
    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !clock.notificationsEnabled && clock.canRequestNotifications {
                Button("开启项目、时段与专注提醒") { clock.requestNotifications() }
            }
            Text("系统项目提醒只安排最近的三个提醒时间；保持应用运行或定期打开，会续排后续提醒。当天投入达到目标后会撤回尚未发送的当天提醒。")
                .font(.system(size: 10)).foregroundColor(Palette.secondary)
            if !clock.message.isEmpty { Text(clock.message).font(.system(size: 11)).foregroundColor(Palette.green) }
        }
    }
}

struct ProjectDaySelection: Identifiable {
    var projectID: UUID
    var day: String
    var id: String { projectID.uuidString + day }
}

struct ProjectDayEditor: View {
    @ObservedObject var store: TodoStore
    let selection: ProjectDaySelection
    @Environment(\.dismiss) private var dismiss
    @ProjectState private var minutes: Int
    @ProjectState private var fixed: Bool
    @ProjectState private var start: Date
    @ProjectState private var message = ""
    init(store: TodoStore, selection: ProjectDaySelection) {
        self.store = store; self.selection = selection
        let plan = store.projects.first { $0.id == selection.projectID }?.plan(on: selection.day) ?? ProjectDayPlan(minutes: 0)
        _minutes = State(initialValue: plan.minutes); _fixed = State(initialValue: plan.startMinute != nil)
        _start = State(initialValue: ClockText.date(Day.today, plan.startMinute ?? 540)!)
    }
    private var plan: ProjectDayPlan { ProjectDayPlan(minutes: minutes, startMinute: fixed ? ClockText.minuteNow(start) : nil) }
    private var project: LifeProject? { store.projects.first { $0.id == selection.projectID } }
    private var candidate: TimeBlock {
        var block = store.timeBlocks.first { $0.projectID == selection.projectID && $0.projectPlanDay == selection.day && $0.day == selection.day && !$0.completed }
            ?? TimeBlock(title: project?.title ?? "项目投入", day: selection.day, startMinute: 540, endMinute: 541)
        block.title = project?.title ?? "项目投入"; block.startMinute = plan.startMinute ?? 540
        block.endMinute = block.startMinute + minutes; block.projectID = selection.projectID; block.projectPlanDay = selection.day
        return block
    }
    private var conflicts: [BusyInterval] {
        PlanningEngine.conflicts(candidate, tasks: store.tasks, blocks: store.timeBlocks.filter { $0.id != candidate.id })
            + ProjectEngine.busy(store.projects, on: selection.day, excluding: selection.projectID).filter { $0.start < candidate.endMinute && $0.end > candidate.startMinute }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("给这一天，调整一点节奏。").font(.system(size: 22, weight: .semibold, design: .rounded))
            Text((project?.title ?? "") + " · " + Day.formatted(selection.day, "M月d日 EEEE")).foregroundColor(Palette.secondary)
            HStack { Text("计划投入"); TextField("分钟", value: $minutes, format: .number).frame(width: 85).textFieldStyle(.roundedBorder); Text("分钟；0 表示休息") }
            Toggle("安排具体时段", isOn: $fixed)
            if fixed { DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute).datePickerStyle(.field) }
            Text("已实际投入 " + ClockText.duration(FocusClock.shared.projectSeconds(selection.projectID, on: selection.day) / 60) + "；调整计划不会修改这些记录。")
                .font(.system(size: 11)).foregroundColor(Palette.secondary)
            if !plan.valid { Text("请输入 0–1440 分钟，具体时段需在当天结束。").foregroundColor(Palette.accent) }
            if fixed && minutes > 0 && !conflicts.isEmpty {
                Text("与现有安排重叠：" + conflicts.prefix(3).map(\.title).joined(separator: "、") + "。请调整后再加入时间轴。")
                    .font(.system(size: 11)).foregroundColor(Palette.accent)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(Palette.green) }
            HStack {
                Button("恢复默认安排") { if store.setProjectPlan(selection.projectID, day: selection.day, plan: nil) { dismiss() } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存这一天") { if store.setProjectPlan(selection.projectID, day: selection.day, plan: plan) { dismiss() } }.buttonStyle(PrimaryActionStyle()).disabled(!plan.valid)
            }
            if fixed && minutes > 0 {
                Button("保存并加入当天时间轴") {
                    if store.setProjectPlan(selection.projectID, day: selection.day, plan: plan, schedule: true) { dismiss() }
                    else { message = "未能保存安排，请检查数据文件权限。" }
                }.disabled(!plan.valid || !conflicts.isEmpty)
            }
        }.font(.system(size: 12)).padding(26).frame(width: 570).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.accent)
    }
}

struct ProjectDayStrip: View {
    @ObservedObject var store: TodoStore
    var day: String
    @ObservedObject private var clock = FocusClock.shared
    @ProjectState private var editing: ProjectDaySelection?
    var body: some View {
        let projects = store.projects.filter { !$0.completed && $0.plan(on: day).minutes > 0 }
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                Text("今天，为长远的目标留一点时间。").font(.system(size: 12, weight: .medium))
                ForEach(projects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.title).font(.system(size: 12, weight: .medium))
                            let plan = project.plan(on: day)
                            Text("投入 \(ClockText.duration(clock.projectSeconds(project.id, on: day) / 60)) / \(ClockText.duration(plan.minutes))" + (plan.startMinute.map { " · " + ClockText.minute($0) + "–" + ClockText.minute($0 + plan.minutes) } ?? " · 灵活完成"))
                                .font(.system(size: 10)).foregroundColor(Palette.secondary)
                        }
                        Spacer()
                        Button("调整") { editing = ProjectDaySelection(projectID: project.id, day: day) }
                        Button("专注") { _ = clock.start(title: project.title, projectID: project.id) }.disabled(day != Day.today || clock.session != nil)
                    }
                    if let start = project.plan(on: day).startMinute {
                        let end = start + project.plan(on: day).minutes
                        let other = PlanningEngine.busy(on: day, tasks: store.tasks, blocks: store.timeBlocks.filter { $0.projectID != project.id }) + ProjectEngine.busy(store.projects, on: day, excluding: project.id)
                        if other.contains(where: { $0.start < end && $0.end > start }) {
                            Text("这个项目时段与其他安排重叠，可点调整重新安排。").font(.system(size: 10)).foregroundColor(Palette.accent)
                        }
                    }
                }
            }.padding(17).background(Palette.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
                .sheet(item: $editing) { ProjectDayEditor(store: store, selection: $0) }
        }
    }
}

struct ProjectNoteStrip: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var clock = FocusClock.shared
    var lightText: Bool
    var open: () -> Void
    var body: some View {
        let projects = store.projects.filter { !$0.completed }.sorted { $0.dueDay < $1.dueDay }
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(projects.prefix(2))) { project in
                    Button(action: open) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.title + " · " + project.countdown()).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            let today = clock.projectSeconds(project.id, on: Day.today) / 60
                            let target = project.plan(on: Day.today).minutes
                            Text((target > 0 ? "今天 \(today) / \(target) 分钟" : "今日不设投入量") + " · 累计 \(ClockText.duration(clock.projectSeconds(project.id) / 60))").font(.system(size: 9)).lineLimit(1).opacity(0.75)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }.foregroundColor(lightText ? .white : Palette.ink).padding(.horizontal, 18).padding(.vertical, 10)
        }
    }
}
