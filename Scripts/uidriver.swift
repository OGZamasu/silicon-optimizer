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
func walk(
    _ element: AXUIElement, path: String = "", depth: Int = 0, into lines: inout [String]
) {
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
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == appName || $0.bundleIdentifier?.contains(appName) == true
}) else {
    print("app not running: \(appName)")
    exit(4)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
// Windows first; fall back to the whole app element for menu-bar popovers.
let windows = (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
let root = windows.first ?? axApp

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
        // Leave nothing open if the pick failed.
        AXUIElementPerformAction(target, kAXCancelAction as CFString)
        print("no menu item matching \(wanted)")
    }

default:
    print("unknown command \(command)")
    exit(2)
}
