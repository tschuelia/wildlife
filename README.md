# Wildlife

Wildlife is a fully local macOS companion for interactive Codex and Claude Code sessions. It watches lifecycle events from any terminal, shows live status around the MacBook notch and in the menu bar, and keeps resumable sessions organized with titles, unique animal emoji, and plain-text notes.

## Highlights

- Native Swift 6 app for macOS 15 and newer
- Notch island with a menu-bar fallback
- In Progress, Backlog, and Completed workflow
- Global Codex and Claude Code hooks, independent of the terminal application
- 30-day local history import with an optional full-history import
- Custom, shell-safe resume-command templates
- No network client, analytics, crash reporting, remote images, or automatic updater

Wildlife only stores session metadata. Its hook bridge explicitly discards prompts, assistant messages, tool arguments, and tool results.

## Build and run

The Swift package builds with the macOS Command Line Tools:

```sh
swift build
swift run Wildlife
```

Run the dependency-free core behavior checks with:

```sh
swift run WildlifeCoreChecks
```

The check executable is used because the standalone Command Line Tools installation on the development machine does not ship XCTest or Swift Testing. It covers lifecycle reduction, configuration merging and repair, notch geometry, local history import, emoji allocation, and resume-command escaping.

For normal development, open `Package.swift` in Xcode. The full Xcode app is required for archive, Developer ID distribution, and notarization.

## Package a macOS app

Create a locally signed app bundle:

```sh
scripts/package-app.sh
open .build/Wildlife.app
```

For a universal Developer ID build, set a signing identity:

```sh
WILDLIFE_CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
WILDLIFE_UNIVERSAL=1 \
scripts/package-app.sh
```

If `WILDLIFE_NOTARY_PROFILE` names a Keychain profile created with `notarytool store-credentials`, the packaging script also submits and staples the app.

## First launch

1. Open Wildlife and select **Install Integrations**.
2. Wildlife copies its small bridge executable into `~/Library/Application Support/Wildlife/bin/`.
3. Wildlife adds its own handlers to `~/.codex/hooks.json` and `~/.claude/settings.json`. It backs up existing files and preserves other hooks.
4. Start a new agent session. Codex requires a one-time `/hooks` review for newly installed hooks.

Already-running agent processes need to be restarted or resumed because both CLIs load hook configuration when a session starts.

On launch, Wildlife automatically repairs options on exact-match handlers it previously installed, including removing Codex's unsupported `async` option. It backs up the original configuration and never installs missing integrations or changes unrelated hooks during this migration. If Settings still shows **Repair needed** because events are missing, select **Install or Repair**.

## Local data

Wildlife stores its state under `~/Library/Application Support/Wildlife/`. Events use a user-private Unix socket and are spooled to a user-private inbox when the app is closed. Removing a Wildlife record never deletes the corresponding Codex or Claude transcript.

Default copied commands are:

```text
cd {{cwd}} && codex resume {{session_id}}
cd {{cwd}} && claude --resume {{session_id}}
```

Both templates are editable in Settings. Wildlife quotes substituted values as POSIX shell arguments before placing a command on the clipboard.
