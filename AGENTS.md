# Agents

Technical rules live here. `README.md` is for users: plain words, no internals. Add only what the code cannot show.

## Commits

Commit each change when it is complete. Do not ask first. Run `swift test` only when a commit changes source code, and commit only when all tests pass. CI only builds.

## Build and test

- Build: `./build.sh`. With Last.fm: `LASTFM_KEY=... LASTFM_SECRET=... ./build.sh`.
- Test: `swift test`. Allocation tests: `swift test -c release --filter SpectrumCostTests`.
- Sanitizers: `swift test --sanitize=address`, `undefined`, `thread`.
- Fuzz: `docker run --rm -v "$PWD":/src:ro -v /tmp/fuzz:/out -e OUT=/out --shm-size=256m swift:latest sh /src/Fuzz/fuzz.sh 300`. Do not edit sources while it builds. Fuzzed parsers use only Foundation. Every crash becomes a regression test with a file in `Tests/OverdriveTests/Fixtures`.
- Every change gets tests. Every bug fix gets a regression test that fails without the fix.
- Tests never use the network. Use a fake `URLProtocol` or a seam (`transport`, `source`, `refresher`, `artwork`) against an `.invalid` endpoint.
- Tests never touch `~/Library`, the home directory, `UserDefaults`, the pasteboard, or a browser. A disk test writes only in its own folder under the system temporary directory.
- Test a release from Homebrew. A local build is only for debugging or profiling.

## Data

- Never write migration code. A file that does not match the current format is ignored or rebuilt. No schema numbers, no legacy readers.
- Every data file is a binary plist, except `Cache.sqlite` and the logs.
- Every write is atomic and durable: `Persist` for plists, SQLite transactions for the cache. Never call `Data.write` directly. Read only through `Persist.read`.
- Song paths in a music folder are relative to that folder. In Application Support they are home-relative.

| Location | Files |
| --- | --- |
| `/private/tmp/Overdrive` | `Session.plist` (gone after a restart) |
| `~/Library/Application Support/Overdrive` | `Scrobbles`, `lastfm`, `Videos`, `Drafts`, `Loves`, `openrouter` (`.plist`) |
| Root of each music folder | `Cache.sqlite`, `Loudness.plist` |
| Root of the first music folder | `Plays.plist`, `Likes.plist`, `Bans.plist`, `Playlists/` |
| Next to each song | `.lyrics` (kept by the user), `.cache.lyrics` (cache) |

- `Likes`, `Bans`, and `Playlists` never write while the first folder is missing.

## Music library

- The library is read-only. The app never writes, moves, renames, or deletes an audio file.
- The filesystem, the cache, and the FTS5 index stay in strict sync. The cache and the index change only in one transaction (the triggers).
- Each scan commits atomically, then shows the result. The UI never shows a state the cache does not have. A failed write keeps the last good state.
- A folder that cannot be walked keeps its cached songs.
- A scan starts only on: changes to playable files or images, removed or renamed folders, volume changes, lost FSEvents, folder changes, launch, the 10-minute check, and the hourly full scan. A write to the app's own files never starts a scan. The exception is a deleted `Cache.sqlite`, which starts a rebuild.
- File kind comes from the extension, never from `contentTypeKey`. A LaunchServices lookup per file makes the scan 28% slower.
- To change the schema, delete the `Cache.sqlite` files. A file whose columns are not `Cache.columns` is rebuilt.
- Album ids come from the current location of the song (`Track.albumID`), never from the stored column.
- `Library.settled` is true only after a complete scan. Nothing may treat a partial library as whole.

## Logging

- Log only through `swift-log` and the loggers in `Log`. Never use `print`, `NSLog`, `os_log`, or `os.Logger`.
- The message is a short, fixed event name. Every value goes in `metadata`.
- Every decision logs its outcome. Never log a password, session key, API secret, or typed characters. Remove the query and fragment from URLs that can hold tokens.
- Only the app bundle writes the log file. Tests read records through `Log.tap`.

## UI rules

- Never use `NavigationStack`, `NavigationLink`, or `navigationDestination`. `Navigation` owns the history, and each page draws its own screens in one `ZStack`. In a `NavigationSplitView` detail, SwiftUI links only one stack.
- A SwiftUI `Table` that diffs thousands of rows hangs the main thread. Give it a new identity (`.id`) when the sort or the query changes.
- Views that redraw often never do O(library) work. Sort only when the sort or the list changes (`Sorted`).
- Hidden pages stay alive and must not react. Only the top screen (`\.active`) takes keys, menus, drags, and drops.
- A view cannot read an environment object from the modifiers of the same body that injects it. It traps on the first render. Pass the object as a parameter.
- A table menu acts on the whole selection. SwiftUI hands `contextMenu(forSelectionType:)` only the rows it has drawn, so use `targets`.
- The app moves the focus only to the search field at launch. Option-Space is the only global shortcut. Do not give a plain key to a menu bar item.
- `TrackMenu`, `CopyMenu`, `FileMenu`, and `GoMenu` are the only definitions of the song actions.
- An unknown SF Symbol draws nothing, with no error. Check that the symbol exists on macOS.
- The spectrum audio tap and each frame never allocate and never wait on a lock.

## Player

- YouTube: one web view, made at launch and kept until quit. A video starts: pause the song. A song starts: close the video window.
- Up Next shows the queue from `Player.head`. A song leaves the list only when it played or was passed, never because the user clicked past it.
- Nothing writes `Session.plist` before the saved queue is back or the user plays something new.
- Only `Discovery.start` plays a discovery, and every pool goes through `Discovery.pick`. Bans apply where a pool is built, and only to discovery. A banned song still plays when the user picks it.

## Last.fm

- Only a 2xx answer without an `error` key is a success.
- A scrobble leaves the queue only when Last.fm accepts it. Code 5 keeps it, codes 6, 7, and 13 isolate it, and codes 1 to 4 reject it.
- Last.fm is the source of truth for loved tracks. Only `Loves.settle` touches `Likes`, with `notify: false` to prevent a loop.
- A read with no complete answer changes nothing. A partial page must never look like a mass unlove.
- Unlove a song the library cannot hold only after a complete scan with every folder readable.
- Space requests. Last.fm answers 29 when one IP spends its rate.

## Lyrics

- Lyrics live in `.lyrics` and `.cache.lyrics` files, which hold LRC text. The app never reads or writes a file with the `.lrc` extension.
- A `.lyrics` file next to the song wins, and then the app never consults the internet. What the user types always wins over a lookup.
- Edits go to the disk at once through `Keeper`, in the `.lyrics` file and in the cache file. A write that fails goes to `Drafts.plist`.
- A `.cache.lyrics` file is valid for one month. After that the old lyric shows at once and the app asks the internet in the background. A non-empty, different answer replaces the file and the lyric on screen, unless the user edited it or another song shows. An empty answer or a failure keeps the old file.
- Hidden lyrics do nothing: no disk reads, no requests, no floating window.

## Deploy

1. Commit and push to `main`.
2. Push a new tag, the last tag plus one.
3. Wait for the `Release` action: `gh run watch <run-id> --exit-status`. If it fails, stop and report it.
4. Update this host: `pkill -x Overdrive`, then `brew update && brew upgrade --cask overdrive`, then `open -a Overdrive`.
5. Check the version: `defaults read /Applications/Overdrive.app/Contents/Info.plist CFBundleShortVersionString`.

Uninstall: `brew uninstall --zap --cask overdrive`. The `.lyrics` and `.cache.lyrics` files stay in the music folders.
