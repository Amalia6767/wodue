import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let asset = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Brand/AppIcon.icns")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let data = try Data(contentsOf: asset)
guard data.starts(with: Data("icns".utf8)) else {
    fatalError("The approved WoDue brand icon is missing or invalid.")
}
try data.write(to: out.appendingPathComponent("AppIcon.icns"), options: .atomic)
