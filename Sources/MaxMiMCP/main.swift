import Foundation

let server = MCPServer(tools: LazyTools())
while let line = readLine(strippingNewline: true) {
    if let reply = await server.handle(line) {
        print(reply)
        fflush(stdout)
    }
}
