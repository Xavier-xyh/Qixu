import SwiftUI
import AppKit
import MoleCore

struct RebuildActivityView: View {
    @State private var records: [ActivityRecord] = []
    @State private var trash: [TrashJournalEntry] = []
    @State private var search = ""
    @State private var restoring: TrashJournalEntry?
    @State private var error: String?
    @State private var isRestoring = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("操作记录").font(.largeTitle.bold()); Text("查看操作结果，恢复仍在废纸篓中的项目。").foregroundStyle(.secondary) }; Spacer(); Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") } }
            TextField("搜索记录", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            TabView {
                List {
                    if records.isEmpty { ContentUnavailableView("暂无操作记录", systemImage: "clock", description: Text("扫描和维护结果会记录在本机。")) }
                    ForEach(records.filter { search.isEmpty || ($0.title + $0.detail + $0.category).localizedCaseInsensitiveContains(search) }) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(item.succeeded ? .teal : .orange).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.headline); if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }; Text(item.category).font(.caption2).foregroundStyle(.tertiary) }
                            Spacer(); Text(item.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 7)
                    }
                }.tabItem { Label("全部记录", systemImage: "list.bullet") }
                List {
                    if trash.isEmpty { ContentUnavailableView("暂无恢复记录", systemImage: "trash", description: Text("本程序移入废纸篓的项目会显示在这里。")) }
                    ForEach(trash.filter { search.isEmpty || $0.originalURL.path.localizedCaseInsensitiveContains(search) }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(item.originalURL.lastPathComponent).font(.headline); Text(item.originalURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            if item.restoredAt != nil { Label("已恢复", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                            else { Button("恢复…") { restoring = item }.disabled(isRestoring) }
                        }.padding(.vertical, 6)
                    }
                }.tabItem { Label("废纸篓恢复", systemImage: "arrow.uturn.backward") }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).task { await reload() }
            .confirmationDialog("恢复到原位置？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
                if let item = restoring {
                    Button("恢复") { isRestoring = true; restoring = nil; Task { do { try await TrashService.shared.restore(item) } catch { self.error = error.localizedDescription }; await reload(); isRestoring = false } }
                    Button("取消", role: .cancel) { restoring = nil }
                }
            } message: { Text(restoring?.originalURL.path ?? "") }
    }
    private func reload() async { records = await ActivityStore.shared.records(); trash = await TrashService.shared.history() }
}
