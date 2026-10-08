#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// The Live Activity shown while a voice note records (an
/// `AudioRecordingIntent` must start one): elapsed time and a Stop button,
/// on the Lock Screen and in the Dynamic Island, then for a few seconds where
/// the voice note went (`result`). It shows no note content.
struct VoiceNoteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When recording started (the timer counts from it).
        var started: Date
        /// Paused by an interruption (a call).
        var paused: Bool
        /// Stopped and being sealed.
        var saving: Bool?
        /// The last state, shown until the activity is dismissed.
        var result: VoiceNoteResult?
        /// When it stopped (the final state shows the length).
        var ended: Date?

        init(started: Date, paused: Bool = false, saving: Bool? = nil, result: VoiceNoteResult? = nil, ended: Date? = nil) {
            self.started = started
            self.paused = paused
            self.saving = saving
            self.result = result
            self.ended = ended
        }

        /// Whether the timer runs and Stop is offered.
        var isRecording: Bool { result == nil && saving != true }
    }
}
#endif
