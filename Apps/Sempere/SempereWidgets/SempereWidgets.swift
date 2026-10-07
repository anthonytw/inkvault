import AppIntents
import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Quick voice notes from outside the app (docs/quick-capture.md): a Lock
/// Screen and Home Screen widget, a Control Center control (also offered to
/// the Action button), and the Live Activity of a recording. Every button
/// runs `StartVoiceNoteIntent` or `StopVoiceNoteIntent` in the app's process;
/// nothing here reads the vault.
@main
struct SempereWidgets: WidgetBundle {
    var body: some Widget {
        VoiceNoteWidget()
        VoiceNoteControl()
        VoiceNoteLiveActivity()
    }
}

struct VoiceNoteEntry: TimelineEntry {
    let date: Date
}

struct VoiceNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceNoteEntry { VoiceNoteEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceNoteEntry) -> Void) {
        completion(VoiceNoteEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceNoteEntry>) -> Void) {
        completion(Timeline(entries: [VoiceNoteEntry(date: Date())], policy: .never))
    }
}

/// One button: record a voice note.
struct VoiceNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.anthonytw.sempere.voice-note", provider: VoiceNoteProvider()) { _ in
            VoiceNoteWidgetView()
        }
        .configurationDisplayName("Voice Note")
        .description("Record a voice note into your vault's inbox, encrypted, without unlocking it.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartVoiceNoteIntent()) {
            switch family {
            case .accessoryCircular:
                Image(systemName: "mic.fill").font(.title2)
            case .accessoryRectangular:
                Label("Voice Note", systemImage: "mic.fill")
            default:
                VStack(spacing: 8) {
                    Image(systemName: "mic.circle.fill").font(.system(size: 44))
                    Text("Voice Note").font(.headline)
                }
            }
        }
        .buttonStyle(.plain)
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityLabel("Record a voice note")
    }
}

/// The Control Center control (iOS 18+), also offered to the Action button.
struct VoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.anthonytw.sempere.voice-note-control") {
            ControlWidgetButton(action: StartVoiceNoteIntent()) {
                Label("Voice Note", systemImage: "mic.fill")
            }
        }
        .displayName("Sempere Voice Note")
        .description("Record a voice note into your vault's inbox.")
    }
}

/// While a voice note records: the elapsed time and Stop.
struct VoiceNoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceNoteAttributes.self) { context in
            HStack {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(context.state.paused ? Color.secondary : Color.red)
                Text(context.state.started, style: .timer).monospacedDigit().font(.title3)
                Spacer()
                Button(intent: StopVoiceNoteIntent()) { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Voice note", systemImage: "mic.fill")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.started, style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StopVoiceNoteIntent()) { Label("Stop and Save", systemImage: "stop.fill") }
                        .tint(.red)
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.started, style: .timer).monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}
