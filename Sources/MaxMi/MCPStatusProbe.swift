import Foundation

enum MCPStatusProbe {
    static func status(executableURL: URL) async -> (healthy: Bool, claudeConnected: Bool) {
        await Task.detached(priority: .utility) {
            let healthy = handshake(executableURL: executableURL)
            let connected = claudeStatus(expectedExecutable: executableURL.path)
            return (healthy, connected)
        }.value
    }

    private static func handshake(executableURL: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        let process = Process()
        process.executableURL = executableURL
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        do {
            try process.run()
            let request = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"maxmi-settings","version":"1"}}}
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}

            """
            input.fileHandleForWriting.write(Data(request.utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return process.terminationStatus == 0
                && text.contains("search_memory") && text.contains("get_latest_context")
                && text.contains("meeting_memory")
        } catch { return false }
    }

    private static func claudeStatus(expectedExecutable: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "claude mcp get maxmi"]
        let output = Pipe()
        process.standardOutput = output; process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return process.terminationStatus == 0
                && text.contains("Connected") && text.contains(expectedExecutable)
        } catch { return false }
    }
}

