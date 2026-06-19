#if canImport(ActivityKit)
import ActivityKit

/// Shared Live Activity data for a long-running AI image task. Used by the app (to
/// start/update/end the activity) and by the Live Activity **widget extension** (to
/// render the Dynamic Island / Lock Screen). When you create the widget extension,
/// add THIS file to its target membership too, so both targets share the type.
struct AIActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var phase: String      // "AI In Progress" / "Ready" / "Failed"
        public var detail: String
        public var done: Bool
        public init(phase: String, detail: String, done: Bool) {
            self.phase = phase; self.detail = detail; self.done = done
        }
    }
    public var title: String          // "AI Edit" / "AI Extend"
    public init(title: String) { self.title = title }
}
#endif
