import AppIntents
import Foundation

/// What the app does when a voice note intent runs. The app sets these at
/// launch (`QuickCapture.register`); the widget extension compiles the same
/// intents for its buttons but never performs them: `AudioRecordingIntent`
/// and `LiveActivityIntent` run in the app's process.
@MainActor
enum VoiceNoteActions {
    static var start: (@MainActor () async throws -> Void)?
    static var stop: (@MainActor () async throws -> Void)?
}

/// Why a voice note intent did nothing.
enum VoiceNoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        "Open Sempere and turn on Quick Voice Notes in Settings first."
    }
}

/// "Record a Sempere voice note": from Siri, Shortcuts, the Action button,
/// the Lock Screen and Home Screen widgets and the Control Center control.
/// Starts recording into the vault's inbox at once, without unlocking the
/// vault and without Face ID (docs/quick-capture.md): the audio is encrypted
/// to the vault's public keys when it stops.
struct StartVoiceNoteIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record a Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Records a voice note into your Sempere vault's inbox, encrypted on this device, without unlocking the vault.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let start = VoiceNoteActions.start else { throw VoiceNoteIntentError.unavailable }
        try await start()
        return .result()
    }
}

/// Stops the voice note being recorded and saves it (encrypted) to the inbox.
struct StopVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the Voice Note"
    static var description: IntentDescription? {
        IntentDescription("Stops the voice note being recorded and saves it, encrypted, to the inbox.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let stop = VoiceNoteActions.stop else { throw VoiceNoteIntentError.unavailable }
        try await stop()
        return .result()
    }
}
