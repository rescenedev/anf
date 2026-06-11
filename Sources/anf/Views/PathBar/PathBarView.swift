import SwiftUI

/// Breadcrumb trail at the bottom edge. Each component is clickable; the current
/// folder is emphasised. A trailing status segment shows counts/selection.
struct PathBarView: View {
    let model: BrowserModel

    var body: some View {
        let comps = model.pathComponents
        HStack(spacing: 2) {
            ForEach(Array(comps.enumerated()), id: \.element) { idx, url in
                if idx > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.navigate(to: url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: idx == 0 ? "macwindow" : "folder")
                            .font(.system(size: 10))
                        Text(label(url))
                    }
                    .font(.system(size: 11, weight: idx == comps.count - 1 ? .semibold : .regular))
                    .foregroundStyle(idx == comps.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private func label(_ url: URL) -> String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }

    private var status: String {
        let total = model.items.count
        let sel = model.selection.count
        if sel > 0 {
            let bytes = model.selectedItems.reduce(Int64(0)) { $0 + $1.size }
            return L("\(sel) of \(total) selected · \(Format.bytes(bytes))", "\(total)개 중 \(sel)개 선택됨 · \(Format.bytes(bytes))")
        }
        return L("\(total) item\(total == 1 ? "" : "s")", "\(total)개 항목")
    }
}
