import Foundation

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/ps")
process.arguments = ["-axo", "pid=,ppid=,pcpu=,args="]

let pipe = Pipe()
process.standardOutput = pipe
process.standardError = Pipe()

try! process.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()

let output = String(data: data, encoding: .utf8)!
let lines = output.split(separator: "\n").map(String.init)
for line in lines {
    if line.lowercased().contains("gemini") {
        print("Found line: \(line)")
    }
}
