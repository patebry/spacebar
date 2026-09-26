// Dumps QuickLookUI private protocols/classes that carry host<->extension messages, looking for any key/text forwarding.
import Foundation
import ObjectiveC
import QuickLookUI
_ = dlopen("/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI", RTLD_NOW)
_ = dlopen("/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", RTLD_NOW)
let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
func dumpProto(_ name: String) {
    guard let p = objc_getProtocol(name) else { print("## protocol \(name): not found"); return }
    print("## protocol \(name)")
    for (req, inst) in [(true, true), (false, true), (true, false), (false, false)] {
        var n: UInt32 = 0
        if let list = protocol_copyMethodDescriptionList(p, req, inst, &n) {
            for i in 0..<Int(n) { if let s = list[i].name { print("  \(inst ? "-" : "+")\(NSStringFromSelector(s))\(req ? "" : " (opt)")") } }
            free(list)
        }
    }
}
func dumpClass(_ name: String) {
    guard let c = NSClassFromString(name) else { print("## class \(name): not found"); return }
    print("## class \(name) : \(class_getSuperclass(c).map { NSStringFromClass($0) } ?? "-")")
    var n: UInt32 = 0
    if let list = class_copyMethodList(c, &n) {
        for i in 0..<Int(n) { let s = NSStringFromSelector(method_getName(list[i])); if filter.isEmpty || s.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil { print("  -\(s)") } }
        free(list)
    }
}
for p in ["QLPreviewExtensionHostContextProtocol", "QLPreviewExtensionViewControllerProtocol", "QLPreviewExtensionUIServiceInterface", "QLUIServiceHostViewControllerProtocol", "QLUIServiceViewControllerProtocol", "QLUIServiceBaseViewControllerProtocol", "QLUIServiceBaseHostViewControllerProtocol", "QLUIServiceHostInterface", "QLUIServiceInterface", "QLRemoteViewControllerDelegate"] { dumpProto(p) }
for c in ["QLPreviewPanel", "QLPreviewExtensionViewController", "QLRemoteViewController", "QLPreviewExtensionHostContext", "QLPreviewExtensionServiceContext", "QLUIServiceViewController", "QLUIServiceHostViewController", "QLKeyCommand", "NSRemoteView", "NSRemoteViewController", "NSServiceViewController"] { dumpClass(c) }
