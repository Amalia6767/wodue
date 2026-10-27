import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

// Explicitly name the property wrapper so command-line builds also work with
// SDKs that expose an optional SwiftUI State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let paper = Color(hex: 0xFAF8F4)
    static let sidebar = Color(hex: 0xF1EDE6)
    static let ink = Color(hex: 0x393832)
    static let secondary = Color(hex: 0x858178)
    static let line = Color(hex: 0xE8E3DA)
    static let pink = Color(hex: 0xB35E70)
    static let blush = Color(hex: 0xF3E2E3)
    static let green = Color(hex: 0x7E8C6D)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

@main
struct DaylistApp: App {
    @StateObject private var store = TodoStore()
    @StateObject private var focus = FocusClock.shared
    @ViewState private var editor: EditorItem? = nil

    init() {
        UNUserNotificationCenter.current().delegate = ReminderNotificationDelegate.shared
        ReminderNotificationDelegate.registerCategories()
    }

    var body: some Scene {
        WindowGroup("我Due！", id: "main") {
            ContentView(store: store, editor: $editor)
                .frame(minWidth: 960, minHeight: 700)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1200, height: 830)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加事项") { editor = EditorItem(day: Day.today) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("导出清单备份…") { exportTasks(store) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("导入清单备份…") { importTasks(store) }
                Divider()
                Button("打开数据文件夹") {
                    NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent())
                }
            }
            CommandMenu("规划") {
                Button("自定义分类与颜色…") { ToolsWindowController.shared.showCategories(store: store) }
                Button("查看三天内的截止提醒") { DeadlineReminder.shared.show() }
                Button("会议与活动提醒…") { EventReminder.shared.show() }
            }
            CommandMenu("桌面便签") {
                Button("显示 / 隐藏便签") { DesktopNoteController.shared.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("显示便签") { DesktopNoteController.shared.show() }
            }
            CommandMenu("导入与同步") {
                Button("Canvas 作业与通知…") { ToolsWindowController.shared.showCanvasImporter(store: store) }
                Button("粘贴识别邮件或文字…") { ToolsWindowController.shared.showImporter(store: store) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("日历同步设置…") { ToolsWindowController.shared.showCalendars(store: store) }
                Button("立即同步日历") { CalendarSyncManager.shared.refresh() }
            }
        }
        MenuBarExtra(isInserted: Binding(get: { focus.session != nil }, set: { _ in })) {
            FocusMenuView(clock: focus)
        } label: {
            Label(focus.clockText, systemImage: "timer").monospacedDigit()
        }.menuBarExtraStyle(.window)
    }
}

struct EditorItem: Identifiable {
    var id = UUID()
    var task: Todo? = nil
    var day: String
}

private enum Scope: String, CaseIterable {
    case today = "今日节奏"
    case horizon = "长期计划"
    case plan = "这几天"
    case all = "全部事项"
    var icon: String {
        switch self {
        case .plan: return "square.grid.2x2"
        case .today: return "sun.max"
        case .horizon: return "calendar.badge.clock"
        case .all: return "tray.full"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: TodoStore
    @Binding var editor: EditorItem?
    @Environment(\.openWindow) private var openWindow
    @ViewState private var scope: Scope = .today
    @ViewState private var anchor = Day.today
    @ViewState private var calendarMonth = Day.date(Day.today)!
    @ViewState private var selectedDay: String? = nil
    @ViewState private var search = ""
    @ViewState private var deleted: Todo? = nil
    @ViewState private var undoDismiss: DispatchWorkItem? = nil
    @ViewState private var toastDismiss: DispatchWorkItem? = nil

    private var visibleDays: [String] {
        if let selectedDay { return [selectedDay] }
        switch scope {
        case .plan: return (0..<4).map { Day.adding($0, to: anchor) }
        case .today: return [Day.today]
        case .all, .horizon: return store.days.isEmpty ? [Day.today] : store.days
        }
    }
    private var filteredDays: [String] {
        search.isEmpty ? visibleDays : visibleDays.filter { day in
            store.tasks(on: day).contains { matches($0) }
        }
    }
    private var visibleTasks: [Todo] {
        store.tasks.filter { task in visibleDays.contains(where: { task.occurs(on: $0) }) && matches(task) }
    }
    private var done: Int { visibleTasks.filter(\.completed).count }
    private var monthTitle: String {
        if selectedDay != nil { return Day.formatted(selectedDay!, "yyyy 年 M 月 d 日") }
        if scope == .today { return Day.formatted(Day.today, "yyyy 年 M 月 d 日") }
        if scope == .all { return "所有日子，都在这里" }
        return "\(Day.formatted(anchor, "M 月 d 日")) — \(Day.formatted(Day.adding(3, to: anchor), "M 月 d 日"))"
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { sidebar }.frame(width: 222).background(Palette.sidebar)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                topbar
                DeadlineBanner(store: store, onEdit: { editor = EditorItem(task: $0, day: $0.day) })
                EventBanner()
                if scope == .today {
                    DailyPlannerView(store: store, day: selectedDay ?? Day.today, onDay: { selectedDay = $0; calendarMonth = Day.date($0)! }, onEdit: { editor = EditorItem(task: $0, day: $0.day) }, onAddTask: { editor = EditorItem(day: selectedDay ?? Day.today) })
                } else if scope == .horizon && selectedDay == nil {
                    HorizonView(store: store, onEdit: { editor = EditorItem(task: $0, day: $0.day) }, onAdd: { editor = EditorItem(day: Day.today) })
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        hero
                        dayToolbar
                        if filteredDays.isEmpty {
                            emptySearch
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 20)], alignment: .leading, spacing: 20) {
                                ForEach(filteredDays, id: \.self) { day in
                                    DayCard(day: day, tasks: store.tasks(on: day).filter(matches), blockCount: store.blocks(on: day).count,
                                            onPlanDay: { scope = .today; selectedDay = day },
                                            onToggle: store.toggle,
                                            onAdd: { editor = EditorItem(day: day) },
                                            onEdit: { editor = EditorItem(task: $0, day: $0.day) },
                                            onDelete: remove)
                                }
                            }
                        }
                        HStack(spacing: 7) {
                            Image(systemName: "heart").font(.system(size: 11))
                            Text("不用一次做完，往前一点就很好。")
                        }
                        .font(.system(size: 11)).foregroundColor(Palette.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 4)
                    }
                    .padding(.horizontal, 34).padding(.top, 28).padding(.bottom, 28)
                }
                .background(Palette.paper)
                }
            }
        }
        .foregroundColor(Palette.ink)
        .background(Palette.paper)
        .tint(Palette.pink)
        .onAppear {
            FocusClock.shared.configure(store: store)
            CalendarSyncManager.shared.configure(store: store)
            DesktopNoteController.shared.configure(store: store, openMain: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }, editTask: { task in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                editor = EditorItem(task: task, day: task.day)
            })
            let deadlines = DeadlineReminder.shared
            deadlines.openTask = { task in
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                editor = EditorItem(task: task, day: task.day)
            }
            deadlines.presentationChanged = { requested in DeadlinePanelController.shared.update(reminder: deadlines, store: store, requested: requested) }
            deadlines.configure(store: store)
            let events = EventReminder.shared
            events.openTask = { task in
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                editor = EditorItem(task: task, day: task.day)
            }
            events.presentationChanged = { requested in EventPanelController.shared.update(reminder: events, requested: requested) }
            events.configure(store: store)
        }
        .sheet(item: $editor) { item in
            TaskEditor(store: store, item: item) { saved in
                if !visibleDays.contains(saved.day) {
                    selectedDay = saved.day
                    calendarMonth = Day.date(saved.day) ?? calendarMonth
                }
                search = ""
            }
        }
        .alert("清单需要留意一下", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let deleted {
                HStack(spacing: 15) {
                    Text("已移除「\(deleted.title)」").lineLimit(1)
                    Button("撤销") {
                        store.restore(deleted)
                        self.deleted = nil
                        undoDismiss?.cancel()
                    }.fontWeight(.semibold).foregroundColor(Palette.blush)
                    Button { self.deleted = nil } label: { Image(systemName: "xmark") }
                        .foregroundColor(.white.opacity(0.6)).help("关闭提示")
                }
                .buttonStyle(.plain).font(.system(size: 12))
                .padding(.vertical, 14).padding(.horizontal, 20)
                .foregroundColor(.white).background(Palette.ink, in: Capsule())
                .padding(.bottom, 24).shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            } else if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).padding(14)
                    .background(.white, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 8)
                    .padding(.bottom, 24)
            }
        }
        .onChange(of: store.toast) { _, value in
            toastDismiss?.cancel()
            if value != nil {
                let job = DispatchWorkItem { store.toast = nil }
                toastDismiss = job
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: job)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Palette.pink).frame(width: 36, height: 36)
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .medium)).foregroundColor(.white)
                }
                Text("我Due！").font(.system(size: 20, weight: .semibold, design: .rounded))
            }.padding(.top, 43)
            Text("给每一天，留一点余地。")
                .font(.system(size: 11)).foregroundColor(Palette.secondary).padding(.top, 12)

            VStack(spacing: 6) {
                ForEach(Scope.allCases, id: \.self) { item in
                    Button {
                        scope = item; selectedDay = nil; search = ""
                        if item == .today { calendarMonth = Day.date(Day.today)! }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon).font(.system(size: 14)).frame(width: 18)
                            Text(item.rawValue).font(.system(size: 13, weight: scope == item && selectedDay == nil ? .semibold : .regular))
                            Spacer()
                            if item == .today {
                                Text("\(store.tasks(on: Day.today).filter { !$0.completed }.count + store.blocks(on: Day.today).filter { !$0.completed }.count)")
                                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.white.opacity(0.65), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 41)
                        .foregroundColor(scope == item && selectedDay == nil ? Palette.pink : Palette.secondary)
                        .background(scope == item && selectedDay == nil ? Palette.blush : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 37)

            Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 28)
            calendar
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("今天的小进度").font(.system(size: 11))
                    Spacer()
                    Text("\(todayDone) / \(todayTotal)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                GeometryReader { proxy in
                    Capsule().fill(Palette.line)
                    Capsule().fill(Palette.green).frame(width: proxy.size.width * todayProgress)
                }.frame(height: 4)
                Text(todayDone > 0 ? "每一件完成，都算数。" : "从一件小事开始吧。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
            }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 32)

            Spacer(minLength: 24)
            HStack(spacing: 17) {
                Button { ToolsWindowController.shared.showImporter(store: store) } label: {
                    Label("粘贴识别", systemImage: "doc.on.clipboard")
                }.help("粘贴邮件、通知或文字，识别日期和时间 ⇧⌘V")
                Button { ToolsWindowController.shared.showCalendars(store: store) } label: {
                    Label("日历同步", systemImage: "calendar.badge.clock")
                }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Palette.secondary).padding(.bottom, 5)
            Button { DesktopNoteController.shared.show() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                    Text("桌面便签")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9))
                }
                .font(.system(size: 11)).foregroundColor(Palette.pink)
                .padding(.vertical, 12)
            }.buttonStyle(.plain).help("显示半透明的今日便签 ⌥⌘M")
            Menu {
                Button("导出备份…") { exportTasks(store) }
                Button("导入备份…") { importTasks(store) }
                Divider()
                Button("打开数据文件夹") { NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent()) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: store.canSave ? "internaldrive" : "exclamationmark.triangle")
                    Text(store.canSave ? "已自动保存在这台 Mac" : "数据读取失败")
                    Spacer()
                }.font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .help("导出、导入或查看本地数据")
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    private var todayDone: Int { store.tasks(on: Day.today).filter(\.completed).count + store.blocks(on: Day.today).filter(\.completed).count }
    private var todayTotal: Int { store.tasks(on: Day.today).count + store.blocks(on: Day.today).count }
    private var todayProgress: CGFloat {
        let count = todayTotal
        return count == 0 ? 0 : CGFloat(todayDone) / CGFloat(count)
    }

    private var calendar: some View {
        VStack(spacing: 15) {
            HStack {
                Text(Day.formatted(Day.key(calendarMonth), "yyyy 年 M 月"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上个月").accessibilityLabel("日历上个月")
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .padding(.leading, 7).help("下个月").accessibilityLabel("日历下个月")
            }.buttonStyle(.plain).font(.system(size: 10))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 5) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                    Text(weekday).font(.system(size: 9)).foregroundColor(Palette.secondary)
                        .frame(maxWidth: .infinity).frame(height: 16)
                }
                ForEach(0..<calendarSlots.count, id: \.self) { i in
                    if let date = calendarSlots[i] {
                        let key = Day.key(date)
                        let today = key == Day.today
                        let inRange = visibleDays.contains(key)
                        Button {
                            selectedDay = key; search = ""
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(Day.calendar.component(.day, from: date))")
                                    .font(.system(size: 10, weight: today ? .semibold : .regular))
                                Circle().fill(store.tasks(on: key).isEmpty ? .clear : (today ? .white : Palette.pink))
                                    .frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .foregroundColor(today ? .white : (inRange ? Palette.pink : Palette.secondary))
                            .background(today ? Palette.pink : (inRange ? Palette.blush : .clear), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(Day.formatted(key, "M月d日，EEEE"))
                    } else { Color.clear.frame(height: 26) }
                }
            }
        }
    }
    private var calendarSlots: [Date?] {
        let c = Day.calendar
        let components = c.dateComponents([.year, .month], from: calendarMonth)
        guard let first = c.date(from: components), let range = c.range(of: .day, in: .month, for: first) else { return [] }
        let offset = (c.component(.weekday, from: first) + 5) % 7
        return Array(repeating: nil, count: offset) + range.map { c.date(byAdding: .day, value: $0 - 1, to: first) }
    }
    private func shiftMonth(_ offset: Int) {
        calendarMonth = Day.calendar.date(byAdding: .month, value: offset, to: calendarMonth) ?? calendarMonth
    }

    private var topbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "house").font(.system(size: 12))
            Text("我的生活").font(.system(size: 11))
            Text("/").padding(.horizontal, 5).foregroundColor(Palette.line)
            Text(selectedDay == nil ? scope.rawValue : "按日查看").font(.system(size: 11)).foregroundColor(Palette.ink)
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Palette.green).frame(width: 5, height: 5)
                Text("一点一点，慢慢完成").font(.system(size: 10))
            }
        }
        .foregroundColor(Palette.secondary).padding(.horizontal, 34).frame(height: 59)
        .background(Palette.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var hero: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 11) {
                Text("DAY BY DAY  /  \(Day.formatted(visibleDays.first ?? Day.today, "yyyy.MM"))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2)
                    .foregroundColor(Palette.pink)
                Text(scope == .today && selectedDay == nil ? "今天，也慢慢来。" : "居家的几天，慢慢来。")
                    .font(.system(size: 29, weight: .medium, design: .serif)).tracking(1)
                Text("把事情放进日子里，做完一件就轻轻划掉。")
                    .font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
            Spacer(minLength: 20)
            ZStack {
                Circle().stroke(Palette.line, lineWidth: 5)
                Circle().trim(from: 0, to: visibleTasks.isEmpty ? 0 : CGFloat(done) / CGFloat(visibleTasks.count))
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text("\(done) / \(visibleTasks.count)").font(.system(size: 17, weight: .medium, design: .rounded))
                    Text("已完成").font(.system(size: 9)).foregroundColor(Palette.secondary)
                }
            }.frame(width: 79, height: 79).padding(.trailing, 5)
                .accessibilityLabel("当前已完成 \(done) 件，共 \(visibleTasks.count) 件")
        }
    }

    private var dayToolbar: some View {
        HStack(spacing: 12) {
            Text(monthTitle).font(.system(size: 13, weight: .medium))
            if scope == .plan && selectedDay == nil {
                HStack(spacing: 12) {
                    Button { shiftRange(-4) } label: { Image(systemName: "chevron.left") }
                        .help("前四天").accessibilityLabel("前四天")
                    Button { shiftRange(4) } label: { Image(systemName: "chevron.right") }
                        .help("后四天").accessibilityLabel("后四天")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            if selectedDay != nil || (scope == .plan && anchor != Day.today) {
                Button("回到计划") { selectedDay = nil; scope = .plan; anchor = Day.today; search = "" }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Palette.pink)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.secondary)
                TextField("搜索", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(Palette.secondary).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 10)).padding(.horizontal, 10).frame(width: 112, height: 30)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
            Button {
                editor = EditorItem(day: selectedDay ?? (scope == .today ? Day.today : anchor))
            } label: {
                Label("新事项", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 13).frame(height: 31)
                    .foregroundColor(.white).background(Palette.pink, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help("添加事项 ⌘N")
        }
    }
    private var emptySearch: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 25)).foregroundColor(Palette.secondary)
            Text("这几个日子里，没有找到「\(search)」").font(.system(size: 13))
            Button("清除搜索") { search = "" }.buttonStyle(.plain).foregroundColor(Palette.pink)
        }.frame(maxWidth: .infinity).padding(.vertical, 80)
    }
    private func matches(_ task: Todo) -> Bool {
        search.isEmpty || task.title.localizedCaseInsensitiveContains(search)
    }
    private func shiftRange(_ offset: Int) {
        anchor = Day.adding(offset, to: anchor)
        calendarMonth = Day.date(anchor)!
    }
    private func remove(_ task: Todo) {
        store.remove(task.id)
        guard !store.tasks.contains(where: { $0.id == task.id }) else { return }
        deleted = task
        undoDismiss?.cancel()
        let job = DispatchWorkItem { deleted = nil }
        undoDismiss = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: job)
    }
}

private struct DayCard: View {
    let day: String
    let tasks: [Todo]
    let blockCount: Int
    let onPlanDay: () -> Void
    let onToggle: (UUID) -> Void
    let onAdd: () -> Void
    let onEdit: (Todo) -> Void
    let onDelete: (Todo) -> Void
    private var today: Bool { day == Day.today }
    private var done: Int { tasks.filter(\.completed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                Text(Day.formatted(day, "dd")).font(.system(size: 31, weight: .regular, design: .serif))
                    .foregroundColor(today ? Palette.pink : Palette.ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Day.formatted(day, "EEEE")).font(.system(size: 11, weight: .medium))
                    Text(Day.formatted(day, "M 月"))
                        .font(.system(size: 9)).foregroundColor(Palette.secondary)
                }
                Spacer()
                if today {
                    Text("今天").font(.system(size: 9, weight: .medium)).foregroundColor(Palette.pink)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Palette.blush, in: Capsule())
                } else if done == tasks.count && !tasks.isEmpty {
                    Image(systemName: "checkmark.seal").foregroundColor(Palette.green).font(.system(size: 17))
                }
            }.padding(.bottom, 16)
            Rectangle().fill(Palette.line).frame(height: 1)
            VStack(spacing: 0) {
                if tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(blockCount > 0 ? "当天的时间已经分好段。" : "还没有安排").font(.system(size: 12)).foregroundColor(Palette.secondary)
                        Text("也可以留一点空白，给自己。")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary.opacity(0.85))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 32)
                } else {
                    ForEach(tasks) { task in
                        TaskRow(task: task, onToggle: { onToggle(task.id) },
                                onEdit: { onEdit(task) }, onDelete: { onDelete(task) })
                    }
                }
            }.padding(.top, 5)
            if blockCount > 0 {
                Button("查看 \(blockCount) 个时间块 →", action: onPlanDay)
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Palette.pink).padding(.vertical, 10)
            }
            Spacer(minLength: 12)
            HStack {
                Button(action: onAdd) {
                    Label("添加一件事", systemImage: "plus").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(Palette.secondary)
                Spacer()
                Text("\(done)/\(tasks.count) 完成")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.secondary)
            }.padding(.top, 11)
        }
        .padding(22).frame(maxWidth: .infinity, minHeight: 256, alignment: .topLeading)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(today ? Palette.pink.opacity(0.45) : Palette.line, lineWidth: 1))
        .overlay(alignment: .top) {
            if today { Capsule().fill(Palette.pink.opacity(0.65)).frame(width: 32, height: 3) }
        }
    }
}

private struct TaskRow: View {
    let task: Todo
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 11) {
                    ZStack {
                        Circle().fill(task.completed ? Palette.green : Color.clear)
                        Circle().stroke(task.completed ? Palette.green : Color(hex: 0xCFC8BD), lineWidth: 1.2)
                        if task.completed {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                        }
                    }.frame(width: 17, height: 17)
                    VStack(alignment: .leading, spacing: 5) {
                        if let time = task.timeLabel {
                            HStack(spacing: 5) {
                                if task.calendarSource != nil { Image(systemName: "calendar").font(.system(size: 8)) }
                                Text(time).font(.system(size: 9, weight: .medium, design: .monospaced))
                            }.foregroundColor(task.completed ? Palette.secondary : Palette.pink)
                        }
                        Text(task.title).font(.system(size: 12))
                            .foregroundColor(task.completed ? Color(hex: 0x8C877F) : Palette.ink)
                            .strikethrough(task.completed, color: Color(hex: 0xA39B90))
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.title + (task.completed ? "，已完成，点击恢复" : "，未完成，点击完成"))
            Menu {
                Button(task.calendarSource == nil ? "编辑事项" : "查看日历事项", action: onEdit)
                Button(task.completed ? "标为未完成" : "标为已完成", action: onToggle)
                if let url = WebLink.safe(task.link) { Button(task.canvasSource == nil ? "打开链接" : "打开 Canvas") { NSWorkspace.shared.open(url) } }
                Divider()
                if task.calendarSource != nil { Button("在系统日历中打开") { CalendarNavigation.open(task) } }
                else { Button("删除事项", role: .destructive, action: onDelete) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 18, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
            .opacity(hovering ? 1 : 0.30).help("编辑或删除事项").accessibilityLabel("更多操作：" + task.title)
        }
        .padding(.vertical, 11)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(task.calendarSource == nil ? "编辑事项" : "查看日历事项", action: onEdit)
            Button(task.completed ? "标为未完成" : "标为已完成", action: onToggle)
            if let url = WebLink.safe(task.link) { Button(task.canvasSource == nil ? "打开链接" : "打开 Canvas") { NSWorkspace.shared.open(url) } }
            Divider()
            if task.calendarSource != nil { Button("在系统日历中打开") { CalendarNavigation.open(task) } }
            else { Button("删除事项", role: .destructive, action: onDelete) }
        }
    }
}

@MainActor
private func exportTasks(_ store: TodoStore) {
    let panel = NSSavePanel()
    panel.title = "导出我Due！备份"
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "我Due！备份-\(Day.today).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try store.exportData().write(to: url, options: .atomic)
        store.toast = "备份已导出"
    } catch { store.errorMessage = "导出失败：" + error.localizedDescription }
}

@MainActor
private func importTasks(_ store: TodoStore) {
    let panel = NSOpenPanel()
    panel.title = "导入我Due！备份"
    panel.message = "合并到当前清单；相同编号的事项会更新为备份中的内容。"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? Int ?? 0) < 20_000_000 else {
            throw StoreError.invalidDocument("文件超过 20 MB，请选择清单备份。")
        }
        try store.importData(Data(contentsOf: url))
    } catch { store.errorMessage = "导入失败：" + error.localizedDescription }
}
