import SwiftUI

private typealias BlockState<Value> = SwiftUI.State<Value>

struct BlockEditorItem: Identifiable {
    var id = UUID()
    var block: TimeBlock?
    var task: Todo?
    var day: String
}

struct BlockEditor: View {
    @ObservedObject var store: TodoStore
    let item: BlockEditorItem
    @Environment(\.dismiss) private var dismiss
    @BlockState private var title: String
    @BlockState private var date: Date
    @BlockState private var start: Date
    @BlockState private var end: Date
    @BlockState private var midnight: Bool
    @BlockState private var categoryID: String
    @BlockState private var taskID: String
    @BlockState private var notes: String
    @BlockState private var rest: Bool
    @BlockState private var slotMessage = ""
    @BlockState private var categories = false

    init(store: TodoStore, item: BlockEditorItem) {
        self.store = store; self.item = item
        let after = item.day == Day.today ? max(540, ClockText.minuteNow()) : 540
        let duration = item.block?.duration ?? min(item.task?.estimatedMinutes ?? 50, 120)
        let slot = PlanningEngine.freeSlot(duration: duration, after: after,
            busy: PlanningEngine.busy(on: item.day, tasks: store.tasks, blocks: store.timeBlocks))
        let first = item.block?.startMinute ?? slot?.lowerBound ?? min(1380, ((after + 14) / 15) * 15)
        let last = item.block?.endMinute ?? slot?.upperBound ?? min(1440, first + duration)
        _title = State(initialValue: item.block?.title ?? item.task?.title ?? "")
        _date = State(initialValue: Day.date(item.day) ?? Date())
        _start = State(initialValue: ClockText.date(Day.today, first)!)
        _end = State(initialValue: ClockText.date(Day.today, last == 1440 ? 1439 : last)!)
        _midnight = State(initialValue: last == 1440)
        _categoryID = State(initialValue: item.block?.categoryID ?? item.task?.categoryID ?? "")
        _taskID = State(initialValue: item.block?.taskID?.uuidString ?? item.task?.id.uuidString ?? "")
        _notes = State(initialValue: item.block?.notes ?? "")
        _rest = State(initialValue: item.block?.isRest ?? (item.task?.resolvedKind == .rest || item.task?.categoryID == "rest"))
        _slotMessage = State(initialValue: item.block == nil && slot == nil ? "21:00 前暂无合适空档。当前时间仅作输入起点，请调整或换一天后保存。" : "")
    }
    private var block: TimeBlock {
        var value = item.block ?? TimeBlock(title: title, day: Day.key(date), startMinute: 0, endMinute: 1)
        value.title = title; value.day = Day.key(date); value.startMinute = ClockText.minuteNow(start)
        value.endMinute = midnight ? 1440 : ClockText.minuteNow(end)
        value.categoryID = categoryID.isEmpty ? nil : categoryID; value.taskID = UUID(uuidString: taskID)
        value.notes = notes.isEmpty ? nil : notes
        value.rest = rest
        return value
    }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 2000
        && block.endMinute > block.startMinute && notes.count <= 100_000
    }
    private var conflicts: [BusyInterval] { PlanningEngine.conflicts(block, tasks: store.tasks, blocks: store.timeBlocks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("这段时间，只做这件事。")
                    .font(.system(size: 23, weight: .medium, design: .serif))
                Text("安排工作、起床、活动或休息。工作时段与原来的截止节点分开保存。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    TextField("例如：课程项目原型制作", text: $title, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4).font(.system(size: 14))
                        .accessibilityLabel("时间块名称")
                    HStack {
                        Picker("分类", selection: $categoryID) {
                            Text("未分类").tag(""); ForEach(store.categories) { Text($0.name).tag($0.id) }
                        }
                        Button("管理分类…") { categories = true }.font(.system(size: 10))
                    }
                    Toggle("这是一段休息 / 放松时间", isOn: $rest).toggleStyle(.checkbox)
                    DatePicker("安排日期", selection: $date, displayedComponents: .date).datePickerStyle(.field)
                    HStack(spacing: 17) {
                        DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                        DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute).datePickerStyle(.field).disabled(midnight)
                    }
                    Toggle("到当天 24:00 结束", isOn: $midnight).toggleStyle(.checkbox)
                    HStack {
                        Text(block.duration > 0 ? "\(ClockText.duration(block.duration)) · 有开始，也有收尾" : "结束时间需晚于开始时间")
                            .foregroundColor(block.duration > 0 ? Palette.secondary : Palette.pink)
                        Spacer()
                        Button("找下个空档", action: findSlot)
                    }
                    if block.duration > 120 { Text("这段比较长，可分成多轮专注，并给自己留休息时间。").foregroundColor(Palette.secondary) }
                    Picker("关联事项", selection: $taskID) {
                        Text("独立安排，不关联事项").tag("")
                        ForEach(store.tasks.filter { !$0.completed || $0.id.uuidString == taskID }) { Text($0.title).lineLimit(1).tag($0.id.uuidString) }
                    }.onChange(of: taskID) { _, id in
                        if let task = store.tasks.first(where: { $0.id.uuidString == id }), item.block == nil {
                            title = task.title; categoryID = task.categoryID ?? ""
                        }
                    }
                    if let linked = store.tasks.first(where: { $0.id.uuidString == taskID }) {
                        Text("关联：\(linked.dateLabel) · \(linked.timeLabel ?? linked.resolvedKind.rawValue)。完成这段时间不会自动划掉原事项。")
                            .foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        if let estimate = linked.estimatedMinutes, estimate > block.duration {
                            Text("总计预计 \(ClockText.duration(estimate))，这次先安排其中一段；可以继续拆分安排。").foregroundColor(Palette.secondary)
                        }
                    }
                    if !conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("与已有安排重叠", systemImage: "rectangle.on.rectangle").foregroundColor(Palette.pink)
                            ForEach(Array(conflicts.prefix(4).enumerated()), id: \.offset) { _, overlap in
                                Text("\(ClockText.minute(overlap.start))–\(ClockText.minute(overlap.end))  \(overlap.title)")
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.blush.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !slotMessage.isEmpty { Text(slotMessage).foregroundColor(Palette.pink) }
                    TextField("这段时间想完成到什么程度？（可选）", text: $notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                }.font(.system(size: 11)).padding(.trailing, 5).environment(\.locale, Locale(identifier: "zh_CN"))
            }
            HStack {
                Text("专注计时会在时间块结束时收尾。").font(.system(size: 10)).foregroundColor(Palette.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(conflicts.isEmpty ? "保存时间块" : "保存（有重叠）") {
                    if store.upsertBlock(block) { FocusClock.shared.updateBlock(block); dismiss() }
                }.buttonStyle(.borderedProminent).tint(Palette.pink).disabled(!valid)
            }
        }.padding(26).frame(width: 560, height: 650).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
            .sheet(isPresented: $categories) { CategoryManagerView(store: store) }
            .onChange(of: categoryID) { _, value in if value == "rest" { rest = true } }
            .onChange(of: store.categories) { _, _ in if store.category(categoryID) == nil { categoryID = "" } }
    }
    private func findSlot() {
        let day = Day.key(date)
        let after = day == Day.today ? max(540, ClockText.minuteNow()) : 540
        let duration = max(5, block.duration)
        let busy = PlanningEngine.busy(on: day, tasks: store.tasks, blocks: store.timeBlocks, excluding: item.block?.id)
        if let range = PlanningEngine.freeSlot(duration: duration, after: after, busy: busy) {
            start = ClockText.date(Day.today, range.lowerBound)!; end = ClockText.date(Day.today, range.upperBound)!
            midnight = false; slotMessage = "已找到 09:00–21:00 范围内的下一个空档，请确认后保存。"
        } else { slotMessage = "今天 21:00 前没有这么长的完整空档；可以缩短这一段，或换一天。" }
    }
}
