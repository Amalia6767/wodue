import SwiftUI
import AppKit

private typealias CanvasState<Value> = SwiftUI.State<Value>

enum ImportClipboard {
    static func text() -> String? {
        let board = NSPasteboard.general
        if let html = board.string(forType: .html), html.contains("/courses/") {
            return String(CanvasParser.textFromHTML(html).prefix(100_000))
        }
        return board.string(forType: .string).map { String($0.prefix(100_000)) }
    }
}

struct CanvasImportView: View {
    @ObservedObject var store: TodoStore
    let onClose: () -> Void
    @CanvasState private var source: String
    @CanvasState private var parsedSource = ""
    @CanvasState private var candidates: [CanvasCandidate] = []
    @CanvasState private var parsed = false
    @CanvasState private var help = false
    @CanvasState private var resultMessage = ""
    private var draftURL: URL { store.fileURL.deletingLastPathComponent().appendingPathComponent("canvas-draft.txt") }

    init(store: TodoStore, source: String, onClose: @escaping () -> Void) {
        self.store = store; self.onClose = onClose
        let file = store.fileURL.deletingLastPathComponent().appendingPathComponent("canvas-draft.txt")
        _source = State(initialValue: source.isEmpty ? ((try? String(contentsOf: file, encoding: .utf8)) ?? "") : source)
    }
    private var chosen: [CanvasCandidate] {
        guard source == parsedSource else { return [] }
        return candidates.filter { item in
            let state = store.canvasDisposition(item)
            return item.selected && item.day != nil && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && item.title.count <= 2000 && !item.requiresConfirmation && (state == .add || state == .update || state == .unchanged)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("作业变了，清单也跟着更新。")
                        .font(.system(size: 24, weight: .medium, design: .serif))
                    Text("粘贴 Canvas 作业、公告或通知；同一份作业按最新通知合并，保留完成状态。")
                        .font(.system(size: 11)).foregroundColor(Palette.secondary)
                }
                Spacer()
                Button { help.toggle() } label: { Label("自动订阅", systemImage: "calendar.badge.plus") }
                    .popover(isPresented: $help) { subscriptionHelp.padding(24).frame(width: 390) }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Canvas 原文").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("粘贴") { if let text = ImportClipboard.text() { source = text; parse() } }
                    }
                    TextEditor(text: $source).font(.system(size: 11))
                        .scrollContentBackground(.hidden).padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
                        .accessibilityLabel("Canvas 待识别内容")
                    HStack {
                        Text("保留链接可识别同一份作业。")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                        Spacer()
                        Button("识别并预览", action: parse).disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.frame(width: 325)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("确认要放进清单的事").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if parsed { Text("\(candidates.count) 项 · 已选 \(chosen.count) 项").font(.system(size: 10)).foregroundColor(Palette.secondary) }
                    }
                    if parsed && !candidates.isEmpty {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(candidates.indices, id: \.self) { index in
                                    candidateCard(index)
                                }
                            }.padding(.trailing, 5)
                        }
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundColor(Palette.pink.opacity(0.6))
                            Text(parsed ? "没有识别到作业。可复制作业标题、链接和 Due 一行后再试。" : "可一次粘贴整页作业或多条通知。")
                                .font(.system(size: 12)).multilineTextAlignment(.center)
                            Text("发布时间用于比较先后，Due 才是截止时间。")
                                .font(.system(size: 10)).foregroundColor(Palette.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if source != parsedSource && parsed { Text("原文已更改，请重新识别。").font(.system(size: 10)).foregroundColor(Palette.pink) }
                }.frame(maxWidth: .infinity)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resultMessage.isEmpty ? "勾选是确认导入；缺日期、旧通知与普通信息不会自动加入。" : resultMessage)
                    Text("加入本机待办；日历弹出提醒可用“导出日历”，持续同步请用“自动订阅”。")
                        .foregroundColor(Palette.secondary)
                }.font(.system(size: 10))
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("导出日历…", action: exportCalendar).disabled(chosen.isEmpty)
                Button("加入 / 更新 \(chosen.count) 项", action: add)
                    .buttonStyle(.borderedProminent).tint(Palette.pink).disabled(chosen.isEmpty)
            }
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
            .onAppear { if !source.isEmpty { parse() } }
            .onChange(of: source) { _, text in
                try? String(text.prefix(100_000)).write(to: draftURL, atomically: true, encoding: .utf8)
            }
    }
    @ViewBuilder private func candidateCard(_ index: Int) -> some View {
        let item = candidates[index]
        let disposition = store.canvasDisposition(item)
        let blocked = [.older, .unknownOrder, .conflict].contains(disposition)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(get: { candidates[index].selected }, set: { value in
                    candidates[index].selected = value
                    if value { candidates[index].requiresConfirmation = false }
                })).labelsHidden().toggleStyle(.checkbox).disabled(item.day == nil || blocked)
                    .accessibilityLabel("导入 " + item.title)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("事项名称", text: $candidates[index].title, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).lineLimit(2...4)
                    HStack(spacing: 6) {
                        Text(item.informational ? "信息通知" : disposition.rawValue)
                            .foregroundColor(blocked ? Palette.pink : Palette.green)
                        if item.mergedCount > 1 { Text("合并 \(item.mergedCount) 条").foregroundColor(Palette.secondary) }
                        Spacer()
                        if let url = WebLink.safe(item.link) { Link("原文 ↗", destination: url) }
                    }.font(.system(size: 9))
                }
            }
            HStack(spacing: 9) {
                Text(item.source.isDeadline ? "截止" : "日期").font(.system(size: 10)).foregroundColor(Palette.secondary)
                if let day = item.day, let date = Day.date(day) {
                    DatePicker("", selection: Binding(get: { Day.date(candidates[index].day ?? "") ?? date }, set: {
                        candidates[index].day = Day.key($0); candidates[index].requiresConfirmation = true; candidates[index].selected = false
                    }), displayedComponents: .date).labelsHidden().datePickerStyle(.field).controlSize(.small)
                } else {
                    Button("指定日期…") { candidates[index].day = Day.today; candidates[index].requiresConfirmation = true }
                        .controlSize(.small)
                }
                Toggle("时间", isOn: Binding(get: { candidates[index].minute != nil }, set: {
                    candidates[index].minute = $0 ? 1439 : nil
                    candidates[index].requiresConfirmation = true; candidates[index].selected = false
                })).font(.system(size: 10)).toggleStyle(.checkbox)
                if item.minute != nil {
                    DatePicker("", selection: Binding(get: {
                        Day.calendar.date(byAdding: .minute, value: candidates[index].minute ?? 0, to: Day.calendar.startOfDay(for: Date()))!
                    }, set: {
                        candidates[index].minute = Day.calendar.component(.hour, from: $0) * 60 + Day.calendar.component(.minute, from: $0)
                        candidates[index].requiresConfirmation = true; candidates[index].selected = false
                    }), displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field).controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .environment(\.locale, Locale(identifier: "zh_CN")).disabled(disposition == .older)
            if let posted = item.source.notifiedAt {
                Text("通知发布：" + posted.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 9)).foregroundColor(Palette.secondary)
            }
            if [.unknownOrder, .conflict].contains(disposition) {
                Label("与清单已有通知无法排定先后，保留原任务。", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundColor(Palette.pink)
            }
            ForEach(Array(item.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.system(size: 10)).foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.requiresConfirmation && item.day != nil && !blocked {
                Text("请确认日期与时间后勾选此项。\(item.minute == nil ? "将作为当天待办，不设具体时刻。" : "")")
                    .font(.system(size: 10)).foregroundColor(Color(hex: 0x9A7955))
            }
            DisclosureGroup("原始通知") {
                Text(item.original).font(.system(size: 10)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
            }.font(.system(size: 10)).foregroundColor(Palette.secondary)
        }.padding(14).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
    private var subscriptionHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("让作业截止时间自动跟过来").font(.system(size: 17, weight: .medium))
            Text("1. Canvas → Calendar → Calendar Feed，复制订阅链接。\n\n2. Mac 日历 → 文件 → 新建日历订阅，粘贴链接，选择自动刷新。\n\n3. 我Due！ → 日历同步，勾选新出现的 Canvas 日历。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("订阅包含 Canvas 日历事件；普通公告和 To Do 条目不在订阅范围。公告中的延期、上课变更可在这里粘贴解析。刷新速度由 Canvas 和 Mac 日历决定。")
                .font(.system(size: 10)).foregroundColor(Palette.secondary)
            Link("Canvas 官方订阅说明 ↗", destination: URL(string: "https://community.instructure.com/en/kb/articles/662804-how-do-i-view-the-calendar-ical-feed-to-import-and-subscribe-to-an-external-calendar")!)
                .font(.system(size: 11))
        }.foregroundColor(Palette.ink)
    }
    private func parse() {
        candidates = CanvasParser.parse(source); parsedSource = source; parsed = true; resultMessage = ""
        try? String(source.prefix(100_000)).write(to: draftURL, atomically: true, encoding: .utf8)
    }
    private func add() {
        let count = chosen.count
        guard count > 0, store.importCanvas(chosen) else { return }
        store.toast = "已处理 \(count) 项 Canvas 作业"
        resultMessage = "已加入或更新 \(count) 项，完成状态已保留。"
        candidates.indices.forEach { candidates[$0].selected = false }
        try? "".write(to: draftURL, atomically: true, encoding: .utf8)
    }
    private func exportCalendar() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Canvas 截止提醒.ics"
        panel.allowedContentTypes = [.init(filenameExtension: "ics")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CanvasCalendarExport.make(chosen).write(to: url, atomically: true, encoding: .utf8)
            resultMessage = "已导出，打开 .ics 可加入 Mac 日历；之后的变更需重新导出。"
        } catch { store.errorMessage = "导出日历失败：" + error.localizedDescription }
    }
}
