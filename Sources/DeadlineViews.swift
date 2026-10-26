import SwiftUI
import AppKit

extension DeadlineStage {
    var color: Color { Color(hex: strong ? 0xAD3E39 : 0x90601F) }
    var tint: Color { Color(hex: strong ? 0xF9E9E5 : 0xF7EFDE) }
    var symbol: String { strong ? "exclamationmark.circle.fill" : "clock.badge.exclamationmark" }
}

struct DeadlineBanner: View {
    @ObservedObject var store: TodoStore
    @ObservedObject private var reminder = DeadlineReminder.shared
    @ObservedObject private var focus = FocusClock.shared
    let onEdit: (Todo) -> Void
    private var stage: DeadlineStage { reminder.items.first?.stage ?? .soon }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: reminder.items.isEmpty ? "checkmark.shield" : stage.symbol)
                Text(reminder.items.isEmpty ? "DDL 提醒已准备好" :
                    (reminder.items.contains(where: { $0.stage == .overdue }) ? "临近截止与逾期 · \(reminder.items.count) 项" : "三天内的截止事项 · \(reminder.items.count) 项"))
                    .fontWeight(.semibold)
                Spacer()
                if RuntimeMode.demo { Text("演示数据").font(.system(size: 10)) }
                Toggle("桌面弹窗", isOn: Binding(get: { reminder.popupsEnabled }, set: reminder.setPopups))
                    .toggleStyle(.checkbox).font(.system(size: 10))
                    .help("临近截止时弹出卡片；每个阶段确认一次，稍后提醒可推迟 30 分钟。")
                if !focus.notificationsEnabled && !RuntimeMode.demo {
                    Button("开启系统通知") { focus.requestNotifications() }.font(.system(size: 10))
                }
                if !reminder.items.isEmpty { Button("查看全部") { reminder.show() }.font(.system(size: 10)) }
            }.font(.system(size: 12)).foregroundColor(reminder.items.isEmpty ? Palette.secondary : stage.color)
            ForEach(Array(reminder.items.prefix(2))) { item in
                HStack(alignment: .center, spacing: 10) {
                    Text(item.stage.label).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .foregroundColor(item.stage.color).background(item.stage.color.opacity(0.09), in: Capsule())
                    VStack(alignment: .leading, spacing: 4) {
                        Button { onEdit(item.task) } label: {
                            Text(item.task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }.buttonStyle(.plain).foregroundColor(Palette.ink)
                        Text(item.exactLabel).font(.system(size: 10)).foregroundColor(Palette.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(item.countdown(at: Date())).font(.system(size: 11, weight: .semibold)).foregroundColor(item.stage.color)
                    Button { reminder.complete(item) } label: { Image(systemName: "circle").font(.system(size: 16)) }
                        .buttonStyle(.plain).foregroundColor(item.stage.color).help("标为已完成，停止这件事的截止提醒")
                }
            }
            if reminder.items.isEmpty {
                Text("将事项性质设为“提交 / 截止”。三天内突出显示，临近截止逐级提醒；标题以 DDL / deadline 开头的单日事项也会识别。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            if !reminder.message.isEmpty { Text(reminder.message).font(.system(size: 10)).foregroundColor(stage.color) }
        }.padding(.horizontal, 20).padding(.vertical, 13)
            .background(reminder.items.isEmpty ? Palette.paper : stage.tint)
            .overlay(alignment: .leading) { Rectangle().fill(reminder.items.isEmpty ? Palette.line : stage.color).frame(width: 3) }
    }
}

private final class DeadlinePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DeadlinePanelController {
    static let shared = DeadlinePanelController()
    private var panel: DeadlinePanel?
    func update(reminder: DeadlineReminder, store: TodoStore, requested: Bool = false) {
        guard !reminder.presented.isEmpty else { panel?.orderOut(nil); return }
        let height = DeadlinePopupView.height(reminder.presented.count)
        if panel == nil {
            let window = DeadlinePanel(contentRect: NSRect(x: 0, y: 0, width: 456, height: height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "临近截止的事项"
            window.identifier = NSUserInterfaceItemIdentifier("DeadlineReminder")
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.isFloatingPanel = true; window.becomesKeyOnlyIfNeeded = true
            window.isMovableByWindowBackground = true; window.isOpaque = false
            window.backgroundColor = .clear; window.hasShadow = true
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: DeadlinePopupView(reminder: reminder, store: store))
            panel = window
        }
        guard let panel else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        if !panel.isVisible {
            panel.setFrame(NSRect(x: area.maxX - 480, y: area.minY + 30, width: 456, height: min(height, area.height - 30)), display: false)
            panel.orderFrontRegardless()
        } else {
            let origin = panel.frame.origin
            panel.setFrame(NSRect(x: min(max(origin.x, area.minX), area.maxX - 456),
                y: min(max(origin.y, area.minY), area.maxY - height), width: 456, height: min(height, area.height)), display: true)
        }
        if requested { panel.makeKeyAndOrderFront(nil) }
    }
}

private struct DeadlinePopupView: View {
    @ObservedObject var reminder: DeadlineReminder
    @ObservedObject var store: TodoStore
    private var stage: DeadlineStage { reminder.presented.first?.stage ?? .soon }
    static func height(_ count: Int) -> CGFloat { min(540, 208 + CGFloat(count) * 94) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stage.symbol).font(.system(size: 29)).foregroundColor(stage.color)
                VStack(alignment: .leading, spacing: 6) {
                    Text(stage == .overdue ? "截止时间已经过了。" : (stage.strong ? "截止时间近了。" : "这几件事，需要开始准备了。"))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("\(reminder.presented.count) 项截止提醒 · 完成后勾掉，就会停止提醒")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                Spacer(minLength: 0)
                Button { reminder.acknowledge() } label: { Image(systemName: "xmark").frame(width: 23, height: 23) }
                    .buttonStyle(.plain).foregroundColor(Palette.secondary).help("确认本轮提醒")
                    .accessibilityLabel("确认本轮截止提醒")
            }.padding(22).background(stage.tint)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(reminder.presented) { item in
                        HStack(alignment: .top, spacing: 11) {
                            Button { reminder.complete(item) } label: { Image(systemName: "circle").font(.system(size: 18)) }
                                .buttonStyle(.plain).foregroundColor(item.stage.color).help("标为已完成")
                                .accessibilityLabel("完成：" + item.task.title)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 7) {
                                    Text(item.stage.label).font(.system(size: 10, weight: .bold)).foregroundColor(item.stage.color)
                                    CategoryBadge(category: store.category(item.task.categoryID))
                                }
                                Button { reminder.open(item) } label: { Text(item.task.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading) }
                                    .buttonStyle(.plain).help("在完整清单中查看和编辑")
                                Text(item.exactLabel + (item.due == nil ? "" : " · " + item.countdown(at: Date())))
                                    .font(.system(size: 10)).foregroundColor(item.stage.color).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 22).padding(.vertical, 15)
                        Divider().padding(.horizontal, 22)
                    }
                }
            }.scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("30 分钟后提醒") { reminder.snooze() }
                    Spacer()
                    Button("知道了") { reminder.acknowledge() }.buttonStyle(.borderedProminent).tint(stage.color).keyboardShortcut(.cancelAction)
                }.font(.system(size: 12))
                Text("确认后本阶段不再弹出；进入下一个提醒阶段时再次提示。")
                    .font(.system(size: 9)).foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }.frame(width: 456, height: Self.height(reminder.presented.count))
            .foregroundColor(Palette.ink).background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(stage.color.opacity(0.3), lineWidth: 1))
            .preferredColorScheme(.light)
    }
}
