# magent-overlay

The visible overlay: a transparent, click-through layer over every display that shows a ghost
cursor, a highlight on the target element, a one-line caption for the next action, and a
scrolling action log. It also owns the global pause/kill hotkeys and the confirmation prompt
for destructive actions.

It runs as a **separate process** that the agent core drives over pipes. Either the agent
spawns it (`--pid`), or it runs all the time as a daemon with one long-lived agent that it
starts itself (`--daemon`, see below). Pause and kill are
done with signals (`SIGSTOP`/`SIGCONT`/`SIGKILL`), so they still work when the agent is stuck
in a model request or its loop is hung. The agent doesn't have to cooperate.

```sh
swift build -c release
.build/release/magent-overlay --demo          # scripted demo, no agent
.build/release/magent-overlay --pid <pid>     # spawned by the agent
.build/release/magent-overlay --daemon <agent> # always on; starts <agent> once, keeps it
```

| Hotkey | Effect |
|---|---|
| ⌃⌥⌘P | Pause / resume the agent (and its process group) |
| ⌃⌥⌘K | Kill the agent (and its process group), then exit |
| ⌃⌥⌘Space | Open/close the prompt bar to give the agent a request |

The prompt bar is a Spotlight-style field on the display with the mouse. Return sends the
request; Esc, the hotkey, or clicking elsewhere cancels. If the agent is running, it is paused
while the bar is open (the bar takes keyboard focus, so the agent's keystrokes would otherwise
land in it) and resumed when it closes.

## Protocol

**Agent → overlay** (overlay stdin): one JSON object per line. Coordinates are global points,
top-left origin at the primary display. That is the same space CGEvent and AX frames use.

| `type` | Fields | Effect |
|---|---|---|
| `action` | `text`, optional `rect`, optional `cursor` | Caption + log line; highlight `rect`; move ghost cursor to `cursor` or the rect's center |
| `cursor` | `x`, `y` | Move ghost cursor |
| `click` | `x`, `y` | Move ghost cursor + click ripple |
| `highlight` | `rect` or `null` | Set/clear highlight |
| `caption` | `text` | Set caption |
| `log` | `text`, optional `level` (`info` `ok` `warn` `error` `action`) | Append to log |
| `status` | `state` (`running` `done` `error`) | Status pill + screen border color |
| `confirm` | `id` (no whitespace), `text` | Show Allow/Deny panel |
| `clear` | | Clear cursor, highlight, caption |

`rect` is `{"x":..,"y":..,"w":..,"h":..}`.

**Overlay → agent** (overlay stdout): space-separated tokens, one event per line, so C can
parse them with `sscanf`. `prompt` is the exception: its text runs to the end of the line.

```
confirm <id> allow|deny
paused
resumed        # re-observe before acting: the screen may have changed while paused
prompt <text>  # a request from the prompt bar; newlines/control chars already turned into spaces
```

Prompt lines have no length limit, so read with `getline` rather than a fixed `fgets` buffer.
The agent is paused while the bar is open, so it reads `paused`, then `prompt ...`, then
`resumed`. A `status` sent just before a pause is held and shown on resume, so the overlay
never shows "Running" for a stopped agent.

If stdin closes, the overlay assumes the agent is gone and exits.

## Daemon mode

`--daemon <agent>` keeps the overlay running with nothing on screen until ⌃⌥⌘Space. It starts
`<agent>` (no arguments) right away, so the agent can load its models before the first request,
and keeps that one process for every request. It talks to it over its **stdin/stdout** with the
same protocol as above: each request arrives as a `prompt <text>` line, and the agent writes JSON
lines to stdout. Its stderr goes to the overlay's log. The agent should:

- send exactly one `{"type":"status","state":"done"}` (or `"error"`) per `prompt` line, when
  that request is finished, and then **stay running** and wait for the next one,
- exit when stdin closes, which means the overlay is gone.

When every request sent so far is finished, the overlay shows the result for 3 s and goes idle;
a request typed while another is running keeps it running until both are done. Any agent exit
the overlay didn't cause shows as an error. ⌃⌥⌘K kills the agent (even an idle one) and the
overlay stays up; the next request starts a new agent, which pays the model load again. The agent is started in its own process group, so pause and kill
always reach its children. When launchd stops the overlay (SIGTERM), it kills the agent first.

To install it as a LaunchAgent (starts at login, restarted if it dies) **in the dev account**:

```sh
scripts/install-launch-agent.sh /path/to/agent     # --print to see the plist without installing
scripts/uninstall-launch-agent.sh
```

- **Permissions belong to the overlay.** macOS attributes a child's Accessibility and Screen
  Recording use to the process that launched it, so grant them to
  `~/Library/Application Support/Magent/magent-overlay`. The build is ad-hoc signed, so each
  reinstall after a rebuild probably needs the grants again.
- **launchd's environment is minimal** (no shell profile, basic `PATH`). The agent should load
  its config and API keys itself, for example from the Keychain. Don't put them in the plist.
- The install script refuses admin accounts unless `MAGENT_ALLOW_ADMIN=1`.

## Spawning from C (sketch)

```c
int to_ov[2], from_ov[2];
pipe(to_ov); pipe(from_ov);
posix_spawn_file_actions_t fa;
posix_spawn_file_actions_init(&fa);
posix_spawn_file_actions_adddup2(&fa, to_ov[0], 0);
posix_spawn_file_actions_adddup2(&fa, from_ov[1], 1);
char pid[16]; snprintf(pid, sizeof pid, "%d", getpid());
char *argv[] = {"magent-overlay", "--pid", pid, NULL};
posix_spawn(&ov_pid, path, &fa, NULL, argv, environ);
close(to_ov[0]); close(from_ov[1]);
FILE *ov = fdopen(to_ov[1], "w");
setvbuf(ov, NULL, _IOLBF, 0);   /* line-buffered: each event goes out immediately */
fprintf(ov, "{\"type\":\"click\",\"x\":%d,\"y\":%d}\n", x, y);
```

Strings in `text` have to be JSON-escaped (`"`, `\`, control chars).

## Things the rest of the system must handle

- **Exclude the overlay from screenshots.** `NSWindow.sharingType = .none` is set, but recent
  macOS doesn't honor it for ScreenCaptureKit. Build the `SCContentFilter` with the overlay's
  windows excluded, or the model will see the ghost cursor and log.
- **Group kill needs the agent to lead its process group.** If it does (the usual case when it's
  started from a shell), pause and kill also reach its child processes. If it doesn't, only the
  agent pid is signalled, and children it spawned keep running.
- **Pausing mid-gesture.** `SIGSTOP` between a mouse-down and a mouse-up leaves the button held.
  The agent should treat `resumed` as a reason to re-observe and re-check its state.
- **The confirmation panel isn't the only safeguard.** Allow only accepts clicks whose CGEvent
  source pid is 0 (real hardware), the buttons are hidden from the AX tree, and Allow is
  disabled for 0.6s after the panel appears. Even so, the executor still has to refuse
  destructive actions until it reads `confirm <id> allow`.
- **Prompts must come from the keyboard.** The prompt bar only submits on a Return whose source
  pid is 0, so an agent that synthesizes keystrokes (say, because a web page told it to) can't
  give itself a request. Opening the bar isn't gated; it only pauses the agent.
