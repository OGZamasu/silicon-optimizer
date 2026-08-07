import Foundation

/// A byte quantity. Wrapping this in a type keeps the many memory calculations in the
/// planner from silently mixing GB, GiB and raw byte counts.
public struct Bytes: Hashable, Sendable, Comparable, Codable {
    public var rawValue: Int64

    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = Int64(rawValue) }

    public static func gib(_ value: Double) -> Bytes { Bytes(Int64(value * 1_073_741_824)) }
    public static func mib(_ value: Double) -> Bytes { Bytes(Int64(value * 1_048_576)) }
    public static func kib(_ value: Double) -> Bytes { Bytes(Int64(value * 1024)) }

    public static let zero = Bytes(0)

    /// Binary units, matching how `hw.memsize` and every model file size are actually
    /// expressed. Named precisely because `formatted` deliberately prints *decimal* GB — that
    /// is what Apple shows in About This Mac — and conflating the two is a 7% error.
    public var gibibytes: Double { Double(rawValue) / 1_073_741_824 }
    public var mebibytes: Double { Double(rawValue) / 1_048_576 }

    public static func < (lhs: Bytes, rhs: Bytes) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func + (lhs: Bytes, rhs: Bytes) -> Bytes { Bytes(lhs.rawValue + rhs.rawValue) }
    public static func - (lhs: Bytes, rhs: Bytes) -> Bytes { Bytes(lhs.rawValue - rhs.rawValue) }
    public static func * (lhs: Bytes, rhs: Double) -> Bytes { Bytes(Int64(Double(lhs.rawValue) * rhs)) }
    public static func / (lhs: Bytes, rhs: Double) -> Bytes { Bytes(Int64(Double(lhs.rawValue) / rhs)) }
    public static func += (lhs: inout Bytes, rhs: Bytes) { lhs = lhs + rhs }

    /// Ratio of one quantity to another, guarding against division by zero.
    public func fraction(of total: Bytes) -> Double {
        guard total.rawValue > 0 else { return 0 }
        return Double(rawValue) / Double(total.rawValue)
    }

    /// Human formatting that matches how Apple presents storage (decimal GB), because that is
    /// what users see in About This Mac and in Finder.
    public var formatted: String {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let value = Double(rawValue)
        for (suffix, scale) in units where abs(value) >= scale {
            let scaled = value / scale
            return String(format: scaled >= 100 ? "%.0f %@" : "%.1f %@", scaled, suffix)
        }
        return "\(rawValue) B"
    }
}

extension Bytes: CustomStringConvertible {
    public var description: String { formatted }
}
