import AppKit
import SwiftUI

enum UIState: Equatable {
    case idle
    case callFound(DetectedCall)
    case recording(call: DetectedCall, since: Date)
    case error(String)
}

final class AgentModel: ObservableObject {
    @Published var state: UIState = .idle
    @Published var lastSaved: String?

    var onRecord: () -> Void = {}
    var onStop: () -> Void = {}
    var onIgnore: () -> Void = {}
    var onRevealLast: () -> Void = {}
}

struct PanelView: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            HStack(spacing: 8) {
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                Text("Waiting for a call").font(.callout).foregroundStyle(.secondary)
            }
            if let saved = model.lastSaved {
                Button("Last recording: \(saved)") { model.onRevealLast() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

        case .callFound(let call):
            Text("Looks like a \(call.app) call").font(.headline)
            Text("Record this one?").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Record") { model.onRecord() }
                    .keyboardShortcut(.defaultAction)
                Button("Not this one") { model.onIgnore() }
            }
            Text("Tell the other people you're recording before you start.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .recording(let call, let since):
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("Recording \(call.app)").font(.headline)
                Spacer()
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Button("Stop recording") { model.onStop() }

        case .error(let message):
            Text("Something went wrong").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Dismiss") { model.onIgnore() }
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
