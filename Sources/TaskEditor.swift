import SwiftUI

private typealias EditorState<Value> = SwiftUI.State<Value>

struct TaskEditor: View {
    @ObservedObject var store: TodoStore
    let item: EditorItem
    let onSaved: (Todo) -> Void
    @Environment(\.dismiss) private var dismiss
    @EditorState private var title: String
    @EditorState private var date: Date
    @EditorState private var lastDate: Date
    @EditorState private var multiDay: Bool
    @EditorState private var hasTime: Bool
    @EditorState private var hasEnd: Bool
    @EditorState private var start: Date
    @EditorState private var end: Date
    @EditorState private var notes: String
    @EditorState private var link: String
    @EditorState private var categoryID: String
    @EditorState private var kind: PlanKind
    @EditorState private var importance: Int
    @EditorState private var estimate: Int
    @EditorState private var hasEstimate: Bool
    @EditorState private var showCategories = false
    @EditorState private var baseline: Todo?
    @EditorState private var restoringCalendar = false
    @FocusState private var titleFocused: Bool

    init(store: TodoStore, item: EditorItem, onSaved: @escaping (Todo) -> Void) {
        self.store = store; self.item = item; self.onSaved = onSaved
        let task = item.task
        _baseline = State(initialValue: task)
        _title = State(initialValue: task?.title ?? "")
        _date = State(initialValue: Day.date(item.day) ?? Date())
        _lastDate = State(initialValue: Day.date(task?.lastDay ?? item.day) ?? Date())
        _multiDay = State(initialValue: task.map { $0.lastDay > $0.day } ?? false)
        _hasTime = State(initialValue: task?.startMinute != nil); _hasEnd = State(initialValue: task?.endMinute != nil)
        _start = State(initialValue: ClockText.date(Day.today, task?.startMinute ?? 600)!)
        _end = State(initialValue: ClockText.date(Day.today, task?.endMinute ?? 660)!)
        _notes = State(initialValue: task?.notes ?? ""); _link = State(initialValue: task?.link ?? "")
        _categoryID = State(initialValue: task?.categoryID ?? ""); _kind = State(initialValue: task?.resolvedKind ?? .task)
        _importance = State(initialValue: task?.importance ?? 1)
        _estimate = State(initialValue: task?.estimatedMinutes ?? 50); _hasEstimate = State(initialValue: task?.estimatedMinutes != nil)
    }
    private var synced: Bool { item.task?.calendarSource != nil }
    private var spans: Bool { multiDay && Day.key(lastDate) > Day.key(date) }
    private var invalidTime: Bool { hasTime && hasEnd && !spans && ClockText.minuteNow(end) <= ClockText.minuteNow(start) }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 2000 && notes.count <= 100_000
        && !invalidTime && (!multiDay || (Day.key(lastDate) >= Day.key(date) && Day.key(lastDate) <= Day.adding(366, to: Day.key(date))))
        && (!hasEstimate || (5...1440).contains(estimate)) && (link.isEmpty || WebLink.safe(link) != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(synced ? "日历里的这件事。" : "给未来，留一个位置。")
                        .font(.system(size: 23, weight: .medium, design: .serif))
                    Text(synced ? "可以修改时间和内容；修正保存在本机，提醒跟随新时间。" : "这里记节点与活动；每天做多少，可以另外安排时间块。")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if synced {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(restoringCalendar ? "保存后恢复日历同步" : (item.task?.calendarEdits == nil ? "来自日历 · 可在这里编辑" : "已在本机修正"), systemImage: "calendar.badge.pencil")
                                .foregroundColor(Palette.pink)
                            Text("改过的字段以本机为准，其余内容继续同步。不会修改原日历。")
                                .font(.system(size: 10)).foregroundColor(Palette.secondary)
                            if item.task?.calendarEdits != nil && !restoringCalendar {
                                Button("恢复日历版本", action: restoreCalendarVersion).font(.system(size: 11))
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.blush.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    }
                    TextField("要完成或参加什么？", text: $title, axis: .vertical)
                        .lineLimit(2...4).font(.system(size: 14)).textFieldStyle(.plain)
                        .padding(13).background(.white, in: RoundedRectangle(cornerRadius: 9)).focused($titleFocused)
                        .accessibilityLabel("事项内容")
                    Picker("性质", selection: $kind) {
                        ForEach(PlanKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(item.task?.canvasSource?.isDeadline == true)
                    HStack {
                        Picker("分类", selection: $categoryID) {
                            Text("未分类").tag("")
                            ForEach(store.categories) { Text($0.name).tag($0.id) }
                        }
                        Button("管理分类…") { showCategories = true }.font(.system(size: 10))
                    }
                    Picker("优先级", selection: $importance) {
                        Text("稍后").tag(0); Text("普通").tag(1); Text("重要").tag(2); Text("优先").tag(3)
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 13) {
                        DatePicker(kind == .deadline ? "截止日期" : "开始日期", selection: $date, displayedComponents: .date).datePickerStyle(.field)
                        if kind != .deadline {
                            Toggle("跨天 / 多日活动", isOn: $multiDay).toggleStyle(.checkbox)
                            if multiDay {
                                DatePicker("结束日期（包含这天）", selection: $lastDate, displayedComponents: .date).datePickerStyle(.field)
                                if Day.key(lastDate) < Day.key(date) || Day.key(lastDate) > Day.adding(366, to: Day.key(date)) {
                                    Text("结束日期需在开始日期之后，单次行程最多 367 天。").foregroundColor(Palette.pink)
                                }
                            }
                        }
                        Toggle(kind == .deadline ? "具体截止时刻" : "具体时间", isOn: $hasTime).toggleStyle(.switch)
                        if hasTime {
                            HStack {
                                DatePicker(kind == .deadline ? "截止" : "开始", selection: $start, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                                if kind != .deadline { Toggle("结束", isOn: $hasEnd).toggleStyle(.checkbox) }
                            }
                            if hasEnd && kind != .deadline { DatePicker("结束时刻", selection: $end, displayedComponents: .hourAndMinute).datePickerStyle(.field) }
                            if invalidTime { Text("同一天的结束时刻需晚于开始时刻。").foregroundColor(Palette.pink) }
                        }
                    }.environment(\.locale, Locale(identifier: "zh_CN"))
                    if kind != .rest {
                        HStack {
                            Toggle("预计需要", isOn: $hasEstimate).toggleStyle(.checkbox)
                            if hasEstimate {
                                TextField("分钟", value: $estimate, format: .number).textFieldStyle(.roundedBorder).frame(width: 65)
                                Text("分钟工作时间").foregroundColor(Palette.secondary)
                            }
                        }
                    }
                    TextField("活动链接 / 网址（可选）", text: $link).textFieldStyle(.roundedBorder)
                    TextField("备注、地址、会议号…", text: $notes, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    if kind == .deadline { Text("提前三天突出提醒，今天、两小时内及半小时内逐级弹出。未填写时刻时只按日期提醒，不会猜测 23:59。准备工作可另排时间块。").font(.system(size: 10)).foregroundColor(Palette.secondary) }
                }.font(.system(size: 12)).padding(.trailing, 5)
            }
            HStack {
                Text("完成后仍然保留划线内容。").font(.system(size: 10)).foregroundColor(Palette.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存事项", action: save).buttonStyle(.borderedProminent).tint(Palette.pink).disabled(!valid)
            }
        }.padding(26).frame(width: 530, height: 700).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
            .onAppear { titleFocused = !synced }
            .onChange(of: kind) { _, value in if value == .deadline { multiDay = false; hasEnd = false } }
            .sheet(isPresented: $showCategories) { CategoryManagerView(store: store) }
            .onChange(of: store.categories) { _, _ in if store.category(categoryID) == nil { categoryID = "" } }
    }
    private func restoreCalendarVersion() {
        guard var task = item.task,
              let current = store.tasks.first(where: { $0.id == task.id }),
              let source = current.calendarEdits?.source else { return }
        source.apply(to: &task)
        baseline = task
        title = task.title; date = Day.date(task.day)!
        lastDate = Day.date(task.lastDay)!; multiDay = task.lastDay > task.day
        hasTime = task.startMinute != nil; hasEnd = task.endMinute != nil
        start = ClockText.date(Day.today, task.startMinute ?? 600)!
        end = ClockText.date(Day.today, task.endMinute ?? 660)!
        notes = task.notes ?? ""; link = task.link ?? ""
        restoringCalendar = true
    }
    private func save() {
        guard valid else { return }
        var task = item.task ?? Todo(title: "", day: item.day)
        task.title = title; task.day = Day.key(date)
        task.endDay = multiDay && kind != .deadline ? Day.key(lastDate) : nil
        task.startMinute = hasTime ? ClockText.minuteNow(start) : nil
        task.endMinute = hasTime && hasEnd && kind != .deadline ? ClockText.minuteNow(end) : nil
        task.kind = kind; task.notes = notes.isEmpty ? nil : notes; task.link = WebLink.safe(link)?.absoluteString
        task.categoryID = categoryID.isEmpty ? nil : categoryID; task.importance = importance
        task.estimatedMinutes = hasEstimate ? estimate : nil
        if store.saveEdits(task, original: baseline, restoreCalendar: restoringCalendar),
           let saved = store.tasks.first(where: { $0.id == task.id }) { onSaved(saved); dismiss() }
    }
}
