import Foundation

struct PowerSettings: Equatable {
    var ac: Int?
    var battery: Int?
    static func parse(_ text: String) -> PowerSettings {
        var result = PowerSettings()
        var source = ""
        for line in text.components(separatedBy: .newlines) {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading == "AC Power:" { source = "ac" }
            if heading == "Battery Power:" { source = "battery" }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2, parts[0] == "powermode", let value = Int(parts[1]), (0...2).contains(value) {
                if source == "ac" { result.ac = value }
                if source == "battery" { result.battery = value }
            }
        }
        return result
    }
    func matches(ac expectedAC: Int?, battery expectedBattery: Int?) -> Bool {
        (expectedAC == nil || ac == expectedAC) && (expectedBattery == nil || battery == expectedBattery)
    }
    func value(forAC: Bool) -> Int? { forAC ? ac : battery }
}

func readSettings() -> PowerSettings {
    let result = PowerAuthorization.run("/usr/bin/pmset", ["-g", "custom"])
    return result.code == 0 ? PowerSettings.parse(result.output) : PowerSettings()
}

func readHighPowerSupport() -> Bool {
    let result = PowerAuthorization.run("/usr/bin/pmset", ["-g", "cap"])
    return result.code == 0 && result.output.split(whereSeparator: { $0.isWhitespace }).contains("highpowermode")
}
