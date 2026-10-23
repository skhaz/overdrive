# Agents

## Documentation

- Keep every technical detail in this file. `README.md` is for users: plain words, what the app does, no internals.
- Write simple, direct English. Short sentences. Keep only what matters. No filler.

## Commits

Commit each change when it is complete. Do not ask before you commit.

## Data

- Never write migration code. Never. A file that does not match the current format is ignored, or deleted and built again. No schema numbers, no legacy readers.

## YouTube

- One YouTube web view, made at launch, kept until quit. Never a second one, never recreated.
- The player page stays loaded and ready. Closing the video window stops the video but keeps the page.
- A video starts: pause the song. A song starts: close the video window.

## Build and test

- Build: `./build.sh`. Last.fm: `LASTFM_KEY=... LASTFM_SECRET=... ./build.sh` (key from https://www.last.fm/api/account/create).
- Test: `swift test`. The tests use a fake Last.fm server. The `Release` action runs the tests before the build.
- Test the release from Homebrew, like a real install. A local build is only for debugging or profiling.
- Sanitizers: `swift test --sanitize=address`, `swift test --sanitize=undefined`, `swift test --sanitize=thread`.
- Fuzzing runs in Docker (OrbStack):
  `docker run --rm -v "$PWD":/src:ro -v /tmp/fuzz:/out -e OUT=/out --shm-size=256m swift:latest sh /src/Fuzz/fuzz.sh 300`.
  Targets in `Fuzz/Targets` (MP4, ID3, MPEG, embedded covers, LRC), seeds in `Fuzz/Seeds`, crashes in `/tmp/fuzz/crashes`. Do not edit the sources while it builds.
- The fuzzed parsers (`MP4.swift`, `ID3.swift`, `MPEG.swift`, `Embedded.swift`, `LRC.swift`) must use only Foundation, so they compile on Linux.
- Every fuzzer crash becomes a regression test with a file in `Tests/OverdriveTests/Fixtures`. `FuzzTests` mutates the seeds on each `swift test` run.
- Uninstall: `brew uninstall --zap --cask overdrive`. The `.lrc` files in the music folders stay.

## Music library

- The library is read-only. The app never writes, moves, renames, or deletes an audio file. `LibraryCacheTests.neverWritesTheMusicFiles` checks it.
- In a music folder the app writes only: `Cache.sqlite` (and its `-wal` and `-shm`) at the folder root, `.lrc` files next to the songs, and, at the root of the first folder, `Likes.plist` and the `Playlists` folder. The watcher ignores them.

## Library cache

**Hard requirement:** the filesystem, the cache (`Cache.sqlite`), and the full-text index (FTS5, `bm25`) stay in strict sync, always and without exception. Any change that can break this is a bug, even for a moment.

- The cache and the index change only in one transaction (the triggers), so they never differ. `LibraryCacheTests` runs the FTS5 `integrity-check` after every scan step.
- The scan commits each step, then shows it. The UI never shows a state the cache does not have: after the walk (removals), after each batch (adds and changes), and at the end (covers). Each commit is one atomic transaction that matches the filesystem at that moment. A scan that a newer scan replaces keeps what it committed; the newer scan does the rest. Only the first snapshot can show files that changed while the app was closed.
- A scan starts on: FSEvents changes to music files, folders, and removals or renames (`Library.relevant`), the mount and unmount of a volume, a change of the folders, and the launch. The cache files, every `.plist`, the `.lrc` lyrics, `.DS_Store`, and hidden paths never start a scan, except a deleted `Cache.sqlite`, which starts a rebuild. The watcher reads the deletion from the event flags.
- `LibraryHarnessTests` runs a live `Library` with the FSEvents watcher on a temporary folder. After each change it waits until the albums in memory, the cache, and the index agree with the filesystem, then checks that a quiet period writes nothing. The harness takes its folders from the initializer, so it never touches `UserDefaults`.
- SQLite is only a cache, rebuilt from the music files. Each library folder has its own `Cache.sqlite` at its root, with paths relative to the folder (its real path), so the cache moves with the music. It is the only data that is not a binary plist.
- Tables: `tracks` (integer `id`, unique `path`, `modified`, `size`, nullable `hash`, and the tags), the index `tracks_album`, `covers` (`album_id`, JPEG `data`), and the FTS5 table `search` (`title`, `artist`, `album`, external content of `tracks`, `tokenize = 'trigram remove_diacritics 1'`), kept in sync by the `tracks_insert`, `tracks_delete`, and `tracks_update` triggers. Upserts use `ON CONFLICT(path) DO UPDATE`.
- Settings: `page_size = 65536` (set before WAL creates the file), `mmap_size = 1 GiB`, WAL, `synchronous = FULL`, `fullfsync`, `checkpoint_fullfsync`, an infinite `busy_timeout`. The cache has no version: to change the schema, delete the `Cache.sqlite` files. A file that does not open is deleted and created again.
- The page size and the mmap are measured on a synthetic library of 200,000 songs (64 KB pages with 1 GiB of mmap are several times faster for writes, cover reads, and orphan removal). Do not change them without measuring again.
- The scan walks by the real path. A file with the same date and size keeps its cached tags. A new size reads the tags again. The same size with a new date is hashed (SHA-256 on a read-only mapping): the same hash keeps the tags, a new hash reads them. A new file gets no hash. A file that is gone, or that cannot be read, leaves the cache.
- Scans run one at a time, in order. Each scan writes its adds, changes, removes, and covers in one transaction (`BEGIN IMMEDIATE` to `COMMIT`, or `ROLLBACK`). A failed write keeps the last good state; the next scan repairs every difference.
- The scan is progressive and runs after the window opens: first the cache, then the walked state, then batches of 256 files. `Library.load` calls `progress` with a full snapshot after each step, and stops without a write when a newer scan replaces it. Adding a folder scans at once.
- Search: the fuzzy search finds the matches; the FTS matches (only when every word has 3 or more characters) come first, in `bm25` order. FTS matches are always fuzzy matches too, so the FTS never removes a result.

## Atomic writes

- Every write of app data is atomic and durable. Period. This applies to every current file and every future file, without exception: the binary plists through `Persist` (`Persist.write`, `Persist.move`, `Persist.remove`, which call `F_FULLFSYNC` and rename), and the cache through SQLite transactions. Never write in place, never use `Data.write` directly, never write a partial state.
- Every file the app produces for its data is a binary plist. No JSON, no plain text. The only exception is `Cache.sqlite`.
- Every song path stored in the data files is home-relative (`~/…`) under the home directory, absolute outside it, computed from the current home at runtime.

## Data files

The app keeps its data in `~/Library/Application Support/Overdrive`:

| File | Content |
| --- | --- |
| `Session.plist` | The queue, the order, the song, the position, shuffle, repeat, the scrobble state, and the open screen. |
| `Loudness.plist` | The EBU R128 loudness of each song. |
| `Scrobbles.plist` | The pending and rejected scrobbles. |
| `lastfm.plist` | The Last.fm session key and user name. |
| `Videos.plist` | The YouTube video ID of each song. |
| `Rules/` | The compiled ad block rules of the web view. |
| `Lyrics/` | The lyrics from LRCLIB and lyrics.ovh, non-empty files only. Missing lyrics are retried on every open. |

`Likes.plist` and `Playlists/` live at the root of the first library folder, computed live from `Library.folders`, so they travel with the music.

## Behavior

- Tables: on Songs, a double-click or Enter plays the row and opens its album (`go(.playing(track))`, which reveals the album of the track that started and replaces the path of the page). The search results are the Songs page, so they open the album too. On a playlist and Liked Songs, the double-click and Enter only play the row; they never open an album.
- Search: when an album opens from a search, it selects every matched song and scrolls to the first; if no song matched, it selects the current song.
- Keyboard: the app never moves the focus by itself, except to the search field at launch. A local key monitor in `ContentView` posts `Key` notifications; only the top screen (`\.active`, through the `Keys` modifier) reacts. Command-F focuses the search field. Command-A selects every song of the visible list or every album of the grid, except in the sidebar, and even while the search field has the focus and text. Tab moves between the search field and the sidebar. Control-Return opens the context menu without moving the pointer. Escape closes the video, then goes back when an album or an artist is open (the search text stays, so the results are there when you return), then leaves the lyrics editor, then clears the search field. Space, Delete, and the arrows go to the player and the list only when the search field has no text.
- Menus: `TrackMenu`, `CopyMenu`, `FileMenu`, and `GoMenu` are the only definitions of the song actions; the context menus and the Song menu use them. The visible list publishes its selection with `focusedSceneValue` (`Selected`, only when `active`), and `SongMenu` reads it. Do not give a plain key (without Command) to a menu bar item.
- History: `Navigation` (in `Navigation.swift`) is the only owner of the screen (page and path) and of two stacks in memory: back and forward. `open` (sidebar, playlist) and `show` (album, artist) push the old screen and clear forward. Escape goes back with `goBack` (Command-] returns); when the history is empty it pops the open screen. Opening the current page goes to its root. `restore` puts back the saved path at launch, except on Liked Songs and playlists, where the page always opens on its list. `remove` drops a deleted playlist. `refresh` re-resolves the albums after a rescan and cuts paths at albums that are gone. Every visited page has its own `NavigationStack`; the hidden pages stay alive in a `ZStack` with their path. The pushed screen carries `.id(route)`, so a new album never reuses the view of the previous one. The stack root never changes its identity (no `.id()` on the root content): a new root identity destroys the pushed screens while the path still reports them. Each history entry keeps a `Position` (offset and selection), written by `Remember`; SwiftUI has no API to read or set the scroll of a `Table` or a `List`. The history is not saved to disk. `NavigationTests` covers 100% of `Navigation.swift`.
- Search: the app never clears the query by itself (only Escape, Command-K, and the clear button). The query also filters the playlists and Liked Songs. Typing a search never closes an open album or artist: the query filters the lists behind the screen, and going back shows the results.
- Volume: each song is measured once (EBU R128, reference -14 LUFS, gain limited by the peak, maximum +12 dB). The worker stops in Low Power Mode and when the Mac is hot. Shuffle off: album gain. Shuffle on: track gain.
- Last.fm: each batch is marked on the disk before it is sent. A scrobble is removed only when Last.fm accepts it. Code 5 keeps it; codes 6, 7, and 13 isolate it; codes 1 to 4 reject it. When the result of a send is not known, the app checks `user.getRecentTracks` before it sends again.
- YouTube: the app searches with the YouTube page itself (`/youtubei/v1/search`), so it needs no API key. It plays the first result that has the song name and the artist, ignores "Topic" channels, and checks with `oembed` that the video can play outside YouTube. The ad block uses a content rule list and removes `adPlacements`, `adSlots`, and `playerAds` from the player response.
- Lyrics: the docked view has no status label and no confirmation dialog. A save button shows when `Lyrics.remote` is true and the text is not empty; `persist` saves next to the song. Editing auto-saves one second after the last change, and deleting all the text removes the `.lrc`. `Lyrics.settle` flushes the pending edit before every navigation, and `Lyrics.flush` does it on quit, so a quit never loses an edit. A lyric is valid only when not nil and not empty: empty files never count and are removed. The `.lrc` next to the song is read first, and when it exists the app never consults the internet. An edit cancels the in-flight lookup; what the user types always wins. Both views show a `ProgressView` while loading. The docked view is always visible when a track is loaded (`shown` only checks `lyrics.visible` and `lyrics.track`); the split view and the docked view share one `HStack`, so the lyrics take real space and never cover the content.
- Floating lyrics: `Lyrics.floating` moves the lyrics between the docked view and a borderless, nonactivating `NSPanel` at level `.floating` (`LyricsPanel`), created once on the first undock with the same `Lyrics` and `Player`. The close button only docks the lyrics back. The footer has the same playback controls as the main window. While `floating` is true, the docked view leaves.

## Deploy

Do these steps for each deploy:

1. Commit the change and push it to `main`.
2. Push a new tag, the last tag plus one (for example `v0.1.67` to `v0.1.68`).
3. Wait for the `Release` action: `gh run watch <run-id> --exit-status`. If it fails, stop and report the failure.
4. Update this host:
   1. Stop the app: `pkill -x Overdrive`.
   2. Upgrade the app: `brew update && brew upgrade --cask overdrive`.
   3. Start it: `open -a Overdrive`.
   4. Check the version: `defaults read /Applications/Overdrive.app/Contents/Info.plist CFBundleShortVersionString`.
