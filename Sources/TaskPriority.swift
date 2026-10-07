import AppKit
import Darwin

struct TaskIdentity: Equatable {
    let pid: Int32
    let uid: UInt32
    let seconds: UInt64
    let microseconds: UInt64
    let nice: Int
}
struct PriorityLease: Equatable {
    let identity: TaskIdentity
    let desired: Int
    let name: String
    let marker: URL
    let expires: Date
}
final class TaskPriority {
    var leases: [PriorityLease] = []
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/priority-helper").path
    func inspect(_ pid: Int32) -> TaskIdentity? {
        var snapshot = MTPProcessIdentity()
        guard MTPReadProcess(pid, &snapshot) != 0 else { return nil }
        return TaskIdentity(pid: pid, uid: snapshot.uid, seconds: snapshot.seconds,
                            microseconds: snapshot.microseconds, nice: Int(snapshot.nice))
    }
    // All mutations run on the app's serial worker, except termination after it is idle.
    func start(pid: Int32, name: String, desired: Int) -> CommandResult {
        guard desired == -5 || desired == -10, pid != getpid(),
              let target = inspect(pid), let owner = inspect(getpid()), target.uid == getuid() else {
            return CommandResult(code: -1, output: "只能选择当前账户的其他进程；目标已退出或无法读取。")
        }
        guard !leases.contains(where: { $0.identity.pid == pid }) else {
            return CommandResult(code: -1, output: "该进程已有优先级会话，请先恢复。")
        }
        guard target.nice > desired else {
            return CommandResult(code: -1, output: "该进程已有相同或更高优先级，无需修改。")
        }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("mac-power-priority-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            return CommandResult(code: -1, output: "无法创建临时会话。")
        }
        let args = ["--session", String(pid), String(target.uid), String(target.seconds), String(target.microseconds),
                    String(target.nice), String(desired), String(owner.pid), String(owner.seconds), String(owner.microseconds), marker.path, "1800"]
        let result = TaskAuthorization.authorize(([helper] + args).map(TaskAuthorization.quote).joined(separator: " "))
        if result.code == 0 {
            leases.append(PriorityLease(identity: target, desired: desired, name: name, marker: marker, expires: Date().addingTimeInterval(1800)))
        } else { try? FileManager.default.removeItem(at: marker) }
        return result
    }
    func end(pid: Int32? = nil) -> CommandResult {
        let selected = leases.filter { pid == nil || $0.identity.pid == pid }
        for lease in selected { try? FileManager.default.removeItem(at: lease.marker) }
        Thread.sleep(forTimeInterval: 1.2)
        var failures: [String] = []
        var completed: Set<Int32> = []
        for lease in selected {
            guard let live = inspect(lease.identity.pid), live.uid == lease.identity.uid,
                  live.seconds == lease.identity.seconds, live.microseconds == lease.identity.microseconds else {
                completed.insert(lease.identity.pid); continue
            }
            if live.nice == lease.desired { failures.append(lease.name) }
            else { completed.insert(lease.identity.pid) }
        }
        leases.removeAll { completed.contains($0.identity.pid) }
        return failures.isEmpty ? CommandResult(code: 0, output: "会话已结束，优先级已回读确认。") :
            CommandResult(code: -1, output: "以下进程的恢复未通过验证，可再次尝试：" + failures.joined(separator: "、"))
    }
    func cleanupExpired() {
        leases.removeAll { lease in
            guard Date() < lease.expires, let live = inspect(lease.identity.pid), live.uid == lease.identity.uid,
                  live.seconds == lease.identity.seconds, live.microseconds == lease.identity.microseconds,
                  live.nice == lease.desired else {
                try? FileManager.default.removeItem(at: lease.marker)
                return true
            }
            return false
        }
    }
    func releaseOnQuit() {
        for lease in leases { try? FileManager.default.removeItem(at: lease.marker) }
        // Supervisor also detects application exit and enforces the 30-minute bound.
    }
}
