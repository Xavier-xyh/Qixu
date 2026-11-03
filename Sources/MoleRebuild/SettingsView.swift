import SwiftUI
import MoleCore

struct RebuildSettingsView: View {
    @ObservedObject var disk: DiskViewModel
    @ObservedObject private var monitor = MonitorModel.shared
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("excludedPaths") private var excludedPaths = ""
    @AppStorage("directoryScanBudget") private var budget = 0.25
    @State private var notice: String?
    var body: some View {
        Form {
            Section("通用") {
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Toggle("在菜单栏显示系统状态", isOn: $showMenuBar)
                HStack { Text("监控采样等待"); Slider(value: $monitor.interval, in: 0.5...5, step: 0.5); Text(String(format: "%.1f 秒", monitor.interval)).monospacedDigit().frame(width: 58) }
            }
            Section("磁盘分析") {
                Toggle("显示隐藏文件", isOn: $disk.showHidden).onChange(of: disk.showHidden) { _, _ in disk.hiddenChanged() }
                HStack { Text("目录首次测量预算"); Slider(value: $budget, in: 0.1...2, step: 0.05); Text(String(format: "%.2f 秒", budget)).monospacedDigit().frame(width: 66) }
                Text("超过预算的目录会保留部分结果，并在后台继续测量。").font(.caption).foregroundStyle(.secondary)
                Button("清空分析缓存") { Task { await disk.clearCache(); notice = disk.cacheNotice ?? disk.error } }
            }
            Section("排除路径") {
                Text("每行填写一个绝对路径；该目录及其子项不会被清理候选和磁盘扫描纳入。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $excludedPaths).font(.system(.caption, design: .monospaced)).frame(height: 105)
                    .onChange(of: excludedPaths) { _, value in
                        let paths = value.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: { $0.value < 0x20 }) }
                        UserDefaults.standard.set(paths, forKey: "cleaningExcludedPaths")
                    }
            }
            Section("关于") {
                LabeledContent("应用", value: "Qixu")
                LabeledContent("系统要求", value: "macOS 14 或更新版本")
                Text("独立实现，使用本机 API。硬件读数不可用时会如实显示；清理和卸载在复核后执行。").font(.caption).foregroundStyle(.secondary)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding().frame(width: 640, height: 680)
            .onAppear {
                let stored = UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? []
                let visible = excludedPaths.split(separator: "\n").map(String.init)
                let merged = Array(Set(visible + stored)).sorted().joined(separator: "\n")
                if merged != excludedPaths { excludedPaths = merged }
            }
    }
}
