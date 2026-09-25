import ApplicationServices
import AppKit

// axdump <pid> [maxDepth] — prints every AX element of every window of <pid> in VoiceOver order.
let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else { print("usage: axdump pid"); exit(1) }
let maxDepth = args.count > 2 ? Int(args[2]) ?? 40 : 40
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String {
    guard let v = attr(e, a) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return String(format: "[%.0f,%.0f %.0fx%.0f]", p.x, p.y, s.width, s.height)
}
func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success, let a = names as? [String] else { return [] }
    return a.filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
}
func walk(_ e: AXUIElement, _ depth: Int) {
    let role = str(e, kAXRoleAttribute)
    let sub = str(e, kAXSubroleAttribute)
    let title = str(e, kAXTitleAttribute)
    let desc = str(e, kAXDescriptionAttribute)
    let value = str(e, kAXValueAttribute)
    let help = str(e, kAXHelpAttribute)
    let ident = str(e, "AXIdentifier")
    let selected = str(e, kAXSelectedAttribute)
    let enabled = str(e, kAXEnabledAttribute)
    var parts = ["\(String(repeating: "  ", count: depth))\(role)\(sub.isEmpty ? "" : "/\(sub)")"]
    if !title.isEmpty { parts.append("title=\"\(title)\"") }
    if !desc.isEmpty { parts.append("label=\"\(desc)\"") }
    if !value.isEmpty { parts.append("value=\"\(value.prefix(80))\"") }
    if !help.isEmpty { parts.append("help=\"\(help.prefix(60))\"") }
    if selected == "1" { parts.append("SELECTED") }
    if enabled == "0" { parts.append("DISABLED") }
    if !ident.isEmpty { parts.append("id=\(ident)") }
    let acts = actions(e); if !acts.isEmpty { parts.append("actions=\(acts.joined(separator: ","))") }
    parts.append(frame(e))
    print(parts.joined(separator: " "))
    guard depth < maxDepth, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids { walk(k, depth + 1) }
}
if let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
    for w in wins { print("=== window \(str(w, kAXTitleAttribute)) id=\(str(w, "AXIdentifier"))"); walk(w, 0) }
} else { print("no windows (AX trusted: \(AXIsProcessTrusted()))") }
