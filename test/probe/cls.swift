import Foundation
import ObjectiveC
for p in ["/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI", "/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", "/System/Library/Frameworks/AppKit.framework/AppKit"] { _ = dlopen(p, RTLD_NOW) }
let args = Array(CommandLine.arguments.dropFirst())
let filter = args.first!.hasPrefix("/") ? String(args.first!.dropFirst()) : ""
for name in args where !name.hasPrefix("/") {
    var c: AnyClass? = NSClassFromString(name)
    guard c != nil else { print("## \(name) not found"); continue }
    var chain: [String] = []; var k = c; while let kk = k { chain.append(NSStringFromClass(kk)); k = class_getSuperclass(kk) }
    print("## \(chain.joined(separator: " : "))")
    for meta in [false, true] {
        var n: UInt32 = 0
        let target: AnyClass = meta ? object_getClass(c!)! : c!
        if let list = class_copyMethodList(target, &n) {
            let names = (0..<Int(n)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted()
            for s in names where filter.isEmpty || s.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil { print("  \(meta ? "+" : "-")\(s)") }
            free(list)
        }
    }
    var pc: UInt32 = 0
    if let ps = class_copyProtocolList(c!, &pc) { print("  protocols: " + (0..<Int(pc)).map { String(cString: protocol_getName(ps[$0])) }.joined(separator: ", ")) }
    c = nil
}
