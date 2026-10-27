# Contributing to FileAdmiral

Thanks for helping. FileAdmiral is a native Swift/AppKit app with no third-party dependencies, so the
whole toolchain is the Xcode Command Line Tools.

## Build and run

```bash
swift build                      # debug build in .build/debug/FileAdmiral
./build.sh && open build/FileAdmiral.app   # signed .app bundle (local self-signed identity)
```

`build.sh` signs with a stable local certificate so macOS keeps the privacy permissions you grant
(Full Disk Access, Desktop/Documents) across rebuilds. Nothing is uploaded anywhere.

## Self-test

The app has a built-in end-to-end test that drives the real UI (panels, keyboard, file operations,
sync, duplicates, archives, plugins) in a scratch folder:

```bash
swift build && FA_SELFTEST=/tmp/fileadmiral-selftest .build/debug/FileAdmiral
```

It prints one `PASS`/`FAIL` line per check and exits non-zero on failure. CI runs exactly this.
Please run it before opening a pull request, and add a check to `Sources/FileAdmiral/SelfTest.swift`
for anything you fix or add — especially anything that copies, moves, deletes or renames files.

FTP/SFTP tests are skipped unless a local sshd (port 2222) and `Tools/test_ftp_server.py` (port 2121)
are running; see the header of `SelfTest.swift` for the environment variables.

## What matters most

FileAdmiral is a file manager: **it must never lose a file.** Rules the code already follows and that
pull requests must keep:

- Copies write to a temporary name and rename into place; the old file survives any failure.
- Renames and moves use `renamex_np(RENAME_EXCL)` so nothing is ever silently replaced.
- Use `lstat`, never `stat`, to decide what something is; never follow symlinks into a copy or delete.
- Undo goes through the Trash; the app never permanently deletes anything on its own initiative.
- An unreadable folder is an **error**, never an empty folder (see `FolderSync.compare`).
- External tools get argument arrays, never shell strings built from file names. Names that could be
  taken as options are prefixed with `./`.
- Anything that can take longer than a blink (listing a big folder, hashing, diffing) runs off the
  main thread and can be cancelled.

## Style

- Match the surrounding code: programmatic Auto Layout, one `NSWindowController` per tool window,
  pure logic in enums (`FolderSync`, `DuplicateFinder`, `TextDiff`, `FileMask`) separated from the UI
  so the self-test can call it.
- Comments explain *why*, not what. Keep them short.
- No new dependencies without discussion.

## Reporting bugs

Open an issue with macOS version, what you did, what happened, and — if files were involved — whether
anything was lost or changed. Data-loss reports are treated as the top priority.
