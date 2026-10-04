// A client of the helper's Mach name: says hello, claims a text session and asks for the status, and prints what came back.
import Foundation

let c = NSXPCConnection(machServiceName: CommandLine.arguments[1], options: [])
c.remoteObjectInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
c.resume()
let sem = DispatchSemaphore(value: 0)
var result: [String] = []
let proxy = c.remoteObjectProxyWithErrorHandler { e in
    result.append("error \((e as NSError).code)")
    sem.signal()
} as! SpacebarHelperProtocol
proxy.hello { ok in
    result.append("hello \(ok)")
    proxy.textSession(true) { held in
        result.append("text \(held)")
        proxy.status { data in
            result.append(data.isEmpty ? "status none" : "status \((try? JSONDecoder().decode(HelperStatus.self, from: data))?.version ?? "?")")
            sem.signal()
        }
    }
}
let timedOut = sem.wait(timeout: .now() + 5) == .timedOut
print(timedOut ? "timeout" : result.joined(separator: ", "))
