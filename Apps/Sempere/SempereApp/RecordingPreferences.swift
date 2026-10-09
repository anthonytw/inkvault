import Foundation
import Sempere
import SempereSpeech

/// The recording format new recordings are made in, read from the Settings
/// panel's *Recording* section (`RecordingSettings`, docs/attachments.md
/// §15): one set of keys, so what the panel shows is what is recorded.
/// Whatever is stored goes through `RecordingFormat.normalized()`, so the
/// encoder only ever sees a format the panel offers.
enum RecordingPreference {
    static let codecKey = RecordingSettings.codecKey
    static let bitRateKey = RecordingSettings.bitRateKey
    static let sampleRateKey = RecordingSettings.sampleRateKey
    static let channelsKey = RecordingSettings.channelsKey

    /// The format new recordings are made in.
    static func format(_ defaults: UserDefaults = .standard) -> RecordingFormat {
        let s = RecordingSettings.load(from: defaults)
        let codec = RecordingFormat.Codec(rawValue: s.codec.rawValue) ?? RecordingFormat.default.codec
        return RecordingFormat(codec: codec, bitRate: s.codec.hasBitRate ? s.bitRate : nil, sampleRate: s.sampleRate,
                               channels: s.channels.rawValue).normalized()
    }

    /// Stores `format` (as the Settings panel does).
    static func save(_ format: RecordingFormat, _ defaults: UserDefaults = .standard) {
        let f = format.normalized()
        var s = RecordingSettings()
        s.codec = RecordingSettings.Codec(rawValue: f.codec.rawValue) ?? RecordingSettings.defaultCodec
        s.bitRate = f.bitRate ?? RecordingSettings.defaultBitRate
        s.sampleRate = f.sampleRate
        s.channels = RecordingSettings.Channels(rawValue: f.channels) ?? RecordingSettings.defaultChannels
        s.save(to: defaults)
    }
}

/// "Transcribe Recordings on This Device" and its language, from the
/// Settings panel's *Transcription* section (`TranscriptionSettings`): off
/// by default (opt-in). When on, a recording is transcribed on device as
/// soon as it is saved; the Transcribe button works either way.
enum TranscriptionPreference {
    static let key = TranscriptionSettings.enabledKey
    static let defaultValue = TranscriptionSettings.defaultEnabled

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        TranscriptionSettings.isEnabled(defaults)
    }

    /// The language chosen in Settings; nil: the note's, else the device's.
    static func language(_ defaults: UserDefaults = .standard) -> String? {
        TranscriptionSettings.localeIdentifier(defaults)
    }

    /// Installs the Settings panel's model-status lookup (`TranscriptionSettings.statusProvider`):
    /// what the on-device engines say for the chosen language, and the download button
    /// (`TranscriptionSettings.downloader`): it asks Apple's asset service for
    /// SpeechTranscriber's model, only when the user taps it (`SpeechTranscription.downloadModel`).
    /// The model is also fetched the first time a recording is transcribed without it.
    @MainActor
    static func installSettingsHooks() {
        TranscriptionSettings.statusProvider = { locale in
            let engines = await SpeechTranscription.availability(options: SpeechTranscription.Options(language: locale))
            return modelStatus(engines)
        }
        TranscriptionSettings.downloader = { locale in
            try await SpeechTranscription.downloadModel(options: SpeechTranscription.Options(language: locale))
        }
    }

    /// The panel's status from the engines' (`SpeechTranscription.availability`): installed when
    /// one can transcribe now, not downloaded when only SpeechTranscriber's model is missing.
    static func modelStatus(_ engines: [SpeechTranscription.EngineStatus]) -> TranscriptionSettings.ModelStatus {
        let available = engines.filter(\.available)
        if available.isEmpty { return .unavailable }
        if available.contains(where: { !$0.detail.hasPrefix("model not installed") }) { return .installed }
        return .notDownloaded
    }
}
