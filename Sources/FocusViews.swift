import SwiftUI

private typealias FocusStateValue<Value> = SwiftUI.State<Value>

struct FocusPane: View {
    @ObservedObject var clock: FocusClock = .shared
    let blocks: [TimeBlock]
    let day: String
    @Binding var selectedBlock: UUID?
    @FocusStateValue private var freeTitle = ""
    @FocusStateValue private var custom = false

    private var chosen: TimeBlock? { blocks.first { $0.id == selectedBlock && !$0.isRest } }
    private var canStart: Bool { day == Day.today && (chosen.map { $0.endMinute > ClockText.minuteNow() && !$0.completed } ?? true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "timer").foregroundColor(Palette.pink)
                Text("一段专注").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("今天 \(clock.seconds(on: Day.today) / 60) min").font(.system(size: 10)).foregroundColor(Palette.secondary)
            }
            if let session = clock.session {
                Text(clock.phaseText).font(.system(size: 11)).foregroundColor(session.phase == .rest ? Palette.green : Palette.pink)
                Text(clock.clockText).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                ProgressView(value: max(0, min(1, 1 - Double(clock.remaining) / Double(max(1, session.initialSeconds)))))
                    .tint(session.phase == .rest ? Palette.green : Palette.pink)
                Text(session.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let hardStop = session.hardStop {
                    Text("本时段最晚到 " + hardStop.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).foregroundColor(Palette.secondary)
                }
                FocusControls(clock: clock)
            } else {
                Text("\(clock.workMinutes):00").font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                    .frame(maxWidth: .infinity).foregroundColor(Palette.ink)
                Picker("关联时段", selection: $selectedBlock) {
                    Text("自由专注").tag(Optional<UUID>.none)
                    ForEach(blocks.filter { !$0.isRest && !$0.completed }) { Text($0.title).tag(Optional($0.id)) }
                }.labelsHidden().font(.system(size: 11))
                if chosen == nil { TextField("这一轮想做什么？", text: $freeTitle).textFieldStyle(.roundedBorder).font(.system(size: 11)) }
                Button("开始专注") {
                    _ = clock.start(title: chosen?.title ?? freeTitle, blockID: chosen?.id, taskID: chosen?.taskID,
                        hardStop: chosen.flatMap { ClockText.date($0.day, $0.endMinute) })
                }.buttonStyle(.borderedProminent).tint(Palette.pink).frame(maxWidth: .infinity).disabled(!canStart)
                if day != Day.today { Text("未来时段先安排好，到当天再开始专注。").font(.system(size: 10)).foregroundColor(Palette.secondary) }
            }
            Divider().opacity(0.6)
            Picker("节奏", selection: Binding(get: {
                if custom { return 0 }; return clock.workMinutes == 25 && clock.restMinutes == 5 ? 25 : (clock.workMinutes == 50 && clock.restMinutes == 10 ? 50 : 0)
            }, set: { value in
                custom = value == 0
                if value == 25 { clock.setDurations(work: 25, rest: 5) }
                if value == 50 { clock.setDurations(work: 50, rest: 10) }
            })) {
                Text("25 / 5").tag(25); Text("50 / 10").tag(50); Text("自定义").tag(0)
            }.pickerStyle(.segmented)
            if custom || !(clock.workMinutes == 25 && clock.restMinutes == 5 || clock.workMinutes == 50 && clock.restMinutes == 10) {
                Stepper("专注 \(clock.workMinutes) 分钟", value: Binding(get: { clock.workMinutes }, set: { clock.setDurations(work: $0, rest: clock.restMinutes) }), in: 5...120, step: 5)
                Stepper("休息 \(clock.restMinutes) 分钟", value: Binding(get: { clock.restMinutes }, set: { clock.setDurations(work: clock.workMinutes, rest: $0) }), in: 1...30)
            }
            Text("专注 / 休息（分钟）。每轮结束后，由你决定休息或继续；到时间不会自动划掉事项。")
                .font(.system(size: 10)).foregroundColor(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            if !clock.message.isEmpty { Text(clock.message).font(.system(size: 10)).foregroundColor(Palette.green).fixedSize(horizontal: false, vertical: true) }
            if RuntimeMode.demo {
                Text("演示模式不会申请系统通知权限。").font(.system(size: 9)).foregroundColor(Palette.secondary)
            } else if !clock.notificationsEnabled {
                Button("开启时段与专注提醒") { clock.requestNotifications() }.font(.system(size: 10))
                Text("未开启时，应用内仍显示倒计时与结束提示。")
                    .font(.system(size: 9)).foregroundColor(Palette.secondary)
            }
        }.font(.system(size: 11)).padding(21).background(.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
    }
}

struct FocusControls: View {
    @ObservedObject var clock: FocusClock
    var body: some View {
        HStack(spacing: 9) {
            if let phase = clock.session?.phase {
                if phase == .readyBreak {
                    Button("休息 \(clock.restMinutes) 分钟") { clock.beginBreak() }.buttonStyle(.borderedProminent).tint(Palette.green)
                    Button("再来一轮") { clock.nextRound() }
                } else if phase == .readyWork {
                    Button("开始下一轮") { clock.nextRound() }.buttonStyle(.borderedProminent).tint(Palette.pink)
                } else {
                    Button(clock.running ? "暂停" : "继续") { if clock.running { clock.pause() } else { clock.resume() } }
                }
                Spacer(minLength: 0)
                Button("结束") { clock.end() }.foregroundColor(Palette.secondary)
            }
        }.font(.system(size: 11))
    }
}

struct FocusMenuView: View {
    @ObservedObject var clock: FocusClock
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(clock.phaseText).font(.system(size: 12, weight: .medium))
            Text(clock.clockText).font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
            Text(clock.session?.title ?? "").font(.system(size: 12)).lineLimit(3)
            FocusControls(clock: clock)
            Button("打开我Due！") { DesktopNoteController.shared.openMain() }
        }.padding(20).frame(width: 300).foregroundColor(Palette.ink).background(Palette.paper)
    }
}
