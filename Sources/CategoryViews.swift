import SwiftUI
import AppKit

private typealias CategoryState<Value> = SwiftUI.State<Value>

struct CategoryBadge: View {
    let category: PlanCategory?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: category?.color ?? 0xB4ADA2)).frame(width: 5, height: 5)
            Text(category?.name ?? "未分类").lineLimit(1)
        }.font(.system(size: 9)).foregroundColor(Palette.secondary)
    }
}

struct CategoryManagerView: View {
    @ObservedObject var store: TodoStore
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @CategoryState private var name = ""
    @CategoryState private var color = Color(hex: 0x5D8A94)
    private func hex(_ color: Color) -> UInt32 {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("你的生活，由你分类。").font(.system(size: 23, weight: .medium, design: .serif))
            Text("作业、旅行、家庭事务，名字和颜色都可以调整。")
                .font(.system(size: 11)).foregroundColor(Palette.secondary)
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.categories) { category in CategoryEditRow(store: store, category: category) }
                }
            }
            HStack(spacing: 10) {
                ColorPicker("颜色", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 28)
                TextField("新分类名称", text: $name).textFieldStyle(.roundedBorder)
                Button("添加分类") {
                    if store.saveCategory(PlanCategory(name: name, color: hex(color))) { name = "" }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40)
            }
            HStack {
                Text("移除分类后，原事项与时间块保留为“未分类”。")
                    .font(.system(size: 10)).foregroundColor(Palette.secondary)
                Spacer()
                Button("完成") { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 550, height: 570).background(Palette.paper).foregroundColor(Palette.ink).tint(Palette.pink)
    }
}

private struct CategoryEditRow: View {
    @ObservedObject var store: TodoStore
    let category: PlanCategory
    @CategoryState private var name: String
    @CategoryState private var color: Color
    init(store: TodoStore, category: PlanCategory) {
        self.store = store; self.category = category
        _name = State(initialValue: category.name); _color = State(initialValue: Color(hex: category.color))
    }
    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("分类颜色", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 28)
            TextField("分类名称", text: $name).textFieldStyle(.roundedBorder)
            Button("保存") {
                let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
                let value = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
                _ = store.saveCategory(PlanCategory(id: category.id, name: name, color: value))
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40)
            Button { _ = store.removeCategory(category.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundColor(Palette.secondary).help("移除分类，保留事项")
        }.padding(11).background(.white, in: RoundedRectangle(cornerRadius: 9))
    }
}
