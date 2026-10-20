import notify
import Foundation

/// Tells the other Half Lid processes that the preferences file changed. The app, the settings window and the command-line
/// tool all share that one file; this is only the "look again" signal, so it carries no data. A process that receives it
/// loads the file and ignores the signal if nothing differs, which also stops two processes from answering each other.
public enum PreferencesBus {
    public static let name = "io.github.fedebartoli.halflid.preferences"

    public static func post() {
        notify_post(name)
    }

    /// Keeps a registration alive; cancels it when released.
    public final class Observation {
        fileprivate let token: Int32
        fileprivate init(token: Int32) { self.token = token }
        deinit { notify_cancel(token) }
    }

    public static func observe(on queue: DispatchQueue = .main, _ handler: @escaping @Sendable () -> Void) -> Observation? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
        return status == NOTIFY_STATUS_OK ? Observation(token: token) : nil
    }
}
