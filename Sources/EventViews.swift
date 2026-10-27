import SwiftUI
import AppKit

private let eventInk = Color(hex: 0xAD3E39)
private let eventTint = Color(hex: 0xF9E9E5)

struct EventReminderStatus: View {
    let task: Todo
    @ObservedObject private var reminder = EventReminder.shared
    var body: some View {
        if let item = EventEngine.item(task) {
            VStack(alignment: .leading, spacing: 8) {
                if item.expires > Date() {
                    Label(reminder.scheduleLabel(item), systemImage: "bell")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                if let url = item.link {
                    Link(destination: url) { Label("打开活动链接", systemImage: "video") }
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Palette.pink)
                        .help(url.host ?? "活动链接")
                }
            }
        }
    }
}

struct EventBanner: View {
    @ObservedObject private var reminder = EventReminder.shared
    private var next: EventItem? { reminder.items.first { $0.start.timeIntervalSinceNow <= 24 * 3600 } }
    var body: some View {
        if let item = next {
            let urgent = item.stage(at: Date()) != nil
            HStack(spacing: 12) {
                Image(systemName: urgent ? "bell.badge.fill" : "video").foregroundColor(urgent ? eventInk : Palette.pink)
                VStack(alignment: .leading, spacing: 5) {
                    Text((urgent ? item.countdown(at: Date()) : "下一场活动") + " · " + item.task.title)
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(item.exactLabel + " · " + reminder.scheduleLabel(item))
                        .font(.system(size: 10)).foregroundColor(Palette.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if let url = item.link {
                    Link("打开活动链接", destination: url).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.pink)
                }
                Button("查看活动") { reminder.show(id: item.id) }.font(.system(size: 10))
                if !reminder.notificationsEnabled && !RuntimeMode.demo {
                    Button("开启系统通知") { FocusClock.shared.requestNotifications() }.font(.system(size: 10))
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .foregroundColor(Palette.ink).background(urgent ? eventTint : Palette.sidebar.opacity(0.55))
                .overlay(alignment: .leading) { Rectangle().fill(urgent ? eventInk : Palette.pink).frame(width: 3) }
        }
    }
}

struct EventNoteStrip: View {
    @ObservedObject private var reminder = EventReminder.shared
    let lightText: Bool
    var body: some View {
        if let item = reminder.items.first(where: { $0.stage(at: Date()) != nil }) {
            VStack(alignment: .leading, spacing: 7) {
                Button { reminder.show(id: item.id) } label: {
                    Label(item.countdown(at: Date()) + " · " + item.task.title, systemImage: "bell.badge.fill")
                        .font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(3)
                }.buttonStyle(.plain)
                if let url = item.link {
                    Link(destination: url) { Label("打开活动链接", systemImage: "video") }
                        .font(.system(size: 10, weight: .semibold))
                }
            }.foregroundColor(lightText ? Color(hex: 0xFFA89C) : eventInk)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 11)
        }
    }
}

private final class EventPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class EventPanelController {
    static let shared = EventPanelController()
    private var panel: EventPanel?
    func update(reminder: EventReminder, requested: Bool = false) {
        guard !reminder.presented.isEmpty else { panel?.orderOut(nil); return }
        let height = EventPopupView.height(reminder.presented.count)
        if panel == nil {
            let window = EventPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "会议与活动提醒"; window.identifier = NSUserInterfaceItemIdentifier("EventReminder")
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.isFloatingPanel = true; window.becomesKeyOnlyIfNeeded = true
            window.isMovableByWindowBackground = true; window.isOpaque = false
            window.backgroundColor = .clear; window.hasShadow = true
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: EventPopupView(reminder: reminder))
            panel = window
        }
        guard let panel else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = min(height, area.height - 30)
        if !panel.isVisible {
            panel.setFrame(NSRect(x: area.midX - 235, y: area.maxY - size - 40, width: 470, height: size), display: false)
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(NSRect(x: min(max(panel.frame.minX, area.minX), area.maxX - 470),
                y: max(area.minY, min(panel.frame.minY, area.maxY - size)), width: 470, height: size), display: true)
        }
        if requested { panel.makeKeyAndOrderFront(nil) }
    }
}

private struct EventPopupView: View {
    @ObservedObject var reminder: EventReminder
    private var urgent: Bool { reminder.presented.contains { $0.stage(at: Date()) != nil } }
    static func height(_ count: Int) -> CGFloat { min(570, 224 + CGFloat(count) * 145) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge.fill").font(.system(size: 26)).foregroundColor(eventInk)
                VStack(alignment: .leading, spacing: 6) {
                    Text(urgent ? "活动快开始了，准备参加。" : "会议与活动，提前留意。")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text("提前 15 分钟提醒，开始时再提醒一次。")
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                Spacer(minLength: 0)
                Button { reminder.acknowledge() } label: { Image(systemName: "xmark").frame(width: 23, height: 23) }
                    .buttonStyle(.plain).accessibilityLabel("关闭本轮活动提醒")
            }.padding(22).background(eventTint)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(reminder.presented) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.task.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(item.exactLabel).font(.system(size: 11)).foregroundColor(eventInk)
                            if item.stage(at: Date()) != nil {
                                Text(item.countdown(at: Date())).font(.system(size: 12, weight: .bold)).foregroundColor(eventInk)
                            }
                            Text(reminder.scheduleLabel(item)).font(.system(size: 10)).foregroundColor(Palette.secondary)
                            HStack {
                                if item.link != nil {
                                    Button("打开活动链接") { reminder.openLink(item) }.buttonStyle(.borderedProminent).tint(eventInk)
                                }
                                Button("查看详情") { reminder.open(item) }
                                Spacer(minLength: 0)
                                Button("标为完成") { reminder.complete(item) }
                            }.font(.system(size: 11))
                        }.padding(20)
                        Divider().padding(.horizontal, 20)
                    }
                }
            }.scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("桌面弹窗", isOn: Binding(get: { reminder.popupsEnabled }, set: reminder.setPopups))
                        .toggleStyle(.checkbox)
                    Spacer()
                    if urgent { Button("5 分钟后提醒") { reminder.snooze() } }
                    Button("知道了") { reminder.acknowledge() }.keyboardShortcut(.cancelAction)
                }.font(.system(size: 11))
                if !reminder.notificationsEnabled && !RuntimeMode.demo {
                    Button("开启系统通知") { FocusClock.shared.requestNotifications() }.font(.system(size: 11))
                }
                if !reminder.message.isEmpty { Text(reminder.message).font(.system(size: 10)).foregroundColor(eventInk) }
                Text("稍后提醒最迟到开始时刻；完成或改期后，会取消或重排提醒。")
                    .font(.system(size: 9)).foregroundColor(Palette.secondary)
            }.padding(20)
        }.frame(width: 470, height: Self.height(reminder.presented.count))
            .foregroundColor(Palette.ink).background(Palette.paper).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(eventInk.opacity(0.3), lineWidth: 1)).preferredColorScheme(.light)
    }
}
