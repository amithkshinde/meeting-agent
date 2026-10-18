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

The cloud AI uses either a free Google Gemini key (https://aistudio.google.com/apikey) or an Anthropic key. Paste it in Settings. Free Google keys may let Google use what you send to improve its products, so use a paid key or the on-device option for confidential work.

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
