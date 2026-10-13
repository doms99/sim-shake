# SimShake

A macOS menu bar app for running commands against iOS simulators. Out of the box it has two
commands: **Shake**, which sends the shake gesture to a booted simulator, and **Add Media**, which
imports a photo or video you pick into a booted simulator's Photos library.

## Build and install

Requires Xcode (for `xcrun simctl`) and Swift 6.

```sh
./build.sh
```

This builds a release binary, assembles and ad-hoc signs `build/SimShake.app`, quits any running
copy, installs it to `~/Applications/SimShake.app`, and launches it. Run it again to update.

The menu bar and app icons are rendered from `Support/Icon.svg` by `Support/make-icons.swift`
during the build; replace the SVG to change both.

Run the tests with `swift test`.

## Commands

Open **Settings…** from the menu bar icon to add, edit, reorder, or delete commands and pick their
icons. **Restore Defaults** replaces all commands with the default Shake and Add Media commands.
Installs from before Add Media existed get it added to the end of their list once; delete it and it
stays deleted.

Commands run through your login shell (`$SHELL -l -c "<command>"`), so `PATH` from `~/.zprofile`
(e.g. Homebrew) applies. `~/.zshrc` is not loaded; tools set up only there (such as nvm) need
full paths.

Put `{udid}` anywhere in a command to target a simulator, and `{udid}` is replaced with that
simulator's UDID. With several simulators booted, the command opens a submenu to pick one; with
exactly one booted, it runs on it directly; with none, it is greyed out:

```sh
xcrun simctl spawn {udid} notifyutil -p com.apple.UIKit.SimulatorShake
xcrun simctl openurl {udid} https://example.com
```

Put `{{name}}` in a command for a value you enter each time it runs. Such commands show `…` in the
menu and open a dialog with one field per parameter (all required; Return runs, Escape cancels).
Each value is inserted as one shell-quoted argument, so write the placeholder without quotes:

```sh
xcrun simctl openurl {udid} {{url}}
say {{text}}
```

Put `{name:file}` in a command for a file or folder you pick each time it runs, or
`{name:file:png,jpg}` to limit the picker to those comma-separated extensions. The dialog shows an
editable path field with a **Choose…** button that opens a file picker; you can also type or paste
a path, and a leading `~` is expanded. The path is inserted as one shell-quoted argument. Using the
same name more than once asks for one path and inserts it everywhere:

```sh
xcrun simctl install {udid} {app:file:app}
xcrun simctl addmedia {udid} {media:file:png,jpg,jpeg,heic,gif,mp4,mov,m4v}
```

Commands without `{udid}` run directly when clicked. Success is silent; if a command exits with a
non-zero status, a notification shows the end of its output.

Commands SimShake started are stopped when it quits.

## Logs

Every run writes its own log file to `~/Library/Logs/SimShake/<command-id>/`, named after the
time it started (`2026-10-02_14-03-27-512.log`). A file starts with a header naming the action,
the command as it ran (with `{udid}` and parameters filled in), the simulator if there is one, and
the start time. The command's output follows as it arrives, then a footer with the end time and
the exit status, or a note that it was stopped because SimShake quit.

Each command's page in **Settings…** has a **Logs** section listing its runs, newest first, with
their status (finished, failed, running, stopped, or incomplete if SimShake exited before writing
the footer), simulator, start time, and command. Click a run to open it in the default app for
`.log` files (Console unless you've changed it); right-click to show it in Finder. **Show in
Finder** opens the command's log folder and **Clear…** deletes all of its logs. Files deleted in
Finder drop out of the list.

**Keep last N logs per command** (default 50) sets how many runs are kept. Older logs are deleted
the next time that command runs, so lowering it doesn't delete anything right away. Removing a
command, or **Restore Defaults**, deletes the removed commands' logs.

## Login item

On first launch from `~/Applications` (or `/Applications`), SimShake adds itself to your login
items. Manage it in **System Settings → General → Login Items**.
