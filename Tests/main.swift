import Foundation

let fixture = """
 Battery Power:
 lowpowermode 0
 powermode 1
AC Power:
 powermode 2
"""
let parsed = PowerSettings.parse(fixture)
precondition(parsed == PowerSettings(ac: 2, battery: 1))
precondition(parsed.matches(ac: 2, battery: nil))
precondition(!parsed.matches(ac: 0, battery: nil))
precondition(parsed.matches(ac: nil, battery: 1))
precondition(!PowerSettings().matches(ac: 0, battery: 0))
precondition(PowerSettings.parse("AC Power:\n powermode invalid").ac == nil)
precondition(PowerSettings.parse("AC Power:\n powermode 3").ac == nil)
precondition(PowerSettings.parse("powermode 2").ac == nil)
precondition(PowerAuthorization.allowed.count == 5)
for command in [["-a", "sleep", "0"], ["-c", "powermode", "2", "sleep", "0"], ["/bin/sh"], ["-b", "powermode", "99"]] {
    precondition(PowerAuthorization.apply(command).code != 0)
}
precondition(PowerAuthorization.quote("a'b") == "'a'\\''b'")
print("PASS: power-source isolation, malformed/missing settings, no-op matching, unauthorized commands rejected")
