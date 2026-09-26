// Reads the ViewBridge keyboard-policy values Quick Look's classes report.
import AppKit
import ObjectiveC
for p in ["/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI", "/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge"] { _ = dlopen(p, RTLD_NOW) }
typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool
typealias U64IMP = @convention(c) (AnyObject, Selector) -> UInt64
func classBool(_ cls: String, _ sel: String) -> String {
    guard let c = NSClassFromString(cls) else { return "no class" }
    let s = NSSelectorFromString(sel)
    guard let m = class_getClassMethod(c, s) else { return "no method" }
    return String(unsafeBitCast(method_getImplementation(m), to: BoolIMP.self)(c, s))
}
for c in ["NSRemoteViewController", "QLRemoteViewController", "QLUIServiceHostViewController"] { print("+[\(c) inhibitFirstResponder] =", classBool(c, "inhibitFirstResponder")) }
for c in ["NSServiceViewController", "QLUIServiceBaseViewController", "QLPreviewExtensionViewController"] {
    print("+[\(c) canBecomeKey] =", classBool(c, "canBecomeKey"))
    let s = NSSelectorFromString("declinedEventMask")
    if let cl = NSClassFromString(c), let m = class_getInstanceMethod(cl, s) {
        let obj = (cl as! NSObject.Type).init()
        let mask = unsafeBitCast(method_getImplementation(m), to: U64IMP.self)(obj, s)
        let keyMask = NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue
        print("-[\(c) declinedEventMask] = 0x\(String(mask, radix: 16)) declinesKeys=\(mask & keyMask == keyMask)")
    }
}
