import Foundation
import AppKit

struct ShellResult {
    var output: String
    var error: String
    var status: Int32

    var combined: String {
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return o }
        if o.isEmpty { return e }
        return o + "\n" + e
    }

    var succeeded: Bool { status == 0 }
}

private final class DataBox {
    var data = Data()
}

enum Shell {
    /// Runs an executable synchronously and captures stdout / stderr.
    @discardableResult
    static func runSync(_ launchPath: String, _ args: [String], input: String? = nil,
                        environment: [String: String]? = nil, directory: URL? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let environment = environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let directory = directory { process.currentDirectoryURL = directory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var inPipe: Pipe?
        if input != nil {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
        }
        do {
            try process.run()
        } catch {
            return ShellResult(output: "", error: error.localizedDescription, status: -1)
        }
        if let input = input, let inPipe = inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(output: String(decoding: outData, as: UTF8.self),
                           error: String(decoding: errBox.data, as: UTF8.self),
                           status: process.terminationStatus)
    }

    /// Runs a zsh command line synchronously.
    @discardableResult
    static func sh(_ command: String) -> ShellResult {
        runSync("/bin/zsh", ["-c", command])
    }

    /// Runs a zsh command line in the background and reports the result on the main thread.
    static func run(_ command: String, completion: ((ShellResult) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSync("/bin/zsh", ["-c", command])
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Runs AppleScript source via osascript in the background.
    static func appleScript(_ source: String, completion: ((ShellResult) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSync("/usr/bin/osascript", ["-e", source])
            if let completion = completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Runs a shell command with administrator privileges (macOS shows its password prompt).
    static func runAsAdmin(_ command: String, completion: ((ShellResult) -> Void)? = nil) {
        appleScript("do shell script \"\(command.appleScriptEscaped)\" with administrator privileges", completion: completion)
    }

    static func notify(title: String = "MacTools", _ message: String) {
        appleScript("display notification \"\(message.appleScriptEscaped)\" with title \"\(title.appleScriptEscaped)\"")
    }
}

/// Streams the output of a long-running process into a published string.
final class CommandRunner: ObservableObject {
    @Published var output = ""
    @Published private(set) var running = false
    @Published private(set) var lastStatus: Int32?

    private var process: Process?
    private let maxLength = 300_000

    func runShell(_ command: String, shell: String = "/bin/zsh") {
        run(executable: shell, args: ["-lc", command], header: "$ " + command)
    }

    func runAppleScript(_ source: String) {
        run(executable: "/usr/bin/osascript", args: ["-e", source], header: "▶︎ AppleScript")
    }

    func run(executable: String, args: [String], header: String? = nil) {
        stop()
        output = header.map { $0 + "\n" } ?? ""
        lastStatus = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.append(text) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            // Give the readability handler a moment to deliver the last output.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                handle.readabilityHandler = nil
                guard let self = self else { return }
                self.append("\n[finished with exit code \(status)]\n")
                self.lastStatus = status
                if self.process === p {
                    self.running = false
                    self.process = nil
                }
            }
        }
        do {
            try process.run()
            self.process = process
            running = true
        } catch {
            append("Failed to start: \(error.localizedDescription)\n")
        }
    }

    /// `wait`: block until the process has exited (e.g. so it can release a port before a restart).
    func stop(wait: Bool = false) {
        if let p = process, p.isRunning {
            p.terminate()
            if wait { p.waitUntilExit() }
        }
        process = nil
        running = false
    }

    func clear() { output = "" }

    private func append(_ text: String) {
        output += text
        if output.count > maxLength {
            output = String(output.suffix(maxLength))
        }
    }
}
