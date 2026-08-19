import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from putting itself to sleep while work that cannot survive it is running.
///
/// A generation is minutes of GPU work with no keyboard or mouse activity, which is precisely
/// what macOS reads as an idle machine. When it idle-sleeps, the inference server is suspended
/// and the streaming connection is dropped, so a half-written answer is lost and the runtime
/// usually has to be reloaded afterwards. Holding an assertion is the supported way to tell the
/// power manager "not idle — busy".
///
/// Deliberately `PreventUserIdleSystemSleep` rather than a display assertion: the screen still
/// sleeps, and closing the lid or choosing Sleep still works. Only the machine's own idle timer
/// is suppressed, and only while something is actually running.
public final class PowerAssertion {

    private var identifier = IOPMAssertionID(0)

    /// False when the assertion could not be taken. Not worth failing over: the work still
    /// runs, it just is not protected from an idle sleep.
    public private(set) var isHeld = false

    /// - Parameter reason: shown against the process in `pmset -g assertions`, so make it read
    ///   as an explanation to whoever is wondering why their Mac stayed awake.
    public init(reason: String) {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        identifier = id
        isHeld = true
    }

    public func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(identifier)
        isHeld = false
    }

    /// Releasing on deinit is the backstop that matters: an assertion outlives the process that
    /// forgot it only until the process exits, but a leaked one keeps the Mac awake for the
    /// whole session.
    deinit { release() }
}
