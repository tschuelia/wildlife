<div align="center">
  <img src="Resources/WildlifeIcon.png" width="160" height="160" alt="Wildlife app icon">

  <h1>Wildlife</h1>

  <p>Wildlife is a local macOS companion for interactive Codex and Claude Code sessions. It keeps active work visible, organizes sessions into a practical workflow, and lets you return to the right terminal without reading or changing provider transcripts.</p>
</div>

Wildlife v0.1.0 runs locally on macOS 15 or newer. It has no network client, telemetry, crash uploader, updater, or third-party package dependencies.

## What Wildlife does

- Registers Codex and Claude Code sessions through local lifecycle hooks, independently of the terminal app you use.
- Shows active sessions in the MacBook notch on supported displays and in the menu bar on every Mac.
- Organizes sessions into **In Progress**, **Backlog**, and **Completed** workflows.
- Provides smart views for sessions needing attention, favorites, recent work, and archived work.
- Searches and filters by provider, workflow, project, tags, attention state, and update time; filters can be saved as custom views.
- Tracks repository, worktree, and branch context and warns when active sessions share a worktree.
- Records a metadata-only activity timeline with elapsed, active, waiting, tool, permission, compaction, interruption, failure, and subagent counts.
- Adds local titles, emoji, tags, notes, pinning, snoozing, archiving, backlog ordering, and workflow automation.
- Focuses active terminal sessions, resumes ended sessions after confirmation, and gracefully terminates verified local processes after confirmation.

## Using the manager

The main window has three columns:

1. Choose a smart view, workflow, or saved view in the sidebar.
2. Single-click a session in the middle column to open its details.
3. Use **Overview**, **Activity**, and **Notes** in the inspector to review or organize the selected session.

Double-clicking a session performs its primary action: an in-progress session focuses its terminal, while any other session opens the confirmation to resume it. The action menu also provides workflow, pin, snooze, archive, Finder, terminal, clipboard, termination, and record-removal actions where applicable.

Removing a Wildlife record does not remove the matching Codex or Claude session or transcript.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘1`–`⌘5` | Open a built-in smart view |
| `⌥⌘↑` / `⌥⌘↓` | Select the previous or next session |
| `⌘Return` | Focus or resume the selected session |
| `⌘P` | Pin or unpin the selected session |
| `⇧⌘A` | Archive or restore the selected session |

## Install the integrations

On first launch, choose **Install Integrations**. You can install, repair, remove, or inspect the hooks later under **Settings → Integrations**.

Wildlife installs its bridge at:

```text
~/Library/Application Support/Wildlife/bin/wildlife-hook
```

It adds only Wildlife-owned handlers to `~/.codex/hooks.json` and `~/.claude/settings.json`. Existing keys and unrelated hooks are preserved, and configuration files are backed up before they are changed. Already-running Codex or Claude processes may need to restart or resume because hook configuration is loaded when a session starts. Codex may also request a one-time `/hooks` review.

If either provider shows **Repair needed**, choose **Install or Repair**. This also restores the bridge's executable permissions.

## Settings

Wildlife can:

- Group session lists by repository and choose the preferred terminal.
- Move failed or interrupted sessions to Backlog automatically.
- Archive completed sessions after 7, 30, or 90 days.
- Launch at login and load older provider history on request.
- Notify for approvals, input requests, failures, and completions.
- Use custom Codex and Claude home directories and resume-command templates.

The default history view includes active sessions and sessions updated during the last seven days. Choose **Load older sessions** in the manager or **Load all older sessions** in Settings to import additional metadata.

## Privacy and local data

Hooks accept an allowlist of lifecycle and project metadata. Prompts, assistant messages, transcript paths, tool arguments, and tool results are discarded before an event reaches Wildlife. Imported and replayed history never produces notifications.

Wildlife stores its own state under `~/Library/Application Support/Wildlife/`:

```text
Wildlife.sqlite3    Application state
Inbox/              Events queued while Wildlife is closed
bin/wildlife-hook   Installed metadata bridge
```

Events use a current-user Unix socket while the app is running. Wildlife reads provider history metadata from Codex's local SQLite database and Claude's `sessions-index.json` files, but never writes to those data sources. Removing a record creates a local tombstone so history import does not recreate it.

See [SECURITY.md](SECURITY.md) for the complete data boundary and threat model.

## Build and run

Wildlife requires a complete Xcode installation because it uses SwiftUI observation macros. If the active developer directory points to Command Line Tools, select Xcode for the shell session:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
swift run Wildlife
```

You can also open `Package.swift` directly in Xcode.

To create an ad-hoc signed local app bundle:

```sh
scripts/package-app.sh
open .build/Wildlife.app
```

For a universal Developer ID build:

```sh
WILDLIFE_CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
WILDLIFE_UNIVERSAL=1 \
scripts/package-app.sh
```

If `WILDLIFE_NOTARY_PROFILE` names a Keychain profile created with `notarytool store-credentials`, the packaging script submits and staples the bundle as well.

## Project structure

- `WildlifeDomain` contains the value types and lifecycle, workflow, filtering, and organization rules.
- `WildlifeInfrastructure` contains SQLite persistence, local transport, history readers, Git inspection, process validation, and secure file handling.
- `Wildlife` is the native SwiftUI app, manager, menu-bar view, notch presentation, notifications, and integration settings.
- `wildlife-hook` is the minimal metadata bridge invoked by Codex and Claude hooks.

The Swift Testing suites cover lifecycle reduction, provider-session isolation, filtering and organization, persistence, metadata redaction, hook merging, authenticated local transport, path safety, read-only history import, Git parsing, and notch geometry.

Default resume templates are:

```text
cd {{cwd}} && codex resume {{session_id}}
cd {{cwd}} && claude --resume {{session_id}}
```

Both templates are editable in **Settings → Integrations**. Substituted values are POSIX-shell quoted before a command is copied or sent to the selected terminal.
