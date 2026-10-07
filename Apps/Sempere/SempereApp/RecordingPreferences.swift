import Foundation
import Sempere

/// The recording settings (docs/attachments.md §9, §15): codec, quality,
/// sample rate and channels, per device in `UserDefaults`. Defaults: AAC-LC,
/// 64 kbit/s, 48 kHz, mono. Whatever is stored goes through
/// `RecordingFormat.normalized()`, so the encoder only ever sees a format the
/// panel offers.
enum RecordingPreference {
    static let codecKey = "Sempere.recording.codec"
    static let bitRateKey = "Sempere.recording.bitRate"
    static let sampleRateKey = "Sempere.recording.sampleRate"
    static let channelsKey = "Sempere.recording.channels"

    /// The format new recordings are made in.
    static func format(_ defaults: UserDefaults = .standard) -> RecordingFormat {
        let d = RecordingFormat.default
        let codec = (defaults.string(forKey: codecKey)).flatMap(RecordingFormat.Codec.init(rawValue:)) ?? d.codec
        let bitRate = defaults.object(forKey: bitRateKey) as? Int
        let sampleRate = defaults.object(forKey: sampleRateKey) as? Int ?? d.sampleRate
        let channels = defaults.object(forKey: channelsKey) as? Int ?? d.channels
        return RecordingFormat(codec: codec, bitRate: bitRate ?? (codec == d.codec ? d.bitRate : codec.defaultBitRate),
                               sampleRate: sampleRate, channels: channels).normalized()
    }

    /// Stores `format` (normalized).
    static func save(_ format: RecordingFormat, _ defaults: UserDefaults = .standard) {
        let f = format.normalized()
        defaults.set(f.codec.rawValue, forKey: codecKey)
        if let b = f.bitRate { defaults.set(b, forKey: bitRateKey) } else { defaults.removeObject(forKey: bitRateKey) }
        defaults.set(f.sampleRate, forKey: sampleRateKey)
        defaults.set(f.channels, forKey: channelsKey)
    }
}

/// "Transcribe recordings on this device" (docs/attachments.md §15): off by
/// default (opt-in). When on, a recording is transcribed on device as soon
/// as it is saved; the Transcribe button works either way.
enum TranscriptionPreference {
    static let key = "Sempere.transcribeRecordings"
    static let defaultValue = false

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}
