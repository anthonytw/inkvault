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
    /// Shows a place in the app (`OpenVoiceNotesIntent`).
    static var open: (@MainActor (VoiceNoteLink) -> Void)?
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

/// Where `OpenVoiceNotesIntent` opens the app.
enum VoiceNoteDestination: String, AppEnum {
    case settings
    case recording

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Voice Note Screen" }
    static var caseDisplayRepresentations: [VoiceNoteDestination: DisplayRepresentation] {
        [.settings: "Quick Voice Notes Settings", .recording: "Voice Note Being Recorded"]
    }

    var link: VoiceNoteLink {
        switch self {
        case .settings: return .settings
        case .recording: return .recording
        }
    }
}

/// Opens Sempere at Settings ▸ Quick Voice Notes or at the recording banner:
/// what the Control Center control does while quick voice notes are not set
/// up (or Live Activities are off), so a tap explains instead of failing.
struct OpenVoiceNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Voice Notes"
    static var description: IntentDescription? {
        IntentDescription("Opens Sempere at the Quick Voice Notes settings or the voice note being recorded.")
    }
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Screen", default: .settings)
    var destination: VoiceNoteDestination

    init() {}

    init(_ destination: VoiceNoteDestination) {
        self.destination = destination
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceNoteActions.open?(destination.link)
        return .result()
    }
}
