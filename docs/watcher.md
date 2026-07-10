# The watcher

The watcher is a **latency optimisation**. `status --check`'s staleness
comparison (bash builtins only, `[[ a -nt b ]]`, no fork) is the
**correctness backstop**, and `awsconfd build` is always safe to run
manually. Nothing in this tool is ever load-bearing on the watcher being
installed, running, or even existing on your platform.

Four layers, each closing a gap the one before it can't:

| Layer | What | Closes |
|---|---|---|
| 1 | systemd path unit / launchd `WatchPaths` | fires close to instantly on a fragment change |
| 2 | `WantedBy=default.target` / launchd `RunAtLoad` | a build at every login - repairs anything Layer 1 missed while you were logged out (machine was off, `git pull` happened remotely, the unit was masked) |
| 3 | the shell hook (`eval "$(awsconfd hook bash)"`) | the one gap neither systemd nor launchd can see: an in-place edit that doesn't touch a directory's mtime. Zero-fork in the common case - it only ever calls `awsconfd` when something is actually stale |
| 4 | `--with-timer`, opt-in | headless hosts nobody ever logs into, where Layers 2 and 3 never fire at all |

## `watch --install`

Detects the init system:

- **macOS** with `launchctl` present → launchd.
- **systemd**, but only when `systemctl --user is-system-running` reports
  `running` or `degraded` (a live, bus-connected user session), or the
  `$XDG_RUNTIME_DIR/systemd/private` socket exists. A `systemctl` binary
  that exists but reports `offline` - the common case inside a plain
  container or a minimal server with no session bus - is treated the same
  as "not present". This matters: earlier drafts of the detection logic
  mis-read `offline` as "usable" and then failed loudly the moment they
  tried to actually talk to a bus that wasn't there.
- **Neither** → not an error. Exits 0, installs nothing, prints the Layer 3
  recommendation. WSL without systemd, containers, and minimal servers all
  land here, correctly.

### systemd

Writes `awsconfd-build.service` and `awsconfd-build.path` to
`${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, both carrying a
`# managed-by: awsconfd` sentinel line so `watch --uninstall` only ever
removes what it wrote. `ExecStart` is this script's own resolved absolute
path (no `readlink -f`/`realpath` - both forbidden; see `_self_path` in the
script), because `systemd --user` provides a minimal `PATH` that doesn't
necessarily include wherever you installed to. `ExecStartPre=<sleep> 0.5`
debounces a burst of several inotify events from one editor save.

`--with-timer` additionally writes `awsconfd-build.timer`
(`OnCalendar=hourly` by default, `--interval` overrides it) - Layer 4.

Re-running `--install` compares the generated unit text against what's on
disk; if identical, nothing is written and `daemon-reload` isn't called.

### launchd

Writes `~/Library/LaunchAgents/com.GingerGraham.awsconfd.plist`.
`RunAtLoad` is Layer 2. **Known, documented limitation**: `WatchPaths` on a
directory fires reliably on create/delete/rename (directory-mtime changes)
but an in-place append may not touch the directory's mtime and may
therefore not fire. Editors that save via write-temp-then-rename (vim, VS
Code, most GUI editors) are unaffected; anything that appends in place
isn't covered by Layer 1 on macOS. `watch --install` prints a
recommendation to also install the shell hook, which is Layer 3 and closes
exactly this gap.

### `watch --status`

Reports, per layer: installed? enabled? Is the unit's `ExecStart` still an
existing, executable path (catches a moved or renamed binary)? Does the
unit's watched path match the currently-resolved `config.d` (catches a
`--config-dir` override that's drifted from what was baked into the unit at
install time)?

### `watch --uninstall`

Removes exactly what `--install` created, checking the sentinel line first
- a unit file without it is left alone rather than deleted, on the
assumption you or something else put it there deliberately.

## Layer 3 - the shell hook

```bash
eval "$(awsconfd hook bash)"   # or: eval "$(awsconfd hook zsh)"
```

Registers a function on `PROMPT_COMMAND` (bash, appended, never clobbering
whatever was already there) or `precmd_functions` (zsh) that does the
staleness check - bash builtins only, no fork - and calls
`awsconfd build --quiet` only when something's actually stale. In the
common case (nothing stale) this costs nothing measurable. It's the only
layer that closes the macOS in-place-append gap, and the only one that
works with no init system at all - which is why it's opt-in rather than
auto-installed: printing the line for you to add to your shell rc is the
whole interface.

Set `AWSCONFD_HOOK_DISABLE=1` to disable it temporarily without removing
the line from your rc file.

## Verifying it's working

```bash
awsconfd status               # fragment table, staleness, watcher state all in one place
systemctl --user status awsconfd-build.path      # Linux
launchctl list | grep GingerGraham.awsconfd      # macOS
```

Headless hosts you never log into interactively need
`loginctl enable-linger $USER` for Layer 2 (the login-time build) to have
anything to trigger on - `watch --install --with-timer` prints this
reminder.
