import SwiftUI

struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var tab: TabSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                Text(pane.title).font(.system(size: 11, weight: .medium))
                Spacer()
                if let dir = pane.cwd {
                    Text(dir).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if tab.broadcast && pane.shellID != nil {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.cyan).font(.system(size: 10))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.gray.opacity(0.15))
            ScrollView {
                Text(pane.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.black)
        }
        .background(Color.black)
        .onTapGesture { tab.setActive(paneID: pane.id) }
        .overlay(
            Rectangle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: tab.activePaneID == pane.id ? 2 : 0)
        )
    }
}