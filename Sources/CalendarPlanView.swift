import SwiftUI
import AppKit

private typealias CalendarPlanState<Value> = SwiftUI.State<Value>
private enum CalendarPlanZoom: String, CaseIterable { case month = "整月总览", focus = "四天聚焦" }

struct CalendarPlanView: View {
    @ObservedObject var store: TodoStore
    @Binding var month: Date
    @Binding var selectedDay: String?
    let onAdd: (String) -> Void
    let onEdit: (Todo) -> Void
    let onDelete: (Todo) -> Void
    @CalendarPlanState private var zoom: CalendarPlanZoom = .month
    @CalendarPlanState private var query = ""
    @CalendarPlanState private var timeline = false
    @CalendarPlanState private var detailRequest = 0
    @CalendarPlanState private var gridRequest = 0
    @CalendarPlanState private var blockEditor: BlockEditorItem?
    @CalendarPlanState private var projectEditor: ProjectDaySelection?
    private var day: String { selectedDay ?? Day.today }
    private var monthKey: String { MonthPlanning.monthStart(Day.key(month)) }
    private var focusDays: [String] { (0..<4).map { Day.adding($0, to: day) } }
    private func entries(_ day: String) -> [MonthPlanning.Entry] {
        MonthPlanning.entries(on: day, tasks: store.tasks, blocks: store.timeBlocks, projects: store.projects, query: query)
    }
    var body: some View {
        GeometryReader { geometry in
            if timeline {
                VStack(spacing: 0) {
                    HStack {
                        Button { timeline = false } label: { Label("返回日期总览", systemImage: "arrow.left") }.buttonStyle(GlassButtonStyle())
                        Spacer()
                        Text("这几天 · 当天时间轴").font(.system(size: 12)).foregroundColor(Palette.secondary)
                    }.padding(.horizontal, 28).padding(.vertical, 12)
                    DailyPlannerView(store: store, day: day, onDay: select, onEdit: onEdit, onAddTask: { onAdd(day) })
                }
            } else {
                ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading.id("calendar-top")
                        toolbar
                        if zoom == .month {
                            if geometry.size.width >= 1180 {
                                HStack(alignment: .top, spacing: 20) {
                                    monthGrid(availableHeight: geometry.size.height)
                                    detail.frame(width: 310).id("selected-day")
                                }
                            } else {
                                monthGrid(availableHeight: geometry.size.height)
                                detail.id("selected-day")
                            }
                        } else {
                            focusGrid
                            detail.id("selected-day")
                        }
                    }.padding(28)
                }.quietScroll()
                    .onChange(of: detailRequest) { _, _ in
                        if geometry.size.width < 1180 { withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo("selected-day", anchor: .top) } }
                    }
                    .onChange(of: gridRequest) { _, _ in withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo("calendar-top", anchor: .top) } }
                }
            }
        }
        .sheet(item: $blockEditor) { BlockEditor(store: store, item: $0) }
        .sheet(item: $projectEditor) { ProjectDayEditor(store: store, selection: $0) }
        .onAppear { if selectedDay == nil { selectedDay = Day.today; month = Day.date(Day.today)! } }
    }
    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("这几天，也看远一点。").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("整月看轻重，选一天看细节；留白的日子，也可以慢慢安排。")
                    .font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
            Spacer()
            Picker("日期视角", selection: $zoom) {
                ForEach(CalendarPlanZoom.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 212)
        }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(zoom == .month ? Day.formatted(monthKey, "yyyy 年 M 月") : Day.formatted(day, "M月d日") + " — " + Day.formatted(focusDays[3], "M月d日"))
                .font(.system(size: 17, weight: .semibold, design: .rounded)).frame(minWidth: 155, alignment: .leading)
            Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(zoom == .month ? "总览上个月" : "聚焦前四天")
            Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(zoom == .month ? "总览下个月" : "聚焦后四天")
            Button("今天") { select(Day.today); query = "" }.buttonStyle(GlassButtonStyle(height: 30))
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.secondary)
                TextField("搜索安排", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除安排搜索")
                }
            }.font(.system(size: 11)).padding(9).frame(width: 160)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
            Button { onAdd(day) } label: { Label("新事项", systemImage: "plus") }.buttonStyle(PrimaryActionStyle())
        }.buttonStyle(.plain)
    }
    private func monthGrid(availableHeight: CGFloat) -> some View {
        let days = MonthPlanning.days(in: monthKey)
        let cellHeight = max(88, min(132, (availableHeight - 200) / CGFloat(max(1, days.count / 7))))
        let projection = Dictionary(uniqueKeysWithValues: days.map { ($0, entries($0)) })
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { label in
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.vertical, 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(days, id: \.self) { key in
                    MonthDayCell(day: key, inMonth: key.prefix(7) == monthKey.prefix(7), selected: key == day,
                                 entries: projection[key] ?? [], height: cellHeight, searching: !query.isEmpty, onSelect: { select(key); detailRequest += 1 }, onAdd: { select(key); onAdd(key) })
                }
            }.padding(1).background(Palette.line)
        }.background(Palette.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private var focusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 18)], spacing: 18) {
            ForEach(focusDays, id: \.self) { key in focusCard(key) }
        }
    }
    private func focusCard(_ key: String) -> some View {
        let items = entries(key)
        return VStack(alignment: .leading, spacing: 16) {
            Button { select(key); timeline = true } label: {
                HStack {
                    Text(Day.formatted(key, "dd")).font(.system(size: 30, design: .rounded))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Day.formatted(key, "EEEE"))
                        Text(Day.formatted(key, "M月")).foregroundColor(Palette.secondary)
                    }.font(.system(size: 11))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("展开当天时间轴")
            Divider()
            if items.isEmpty { Text(query.isEmpty ? "还没有安排，也可以留一点空白。" : "没有匹配的安排。")
                .font(.system(size: 11)).foregroundColor(Palette.secondary).padding(.vertical, 20) }
            ForEach(Array(items.prefix(6))) { item in entryRow(item, on: key) }
            if items.count > 6 { Button("查看全部 \(items.count) 项") { select(key); timeline = true }.font(.system(size: 11)) }
            Spacer(minLength: 0)
            Button { onAdd(key) } label: { Label("添加一件事", systemImage: "plus") }.font(.system(size: 11)).buttonStyle(.plain)
        }.padding(22).frame(maxWidth: .infinity, minHeight: 256, alignment: .topLeading)
            .background(Palette.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(key == Day.today ? Palette.accent.opacity(0.4) : Palette.line))
    }
    private var detail: some View {
        let items = entries(day)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Day.formatted(day, "M月d日 · EEEE")).font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(items.isEmpty ? (query.isEmpty ? "还没有安排，可以从一件小事开始。" : "当天没有匹配的安排。") : "\(items.count) 项安排 · \(items.filter { !$0.completed }.count) 项未完成")
                        .font(.system(size: 11)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { gridRequest += 1 } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).help("返回日期总览")
            }
            HStack {
                Button("添加事项") { onAdd(day) }
                Button("安排时间") { blockEditor = BlockEditorItem(day: day) }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).buttonStyle(.bordered)
            if !items.isEmpty {
                Divider()
                ForEach(items) { item in entryRow(item, on: day) }
            }
            Button { timeline = true } label: { Label("展开当天时间轴", systemImage: "arrow.up.left.and.arrow.down.right") }
                .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundColor(Palette.accent)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }
    private func entryRow(_ item: MonthPlanning.Entry, on key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if item.kind == .project {
                Image(systemName: "flag").foregroundColor(Palette.secondary).frame(width: 18).padding(.top, 2)
            } else {
                Button { toggle(item) } label: {
                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                }.buttonStyle(.plain).foregroundColor(Palette.secondary).accessibilityLabel((item.completed ? "恢复：" : "完成：") + item.title)
            }
            Button { edit(item, on: key) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).strikethrough(item.completed).multilineTextAlignment(.leading)
                    Text([item.time, item.kind == .project ? "项目投入" : (item.kind == .block ? "时间块" : "事项")].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundColor(item.deadline && !item.completed ? Palette.coralText : Palette.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(item.completed ? Palette.secondary : Palette.ink).help("编辑这项安排")
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(Palette.secondary)
        }.padding(.vertical, 4)
            .contextMenu {
                if item.kind == .task, let task = store.tasks.first(where: { $0.id == item.sourceID }) {
                    Button("编辑事项") { onEdit(task) }
                    Button(task.completed ? "标为未完成" : "标为已完成") { store.toggle(task.id) }
                    if let url = WebLink.safe(task.link) { Button("打开链接") { NSWorkspace.shared.open(url) } }
                    if task.calendarSource == nil { Button("删除事项", role: .destructive) { onDelete(task) } }
                }
            }
    }
    private func select(_ key: String) { selectedDay = key; month = Day.date(key)! }
    private func navigate(_ direction: Int) {
        if zoom == .month { select(MonthPlanning.shiftMonth(monthKey, by: direction)) }
        else { select(Day.adding(direction * 4, to: day)) }
    }
    private func toggle(_ item: MonthPlanning.Entry) {
        switch item.kind {
        case .task: store.toggle(item.sourceID)
        case .block: store.toggleBlock(item.sourceID)
        case .project: break
        }
    }
    private func edit(_ item: MonthPlanning.Entry, on key: String) {
        switch item.kind {
        case .task: if let task = store.tasks.first(where: { $0.id == item.sourceID }) { onEdit(task) }
        case .block: if let block = store.timeBlocks.first(where: { $0.id == item.sourceID }) { blockEditor = BlockEditorItem(block: block, day: key) }
        case .project: projectEditor = ProjectDaySelection(projectID: item.sourceID, day: key)
        }
    }
}

private struct MonthDayCell: View {
    let day: String
    let inMonth: Bool
    let selected: Bool
    let entries: [MonthPlanning.Entry]
    let height: CGFloat
    let searching: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void
    @CalendarPlanState private var hovering = false
    private var today: Bool { day == Day.today }
    private var previewLimit: Int { height >= 114 ? 3 : 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Day.formatted(day, "d")).font(.system(size: 12, weight: today || selected ? .bold : .medium, design: .rounded))
                    .foregroundColor(today ? .white : Palette.ink)
                    .frame(width: 22, height: 22).background(today ? Palette.coral : .clear, in: Circle())
                Spacer(minLength: 0)
                Button(action: onAdd) { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 22) }
                    .buttonStyle(.plain).opacity(hovering || selected ? 1 : 0).accessibilityLabel("添加到" + Day.formatted(day, "M月d日"))
            }
            ForEach(Array(entries.prefix(previewLimit))) { item in
                MonthPreviewRow(item: item)
            }
            if entries.count > previewLimit { Text("还有 \(entries.count - previewLimit) 项").font(.system(size: 9)).foregroundColor(Palette.secondary) }
            if entries.isEmpty { Text(searching ? "" : "留白").font(.system(size: 10)).foregroundColor(Palette.secondary.opacity(0.55)).padding(.top, 5) }
            Spacer(minLength: 0)
        }.padding(6).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(selected ? Palette.selection : (inMonth ? Palette.card : Palette.paper.opacity(0.8)))
            .opacity(inMonth ? 1 : 0.48)
            .overlay { if selected { Rectangle().stroke(Palette.accent.opacity(0.55), lineWidth: 2) } }
            .contentShape(Rectangle()).onTapGesture(perform: onSelect).onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect() }
            .accessibilityLabel(Day.formatted(day, "yyyy年M月d日 EEEE") + (today ? "，今天" : "") + "，\(entries.count) 项安排")
    }
}

private struct MonthPreviewRow: View {
    let item: MonthPlanning.Entry
    private var stripe: Color {
        if item.deadline && !item.completed { return Palette.coral }
        return Palette.accent.opacity(0.5)
    }
    private var textColor: Color { item.completed ? Palette.secondary.opacity(0.7) : Palette.ink }
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(stripe).frame(width: 3, height: 12)
            Text(item.title).font(.system(size: 10)).lineLimit(1).strikethrough(item.completed).foregroundColor(textColor)
        }.frame(height: 14).help((item.time.map { $0 + " · " } ?? "") + item.title)
    }
}
