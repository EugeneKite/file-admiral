# Changelog

## Unreleased — first public release

### Fixed (data safety)
- **Synchronize Folders**: a folder that could not be read (no Full Disk Access, permission error,
  dropped network share) was treated as *empty*; in mirror mode with "delete extra files" that marked
  every file on the other side for deletion. The comparison now aborts with an error instead.
- **Synchronize Folders**: a folder on one side and a file with the same name on the other is never
  resolved automatically any more, not even after changing options after a compare.
- **Find Duplicates**: files were compared by path, so a hard link — or the same file seen through
  `/System/Volumes/Data` when scanning from `/` — was offered as a "duplicate" of itself. Scans now stay
  on one volume and count each inode once.
- **Disk Usage**: no longer double-counts the data volume through `/System/Volumes/Data` or follows
  into other mounted volumes.
- **Rename (F2)**: uses `RENAME_EXCL`, so a file that appears under the new name between the check and
  the rename is never replaced.
- **FTP**: folder downloads build local paths from names sent by the server; names containing `/`
  or `..` are now rejected, so a hostile server cannot write outside the destination folder.
- **Compare by Content / Synchronize**: a file that cannot be opened is reported as an error instead of
  "differs at byte 0"; byte comparison tolerates short reads on network volumes.

### Fixed (robustness)
- Directory listing runs off the main thread: huge folders and slow network shares show a loading state
  instead of freezing the app. Small local folders behave exactly as before.
- Compare by Content computes the diff in the background (large files no longer block the UI).
- Lister refuses pipes, sockets and devices instead of hanging, and lays out large files lazily.
- Multi-Rename: an overflowing counter no longer crashes the app; an invalid regular expression is
  reported instead of silently renaming nothing; temporary names used during a rename are visible, so
  a crash mid-rename leaves files easy to find.
- Find Files: Stop ends a running Spotlight (`mdfind`) query; buttons act on the keyboard selection.
- Thumbnail cache is bounded in bytes (256 MB), not only in entries.
- Synchronize shows per-file progress and Cancel stops the current copy.
- Permissions window stops polling when it is not in front.

### Changed
- Renamed internally from the pre-release name "MacCommander": bundle id `io.github.eugenekite.fileadmiral`,
  support folder `~/Library/Application Support/FileAdmiral`, plugin environment variables `FA_*`
  (was `MC_*`). Settings, plugins and saved connections from pre-release builds do not carry over.
- The encoding assumed for text that is not UTF-8/UTF-16 is a setting (Settings → Tools → "Non-UTF-8
  text"); the default is Windows-1252. It was hard-coded to Windows-1251.

### Added
- GPL-3.0 license, contributing guide, GitHub Actions CI running the build and the self-test.
