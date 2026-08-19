import CoreGraphics
import Foundation
// Post a real click (and optional typing) at global screen coordinates.
let args = CommandLine.arguments
let x = Double(args[1])!, y = Double(args[2])!
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(150_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
if args.count > 3 {
    usleep(400_000)
    for ch in args[3].unicodeScalars {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        var utf16 = Array(String(ch).utf16)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}
print("clicked \(x),\(y)")
