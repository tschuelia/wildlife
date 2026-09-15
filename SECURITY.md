# Wildlife security model

Wildlife is a local metadata viewer for Codex and Claude Code. It has no network client, analytics, crash uploader, remote images, or automatic updater. Its Swift package has no third-party dependencies.

## Trust boundary

Wildlife protects its state from other macOS users. Processes already running as the current user, including Codex and Claude, are trusted and retain their normal filesystem access and provider-managed session separation. Wildlife is not an additional sandbox for an agent running as the same user.

The app intentionally displays metadata from multiple sessions in one local UI. It never injects that metadata into a Codex or Claude session. Copying a session ID, path, or resume command places that value on the system pasteboard only after an explicit user action. Resuming a session requires confirmation before Wildlife asks the configured terminal application to run the command. Terminating an active session also requires confirmation; Wildlife revalidates the recorded PID and process-start identity before sending `SIGTERM`, never escalates to `SIGKILL`, and leaves the provider transcript untouched.

## Data retained locally

Wildlife may retain:

- provider and opaque session ID
- locally generated session title or summary
- working directory, timestamps, lifecycle status, model, and tool name
- process ID, process start identity, and terminal device
- Git repository/worktree paths and branch name
- metadata-only lifecycle activity (up to 500 recent entries) and lifetime duration/event-count rollups
- user-selected emoji, tags, local notes, saved filters, pin/archive/snooze state, workflow position, and deletion tombstones

State is stored in `~/Library/Application Support/Wildlife/Sessions.json`. Wildlife directories are mode `0700`; state, configuration backups, and inbox events are mode `0600`; the installed hook is mode `0700`.

History import reads only the local Codex SQLite metadata database and Claude `sessions-index.json` files configured in Settings. It does not open transcript files. Activity history never contains prompts, transcript text, tool arguments, or tool results.

## Hook input and transport

Provider hooks can receive content-bearing JSON fields, including prompts, transcript paths, tool inputs/results, and assistant messages. `wildlife-hook` decodes only the metadata fields listed above. Unknown fields are ignored, the raw stdin buffer is cleared after decoding, and only the reduced `BridgeEvent` is serialized.

Events are written to the private local inbox and, when the app is running, sent over an `AF_UNIX` socket. Both sides verify the peer's effective UID with `getpeereid`; no TCP, HTTP, WebSocket, or remote endpoint is used. The hook writes nothing to stdout, so it supplies no context or decisions to the originating agent session.

## Limitations

Wildlife is not App-Sandboxed because it must read configurable local Codex and Claude metadata, install user-level hooks, inspect local processes, and automate supported terminal applications. Its local-only guarantee is enforced by its code and dependency surface rather than an operating-system network entitlement.
