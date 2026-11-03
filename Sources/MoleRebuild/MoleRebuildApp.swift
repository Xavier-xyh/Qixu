import SwiftUI
import AppKit
import MoleCore

final class RebuildAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

enum RebuildSection: String, CaseIterable, Identifiable {
    case overview = "总览", cleaning = "清理空间", software = "软件管理", disk = "磁盘分析", monitor = "系统状态", tools = "维护工具", activity = "操作记录"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cleaning: return "sparkles"
        case .software: return "square.stack.3d.up"
        case .disk: return "chart.pie"
        case .monitor: return "waveform.path.ecg"
        case .tools: return "wrench.and.screwdriver"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}
@MainActor final class RebuildRouter: ObservableObject { @Published var selection: RebuildSection = .overview }

@main
struct MoleRebuildApp: App {
    @NSApplicationDelegateAdaptor(RebuildAppDelegate.self) private var delegate
    @StateObject private var router = RebuildRouter()
    @StateObject private var disk = DiskViewModel()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("appearance") private var appearance = "system"
    private var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    var body: some Scene {
        WindowGroup("Qixu") {
            RebuildRootView(router: router, disk: disk).preferredColorScheme(colorScheme)
                .frame(minWidth: 1080, minHeight: 730)
                .onAppear {
                    let args = CommandLine.arguments
                    if let position = args.firstIndex(of: "--inspect-folder"), args.indices.contains(position + 1), disk.currentURL == nil {
                        router.selection = .disk; disk.open(URL(fileURLWithPath: args[position + 1], isDirectory: true))
                    }
                }
        }
        .defaultSize(width: 1240, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("分析文件夹…") { router.selection = .disk; disk.chooseFolder() }.keyboardShortcut("o")
            }
            CommandMenu("前往") {
                ForEach(Array(RebuildSection.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.rawValue) { router.selection = item }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        MenuBarExtra(isInserted: $showMenuBar) { MonitorMenuContent() } label: { MonitorMenuLabel() }.menuBarExtraStyle(.window)
        Settings { RebuildSettingsView(disk: disk).preferredColorScheme(colorScheme) }
    }
}

struct RebuildRootView: View {
    @ObservedObject var router: RebuildRouter
    @ObservedObject var disk: DiskViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 9) {
                    QixuBrandMark().frame(width: 30, height: 30).accessibilityHidden(true)
                    Text("Qixu").font(.title3.weight(.bold))
                }.fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(RebuildSection.allCases) { item in
                        let selected = router.selection == item
                        Button {
                            router.selection = item
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .fixedSize()
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .foregroundStyle(selected ? Color.teal : Color.secondary)
                                .background(Color.teal.opacity(selected ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("设置").help("设置")
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.bar)
            Divider()
            Group {
                switch router.selection {
                case .overview: RebuildOverviewView(router: router)
                case .cleaning: CleaningView()
                case .software: SoftwareView()
                case .disk: DiskView(model: disk)
                case .monitor: MonitorView()
                case .tools: ToolsView()
                case .activity: RebuildActivityView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
