import SwiftUI
import MoleCore

struct MonitorHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
    let gpu: Double?
    let received: Double
    let sent: Double
}

@MainActor
final class MonitorModel: ObservableObject {
    static let shared = MonitorModel()
    @Published private(set) var snapshot: MonitorSnapshot?
    @Published private(set) var history: [MonitorHistoryPoint] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published var interval: Double = 1 {
        didSet {
            let bounded = interval.isFinite ? min(5, max(0.5, interval)) : 1
            if interval != bounded { interval = bounded; return }
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval, forKey: "monitor.interval")
            if isRunning { restart() }
        }
    }
    private let collector = SystemMonitorCollector()
    private var consumers: Set<String> = []
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {
        let saved = UserDefaults.standard.double(forKey: "monitor.interval")
        _interval = Published(initialValue: saved >= 0.5 && saved <= 5 ? saved : 1)
    }

    func acquire(_ name: String) { consumers.insert(name); startIfNeeded() }
    func release(_ name: String) {
        consumers.remove(name)
        if consumers.isEmpty { stop() }
    }
    func togglePause() {
        isPaused.toggle()
        if isPaused { stop() } else { startIfNeeded() }
    }
    func refresh() {
        guard !isPaused else { return }
        restart()
    }
    private func restart() { stop(); startIfNeeded() }
    private func stop() {
        generation &+= 1; task?.cancel(); task = nil; isRunning = false
    }
    private func startIfNeeded() {
        guard task == nil, !consumers.isEmpty, !isPaused else { return }
        isRunning = true
        let workGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.generation == workGeneration {
                let detailed = self.consumers.contains { !$0.hasPrefix("label-") }
                let value = await self.collector.collect(includeProcesses: detailed)
                guard !Task.isCancelled, self.generation == workGeneration else { break }
                self.snapshot = value
                self.history.append(MonitorHistoryPoint(date: value.date,
                    cpu: value.cpu?.hasBaseline == true ? value.cpu?.usage : nil,
                    memory: value.memory?.usedPercent,
                    gpu: value.gpuPercent,
                    received: value.network.reduce(0) { $0 + $1.receivedPerSecond },
                    sent: value.network.reduce(0) { $0 + $1.sentPerSecond }))
                self.history.removeAll { $0.date < value.date.addingTimeInterval(-120) }
                if self.history.count > 300 { self.history.removeFirst(self.history.count - 300) }
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { break }
            }
        }
    }
}

enum MonitorDisplay {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
    }
    static func bytes(_ value: Int64) -> String { bytes(UInt64(max(0, value))) }
    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max) - 1024)), countStyle: .file) + "/s"
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func thermal(_ state: Int) -> String {
        switch state { case 0: return "正常"; case 1: return "温暖"; case 2: return "较热"; case 3: return "高温"; default: return "未知" }
    }
    static func pressure(_ value: Int) -> String {
        switch value { case 1: return "正常"; case 2: return "偏高"; case 4: return "紧张"; default: return "不可用" }
    }
    static func uptime(_ value: TimeInterval) -> String {
        let minutes = Int(max(0, value) / 60)
        if minutes >= 1440 { return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}
