# Sending an update to everyone

Meeting Agent checks GitHub twice a day. When you publish a newer **Release**, everyone who has the app
sees a banner: *"Meeting Agent 0.3.0 is ready. [Download]"*. One click downloads the right installer for
their Mac (Apple silicon or Intel). They open it, drag the app onto Applications and choose **Replace**.
Their calls, notes and settings stay where they are.

You do not need to message anyone. Nothing is installed without them clicking.

## Publishing an update (about 10 minutes)

1. **Raise the version number.** Open `Resources/Info.plist` and change the number under
   `CFBundleShortVersionString` (for example `0.2.0` to `0.3.0`). Also raise `CFBundleVersion` by one.
   The number must be higher than the last release, or nobody will be told.
2. **Build both installers.** Double-click `Make Installer.command`. When it finishes, the folder `dist`
   holds two files:
   - `MeetingAgent-0.3.0-arm64.dmg` for Apple silicon (M1, M2, M3, M4)
   - `MeetingAgent-0.3.0-intel.dmg` for Intel Macs
3. **Create the release on GitHub.**
   - Open https://github.com/amithkshinde/meeting-agent/releases/new
   - In **Choose a tag** type `v0.3.0` (a `v` and the same number as step 1) and pick **Create new tag**.
   - Title: `Meeting Agent 0.3.0`.
   - In the description, the **first line is what people see in the banner**, so make it a plain sentence,
     for example: `Fixes recordings that stopped in the middle of a call.`
   - Drag both `.dmg` files into the box that says "Attach binaries".
   - Leave **Set as a pre-release** unticked and click **Publish release**.
4. **Check it worked.** On your own Mac open Meeting Agent, then Settings > Recorder health > **Check for
   updates**. Use an older copy of the app to see the banner appear.

The file names matter: each installer name must end in `-arm64.dmg` or `-intel.dmg`. `Make Installer.command`
already names them that way.

## Things to know

- **Not notarized.** The first time a person opens a new version macOS may say it can't verify the app. Right-click
  the app, choose **Open**, then **Open** again. Put this line in the release notes so nobody is surprised.
- **Permissions stay** as long as the app is signed with the same "Meeting Agent Dev" certificate. If you build on
  a different Mac or without it, macOS asks for Screen Recording again and people must switch it on and reopen.
- **Pre-releases and drafts are ignored** by the app, so you can test a release privately before publishing it.
- **First run of the speech model.** The first call after installing 0.2.0 downloads the Parakeet speech model
  (about 480 MB, once). Tell people to open Settings and press **Download now** while on good Wi-Fi.
- **If someone has no banner.** They may be offline, or on a very old version that has no update check. Send them the
  right `.dmg` once by message; from then on they will be told automatically.
- **Windows.** The Windows app has the same check. Its installer is attached to the same release (see the Windows
  README).
