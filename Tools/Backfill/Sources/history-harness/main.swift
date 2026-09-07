import Foundation
import HistoryHarnessCore

let arguments = Array(CommandLine.arguments.dropFirst())
var days = HistoryHarness.supportedDays
var output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("history-harness-report.json")
var keepDatabases = false

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--days":
        guard index + 1 < arguments.count else {
            throw HistoryHarnessError.noScenarios
        }
        days = arguments[index + 1]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        index += 2
    case "--output":
        guard index + 1 < arguments.count else {
            throw CocoaError(.fileNoSuchFile)
        }
        output = URL(fileURLWithPath: arguments[index + 1])
        index += 2
    case "--keep-databases":
        keepDatabases = true
        index += 1
    default:
        throw CocoaError(.fileReadUnsupportedScheme)
    }
}

let report = try await HistoryHarness.run(
    days: days,
    keepTemporaryDatabases: keepDatabases
) { message in
    print(message)
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(report).write(to: output, options: .atomic)
print("history-harness: report \(output.path)")
