# Sending an update to everyone

Meeting Agent checks GitHub twice a day. When you publish a newer **Release**, everyone who has the app sees a
banner: *"Meeting Agent 0.4.0 is ready. [Download]"*. One click downloads the right installer. Their calls, notes
and settings stay where they are. You do not message anyone, and nothing installs without them clicking.

There are three places and one rule:

| What | Repo | Who builds it | Where people get it |
|---|---|---|---|
| Mac app (Apple Silicon and Intel) and the website | `amithkshinde/meeting-agent` | GitHub, from a tag like `v0.4.0` | Releases of `meeting-agent` |
| Windows app | `amithkshinde/meeting-agent-windows` | GitHub, from a tag like `v0.4.0` | Releases of `meeting-agent-windows` |
| Website (Vercel) | `meeting-agent` | Vercel, from `main` | the site's Download buttons read the latest releases |

**The rule:** never edit `main` directly. Work on a branch, open a pull request, check that the green tick appears,
then merge. Merging to `main` updates the website by itself. A release only happens when you push a tag.

## Everyday changes (no new version)

1. Make a branch: `feature/<what-you-are-doing>`.
2. Push it. GitHub runs **Check** (builds the Mac app and runs the tests). For Windows, run `npm test`.
3. Open a pull request into `main`. When Check is green, press **Merge**. Vercel updates the website within a minute.

## Publishing a Mac update (about 15 minutes, mostly waiting)

1. **Raise the version** in `Resources/Info.plist`: `CFBundleShortVersionString` (for example `0.3.0` to `0.4.0`)
   and add one to `CFBundleVersion`. It must be higher than the last release or nobody is told.
2. **Write the release notes** in `RELEASE_NOTES.md`. The **first line** is what people see in the banner, so make it
   one plain sentence.
3. Commit these on a branch, open a pull request, and merge it once Check is green.
4. **Start the build.** Easiest: on GitHub open **Actions > Release Mac app > Run workflow**, keep branch `main`, type
   `v0.4.0` (a `v` plus the exact number from step 1) and press the green button. (Terminal alternative:
   `git checkout main && git pull && git tag v0.4.0 && git push origin v0.4.0`.) GitHub now builds `MeetingAgent-0.4.0-arm64.dmg` and
   `MeetingAgent-0.4.0-intel.dmg` and publishes the release. Watch it on the **Actions** tab (about 15 to 25 minutes).
   If the tag and the plist number differ, the build stops and says so. Fix the number and tag again.
5. **Check it.** Open Meeting Agent, Settings, Recorder health, **Check for updates**.

## Publishing a Windows update

1. In the Windows repo raise `version` in `package.json`, write what changed, merge through a pull request.
2. On GitHub open **Actions > Build Windows installer > Run workflow** (or push a tag like `v0.4.0`). GitHub builds the
   installer on a Windows machine and publishes it.
3. Keep the Windows and Mac version numbers in step when you can; they do not have to match.

## Keeping macOS permissions across Mac updates

macOS forgets Screen Recording permission when the app's signature changes. Builds made on GitHub are signed ad hoc,
so people would have to switch Screen Recording on again after every update. To avoid this once and for all:

1. On your Mac open Keychain Access, find the **Meeting Agent Dev** certificate, right-click, **Export**, save as `.p12`
   and choose a password.
2. In Terminal: `base64 -i MeetingAgentDev.p12 | pbcopy`
3. On GitHub open `meeting-agent` > Settings > Secrets and variables > Actions > New repository secret. Add
   `MAC_CERT_P12` (paste) and `MAC_CERT_PASSWORD` (the password). Delete the `.p12` file afterwards.

From then on every release is signed with the same certificate as your own builds.
(Fallback if you would rather not: run `Make Installer.command` on your Mac and attach its `.dmg` files to a release by hand.)

## Things to know

- **Not notarized.** The first time someone opens a new version macOS may say it can't verify the app. Right-click it,
  choose **Open**, then **Open** again. The release notes already say so.
- **Pre-releases and drafts are ignored** by the app, so you can test a release privately by marking it as a draft.
- **First run of the speech model.** The first call after installing downloads the Parakeet speech model
  (about 480 MB on Mac, 650 MB on Windows, once). Tell people to open Settings and press **Download now** on good Wi-Fi.
- **If someone has no banner.** They may be offline, or on a version with no update check. Send them the right installer
  once; after that they are told automatically.
- **Never put personal details in the code.** The feedback email is set locally in `Resources/Info.plist`
  (`FeedbackEmail`) and in the Windows `package.json` (`meetingAgent.feedbackEmail`). Keep both empty in anything you push.
- **Rolling back.** If a release is bad, mark it as a draft on GitHub. The app then stops offering it. Publish a fixed
  version with a higher number.
