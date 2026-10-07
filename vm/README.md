# magent-vm

Runs the staged-mode macOS VM directly on Apple's Virtualization framework (no Tart/Lume), so we
control the display, saved state and, later, networking.

```sh
./scripts/build.sh                       # build + sign with the virtualization entitlement
BIN=$(./scripts/build.sh | tail -1)

$BIN install golden                      # downloads ~15 GB installer (cached, resumable), installs macOS
$BIN run golden --window                 # one-time: Setup Assistant, permissions, helper install
$BIN run golden --window --save-on-quit  # quit once set up: saves RAM state next to the disk

$BIN clone golden task1 --keep-identity  # instant APFS copy, keeps the saved state
$BIN run task1                           # resumes in seconds, in a corner preview
```

Use `scripts/build.sh`, not `swift run`. `swift run` relinks the binary, which drops the entitlement.

## Corner preview

`run` without `--window` opens a small floating preview in the bottom-left. The overlay's log
sits in the bottom-right, so the two don't overlap.

- **View-only by default.** Mouse and keyboard over the preview are not passed to the VM, so
  glancing at it can't interfere with the agent. Tick **Interact** to take over.
- **Double-click** or **Expand** toggles between corner size and a large centered view.
- **Close / Ctrl-C** asks the guest to shut down (forced after 30s). A second close or Ctrl-C
  forces it right away. With `--save-on-quit`, it saves state instead.

## Saved state rules

A saved state (`state.vzvmsave`) is RAM/CPU state that is only valid together with the disk
**exactly** as it was when saved. So:

- It is deleted as soon as the VM starts running, whether resumed or cold-booted. After that the
  disk has diverged, and restoring the old RAM onto it could corrupt the guest filesystem.
  To reuse a state many times, keep it in a golden VM you never run, and clone per task.
- A state only restores into an identical configuration. `clone` without `--keep-identity` gives
  the copy a fresh machine identifier and MAC (so two copies can run side by side) and drops the state.
- If a restore fails, `run` falls back to a cold boot and says so.

## Layout

`~/.magent/vms/<name>/` (override the root with `MAGENT_VM_HOME`):

| File | |
|---|---|
| `disk.img` | sparse disk image (uses space only as the guest writes) |
| `aux.img` | Mac auxiliary storage (NVRAM). Required to boot |
| `spec.json` | CPUs, RAM, display, MAC, hardware model, machine identifier |
| `state.vzvmsave` | saved state, if any |

Installer images are cached in `~/.magent/vms/.ipsw/`.

## Defaults

4 CPUs, 8 GB RAM, 64 GB disk, display 1920×1080 at 80 ppi. The low ppi makes the guest
non-Retina, so screenshot pixels equal guest points, which keeps agent coordinates simple and
screenshots small. Override with `install --cpus/--memory/--disk`.
