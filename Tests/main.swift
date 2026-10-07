import Foundation
import Darwin

precondition(TaskAuthorization.quote("a'b") == "'a'\\''b'")
let priority = TaskPriority()
precondition(priority.start(pid: getpid(), name: "self", desired: -5).code != 0)
precondition(priority.start(pid: 0, name: "invalid", desired: -20).code != 0)
let helper = CommandLine.arguments[1]
let live = TaskAuthorization.run(helper, ["--inspect", String(getpid())])
precondition(live.code == 0)
let values = live.output.split(whereSeparator: { $0.isWhitespace })
precondition(values.count == 4 && UInt32(values[0]) == getuid())
let native = priority.inspect(getpid())!
precondition(native.uid == UInt32(values[0]) && native.seconds == UInt64(values[1]) && native.microseconds == UInt64(values[2]) && native.nice == Int(values[3]))
precondition(priority.inspect(0) == nil && priority.inspect(1) == nil && priority.inspect(-1) == nil)
for args in [["--inspect", "0"], ["--inspect", "-1"], ["--inspect", "2147483648"], ["--inspect", "1;echo unsafe"], ["--session"], ["--unknown"]] {
    precondition(TaskAuthorization.run(helper, args).code != 0)
}
precondition(priority.leases.isEmpty)
print("PASS: live identity, invalid arguments, self-target and unsupported priority rejected")
