import SwiftUI

private typealias PlanState<Value> = SwiftUI.State<Value>

private struct AgendaItem: Identifiable {
    var block: TimeBlock?
    var task: Todo?
    var day: String
    var id: String { block?.id.uuidString ?? task!.id.uuidString }
    var start: Int { block?.startMinute ?? task?.start(on: day) ?? 0 }
    var end: Int? { block?.endMinute ?? task?.end(on: day) }
    var title: String { block?.title ?? task?.title ?? "" }
    var categoryID: String? { block?.categoryID ?? task?.categoryID }
    var completed: Bool { block?.completed ?? task?.completed ?? false }
}

struct DailyPlannerView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var focus = FocusClock.shared
    let day: String
    let onDay: (String) -> Void
    let onEdit: (Todo) -> Void
    let onAddTask: () -> Void
    @PlanState private var editor: BlockEditorItem?
    @PlanState private var selectedBlock: UUID?
    @PlanState private var removed: TimeBlock?
    @PlanState private var categories = false
    @PlanState private var filter = ""

    private var blocks: [TimeBlock] { store.blocks(on: day) }
    private var tasks: [Todo] { store.tasks(on: day) }
    private var agenda: [AgendaItem] {
        let items = blocks.map { AgendaItem(block: $0, day: day) } + tasks.filter { $0.start(on: day) != nil && $0.resolvedKind != .deadline }.map { AgendaItem(task: $0, day: day) }
        return items.filter { filter.isEmpty || $0.categoryID == filter }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
    private var points: [Todo] { tasks.filter { ($0.resolvedKind == .deadline || $0.start(on: day) == nil) && (filter.isEmpty || $0.categoryID == filter) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                header
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 18) {
                        if !points.isEmpty { dayPoints }
                        HStack {
                            Text("把今天，分成能完成的小段。 ").font(.system(size: 14, weight: .medium))
                            Spacer()
                            Picker("分类", selection: $filter) {
                                Text("所有分类").tag(""); ForEach(store.categories) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(width: 120)
                        }
                        if agenda.isEmpty {
                            VStack(alignment: .leading, spacing: 13) {
                                Text("还没有时间安排。 ").font(.system(size: 16, weight: .medium))
                                Text("例如 10:00–10:15 起床，11:00–12:00 做作业，13:00–18:00 组装硬件，也记得给午饭和休息留位置。")
                                    .font(.system(size: 12)).foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("安排第一个时间块") { editor = BlockEditorItem(day: day) }
                                    .buttonStyle(.borderedProminent).tint(Palette.pink)
                            }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                VStack(spacing: 10) {
                                    ForEach(Array(agenda.enumerated()), id: \.element.id) { index, item in
                                        if index > 0, let end = agenda.prefix(index).compactMap(\.end).max(), item.start > end {
                                            HStack {
                                                Text("\(ClockText.minute(end)) – \(ClockText.minute(item.start))")
                                                    .font(.system(size: 9, design: .monospaced)).frame(width: 86, alignment: .leading)
                                                Text("\(ClockText.duration(item.start - end)) 留白 · 吃饭、走动，或留作缓冲")
                                                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                                                Spacer()
                                            }.foregroundColor(Palette.secondary).padding(.vertical, 8)
                                        }
                                        agendaRow(item, now: context.date)
                                    }
                                }
                            }
                        }
                        Button { editor = BlockEditorItem(day: day) } label: {
                            Label("再加一段，包括休息", systemImage: "plus").font(.system(size: 11))
                                .frame(maxWidth: .infinity).padding(14)
                                .background(Palette.blush.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).foregroundColor(Palette.pink)
                        if let removed {
                            HStack {
                                Text("已移除「\(removed.title)」").lineLimit(1)
                                Spacer()
                                Button("撤销") { _ = store.upsertBlock(removed); self.removed = nil }
                            }.font(.system(size: 11)).padding(12).background(Palette.blush, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        FocusPane(blocks: blocks, day: day, selectedBlock: $selectedBlock)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("有安排，也有余地。").font(.system(size: 12, weight: .medium))
                            Text("已排 \(ClockText.duration(blocks.reduce(0) { $0 + $1.duration }))\n其中休息 \(ClockText.duration(blocks.filter(\.isRest).reduce(0) { $0 + $1.duration }))\n完成 \(blocks.filter(\.completed).count) / \(blocks.count) 个时间块")
                                .font(.system(size: 11)).lineSpacing(6).foregroundColor(Palette.secondary)
                            Text("重叠安排会提示；空白时间可以用来休息，不必填满。")
                                .font(.system(size: 10)).foregroundColor(Palette.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    }.frame(width: 270)
                }
            }.padding(28)
        }.background(Palette.paper)
            .sheet(item: $editor) { BlockEditor(store: store, item: $0) }
            .sheet(isPresented: $categories) { CategoryManagerView(store: store) }
            .onAppear { selectedBlock = blocks.first { !$0.isRest && !$0.completed && $0.startMinute <= ClockText.minuteNow() && $0.endMinute > ClockText.minuteNow() }?.id }
            .onChange(of: day) { _, _ in selectedBlock = nil; filter = "" }
            .onChange(of: blocks) { _, value in if !value.contains(where: { $0.id == selectedBlock && !$0.completed && !$0.isRest }) { selectedBlock = nil } }
            .onChange(of: store.categories) { _, _ in if store.category(filter) == nil { filter = "" } }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    Text("A DAY WITH RHYTHM").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundColor(Palette.pink)
                    Text(day == Day.today ? "今天，有条不紊地过。" : "为这一天，排一点节奏。")
                        .font(.system(size: 27, weight: .medium, design: .serif))
                    Text("先看节点，再安排时间；专注一会儿，也好好休息。")
                        .font(.system(size: 12)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button("新事项", action: onAddTask)
                Button("安排时间") { editor = BlockEditorItem(day: day) }.buttonStyle(.borderedProminent).tint(Palette.pink)
            }
            HStack(spacing: 13) {
                Text(Day.formatted(day, "M 月 d 日 · EEEE")).font(.system(size: 13, weight: .medium))
                Button { onDay(Day.adding(-1, to: day)) } label: { Image(systemName: "chevron.left") }.help("前一天")
                Button { onDay(Day.adding(1, to: day)) } label: { Image(systemName: "chevron.right") }.help("后一天")
                if day != Day.today { Button("回到今天") { onDay(Day.today) } }
                Spacer()
                Button("管理分类") { categories = true }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Palette.secondary)
        }
    }
    private var dayPoints: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这一天的节点与事项").font(.system(size: 11, weight: .medium)).foregroundColor(Palette.secondary)
            ForEach(points) { task in
                HStack(alignment: .top, spacing: 9) {
                    Button { store.toggle(task.id) } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").foregroundColor(task.completed ? Palette.green : Palette.secondary) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Button { onEdit(task) } label: { Text(task.title).strikethrough(task.completed).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        HStack { CategoryBadge(category: store.category(task.categoryID)); Text(task.timeLabel ?? (task.lastDay > task.day ? task.dateLabel : task.resolvedKind.rawValue)).foregroundColor(Palette.pink) }.font(.system(size: 9))
                    }
                    Spacer(minLength: 4)
                    if task.resolvedKind == .task || task.resolvedKind == .deadline {
                        Button("安排时间") { editor = BlockEditorItem(task: task, day: day) }.font(.system(size: 10))
                    }
                }.font(.system(size: 11))
            }
        }.padding(17).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
    }
    @ViewBuilder private func agendaRow(_ item: AgendaItem, now: Date) -> some View {
        let minute = ClockText.minuteNow(now)
        let active = day == Day.key(now) && item.start <= minute && item.end.map { minute < $0 } == true
        let color = Color(hex: store.category(item.categoryID)?.color ?? (item.block?.isRest == true ? 0x7E8C6D : 0xB35E70))
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ClockText.minute(item.start)).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                if let end = item.end { Text(ClockText.minute(end)).font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.secondary) }
                else { Text("时间点").font(.system(size: 9)).foregroundColor(Palette.secondary) }
                if active { Text("现在").font(.system(size: 9, weight: .medium)).foregroundColor(Palette.pink) }
            }.frame(width: 69, alignment: .leading).padding(.top, 11)
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if let block = item.block {
                            if !block.completed && focus.session?.blockID == block.id { focus.end() }
                            store.toggleBlock(block.id)
                        } else if let task = item.task { store.toggle(task.id) }
                    } label: { Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").foregroundColor(item.completed ? Palette.green : color) }.buttonStyle(.plain)
                    Text(item.title).font(.system(size: 13, weight: .medium)).strikethrough(item.completed).fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(item.completed ? Palette.secondary : Palette.ink)
                    Spacer(minLength: 0)
                    Menu {
                        Button("编辑") { if let block = item.block { editor = BlockEditorItem(block: block, day: day) } else if let task = item.task { onEdit(task) } }
                        if let block = item.block {
                            Button("移除时间块") {
                                if focus.session?.blockID == block.id { focus.end() }
                                store.removeBlock(block.id); removed = block
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                }
                HStack {
                    CategoryBadge(category: store.category(item.categoryID))
                    if let block = item.block {
                        Text(ClockText.duration(block.duration)).font(.system(size: 9)).foregroundColor(Palette.secondary)
                        Spacer()
                        if block.isRest { Label("好好休息", systemImage: "leaf").font(.system(size: 10)).foregroundColor(Palette.green) }
                        else if !block.completed && day == Day.today && block.endMinute > minute {
                            Button(focus.session?.blockID == block.id ? "正在计时" : "专注这段") {
                                selectedBlock = block.id
                                _ = focus.start(title: block.title, blockID: block.id, taskID: block.taskID, hardStop: ClockText.date(day, block.endMinute))
                            }.font(.system(size: 10)).disabled(focus.session != nil)
                        }
                    } else {
                        Text(item.task?.calendarEdits != nil ? "日历活动 · 本机修正" : (item.task?.calendarSource != nil ? "日历活动" : "事项中的时间")).font(.system(size: 9)).foregroundColor(Palette.secondary)
                        Spacer()
                    }
                }
                if let task = item.task { EventReminderStatus(task: task) }
                if let block = item.block {
                    if let linked = store.tasks.first(where: { $0.id == block.taskID }) {
                        Text("准备：\(linked.title) · \(linked.dateLabel)").font(.system(size: 9)).foregroundColor(Palette.secondary).lineLimit(2)
                    }
                    if let note = block.notes, !note.isEmpty { Text(note).font(.system(size: 10)).foregroundColor(Palette.secondary).lineLimit(2) }
                    if !PlanningEngine.conflicts(block, tasks: store.tasks, blocks: store.timeBlocks).isEmpty {
                        Label("这段与其他安排有重叠，可调整时间。", systemImage: "rectangle.on.rectangle").font(.system(size: 9)).foregroundColor(Palette.pink)
                    }
                }
            }.padding(15).frame(maxWidth: .infinity, minHeight: item.block.map { min(130, max(78, Double($0.duration) * 0.45)) } ?? 78, alignment: .topLeading)
                .background(color.opacity(item.completed ? 0.035 : 0.07), in: RoundedRectangle(cornerRadius: 11))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color.opacity(item.completed ? 0.3 : 0.8)).frame(width: 3).padding(.vertical, 9) }
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(active ? color.opacity(0.5) : .clear))
        }
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
                        Text("MAKE ROOM FOR WHAT MATTERS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundColor(Palette.pink)
                        Text("重要的节点，先看见。").font(.system(size: 28, weight: .medium, design: .serif))
                        Text("作业与 presentation、线上线下活动、展会与旅行，都放进自己的节奏里。")
                            .font(.system(size: 12)).foregroundColor(Palette.secondary)
                    }
                    Spacer()
                    Button("新节点 / 活动", action: onAdd).buttonStyle(.borderedProminent).tint(Palette.pink)
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
        }.background(Palette.paper)
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
                        Text(urgent.label).font(.system(size: 9)).foregroundColor(urgent.rank <= 2 ? Palette.pink : Palette.secondary)
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
        }.padding(15).frame(minHeight: 76).background(.white.opacity(priority ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}
