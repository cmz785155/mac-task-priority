import AppKit
import Darwin

struct CommandResult {
    let code: Int32
    let output: String
}

enum PowerAuthorization {
    static let uid = getuid()
    static var rulePath: String { "/private/etc/sudoers.d/local-macpowermodes-\(uid)" }
    static let allowed = [
        ["-c", "powermode", "2"], ["-c", "powermode", "0"],
        ["-b", "powermode", "2"], ["-b", "powermode", "1"],
        ["-a", "powermode", "0"]
    ]
    static var installed: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rulePath) else { return false }
        return (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == 0 &&
            (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o440 &&
            (attrs[.type] as? FileAttributeType) == .typeRegular
    }
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
    static func install() -> CommandResult {
        guard uid >= 501 else { return CommandResult(code: -1, output: "请从普通登录账户启用此功能") }
        let commands = allowed.map { "/usr/bin/pmset " + $0.joined(separator: " ") }.joined(separator: ", ")
        let rule = "# MacPowerModes: only fixed power-mode commands for this local UID.\n#\(uid) ALL=(root) NOPASSWD: NOSETENV: \(commands)\n"
        // Root-owned directory and atomic replacement. No user-writable executable is privileged.
        let script = """
        set -eu
        /usr/sbin/visudo -c >/dev/null
        /usr/bin/grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers.d([[:space:]]|$)' /private/etc/sudoers || { echo '系统未启用 sudoers.d，未修改权限'; exit 1; }
        test -d /private/etc/sudoers.d
        test ! -L /private/etc/sudoers.d
        test "$(/usr/bin/stat -f '%u:%Lp' /private/etc/sudoers.d)" = '0:755'
        target=\(quote(rulePath))
        test ! -L "$target"
        if test -e "$target"; then echo '权限规则已存在；请先撤销再启用'; exit 1; fi
        temp=$(/usr/bin/mktemp /private/etc/sudoers.d/.macpowermodes.XXXXXX)
        trap '/bin/rm -f "$temp"' EXIT
        /usr/bin/printf '%s' \(quote(rule)) > "$temp"
        /usr/sbin/chown root:wheel "$temp"
        /bin/chmod 440 "$temp"
        /usr/sbin/visudo -cf "$temp" >/dev/null
        /bin/mv "$temp" "$target"
        if ! /usr/sbin/visudo -c >/dev/null; then /bin/rm -f "$target"; exit 1; fi
        echo '已启用受限免密切换'
        """
        return authorize(script)
    }
    static func uninstall() -> CommandResult {
        authorize("set -eu\n/bin/rm -f " + quote(rulePath) + "\n/usr/sbin/visudo -c\necho '已撤销免密切换'")
    }
    static func apply(_ arguments: [String]) -> CommandResult {
        guard allowed.contains(arguments) else { return CommandResult(code: -1, output: "已拒绝非允许的电源操作") }
        if !installed {
            return authorize("/usr/bin/pmset " + arguments.map(quote).joined(separator: " "))
        }
        return run("/usr/bin/sudo", ["-n", "--", "/usr/bin/pmset"] + arguments)
    }
}
