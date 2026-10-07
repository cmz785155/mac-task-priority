import AppKit
import Darwin

struct CommandResult {
    let code: Int32
    let output: String
}

enum TaskAuthorization {
    static let uid = getuid()
    static var legacyRulePath: String { "/private/etc/sudoers.d/local-macpowermodes-\(uid)" }
    static var legacyPermissionExists: Bool { FileManager.default.fileExists(atPath: legacyRulePath) }
    static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(code: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
        } catch { return CommandResult(code: -1, output: error.localizedDescription) }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func authorize(_ shell: String) -> CommandResult {
        let command = "/bin/sh -c " + quote(shell)
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        var error: NSDictionary?
        let result = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            return CommandResult(code: (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? -1,
                                 output: error[NSAppleScript.errorMessage] as? String ?? "系统授权失败")
        }
        guard let result else { return CommandResult(code: -1, output: "无法启动系统授权") }
        return CommandResult(code: 0, output: result.stringValue ?? "")
    }
    // Migration only: no new sudoers rule or power-setting command exists.
    static func removeLegacyPermission() -> CommandResult {
        guard legacyPermissionExists else { return CommandResult(code: 0, output: "没有旧版电源免密权限。") }
        let script = """
        set -eu
        target=\(quote(legacyRulePath))
        test ! -L "$target"
        test -f "$target"
        test "$(/usr/bin/stat -f '%u:%Lp' "$target")" = '0:440'
        /usr/bin/grep -Fxq '# MacPowerModes: only fixed power-mode commands for this local UID.' "$target"
        /usr/sbin/visudo -c >/dev/null
        /bin/rm "$target"
        /usr/sbin/visudo -c >/dev/null
        echo '已移除旧版电源免密权限；电源设置未改变。'
        """
        return authorize(script)
    }
}
