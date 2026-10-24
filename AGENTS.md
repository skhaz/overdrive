# Agents

## Rules for this file

- Technical details live here. `README.md` is for users: plain words, no internals.
- Write simple, direct English. Only what matters. No filler.

## Commits

Commit each change when it is complete. Do not ask before you commit.

Always run `swift test` before every commit. Commit only when all tests pass. GitHub Actions does not run the tests; the `Release` workflow only builds.

## Data

- Never write migration code. A file that does not match the current format is ignored, or deleted and built again. No schema numbers, no legacy readers.

## YouTube

- One web view, made at launch, kept until quit. Never a second one, never recreated. The player page stays loaded and ready.
- A video starts: pause the song. A song starts: close the video window.

## Build and test

- Build: `./build.sh`. Last.fm: `LASTFM_KEY=... LASTFM_SECRET=... ./build.sh` (key from https://www.last.fm/api/account/create).
- Every change gets tests: new code and the code it touches. Every bug fix gets a regression test that fails without the fix. Code without tests gets them when it changes.
- Test: `swift test`. Test the release from Homebrew; a local build is only for debugging or profiling.
- Sanitizers: `swift test --sanitize=address`, `swift test --sanitize=undefined`, `swift test --sanitize=thread`.
- Fuzzing: `docker run --rm -v "$PWD":/src:ro -v /tmp/fuzz:/out -e OUT=/out --shm-size=256m swift:latest sh /src/Fuzz/fuzz.sh 300`. Targets in `Fuzz/Targets`, seeds in `Fuzz/Seeds`, crashes in `/tmp/fuzz/crashes`. Do not edit sources while it builds.
- The fuzzed parsers must use only Foundation, so they compile on Linux.
- Every fuzzer crash becomes a regression test with a file in `Tests/OverdriveTests/Fixtures`.
- Uninstall: `brew uninstall --zap --cask overdrive`. The `.lrc` files in the music folders stay.

## Music library

- The library is read-only. The app never writes, moves, renames, or deletes an audio file.
- In a music folder the app writes only: `Cache.sqlite` (and its `-wal` and `-shm`) and `Loudness.plist` at the folder root, `.lrc` files next to the songs, and, at the root of the first folder, `Likes.plist`, the `Playlists` folder, and the `Lyrics` folder (the lyrics cache, `.txt`). The watcher ignores them: a write there must never start a scan.

## Library cache

**Hard requirement:** the filesystem, the cache, and the full-text index (FTS5, `bm25`) stay in strict sync, always and without exception.

- The cache and the index change only in one transaction (the triggers). `LibraryCacheTests` runs the FTS5 `integrity-check` after every scan step.
- The scan commits each step atomically, then shows it. The UI never shows a state the cache does not have. A replaced scan keeps what it committed. Only the first snapshot can show files that changed while the app was closed.
- A scan starts on: FSEvents changes to music files, folders, removals or renames, volume mount and unmount, folder changes, and the launch. Cache files, `.plist`s, `.lrc`s, `.DS_Store`, and hidden paths never start a scan, except a deleted `Cache.sqlite`, which starts a rebuild.
- `LibraryHarnessTests` runs a live `Library` with the watcher on a temporary folder; the harness never touches `UserDefaults`.
- `Loudness.plist` (EBU R128 loudness per song) lives at the root of each music folder, with paths relative to the folder (realpath), so a moved folder keeps its measurements.
- SQLite is only a cache, rebuilt from the music files. Each folder has its own `Cache.sqlite` at its root, paths relative to the folder (realpath). It is the only data that is not a binary plist.
- Tables: `tracks` (unique `path`, tags, `modified`, `size`, nullable `hash`), `tracks_album`, `covers` (JPEG), and the FTS5 `search` (`tokenize = 'trigram remove_diacritics 1'`), kept in sync by the insert, delete, and update triggers. Upserts use `ON CONFLICT(path) DO UPDATE`.
- Settings: `page_size = 65536` (before WAL), `mmap_size = 1 GiB`, WAL, `synchronous = FULL`, `fullfsync`, `checkpoint_fullfsync`, infinite `busy_timeout`. No version: to change the schema, delete the `Cache.sqlite` files.
- The scan walks by the real path. Same date and size: cached tags. New size: read again. Same size, new date: hash (SHA-256); the same hash keeps the tags. New files get no hash. Gone or unreadable files leave the cache.
- Scans run one at a time. Each scan writes its adds, changes, removes, and covers in one transaction (`BEGIN IMMEDIATE` to `COMMIT`, or `ROLLBACK`). A failed write keeps the last good state.
- The scan is progressive: first the cache, then the walk, then batches of 256 files. `Library.load` calls `progress` after each step and stops without a write when a newer scan replaces it. Adding a folder scans at once.
- Search: fuzzy matches; FTS matches (words of 3+ characters) come first, in `bm25` order. The results (Songs with a query) show the matched albums above the songs (`AlbumStrip`). A click on an album opens it; its Play button plays it from the first song, shuffle off, and opens it on that song. Few albums fill the width; many scroll (`AlbumStrip.width`).

## Atomic writes

- Every write of app data is atomic and durable. Period. This applies to every current file and every future file, without exception: binary plists through `Persist` (`write`, `move`, `remove`), and the cache through SQLite transactions. Never write in place, never `Data.write` directly, never a partial state.
- Every data file is a binary plist. No JSON, no plain text. Exception: `Cache.sqlite`.
- Song paths in the data files in a music folder (`Likes.plist`, `Playlists/`, `Loudness.plist`) are relative to that folder, so the library can move. In `~/Library/Application Support/Overdrive` they are home-relative (`~/…`) under the home directory, absolute outside it, computed at runtime.

## Logging

- Every log is a structured log through `swift-log` (`Logging`, pinned to an exact version). Use the loggers in `Log` (`Log.player`, `Log.library`, ...). The message is a short, fixed event name; every value goes in `metadata`. Never put values in the message. Never use `print`, `NSLog`, `os_log`, or `os.Logger` directly.
- Log everything that helps to debug: user actions, player state changes, navigation, keys (key code and flags only, never the typed characters), scans, cache and file writes, network requests and responses, errors with their cause. Never log a password, a session key, or an API secret.
- The handler (`Handler`) writes each record as one JSON line (`time` in UTC, `level`, `label`, `message`, `source`, `metadata`) to `~/Library/Logs/Overdrive/<UTC hour>.log` (`Sink`), and the same record to the unified log (subsystem `org.delduca.Overdrive`).
- A new file starts every hour. Files older than one day (24 files) are deleted. Log writes are asynchronous, the only file writes that are: `Sink.write` returns at once, and a serial background queue does one `write(2)` with `O_APPEND`, then `fsync`, so the order stays and the caller never waits. `Log.flush` waits for the queue (quit, crash). Each record is whole or absent: when a file opens, a torn last record (no final newline, after a power loss) is cut off (`Sink.repair`). A crash signal or an uncaught exception writes a last record.
- Only the app bundle (`org.delduca.Overdrive`) writes the file. Tests never write it (`Log.sink` is nil); they read the records through `Log.tap`.
- `LogTests` runs the components and checks their records, and checks that every public action of `Player`, `YouTube`, and the navigation logs.
- The log files are the only app files that are not binary plists or `Cache.sqlite`.

## Data files

In `~/Library/Application Support/Overdrive`:

| File | Content |
| --- | --- |
| `Session.plist` | Queue, order, added songs, song, position, shuffle, repeat, scrobbles, open screen, lyrics shown. |
| `Scrobbles.plist` | Pending and rejected scrobbles. |
| `lastfm.plist` | Last.fm session key and user name. |
| `Videos.plist` | YouTube video ID per song. |

`Likes.plist`, `Playlists/`, and `Lyrics/` (lyrics from LRCLIB and lyrics.ovh, non-empty only) live at the root of the first library folder, so they travel with the music.

## Behavior

- Tables: on Songs, a double-click or Enter plays the row and opens its album (`go(.playing(track))`). The search results are the Songs page. On a playlist and Liked Songs, the double-click and Enter only play the row; they never open an album. In an open album, playing a song stays on that album. `Navigation.played` holds this rule.
- From a search, an opened album selects every matched song and scrolls to the first; if none matched, it selects the current song.
- The app never moves the focus by itself, except to the search field at launch. Option-Space (Edit > Find Song) is a global shortcut (two keys only; it must not collide with the system, such as Control-Command-F for full screen, Command-Space, Control-Space; `HotKey`, Carbon `RegisterEventHotKey`, no Accessibility permission): from any app it activates Overdrive, shows the main window (opens it when closed), and focuses the search with its text selected. It is the only global shortcut. Keys post `Key` notifications; only the top screen (`\.active`, through `Keys`) reacts. There is no other shortcut to focus the search field. Letters and digits typed outside an editable text go to the search field (`Focus.typing`), and the field takes the focus through its `NSSearchField` (`Focus.field`); while the query has text, a space, punctuation, and Delete go there too (`Focus.types`). The selectable synced lyrics are not an editable text, the lyrics editor is. Command-A selects all songs or all albums, except in the sidebar and in an editable text (the search field selects its text). Tab moves between the search field and the sidebar. The arrows move the sidebar when it has the focus; otherwise they move the list. Control-Return opens the context menu without moving the pointer. Escape closes the video, then goes back from any focus (the search text stays), then leaves the lyrics editor, then clears the search field. Space, Delete, and the arrows act only when the search field has no text.
- Menus: `TrackMenu`, `CopyMenu`, `FileMenu`, and `GoMenu` are the only definitions of the song actions. The visible list publishes its selection (`Selected`, only when `active`). Do not give a plain key to a menu bar item.
- History: `Navigation` (in `Navigation.swift`) owns the screen and the back and forward stacks. `open` and `show` push the old screen and clear forward. `restore` puts back the saved path at launch, except on Liked Songs, playlists, and the Queue, where the page always opens on its list. `refresh` cuts paths at albums that are gone. Each page draws its root and its pushed screens itself, in one `ZStack`; only the top screen of the current page shows, gets hits, and is `\.active`. Never use `NavigationStack`, `NavigationLink`, or `navigationDestination`: in a `NavigationSplitView` detail SwiftUI links only one stack, so a push on one page went to another page. Hidden pages and screens stay alive. Each pushed screen carries `.id(route)`. The Songs table carries `.id(library.query)`: a SwiftUI `Table` that diffs from a few rows to the whole library hangs the main thread. SwiftUI has no API to read or set the scroll of a `Table` or a `List`. The history is not saved to disk.
- Search: a change to another page (sidebar, back, forward, a new or deleted playlist) clears the query; the page that the search opens, or that a click on an artist name opens, keeps it (`Navigation.searching`). Opening an album or artist from the results keeps it. Otherwise only Escape, Command-K, and the clear button clear it. Every change to a query with text opens the results (the Songs page) from any screen (`Navigation.searched`); going back shows the old screen. The exception is a click on an artist name, which opens Albums filtered by that artist (`Navigation.filter`).
- Volume: each song is measured once (EBU R128, -14 LUFS, maximum +12 dB). Shuffle off: album gain. Shuffle on: track gain.
- Last.fm: each batch is marked on the disk before it is sent. A scrobble leaves only when Last.fm accepts it. Code 5 keeps it; 6, 7, and 13 isolate it; 1 to 4 reject it.
- YouTube: the app searches with the YouTube page itself, so it needs no API key.
- Lyrics toggle: the toolbar button (`quote.bubble`) and Option-Command-Y show and hide the lyrics (`Player.lyrics`, saved in `Session.plist`, shown by default). Hidden lyrics do nothing: no disk reads, no requests, no cache folder, no floating window (`Lyrics.enabled`). Hiding saves a pending edit first. Show Lyrics in a Floating Window shows them again.
- Lyrics: no status label, no confirmation dialog. A save button shows when `Lyrics.remote` is true and the text is not empty. Editing auto-saves one second after the last change; deleting all the text removes the `.lrc`. `Lyrics.settle` flushes the pending edit before every navigation, and `Lyrics.flush` on quit. A lyric is valid only when not nil and not empty. The `.lrc` next to the song is read first; when it exists, the app never consults the internet. An edit cancels the in-flight lookup; what the user types always wins. The lyrics show the one selected song of the top screen (`Selected`), else the current song. They load at once, also when no lyrics view shows. The docked view shows while there is a current song (paused too) or one selected song, on an album, Songs, the search results, Liked Songs, and playlists; it hides on the Albums grid, the Artists list, and an artist's albums (`Navigation.lyrics`). It shares one `HStack` with the split view, so it never covers content. Only the user opens and closes the floating window.
- Queue: the queue is the buffer of what plays and what follows, a playlist that is never saved as one. The Queue page (sidebar) shows the song that plays and the songs after it; the played songs stay in `Player.queue` for Previous but do not show. Add to Queue puts the songs after the current song and the songs added before, ahead of the rest of the album; Play Next puts them right after the current song (`Player.inserting`, marks in `Player.added`). A drag reorders the songs after the current one (`Player.move`); Delete and Remove from Queue remove the selected songs (`Player.remove`), never the song that plays; a double-click or Enter plays the row (`Player.jump`). With shuffle off, the edit also changes the play order. The session keeps the queue for the next launch. Clear Queue (toolbar of the Queue page, Controls menu), or a remove of the current song with every next song, asks for a confirmation (`clearQueue`), then stops the song and resets the player as at launch with no song: no items, no current song, not paused (`Player.clear`).
- Floating lyrics: `Lyrics.floating` moves the lyrics to a borderless, nonactivating `NSPanel` at level `.floating` (`LyricsPanel`), created once on the first undock, with the same `Lyrics` and `Player`. The close button only docks the lyrics back. The window button and a double-click on the song dock the lyrics back, activate the app, and show the main window (`openWindow(id: "main")`). While `floating` is true, the docked view leaves.

## Deploy

1. Commit the change and push it to `main`.
2. Push a new tag, the last tag plus one.
3. Wait for the `Release` action (build only): `gh run watch <run-id> --exit-status`. If it fails, stop and report the failure.
4. Update this host:
   1. Stop the app: `pkill -x Overdrive`.
   2. Upgrade the app: `brew update && brew upgrade --cask overdrive`.
   3. Start it: `open -a Overdrive`.
   4. Check the version: `defaults read /Applications/Overdrive.app/Contents/Info.plist CFBundleShortVersionString`.
