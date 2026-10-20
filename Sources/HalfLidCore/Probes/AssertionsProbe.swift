import Foundation
import IOKit.pwr_mgt

public struct PowerAssertion: Sendable, Equatable {
    public var pid: Int32
    public var type: String
    public var name: String

    public init(pid: Int32, type: String, name: String) {
        self.pid = pid
        self.type = type
        self.name = name
    }

    /// Assertion types that keep the Mac from sleeping on its own.
    public var preventsSleep: Bool {
        type == "PreventUserIdleSystemSleep" || type == "PreventSystemSleep" || type == "NoIdleSleepAssertion"
    }
}

public enum AssertionsProbe {
    /// All power assertions currently held, per process (what `pmset -g assertions` shows).
    public static func read() -> [PowerAssertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [PowerAssertion] = []
        for (pid, assertions) in dictionary {
            for assertion in assertions {
                result.append(PowerAssertion(
                    pid: pid.int32Value,
                    type: assertion[kIOPMAssertionTypeKey as String] as? String ?? "",
                    name: assertion[kIOPMAssertionNameKey as String] as? String ?? ""
                ))
            }
        }
        return result
    }
}
