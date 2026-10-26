import SwiftUI
import AppKit

private typealias ImportState<Value> = SwiftUI.State<Value>

@MainActor
final class ToolsWindowController {
    static let shared = ToolsWindowController()
    private var importWindow: NSWindow?
    private var calendarWindow: NSWindow?
    private var canvasWindow: NSWindow?
    private var categoryWindow: NSWindow?

    func showCategories(store: TodoStore) {
        if let window = categoryWindow, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = makeWindow(title: "自定义分类", width: 550, height: 570)
        window.contentView = NSHostingView(rootView: CategoryManagerView(store: store, onClose: { [weak window] in window?.close() }).preferredColorScheme(.light))
        categoryWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func showCanvasImporter(store: TodoStore, source: String = "") {
        if let window = canvasWindow, window.isVisible {
            if !source.isEmpty {
                window.contentView = NSHostingView(rootView: CanvasImportView(store: store, source: source) { [weak window] in window?.close() }.preferredColorScheme(.light))
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = makeWindow(title: "Canvas 作业与通知", width: 1010, height: 700)
        window.contentView = NSHostingView(rootView: CanvasImportView(store: store, source: source) { [weak window] in window?.close() }.preferredColorScheme(.light))
        canvasWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func showImporter(store: TodoStore) {
        if let window = importWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = makeWindow(title: "粘贴识别", width: 830, height: 620)
        window.contentView = NSHostingView(rootView: PasteImportView(store: store) { [weak window] in window?.close() }.preferredColorScheme(.light))
        importWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showCalendars(store: TodoStore) {
        CalendarSyncManager.shared.configure(store: store)
        if let window = calendarWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = makeWindow(title: "日历同步", width: 520, height: 590)
        window.contentView = NSHostingView(rootView: CalendarSettingsView(manager: .shared).preferredColorScheme(.light))
        calendarWindow = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: width, height: height)
        window.backgroundColor = NSColor(srgbRed: 0.98, green: 0.973, blue: 0.957, alpha: 1)
        return window
    }
}

private struct CalendarSettingsView: View {
    @ObservedObject var manager: CalendarSyncManager
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 9) {
                Label("日历里的事，也放在这里。", systemImage: "calendar")
                    .font(.system(size: 22, weight: .medium, design: .serif))
                Text("同步 Mac 日历里已接入的 Google、iCloud 等账号。")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            HStack(spacing: 10) {
                Circle().fill(manager.hasAccess ? Palette.green : Palette.secondary).frame(width: 6, height: 6)
                Text(manager.status).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if manager.busy { ProgressView().controlSize(.small) }
            }.padding(13).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            if manager.hasAccess {
                Toggle("自动同步到清单和桌面便签", isOn: Binding(get: { manager.enabled }, set: manager.setEnabled))
                    .toggleStyle(.switch).font(.system(size: 12))
                HStack {
                    Text("显示哪些日历").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("立即刷新") { manager.refresh() }.font(.system(size: 10)).disabled(manager.busy)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        if manager.calendars.isEmpty {
                            Text("正在读取日历列表，或本机还没有可用日历。")
                                .font(.system(size: 11)).foregroundColor(Palette.secondary).padding(18)
                        }
                        ForEach(manager.calendars) { calendar in
                            Toggle(isOn: Binding(get: { manager.selectedIDs.contains(calendar.id) }, set: { manager.select(calendar.id, selected: $0) })) {
                                HStack(spacing: 10) {
                                    Circle().fill(Color(hex: calendar.color)).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(calendar.title).font(.system(size: 12))
                                        Text(calendar.account).font(.system(size: 9)).foregroundColor(Palette.secondary)
                                    }
                                    Spacer()
                                }
                            }.toggleStyle(.checkbox).padding(.vertical, 10).padding(.horizontal, 12)
                            Divider().opacity(0.45)
                        }
                    }
                }.background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("首次连接需要允许系统的日历访问请求。")
                        .font(.system(size: 12))
                    Button(manager.busy ? "等待授权…" : "连接 Mac 日历") { manager.connect() }
                        .buttonStyle(.borderedProminent).tint(Palette.pink).disabled(manager.busy)
                    Button("打开系统设置") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                            NSWorkspace.shared.open(url)
                        }
                    }.font(.system(size: 10))
                    Text("若之前点过不允许，请到：隐私与安全性 → 日历 → 我Due！。")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }.padding(.vertical, 12)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("范围：最近 30 天及未来 180 天；本机日历更新后自动刷新。")
                Text("Google 远端变更需先同步到 Mac 日历。应用关闭时暂停，重新打开后更新。")
                Text("在这里划掉日程，只记录完成状态；原日历的标题、时间与事件不受影响。")
                if let date = manager.lastSync {
                    Text("上次更新：" + date.formatted(date: .omitted, time: .standard))
                }
            }.font(.system(size: 10)).foregroundColor(Palette.secondary)
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
    }
}

private struct PasteImportView: View {
    @ObservedObject var store: TodoStore
    let onClose: () -> Void
    @ImportState private var source: String
    @ImportState private var parsed = false
    @ImportState private var lastParsedSource = ""
    @ImportState private var title = ""
    @ImportState private var date = Date()
    @ImportState private var hasTime = false
    @ImportState private var hasEnd = false
    @ImportState private var start = Date()
    @ImportState private var end = Date()
    @ImportState private var link = ""
    @ImportState private var notes = ""
    @ImportState private var warnings: [String] = []
    @ImportState private var categoryID = ""
    @ImportState private var kind: PlanKind = .event
    private var draftURL: URL { store.fileURL.deletingLastPathComponent().appendingPathComponent("paste-draft.txt") }

    init(store: TodoStore, onClose: @escaping () -> Void) {
        self.store = store; self.onClose = onClose
        let path = store.fileURL.deletingLastPathComponent().appendingPathComponent("paste-draft.txt")
        _source = State(initialValue: (try? String(contentsOf: path, encoding: .utf8)) ?? "")
    }
    private func minute(_ value: Date) -> Int {
        Day.calendar.component(.hour, from: value) * 60 + Day.calendar.component(.minute, from: value)
    }
    private var task: Todo {
        Todo(title: title.trimmingCharacters(in: .whitespacesAndNewlines), day: Day.key(date),
            startMinute: hasTime ? minute(start) : nil, endMinute: hasTime && hasEnd && kind != .deadline ? minute(end) : nil,
            notes: notes.isEmpty ? nil : notes, link: WebLink.safe(link)?.absoluteString,
            categoryID: categoryID.isEmpty ? nil : categoryID, kind: kind)
    }
    private var invalidTime: Bool { hasTime && hasEnd && minute(end) <= minute(start) }
    private var duplicate: Todo? { parsed ? store.duplicate(of: task) : nil }
    private var valid: Bool { parsed && source == lastParsedSource && !task.title.isEmpty && task.title.count <= 2000 && !invalidTime && duplicate == nil && (link.isEmpty || WebLink.safe(link) != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Text("把邮件与通知，轻轻放进清单。")
                    .font(.system(size: 23, weight: .medium, design: .serif))
                Text("粘贴邮件、消息或通知，在本机提取日期、时间和会议链接。确认后加入清单。")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary)
            }
            HStack(alignment: .top, spacing: 23) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("粘贴内容").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("从剪贴板粘贴") {
                            if let text = ImportClipboard.text() { source = text; parse() }
                        }.font(.system(size: 10))
                    }
                    TextEditor(text: $source).font(.system(size: 12))
                        .scrollContentBackground(.hidden).padding(9)
                        .background(.white, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                        .accessibilityLabel("待识别的邮件或文字")
                    HStack {
                        Button("Canvas 批量导入…") { ToolsWindowController.shared.showCanvasImporter(store: store) }
                            .font(.system(size: 10))
                        Spacer()
                        Button("识别并预览") { parse() }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Text("确认安排").font(.system(size: 12, weight: .medium))
                    if parsed {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 15) {
                                TextField("事项名称", text: $title, axis: .vertical)
                                    .lineLimit(2...3).font(.system(size: 14)).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("识别的事项名称")
                                DatePicker("日期", selection: $date, displayedComponents: .date)
                                    .datePickerStyle(.field).font(.system(size: 11))
                                    .environment(\.locale, Locale(identifier: "zh_CN"))
                                Picker("分类", selection: $categoryID) {
                                    Text("未分类").tag(""); ForEach(store.categories) { Text($0.name).tag($0.id) }
                                }
                                Picker("性质", selection: $kind) {
                                    ForEach(PlanKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                Toggle("具体时间", isOn: $hasTime).font(.system(size: 11))
                                if hasTime {
                                    DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                                    Toggle("结束时间", isOn: $hasEnd)
                                    if hasEnd { DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute).datePickerStyle(.field) }
                                }
                                if invalidTime { Text("结束时间需晚于开始时间。").foregroundColor(Palette.pink) }
                                TextField("会议链接（可选）", text: $link).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("识别的会议链接")
                                if !link.isEmpty && WebLink.safe(link) == nil {
                                    Text("请输入完整的 http 或 https 网址。").foregroundColor(Palette.pink)
                                }
                                if let url = WebLink.safe(link) {
                                    Link(destination: url) { Label("打开会议链接", systemImage: "arrow.up.right") }
                                }
                                DisclosureGroup("原文与会议资料") {
                                    Text(notes).font(.system(size: 10)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
                                }
                                if duplicate != nil {
                                    Label("清单里已经有同名、同一天、同时间的事项。", systemImage: "checkmark.circle")
                                        .foregroundColor(Palette.green)
                                }
                                if source != lastParsedSource { Text("原文已更改，请重新点“识别并预览”。").foregroundColor(Palette.pink) }
                                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                    Label(warning, systemImage: "info.circle")
                                        .font(.system(size: 10)).foregroundColor(Color(hex: 0x9A7955))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.font(.system(size: 11)).padding(.trailing, 4)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "text.viewfinder").font(.system(size: 28)).foregroundColor(Palette.pink.opacity(0.5))
                            Text("粘贴内容后，点“识别并预览”。")
                                .font(.system(size: 11)).foregroundColor(Palette.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(width: 326)
            }
            HStack {
                Text("加入我Due！；日历同步来源的事件仍由原日历管理。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("加入清单") { add() }.buttonStyle(.borderedProminent).tint(Palette.pink).disabled(!valid)
            }
        }
        .padding(27).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
        .onAppear { if !source.isEmpty { parse() } }
        .onChange(of: source) { _, value in
            try? String(value.prefix(50_000)).write(to: draftURL, atomically: true, encoding: .utf8)
        }
    }
    private func parse() {
        if CanvasParser.looksLike(source) {
            ToolsWindowController.shared.showCanvasImporter(store: store, source: source)
            onClose(); return
        }
        let result = EventParser.parse(source)
        title = result.task.title
        kind = result.task.resolvedKind
        date = Day.date(result.task.day) ?? Date()
        hasTime = result.task.startMinute != nil
        hasEnd = result.task.endMinute != nil
        let base = Day.calendar.startOfDay(for: date)
        start = Day.calendar.date(byAdding: .minute, value: result.task.startMinute ?? 600, to: base)!
        end = Day.calendar.date(byAdding: .minute, value: result.task.endMinute ?? 660, to: base)!
        link = result.task.link ?? ""
        notes = result.task.notes ?? ""
        warnings = result.warnings
        lastParsedSource = source
        parsed = true
    }
    private func add() {
        guard valid else { return }
        if store.upsert(task) {
            store.toast = "已加入 \(Day.formatted(task.day, "M月d日")) 的清单"
            try? "".write(to: draftURL, atomically: true, encoding: .utf8)
            onClose()
        }
    }
}
