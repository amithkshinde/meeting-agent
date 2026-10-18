import SwiftUI

/// Three short screens shown the first time the app opens.
struct OnboardingSheet: View {
    var onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let text: String
    }

    private let pages = [
        Page(icon: "waveform.circle.fill",
             title: "Your calls, remembered",
             text: "Meeting Agent records your calls, writes the notes, and remembers every promise. Then you can ask it anything about any project."),
        Page(icon: "rectangle.stack.fill",
             title: "How it works",
             text: "1. Join a call. I'll offer to record it.\n2. Watch the small window for a live recap and good questions to ask.\n3. After the call, read the summary and tick off promises.\n4. Keep calls, files and emails together in a project, and ask questions across all of it."),
        Page(icon: "lock.shield.fill",
             title: "Private by design",
             text: "Recordings stay on your Mac. Only text is ever sent to the AI, and you can keep a whole project on this Mac only. Always tell people on the call that you're recording."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: pages[page].icon)
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text(pages[page].title).font(.title.bold())
            Text(pages[page].text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle().fill(index == page ? Color.accentColor : Color.primary.opacity(0.2)).frame(width: 7, height: 7)
                }
            }
            HStack {
                if page > 0 { Button("Back") { page -= 1 }.buttonStyle(SoftButtonStyle()) }
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { page += 1 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Get started", action: onFinish).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(30)
        .frame(width: 520, height: 420)
    }
}
