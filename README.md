# Meeting Agent

A floating Mac agent that notices when you join a call, records and transcribes it, and coaches you live using what was said in earlier conversations with the same client.

**Status:** Phase 0 spike. The first build detects calls and records screen and audio. It has not been compiled or run yet. Transcription, memory and suggestions are not built.

## Try the spike

Needs a Mac on macOS 15 or later with Xcode 16 or the Swift toolchain.

```bash
scripts/build-app.sh
open build/MeetingAgent.app
```

Then follow the [spike test plan](docs/SPIKE.md).

## What it will do

- **Detects calls on its own.** Google Meet, Teams, Zoom and others, including calls that were never on your calendar, by watching for call apps and call cues on screen.
- **Records everything locally.** Screen, your microphone and the other participants' audio, saved on your Mac with no meeting bot joining the call.
- **Transcribes live.** A running transcript with "you" and "them" labels.
- **Coaches you while the client speaks.** Short cards with a question to ask, a point to push back on, or a contradiction with something said in an earlier call, always with the source.
- **Keeps you oriented.** A recap strip with the last few points, a "Catch me up" button for when you drift off, and an alert when someone asks you a question you haven't answered.
- **Remembers every client.** Per-client memory across calls, a pre-call brief, and a summary with action items after each call.

## Docs

- [Spike test plan](docs/SPIKE.md): how to build the spike, what to check on real calls, known limits.
- [Product requirements (PRD)](docs/PRD.md): goals, scenarios, requirements, UX, technical approach, privacy and legal, phasing, risks and open questions.

## Planned approach

Native macOS app in Swift and SwiftUI, running as a menu bar agent with a floating window. Screen and audio capture through ScreenCaptureKit and Core Audio, on-device transcription, a local SQLite store with a vector index for memory, and a language model for suggestions that only ever sees short text snippets. Distributed as a signed, notarized direct download. The API choices in the PRD are to be confirmed in a short spike first.

## Roadmap

| Phase | Focus |
| --- | --- |
| 0. Spike | Prove call detection and capture on a real Mac across Meet, Teams and Zoom |
| 1. Recorder MVP | Floating window, auto start and stop, live transcript, recap and Catch me up, post-call summary |
| 2. Memory | Per-client store, calendar link, pre-call brief, search |
| 3. Live copilot | Ask, Push back and Flag cards with sources |
| 4. Polish | Onboarding, installer, Hindi support, export |

## Privacy and consent

Recording laws vary by country and state, and some require every participant's consent. The app is designed around a consent mode (announce by default), a visible recording indicator, local-first storage, one-click delete, and a never-record list. Get legal advice before recording real client calls.

## Author

Amith K Shinde
