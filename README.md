# Meeting Agent

A floating Mac agent that notices when you join a call, records and transcribes it, coaches you live using what was said in earlier conversations, and keeps everything organised by project so you can ask questions about all of it later.

Built by Amith K Shinde. Native macOS app in Swift and SwiftUI.

## Install (no Terminal needed)

1. Download or clone this folder.
2. Double-click **Install Meeting Agent.command**. The first time, right-click it and choose Open.
3. Wait for "Built". The app opens by itself.
4. Follow the checklist on the Home screen (Screen Recording, Microphone, Speech Recognition, AI key).

Needs macOS 15 or later (macOS 26 recommended for the better speech engine and the on-device AI). To build by hand:

```bash
cd ~/Desktop/meeting-agent-main
scripts/build-app.sh
open build/MeetingAgent.app
```

## Installers (for sharing)

The installer is built on your Mac and saved in a folder called `dist`. It is not stored in this repository, so make it yourself:

1. Double-click **Make Installer.command**. It takes two to four minutes.
2. A folder opens with the installer inside `dist/`.

| File | Which Macs it is for |
|---|---|
| `dist/MeetingAgent-<version>-universal.dmg` | **Use this one for everyone.** One file that runs on both Apple Silicon (M1 or newer) and Intel Macs, macOS 15 or later. |

There are no separate Apple Silicon and Intel files. If you find a file ending in `-arm64.dmg` in `dist/`, it came from an older build script and only works on Apple Silicon. Send the `-universal` file instead.

Send that one `.dmg`. The person opens it, drags Meeting Agent into Applications, and follows `READ ME FIRST.txt` inside the disk image. The app is signed with your own certificate, not an Apple Developer ID, so macOS shows a one-time warning: System Settings > Privacy & Security > Open Anyway. Removing the warning completely needs a paid Apple Developer account and notarization.

The first-run setup in the app walks a new person through the three permissions and through connecting the AI: a free Gemini key, a Claude key, or the Mac's built-in AI (Apple Silicon only), with step-by-step help for getting each key.

## Run it from the Terminal

Open the Terminal app and go to the project folder (change the path if yours is elsewhere):

```bash
cd ~/Desktop/meeting-agent-main
```

If you get "permission denied" on a script, run this once: `chmod +x scripts/*.sh *.command`

| What you want | Command |
|---|---|
| Build and open the app | `scripts/build-app.sh && open build/MeetingAgent.app` |
| Build, copy into Applications and open | `scripts/install.sh` |
| Build the shareable installer (Apple Silicon and Intel) | `scripts/make-installer.sh` |
| Build only a universal app, no disk image | `UNIVERSAL=1 scripts/build-app.sh` |
| One-time: create the signing certificate so macOS keeps permissions between builds | `scripts/setup-signing.sh` |
| Run the app with its messages shown in the Terminal | `build/MeetingAgent.app/Contents/MacOS/MeetingAgent` |
| Watch the log while it runs | `tail -f ~/Movies/MeetingAgent/spike-log.txt` |
| Run the tests | `swift test` |
| Quit a running copy | `pkill -x MeetingAgent` |
| Open the recordings folder | `open ~/Movies/MeetingAgent` |
| Clear a macOS "can't be opened" block on a copy you were sent | `xattr -dr com.apple.quarantine "/Applications/Meeting Agent.app"` |

You need Xcode or the Xcode Command Line Tools (`xcode-select --install`) to build. People who only receive the installer do not.

## What it does

**During a call**
- Detects Meet, Teams, Zoom and other calls, including ones that were never on your calendar, and offers to record.
- Records screen, call audio and your microphone to your Mac, with no bot joining the call.
- Live transcript (English, Hindi, Kannada and others), with "You" and "Them" labels.
- Live recap and cards: a question to ask, a point to push back on, or a flag. Each card says where it comes from.
- Catch me up and Last minute buttons, and a chat you can ask anything.
- Quiet mode hides suggestions until you peek.
- Global shortcuts (Control + Option): **M** show or hide the window, **A** ask a question, **S** peek at suggestions, **R** start or stop recording.

**After a call**
- Transcript clean-up pass for Hindi, Hinglish and names (the original is kept too).
- Summary with decisions, action items and open questions.
- Promises are pulled out automatically into one list: what you owe, and what others owe you, with due dates.
- Draft a follow-up email in one click. It opens in your mail app and nothing is sent for you.
- Interrupted calls (crash, restart, sleep) are recovered on the next launch.

**Projects and memory**
- A project holds calls, files, emails and notes, plus an AI-written brief.
- Ask questions across a project. Every answer lists the exact call, file or email it came from, with an Open button.
- Live suggestions use everything in the project, including open promises.

**Calendar**
- Connect the Mac's Calendar (Google Calendar works once your Google account is added in System Settings > Internet Accounts).
- A briefing appears a few minutes before each meeting: last time, open promises, questions to ask.
- The calendar invite names the people on the call and files the call under the right project.

**Privacy**
- Recordings, transcripts and notes stay on your Mac, in Movies > MeetingAgent.
- Only text is ever sent to the AI, never audio or video. The key is kept in the macOS Keychain.
- Choose "On this Mac only" in Settings, or per project, to use Apple's on-device model so nothing leaves the Mac. Projects marked this way are also kept out of cloud searches.
- Tell people on the call that you are recording. Laws on recording differ by place.

## AI key

The cloud AI uses either a free Google Gemini key (https://aistudio.google.com/apikey) or an Anthropic Claude key (https://console.anthropic.com/settings/keys), or the Mac's built-in AI. Settings > AI assistant > Set up AI walks you through getting and pasting a key. Free Gemini keys allow only about 20 requests a day, so live suggestions slow down and stop early to leave room for the call summary. Free Google keys may let Google use what you send to improve its products, so use a paid key or the on-device option for confidential work.

## Project layout

- `Sources/MeetingAgent`: the app. `AppDelegate` wires everything; `CallDetector`, `CallRecorder`, `LiveTranscriber` and `ModernTranscriber` handle calls, capture and speech; `PostCall` writes notes and promises; `CalendarService` does briefings; `Knowledge` holds projects and retrieval; `MainView`, `ProjectPage`, `PromisesView`, `SettingsView` and `PanelView` are the screens.
- `scripts/`: `build-app.sh`, `install.sh`, `setup-signing.sh` (a stable signing certificate so macOS keeps your permissions between builds).
- `docs/`: [Product requirements](docs/PRD.md) and the [original spike test plan](docs/SPIKE.md).

## Known limits

- Speaker labels are "You" and "Them". Names from the calendar are used only when the invite makes it clear who is who.
- Hindi and Hinglish accuracy depends on Apple's on-device recogniser; the clean-up pass helps but is not perfect. Kannada support varies by Mac.
- Direct Gmail import is not built. In Gmail, download an email (⋮ > Download message) and drag the .eml file onto a project.
- The on-device AI has a small context window, so answers are shorter and long calls are trimmed.

## Roadmap

Direct Gmail sync, per-speaker voice separation, export and delete tools, notarized distribution.
