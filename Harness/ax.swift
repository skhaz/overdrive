import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.delduca.Overdrive").first(where: { $0.bundleURL?.path.hasPrefix("/Applications") == false }) else {
    print("no app")
    exit(1)
}

let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 5)

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
    attr(element, name).map { "\($0)" } ?? ""
}

func role(_ element: AXUIElement) -> String {
    string(element, kAXRoleAttribute)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func position(_ element: AXUIElement) -> CGPoint {
    var point = CGPoint.zero
    if let value = attr(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
    return point
}

func window() -> AXUIElement {
    let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    guard let main = windows.first(where: { string($0, kAXIdentifierAttribute).hasPrefix("main") }) else {
        print("no window")
        exit(1)
    }
    return main
}

func sidebar(_ element: AXUIElement) -> Bool {
    role(element) == "AXOutline" && string(element, kAXDescriptionAttribute) == "Sidebar"
}

func table(_ element: AXUIElement) -> Bool {
    role(element) == "AXTable" || role(element) == "AXOutline" && !sidebar(element)
}

func find(_ match: (AXUIElement) -> Bool) -> AXUIElement? {
    var stack = [window()]
    while let element = stack.popLast() {
        if match(element) { return element }
        if table(element) || sidebar(element) { continue }
        stack += children(element).reversed()
    }
    return nil
}

func texts(_ element: AXUIElement) -> [String] {
    var result: [String] = []
    var stack = [element]
    while let element = stack.popLast() {
        if role(element) == "AXStaticText" { result.append(string(element, kAXValueAttribute)) }
        stack += children(element).reversed()
    }
    return result
}

func done(_ error: AXError) {
    print(error == .success ? "ok" : "error \(error.rawValue)")
    exit(error == .success ? 0 : 1)
}

let content = { (element: AXUIElement) in position(element).x > 150 && position(element).y > 80 }

switch args.first {
case "title":
    print(string(window(), kAXTitleAttribute))
case "page":
    guard let outline = find(sidebar) else { print("no sidebar"); exit(1) }
    for row in children(outline) where string(row, kAXSelectedAttribute) == "1" { print(texts(row).first ?? "") }
case "select":
    guard let outline = find(sidebar) else { print("no sidebar"); exit(1) }
    guard let row = children(outline).first(where: { texts($0).contains(args[1]) }) else { print("no row"); exit(1) }
    done(AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue))
case "press":
    guard let button = find({ role($0) == "AXButton" && string($0, kAXDescriptionAttribute).hasPrefix(args[1]) }) else { print("no button"); exit(1) }
    done(AXUIElementPerformAction(button, kAXPressAction as CFString))
case "album":
    var skip = Int(args.count > 1 ? args[1] : "0") ?? 0
    guard let button = find({
        guard role($0) == "AXButton", content($0), string($0, kAXDescriptionAttribute).hasSuffix(" song") || string($0, kAXDescriptionAttribute).hasSuffix(" songs") else { return false }
        skip -= 1
        return skip < 0
    }) else { print("no album"); exit(1) }
    done(AXUIElementPerformAction(button, kAXPressAction as CFString))
case "rows":
    guard let list = find({ table($0) && content($0) }) else { print("0"); exit(0) }
    print((attr(list, kAXRowsAttribute) as? [AXUIElement])?.count ?? 0)
case "row":
    guard let list = find({ table($0) && content($0) }) else { print("no table"); exit(1) }
    let rows = attr(list, kAXRowsAttribute) as? [AXUIElement] ?? []
    let index = Int(args[1]) ?? 0
    let picked: [AXUIElement] = index < 0 || rows.isEmpty ? [] : [rows[index % rows.count]]
    done(AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, picked as CFArray))
case "search":
    guard let field = find({ role($0) == "AXTextField" }) else { print("no field"); exit(1) }
    done(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, (args.count > 1 ? args[1] : "") as CFString))
case "query":
    print(find({ role($0) == "AXTextField" }).map { string($0, kAXValueAttribute) } ?? "")
case "pages":
    guard let outline = find(sidebar) else { print("no sidebar"); exit(1) }
    for row in children(outline) { if let name = texts(row).first { print(name) } }
case "dock":
    let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for panel in windows {
        var stack = [panel]
        while let element = stack.popLast() {
            if role(element) == "AXButton", string(element, kAXDescriptionAttribute) == "Put the lyrics back in the window" { done(AXUIElementPerformAction(element, kAXPressAction as CFString)) }
            stack += children(element)
        }
    }
    print("no panel")
case "volume":
    let sliders = { () -> [AXUIElement] in
        var result: [AXUIElement] = []
        var stack = [window()]
        while let element = stack.popLast() {
            if role(element) == "AXSlider" { result.append(element) }
            if table(element) || sidebar(element) { continue }
            stack += children(element)
        }
        return result.sorted { position($0).x < position($1).x }
    }()
    guard let slider = sliders.last else { print("no slider"); exit(1) }
    if args.count > 1 { done(AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, Double(args[1])! as CFNumber)) }
    print(string(slider, kAXValueAttribute))
case "song":
    print(find({ role($0) == "AXButton" && string($0, kAXDescriptionAttribute).contains(" — ") }).map { string($0, kAXDescriptionAttribute) } ?? "")
case "lyrics":
    print(find({ role($0) == "AXButton" && string($0, kAXDescriptionAttribute) == "Show in a Floating Window" }) == nil ? "hidden" : "shown")
default:
    print("usage: ax title|page|pages|select NAME|press LABEL|album N|rows|row N|search TEXT|query|song|lyrics|dock|volume [VALUE]")
    exit(2)
}
