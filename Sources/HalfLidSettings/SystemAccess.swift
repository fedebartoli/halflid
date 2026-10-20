import AppKit
import Darwin
import HalfLidCore
import ServiceManagement

/// Places in System Settings that the settings window can open.
enum SystemLinks {
    static func openMenuBarSettings() {
        open("x-apple.systempreferences:com.apple.MenuBarSettings")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The notification settings of the menu bar app: notifications belong to it, not to this window.
    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.menuBarBundleIdentifier)")
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// One thing that keeps the Mac from sleeping on its own, for the diagnostics pane.
struct SleepHolder: Identifiable, Equatable {
    var id: String
    var process: String
    /// Catalog key of the short description of what kind of hold it is.
    var kindKey: String
    var reason: String

    static func current() -> [SleepHolder] {
        var seen = Set<String>()
        var result: [SleepHolder] = []
        for assertion in AssertionsProbe.read() where assertion.preventsSleep {
            let process = processName(assertion.pid)
            let key = "\(assertion.pid)|\(assertion.type)|\(assertion.name)"
            guard seen.insert(key).inserted else { continue }
            let kind = assertion.type == "PreventSystemSleep" ? "settings.diagnostics.kind.system" : "settings.diagnostics.kind.idle"
            result.append(SleepHolder(id: key, process: process, kindKey: kind, reason: readable(assertion.name)))
        }
        return result.sorted { $0.process.localizedCaseInsensitiveCompare($1.process) == .orderedAscending }
    }

    /// The reason a process gave for holding the Mac awake, only when it reads like a sentence; identifiers and long machine
    /// strings are left out.
    private static func readable(_ reason: String) -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 70, !text.contains("<"), !text.contains(">") else { return "" }
        let looksLikeIdentifier = !text.contains(" ") && text.filter { $0 == "." }.count >= 2
        return looksLikeIdentifier ? "" : text
    }

    /// The executable's name only: never its arguments. System processes owned by another user do not answer `proc_name`, so
    /// the short name the kernel keeps for every process is the fallback.
    private static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&request, UInt32(request.count), &info, &size, nil, 0) == 0, size > 0 {
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }
}
