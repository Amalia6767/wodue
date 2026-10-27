import SwiftUI
import AppKit
import Combine

private typealias NoteState<Value> = SwiftUI.State<Value>

private final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class DesktopNoteController: ObservableObject {
    static let shared = DesktopNoteController()
    @Published private(set) var hovering = false
    @Published var pinned = true {
        didSet {
            panel?.level = pinned ? .floating : .normal
            UserDefaults.standard.set(pinned, forKey: "DesktopNotePinned")
        }
    }
    @Published var idleOpacity = 0.0 {
        didSet { UserDefaults.standard.set(idleOpacity, forKey: "DesktopNoteIdleOpacity") }
    }
    @Published var focusOpacity = 0.96 {
        didSet { UserDefaults.standard.set(focusOpacity, forKey: "DesktopNoteFocusOpacity") }
    }
    @Published var lightText = false {
        didSet {
            UserDefaults.standard.set(lightText, forKey: "DesktopNoteLightText")
            panel?.appearance = NSAppearance(named: lightText ? .darkAqua : .aqua)
        }
    }
    private var panel: NotePanel?
    private var openMainAction: (() -> Void)?
    private var editTaskAction: ((Todo) -> Void)?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var pointerInside = false
    private var hoverExit: DispatchWorkItem?

    private init() {
        UserDefaults.standard.register(defaults: [
            "DesktopNotePinned": true,
            "DesktopNoteVisible": true,
            "DesktopNoteIdleOpacity": 0.0,
            "DesktopNoteFocusOpacity": 0.96,
            "DesktopNoteLightText": false
        ])
        pinned = UserDefaults.standard.bool(forKey: "DesktopNotePinned")
        idleOpacity = min(0.14, max(0, UserDefaults.standard.double(forKey: "DesktopNoteIdleOpacity")))
        focusOpacity = min(1, max(0.86, UserDefaults.standard.double(forKey: "DesktopNoteFocusOpacity")))
        lightText = UserDefaults.standard.bool(forKey: "DesktopNoteLightText")
    }

    func configure(store: TodoStore, openMain: @escaping () -> Void, editTask: @escaping (Todo) -> Void) {
        openMainAction = openMain
        editTaskAction = editTask
        guard panel == nil else { return }
        let note = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 294, height: 280),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        note.title = "今天的桌面便签"
        note.identifier = NSUserInterfaceItemIdentifier("DesktopNote")
        note.isReleasedWhenClosed = false
        note.isFloatingPanel = true
        note.becomesKeyOnlyIfNeeded = true
        note.hidesOnDeactivate = false
        note.isMovableByWindowBackground = true
        note.isOpaque = false
        note.backgroundColor = .clear
        note.hasShadow = false
        note.acceptsMouseMovedEvents = true
        note.appearance = NSAppearance(named: lightText ? .darkAqua : .aqua)
        note.level = pinned ? .floating : .normal
        note.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        note.minSize = NSSize(width: 260, height: 210)
        note.maxSize = NSSize(width: 460, height: 800)
        let hosting = ClearHostingView(rootView: DesktopNoteView(store: store, controller: self))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        note.contentView = hosting
        note.initialFirstResponder = hosting
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            note.setFrameOrigin(NSPoint(x: area.maxX - 338, y: area.maxY - 382))
        }
        _ = note.setFrameAutosaveName("DaylistDesktopNoteFrame")
        keepOnScreen(note)
        panel = note
        installPointerTracking()
        if UserDefaults.standard.bool(forKey: "DesktopNoteVisible") { show() }
    }
    func show() {
        if let panel { keepOnScreen(panel) }
        panel?.orderFrontRegardless()
        refreshPointer()
        UserDefaults.standard.set(true, forKey: "DesktopNoteVisible")
    }
    func hide() {
        panel?.orderOut(nil)
        updatePointer(false)
        UserDefaults.standard.set(false, forKey: "DesktopNoteVisible")
    }
    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }
    func openMain() { openMainAction?() }
    func edit(_ task: Todo) { editTaskAction?(task) }

    func refreshPointer() {
        guard let panel else { return }
        updatePointer(panel.isVisible && !NSApp.isHidden && panel.frame.contains(NSEvent.mouseLocation))
    }

    private func installPointerTracking() {
        guard localPointerMonitor == nil else { return }
        // A nonactivating, transparent panel must react while other apps have
        // focus. Observe pointer motion only; never collect keys or swallow input.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.refreshPointer()
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in self?.refreshPointer() }
        }
    }

    private func updatePointer(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        hoverExit?.cancel()
        if inside {
            hovering = true
        } else {
            let job = DispatchWorkItem { [weak self] in self?.hovering = false }
            hoverExit = job
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: job)
        }
    }

    private func keepOnScreen(_ note: NSWindow) {
        guard let screen = note.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        var frame = note.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        if note.frame != frame { note.setFrame(frame, display: false) }
    }
}

private struct DesktopNoteView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var controller: DesktopNoteController
    @ObservedObject private var focusClock = FocusClock.shared
    @ObservedObject private var deadlines = DeadlineReminder.shared
    @NoteState private var today = Day.today
    @NoteState private var newTitle = ""
    @NoteState private var inputError: String? = nil
    @NoteState private var showAppearance = false
    @NoteState private var menuTracking = false
    @NoteState private var inputWasChosen = false
    @FocusState private var adding: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private var tasks: [Todo] { store.tasks(on: today) }
    private var done: Int { tasks.filter(\.completed).count }
    private var editing: Bool { (adding && inputWasChosen) || !newTitle.isEmpty }
    private var engaged: Bool { controller.hovering || editing || showAppearance || menuTracking }
    private var ink: Color {
        controller.lightText ? .white.opacity(engaged ? 0.98 : 0.91) : Color(hex: 0x24272B).opacity(engaged ? 0.98 : 0.88)
    }
    private var secondary: Color {
        controller.lightText ? .white.opacity(engaged ? 0.64 : 0.65) : Color(hex: 0x24272B).opacity(engaged ? 0.58 : 0.64)
    }
    private var surface: Color { controller.lightText ? Color(hex: 0x202329) : Color(hex: 0xFBF9F5) }
    // One alpha step keeps the whole window hit-testable while visually clear.
    private var plateOpacity: Double { reduceTransparency ? 1 : (engaged ? controller.focusOpacity : max(1.0 / 255, controller.idleOpacity)) }
    private var transition: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天").font(.system(size: 13, weight: .semibold))
                    Text(Day.formatted(today, "M 月 d 日 · EEEE"))
                        .font(.system(size: 9)).foregroundColor(secondary)
                }
                Spacer(minLength: 5)
                Text("\(max(0, tasks.count - done)) 件待办")
                    .font(.system(size: 9, weight: .medium)).foregroundColor(secondary)
                    .opacity(engaged ? 1 : 0)
                Button { controller.pinned.toggle() } label: {
                    Image(systemName: controller.pinned ? "pin.fill" : "pin.slash")
                        .frame(width: 23, height: 25).foregroundColor(secondary).opacity(engaged ? 1 : 0)
                }
                .help(controller.pinned ? "已置顶，点击取消" : "点击始终置顶")
                .accessibilityLabel(controller.pinned ? "取消便签置顶" : "便签始终置顶")
                Menu {
                    Button("打开完整清单") { controller.openMain() }
                    Button("粘贴识别邮件或文字…") { ToolsWindowController.shared.showImporter(store: store) }
                    Button("Canvas 作业与通知…") { ToolsWindowController.shared.showCanvasImporter(store: store) }
                    Button("日历同步设置…") { ToolsWindowController.shared.showCalendars(store: store) }
                    Button("查看三天内的截止提醒") { deadlines.show() }
                    Button("会议与活动提醒…") { EventReminder.shared.show() }
                    Divider()
                    Button("外观与文字颜色…") { showAppearance = true }
                    Divider()
                    Button("隐藏便签 ⌥⌘M") { controller.hide() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 23, height: 25).opacity(engaged ? 1 : 0)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 23)
                .opacity(engaged ? 1 : 0)
                .accessibilityLabel("桌面便签选项")
            }
            .buttonStyle(.plain).font(.system(size: 11))
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            Rectangle().fill(secondary.opacity(engaged ? 0.18 : 0)).frame(height: 0.5).padding(.horizontal, 18)

            if let urgent = deadlines.items.first {
                Button { deadlines.show() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: urgent.stage.symbol).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DDL · \(urgent.stage.label)" + (deadlines.items.count > 1 ? " · 共 \(deadlines.items.count) 项" : ""))
                                .font(.system(size: 10, weight: .bold))
                            Text(urgent.task.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(urgent.countdown(at: Date())).font(.system(size: 9))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).opacity(engaged ? 1 : 0)
                    }.padding(.horizontal, 18).padding(.vertical, 11)
                        .foregroundColor(controller.lightText ? Color(hex: urgent.stage.strong ? 0xFFA89C : 0xF6D69C) : urgent.stage.color)
                        .background(urgent.stage.color.opacity(engaged ? 0.09 : 0))
                }.buttonStyle(.plain).help("查看所有临近截止事项")
            }

            EventNoteStrip(lightText: controller.lightText)

            if let session = focusClock.session {
                HStack(spacing: 8) {
                    Image(systemName: session.phase == .rest ? "leaf" : "timer").font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(focusClock.phaseText + " · " + focusClock.clockText).font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text(session.title).font(.system(size: 10)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        switch session.phase {
                        case .readyBreak: focusClock.beginBreak()
                        case .readyWork: focusClock.nextRound()
                        default: if focusClock.running { focusClock.pause() } else { focusClock.resume() }
                        }
                    } label: { Image(systemName: focusClock.running ? "pause.fill" : "play.fill").frame(width: 22, height: 25) }
                        .buttonStyle(.plain).opacity(engaged ? 1 : 0).help("暂停、继续或开始下一段")
                }.foregroundColor(ink).padding(.horizontal, 18).padding(.vertical, 11)
            } else if let block = store.blocks(on: today).first(where: { !$0.completed && $0.endMinute > ClockText.minuteNow() }) {
                HStack(spacing: 8) {
                    Image(systemName: block.isRest ? "leaf" : "clock").font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.timeLabel).font(.system(size: 10, weight: .medium, design: .monospaced))
                        Text(block.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if block.isRest { controller.openMain() }
                        else { _ = focusClock.start(title: block.title, blockID: block.id, taskID: block.taskID, hardStop: ClockText.date(block.day, block.endMinute)) }
                    } label: { Image(systemName: block.isRest ? "arrow.up.right" : "play.fill").frame(width: 22, height: 25) }
                        .buttonStyle(.plain).opacity(engaged ? 1 : 0).help("专注当前时段，或打开完整计划")
                }.foregroundColor(ink).padding(.horizontal, 18).padding(.vertical, 11)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("今天还没有安排").font(.system(size: 12))
                            Text("在下面记下一件小事吧。")
                                .font(.system(size: 10)).foregroundColor(secondary)
                        }.padding(.vertical, 25)
                    }
                    ForEach(tasks) { task in
                        Button { store.toggle(task.id) } label: {
                            HStack(alignment: .center, spacing: 10) {
                                ZStack {
                                    Circle().fill(task.completed ? secondary.opacity(engaged ? 0.55 : 0.35) : .clear)
                                    Circle().stroke(secondary.opacity(task.completed ? 0.4 : 0.75), lineWidth: 1)
                                    if task.completed {
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)).foregroundColor(.white)
                                    }
                                }.frame(width: 15, height: 15)
                                VStack(alignment: .leading, spacing: 4) {
                                    if let time = task.timeLabel {
                                        Text(time).font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(secondary)
                                    }
                                    Text(task.title)
                                        .font(.system(size: 12, weight: task.completed ? .regular : .medium))
                                        .foregroundColor(task.completed ? secondary : ink)
                                        .strikethrough(task.completed, color: secondary.opacity(0.8))
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(task.title)
                        .accessibilityLabel(task.title + (task.completed ? "，已完成，点击恢复" : "，未完成，点击完成"))
                        .contextMenu {
                            Button(task.completed ? "恢复为未完成" : "标为已完成") { store.toggle(task.id) }
                            Button(task.calendarSource == nil ? "在完整清单中编辑" : "查看日历事项") { controller.edit(task) }
                            if task.calendarSource != nil { Button("在系统日历中打开") { CalendarNavigation.open(task) } }
                            if let url = WebLink.safe(task.link) { Button(task.canvasSource == nil ? "打开链接" : "打开 Canvas") { NSWorkspace.shared.open(url) } }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 6)
            }.scrollIndicators(.never)

            VStack(spacing: 10) {
                if let inputError {
                    Text(inputError).font(.system(size: 10)).foregroundColor(Palette.pink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundColor(secondary)
                    TextField("添加今天的事项…", text: $newTitle)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .focused($adding).onSubmit(addTask)
                        .simultaneousGesture(TapGesture().onEnded { inputWasChosen = true })
                        .accessibilityLabel("便签新增今天的事项")
                    if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: addTask) {
                            Image(systemName: "arrow.turn.down.left").font(.system(size: 10, weight: .medium))
                                .frame(width: 24, height: 23).foregroundColor(.white)
                                .background(Palette.pink, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel("添加到今天的便签")
                    }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background((controller.lightText ? Color.white : Color.black).opacity(editing ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(editing ? Palette.pink.opacity(0.55) : secondary.opacity(0.10), lineWidth: 1))
                .opacity(engaged ? 1 : 0)
                .allowsHitTesting(engaged)
                HStack {
                    Text("\(done) / \(tasks.count) 已完成").font(.system(size: 9, design: .monospaced))
                    Spacer()
                    Button {
                        ToolsWindowController.shared.showImporter(store: store)
                    } label: {
                        Label("粘贴识别", systemImage: "doc.on.clipboard")
                    }.buttonStyle(.plain).help("粘贴邮件或通知 ⇧⌘V")
                }.font(.system(size: 9)).foregroundColor(secondary).opacity(engaged ? 1 : 0)
                    .allowsHitTesting(engaged)
            }
            .padding(.horizontal, 15).padding(.top, 6).padding(.bottom, 12)
        }
        .foregroundColor(ink)
        .shadow(color: controller.lightText ? .black.opacity(engaged ? 0 : 0.55) : .white.opacity(engaged ? 0 : 0.65), radius: engaged ? 0 : 1.2, x: 0, y: controller.lightText ? 0.6 : 0)
        .background(surface.opacity(plateOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke((controller.lightText ? Color.white : Color.black).opacity(engaged ? 0.075 : 0), lineWidth: 0.7))
        .contentShape(Rectangle())
        .environment(\.colorScheme, controller.lightText ? .dark : .light)
        .animation(transition, value: engaged)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
            controller.refreshPointer()
            let isNoteMenu = (notification.object as? NSMenu)?.items.contains {
                ["打开完整清单", "外观与文字颜色…", "在完整清单中编辑", "查看日历事项"].contains($0.title)
            } ?? false
            if isNoteMenu || controller.hovering || editing || showAppearance { menuTracking = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
        }
        .onChange(of: adding) { _, focused in if !focused { inputWasChosen = false } }
        .popover(isPresented: $showAppearance, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 15) {
                Text("安静地放着，需要时再清楚一点。")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    Text("静置背景").font(.system(size: 11))
                    Spacer()
                    Text("\(Int(controller.idleOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.secondary)
                }
                Slider(value: $controller.idleOpacity, in: 0...0.14)
                    .tint(Palette.pink).accessibilityLabel("便签静置背景浓度")
                HStack {
                    Text("关注时背景").font(.system(size: 11))
                    Spacer()
                    Text("\(Int(controller.focusOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.secondary)
                }
                Slider(value: $controller.focusOpacity, in: 0.86...1)
                    .tint(Palette.pink).accessibilityLabel("便签关注时背景浓度")
                Text("鼠标移入时显示底板；输入和打开菜单时保持清楚。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                Picker("文字颜色", selection: $controller.lightText) {
                    Text("深色文字").tag(false)
                    Text("浅色文字").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Text("浅色文字配深色底板，深色文字配浅色底板。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                Button("恢复推荐透明度") { controller.idleOpacity = 0; controller.focusOpacity = 0.96 }
                    .font(.system(size: 10)).tint(Palette.pink)
            }.padding(20).frame(width: 260).foregroundColor(Palette.ink).preferredColorScheme(.light)
        }
        .onReceive(clock) { _ in if today != Day.today { today = Day.today } }
    }

    private func addTask() {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard clean.count <= 2000 else { inputError = "请控制在 2000 字以内。"; return }
        let task = Todo(title: clean, day: Day.today)
        if store.upsert(task) {
            newTitle = ""; inputError = nil; inputWasChosen = false; adding = false
        } else { inputError = "保存失败，请在完整清单中查看原因。" }
    }
}
