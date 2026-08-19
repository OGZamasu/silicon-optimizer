import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Silicon Optimizer"
    guard (w[kCGWindowOwnerName as String] as? String)?.contains(wanted) == true else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(id) x=\(b["X"] ?? 0) y=\(b["Y"] ?? 0) w=\(b["Width"] ?? 0) h=\(b["Height"] ?? 0)")
}
