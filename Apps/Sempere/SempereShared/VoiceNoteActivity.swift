#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// The Live Activity shown while a voice note records (an
/// `AudioRecordingIntent` must start one): elapsed time and a Stop button,
/// on the Lock Screen and in the Dynamic Island. It shows no note content.
struct VoiceNoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When recording started (the timer counts from it).
        var started: Date
        /// Paused by an interruption (a call).
        var paused: Bool
    }
}
#endif
