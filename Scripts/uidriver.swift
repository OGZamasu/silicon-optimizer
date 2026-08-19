// A small accessibility driver for testing the app the way a person uses it.
//
// AppleScript's object model gets unreliable against deep SwiftUI trees — half the
// queries it accepts on one element throw on the next. This talks to the same
// accessibility API directly, which is deterministic, and gives every element a stable
// index path so a test can say "press 12" and mean it twice.
//
// Build: swiftc -O Scripts/uidriver.swift -o /tmp/uidriver
// Usage: uidriver <app> dump [filter]
//        uidriver <app> value <path> <text>
//        uidriver <app> press <path>
//        uidriver <app> pick  <path> <menu item title>
//        uidriver <app> read  <path>
//        uidriver <app> text  <path>

import ApplicationServices
import AppKit
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func describe(_ element: AXUIElement) -> String {
    let role = string(element, kAXRoleAttribute as String) ?? "?"
    var parts = [role]
    for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                 kAXHelpAttribute, kAXPlaceholderValueAttribute] {
        if let raw = attribute(element, name as String) {
            let text: String?
            if let s = raw as? String { text = s }
            else if let n = raw as? NSNumber { text = n.stringValue }
            else { text = nil }
            if let text, !text.isEmpty, text.count < 120 {
                parts.append("\(name as String == kAXTitleAttribute as String ? "title" : (name as String == kAXValueAttribute as String ? "value" : "desc"))=\(text)")
            }
        }
    }
    if let enabled = attribute(element, kAXEnabledAttribute as String) as? Bool, !enabled {
        parts.append("DISABLED")
    }
    return parts.joined(separator: " ")
}

/// Depth-first walk, numbering every element so a path can name one.
///
/// Bounded on both axes. An accessibility tree can contain a cycle — a child that
/// points back at an ancestor — and an unbounded walk answers that by exhausting the
/// stack and taking the process with it, which is a confusing way to learn that a
/// window exists.
func walk(
    _ element: AXUIElement, path: String = "", depth: Int = 0, into lines: inout [String]
) {
    guard depth < 40, lines.count < 4000 else { return }
    // A window's tree can point back at the application, and from there at every menu bar
    // in the system — thousands of lines of nothing before the budget runs out and the
    // controls you were looking for never get printed. Nothing inside a window is one of
    // these, so walking into them is always the cycle, never the content.
    let role = string(element, kAXRoleAttribute as String) ?? ""
    if depth > 0, ["AXApplication", "AXMenuBar", "AXMenuBarItem"].contains(role) { return }
    let text = describe(element)
    lines.append("\(path.isEmpty ? "-" : path)\t\(String(repeating: "  ", count: depth))\(text)")
    for (index, child) in children(element).enumerated() {
        walk(child, path: path.isEmpty ? "\(index)" : "\(path)/\(index)",
             depth: depth + 1, into: &lines)
    }
}

func element(at path: String, from root: AXUIElement) -> AXUIElement? {
    var current = root
    for component in path.split(separator: "/") {
        guard let index = Int(component) else { return nil }
        let kids = children(current)
        guard kids.indices.contains(index) else { return nil }
        current = kids[index]
    }
    return current
}

// MARK: - Entry

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: uidriver <app name> dump|value|press|pick|read [path] [text]")
    exit(2)
}
let appName = arguments[1]
let command = arguments[2]

guard AXIsProcessTrusted() else {
    print("not trusted: grant Accessibility to this terminal in System Settings")
    exit(3)
}

// A locked screen hides every window from accessibility. The app is still running and its
// windows are still on screen behind the lock, so without this the answer is an empty tree
// and a long hunt for a bug that is really someone stepping away from the machine.
if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
   session["CGSSessionScreenIsLocked"] as? Int == 1 {
    print("screen is locked: unlock the Mac before driving the UI")
    exit(7)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == appName || $0.bundleIdentifier?.contains(appName) == true
}) else {
    print("app not running: \(appName)")
    exit(4)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

/// The app's windows. Asked for more than once because the answer is sometimes an empty
/// array for a moment — right after a window opens, or while a menu-bar popover is being
/// dismissed — and a caller that believes it has just found an app with no windows goes on
/// to dump one useless line.
func windowList() -> [AXUIElement] {
    for attempt in 0..<6 {
        let found = (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        if !found.isEmpty { return found }
        if attempt < 5 { Thread.sleep(forTimeInterval: 0.3) }
    }
    return []
}
let windows = windowList()

// The real window, not whatever is on top. A menu-bar app's popover is also a
// window and it arrives first, which silently pointed every command at the wrong
// tree. Prefer a standard window; fall back to the app element.
/// The window to drive.
///
/// Not simply `windows.first`: an app can hand back a window list whose first entry is a
/// proxy that reports itself as the application, and walking that lands in the menu bars of
/// every app on the system instead of the window in front of you. So the choice is made by
/// role, and `AXMainWindow` — which names the real one directly — is asked first.
func pickRoot() -> AXUIElement {
    func isWindow(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute as String) == "AXWindow"
    }
    for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        if let candidate = attribute(axApp, name as String),
           CFGetTypeID(candidate) == AXUIElementGetTypeID() {
            let element = candidate as! AXUIElement
            if isWindow(element) { return element }
        }
    }
    let real = windows.filter(isWindow)
    if let standard = real.first(where: {
        string($0, kAXSubroleAttribute as String) == "AXStandardWindow"
    }) { return standard }
    if let any = real.first { return any }

    // Neither the window list nor the main-window attribute gave a window. That happens
    // while the app is in the background: what comes back is a proxy that reports itself as
    // the application. The real window is a short way inside it.
    var queue = windows + children(axApp)
    var depth = 0
    while !queue.isEmpty, depth < 4 {
        if let found = queue.first(where: isWindow) { return found }
        queue = queue.flatMap(children)
        depth += 1
    }
    return windows.first ?? axApp
}
let root = pickRoot()
if windows.isEmpty {
    // Say so rather than printing a one-line tree and letting it read as "nothing there".
    FileHandle.standardError.write(
        Data("note: \(appName) reports no windows; dumping the application element\n".utf8)
    )
}

switch command {
case "dump":
    var lines: [String] = []
    walk(root, into: &lines)
    let filter = arguments.count > 3 ? arguments[3].lowercased() : nil
    for line in lines {
        if let filter {
            if line.lowercased().contains(filter) { print(line) }
        } else {
            print(line)
        }
    }

case "pos":
    // Where an element actually is on screen, so a real mouse event can find it.
    guard arguments.count > 3, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }

    func frame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var point = CGPoint.zero
        var size = CGSize.zero
        if let positionValue { AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) }
        if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }

    // Bring it into view first. A control inside a scrolled pane still reports a position
    // when it is nowhere near the screen, and clicking that lands on whatever app happens
    // to be underneath — which is how a prompt meant for this app ends up typed into
    // someone's terminal.
    AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
    Thread.sleep(forTimeInterval: 0.35)

    let box = frame(target)
    let window = frame(root)
    let centre = CGPoint(x: box.midX, y: box.midY)
    if !window.isEmpty, !window.insetBy(dx: -2, dy: -2).contains(centre) {
        print("offscreen: element is at \(Int(centre.x)),\(Int(centre.y)), outside the window "
              + "\(Int(window.minX)),\(Int(window.minY)) \(Int(window.width))x\(Int(window.height)) "
              + "— scroll it into view before clicking")
        exit(6)
    }
    print("\(Int(centre.x)) \(Int(centre.y)) \(Int(box.width))x\(Int(box.height))")

case "text":
    // The whole value, untruncated. `read` summarises for a dump; a launch command or
    // an error message is exactly the case where the tail is the part that matters.
    guard arguments.count > 3, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }
    for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let value = string(target, name as String), !value.isEmpty {
            print(value)
            break
        }
    }

case "show":
    // Scroll until the element is actually on screen.
    //
    // SwiftUI panes do not answer the accessibility scroll-to-visible action, so this does
    // what a person does: put the pointer over the pane and turn the wheel, checking after
    // each turn. Bounded, because a pane that will not move must not spin here forever.
    guard arguments.count > 3, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }

    func rect(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var point = CGPoint.zero
        var size = CGSize.zero
        if let positionValue { AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) }
        if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }

    let windowFrame = rect(root)

    // Two cheaper ways first. Both are what the app itself does when a control needs to be
    // seen — and scroll wheel events only reach the app that owns the pointer's window, so
    // it has to be in front either way.
    app.activate()
    Thread.sleep(forTimeInterval: 0.3)
    AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.4)

    let source = CGEventSource(stateID: .hidSystemState)
    // Over the element's own column, not the middle of the window: a pane split into two
    // scrolling columns only scrolls the one the pointer is over.
    let hover = CGPoint(
        x: min(max(rect(target).midX, windowFrame.minX + 20), windowFrame.maxX - 20),
        y: windowFrame.midY
    )
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: hover,
            mouseButton: .left)?.post(tap: .cghidEventTap)

    var moved = 0
    for _ in 0..<60 {
        let box = rect(target)
        // Keep a margin: a control flush against the window edge is half under the chrome.
        let visible = windowFrame.insetBy(dx: 0, dy: 40)
        if visible.contains(CGPoint(x: box.midX, y: box.midY)) { break }
        // Positive scrolls the content down, which is what is wanted when the target sits
        // above the window; below it, the wheel turns the other way.
        let ticks: Int32 = box.midY > windowFrame.midY ? -3 : 3
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                wheel1: ticks, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        moved += 1
        Thread.sleep(forTimeInterval: 0.12)
    }

    let box = rect(target)
    let centre = CGPoint(x: box.midX, y: box.midY)
    if windowFrame.insetBy(dx: 0, dy: 20).contains(centre) {
        print("\(Int(centre.x)) \(Int(centre.y)) \(Int(box.width))x\(Int(box.height)) after \(moved) turns")
    } else {
        print("could not bring it into view after \(moved) turns; it sits at \(Int(centre.x)),\(Int(centre.y))")
        exit(6)
    }

case "read":
    guard arguments.count > 3, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }
    print(describe(target))

case "value":
    guard arguments.count > 4, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }
    let text = arguments[4] as CFString
    let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text)
    print(result == .success ? "set" : "failed: \(result.rawValue)")

case "press":
    guard arguments.count > 3, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print(result == .success ? "pressed" : "failed: \(result.rawValue)")

case "pick":
    // A pop-up: open it, wait for its menu, then press the item with this title.
    guard arguments.count > 4, let target = element(at: arguments[3], from: root) else {
        print("no element at path"); exit(5)
    }
    let wanted = arguments[4]
    AXUIElementPerformAction(target, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.8)

    // The opened menu is not a child of the button: it arrives as its own element
    // somewhere under the application. Search the whole app for menu items.
    func findMenuItem(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        let role = string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXMenuItem" {
            let title = string(element, kAXTitleAttribute as String)
                ?? string(element, kAXValueAttribute as String) ?? ""
            if title.localizedCaseInsensitiveContains(wanted) { return element }
        }
        for child in children(element) {
            if let hit = findMenuItem(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    if let item = findMenuItem(axApp) {
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print(result == .success ? "picked \(wanted)" : "found but could not press \(wanted)")
    } else {
        // A failed pick must not leave the menu hanging: an open menu blocks every
        // later query, and the accessibility cancel action does not close it. A real
        // Escape key event does.
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?
            .post(tap: .cghidEventTap)
        var titles: [String] = []
        func collect(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 12 else { return }
            if string(element, kAXRoleAttribute as String) == "AXMenuItem",
               let title = string(element, kAXTitleAttribute as String)
                ?? string(element, kAXValueAttribute as String) {
                titles.append(title)
            }
            for child in children(element) { collect(child, depth: depth + 1) }
        }
        collect(axApp)
        print("no menu item matching \(wanted); menu offered: \(titles.joined(separator: " | "))")
    }

default:
    print("unknown command \(command)")
    exit(2)
}
