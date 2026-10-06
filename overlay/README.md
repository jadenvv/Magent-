# magent-overlay

The visible overlay: a transparent, click-through layer over every display that shows a ghost
cursor, a highlight on the target element, a one-line caption for the next action, and a
scrolling action log. It also owns the global pause/kill hotkeys and the confirmation prompt
for destructive actions.

It runs as a **separate process** that the agent core drives over pipes. Pause and kill are
done with signals (`SIGSTOP`/`SIGCONT`/`SIGKILL`), so they still work when the agent is stuck
in a model request or its loop is hung. The agent doesn't have to cooperate.

```sh
swift build -c release
.build/release/magent-overlay --demo          # scripted demo, no agent
.build/release/magent-overlay --pid <pid>     # normal use, spawned by the agent
```

| Hotkey | Effect |
|---|---|
| ⌃⌥⌘P | Pause / resume the agent (and its process group) |
| ⌃⌥⌘K | Kill the agent (and its process group), then exit |

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
parse them with `sscanf`.

```
confirm <id> allow|deny
paused
resumed        # re-observe before acting: the screen may have changed while paused
```

If stdin closes, the overlay assumes the agent is gone and exits.

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
