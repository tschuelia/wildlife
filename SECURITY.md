# Wildlife security model

Wildlife is a local metadata viewer for Codex and Claude Code. It has no network client, analytics, crash uploader, remote images, automatic updater, or third-party package dependency.

## Trust boundary

Wildlife protects its state from other macOS users. Processes already running as the current user, including Codex and Claude, are trusted and retain their normal filesystem access and provider-managed session separation. Wildlife is not an additional sandbox for an agent running as the same user.

The app displays metadata from multiple sessions in one local UI. It never injects that metadata into an agent session. Copy actions use the system pasteboard only after an explicit user action. Resume requires confirmation before the configured terminal runs a command. Termination also requires confirmation, revalidates both PID and process-start identity before sending `SIGTERM`, never escalates to `SIGKILL`, and leaves provider data untouched.

## Data retained locally

Wildlife may retain:

- provider and opaque session ID
- source or user-selected session title
- working directory, timestamps, lifecycle status, model, and tool name
- process ID, process-start identity, and terminal device
- Git repository/worktree paths and branch name
- up to 500 metadata-only lifecycle entries plus lifetime duration and event-count rollups
- user-selected emoji, tags, notes, saved views, pin/archive/snooze state, workflow position, and deletion tombstones

Application state is stored in `~/Library/Application Support/Wildlife/Wildlife.sqlite3`. Wildlife-owned directories are mode `0700`; the database, configuration backups, and inbox events are mode `0600`; the installed hook is mode `0700`.

History import opens the configured Codex SQLite metadata database read-only and decodes Claude `sessions-index.json` files. It does not open transcript files and never writes, renames, deletes, or changes permissions on Codex or Claude session data. Hook configuration is changed only by an explicit Install, Repair, or Remove Hooks action.

## Hook input and transport

Provider hooks can receive content-bearing JSON fields, including prompts, transcript paths, tool inputs/results, and assistant messages. `wildlife-hook` decodes only provider, opaque session ID, event name, working directory, model, tool name, lifecycle reason/source, notification type, and local process identity. Unknown fields are ignored, the raw standard-input buffer is cleared after decoding, and only the reduced typed `AgentEvent` is serialized.

Events are written to the private local inbox and, when the app is running, sent over an `AF_UNIX` socket. Both sides verify the peer's effective UID with `getpeereid`; no TCP, HTTP, WebSocket, or remote endpoint is used. The hook writes nothing to standard output, so it supplies no context or decisions to the originating agent session.

Hook configuration updates use typed, lossless JSON merging: unrelated root keys, hook groups, handler fields, and third-party handlers are preserved. Changed files are backed up. Wildlife removes only handlers whose command exactly matches its installed bridge.

## Limitations

Wildlife is not App-Sandboxed because it must read configurable local Codex and Claude metadata, install user-level hooks, inspect local processes, and automate supported terminal applications. Its local-only guarantee is enforced by the code and dependency surface rather than a network entitlement.
