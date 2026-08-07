import Foundation

extension Comparable {
    /// Constrains a value to a range. Used throughout the planner, where an out-of-range
    /// fraction silently produces nonsense rather than an error.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
