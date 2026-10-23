# Agents

## Documentation

- Put every technical detail in this file: build, tests, fuzzing, release, data files, formats, protocols, and internal behavior.
- `README.md` is for users with no technical knowledge. Use plain words. Write what the app does and how to use it. Do not write about code, files, tools, or how the app works inside.

## Commits

Commit each change when it is complete. Do not ask before you commit.

## Data

- **Never write migration code. Never.** A file that does not match the current format is ignored, or deleted and built again. Write everything as if it were new. Nothing is versioned: no schema numbers, no legacy readers, no moves between formats or between folders.

## YouTube

- The app has only one YouTube web view. The app makes it when it starts and keeps it until it quits. Do not make a second web view, and do not release or recreate it.
- The web view always keeps the YouTube player page loaded and ready, so a video starts at once. When the video window closes, stop the video, but keep the page loaded.
- When a video starts, pause the song that plays. When a song starts to play, close the video window.

## Build and test

- Build: `./build.sh`. To build with Last.fm, set the API key from https://www.last.fm/api/account/create: `LASTFM_KEY=... LASTFM_SECRET=... ./build.sh`.
- Test: `swift test`. The tests use a fake Last.fm server, so they do not send scrobbles to a real account. The `Release` action runs the tests before the build.
- Do all tests on the release from Homebrew, the same as a real installation. Use a local build only to debug or to profile.
- Sanitizers: `swift test --sanitize=address`, `swift test --sanitize=undefined`, and `swift test --sanitize=thread`.
- Fuzzing: run the libFuzzer targets in Docker (OrbStack), because the macOS toolchain has no libFuzzer runtime:
  `docker run --rm -v "$PWD":/src:ro -v /tmp/fuzz:/out -e OUT=/out --shm-size=256m swift:latest sh /src/Fuzz/fuzz.sh 300`.
  The argument is the number of seconds for each target. The targets are in `Fuzz/Targets` (MP4, ID3, MPEG, embedded covers, and LRC), and the seeds are in `Fuzz/Seeds`. Crashes go to `/tmp/fuzz/crashes`. Do not edit the sources while the fuzzer builds, because the container reads them from this folder.
- The parsers that the fuzzer builds (`MP4.swift`, `ID3.swift`, `MPEG.swift`, `Embedded.swift`, and `LRC.swift`) must use only Foundation, so they compile on Linux.
- Add each fuzzer crash as a regression test with a file in `Tests/OverdriveTests/Fixtures`.
- `FuzzTests` mutates the seeds on macOS on each `swift test` run, also through `AudioToolbox` and `ImageIO`.
- Uninstall: `brew uninstall --zap --cask overdrive`. The `--zap` option also removes the settings, the Last.fm session, and the lyrics cache. It does not remove the `.lrc` files in the music folders.

## Music library

- The music library is read-only. The app never writes, moves, renames, or deletes an audio file. It opens them only to read (AudioToolbox with `readPermission`, the MP4 and ID3 parsers, and `Data` with `.alwaysMapped` for the hash). `LibraryCacheTests.neverWritesTheMusicFiles` checks it.
- The only files that the app writes in a music folder are its cache (`Cache.sqlite` and its `-wal` and `-shm` files, at the root of each library folder), the `.lrc` lyrics next to the songs, and, at the root of the first library folder, `Likes.plist` and the `Playlists` folder, so the likes and the playlists travel with the music. The FSEvents watcher ignores them, so they do not start a scan.

## Library cache

**Hard requirement:** the filesystem, the cache (`Cache.sqlite`), and the full-text index (FTS5, `bm25`) must be in strict sync, in every situation and without exception. A change that can break this sync is a bug, even for a moment that the app can avoid. Every change to the scan, the cache, the watcher, or the search must keep these rules, with tests:

- The cache and the full-text index change only in the same transaction (the triggers), so they can never differ. `LibraryCacheTests` runs the FTS5 `integrity-check` after every scan step.
- The scan commits each step, then shows it. The UI never shows a state that the cache does not have: after the walk (removals), after each batch (adds and changes), and at the end (covers). Each commit is one atomic transaction that matches the filesystem at that moment. A scan that a newer scan replaces keeps what it committed, and the newer scan does the rest. Only the first snapshot (the cache, before the walk) can show files that changed while the app was closed.
- Every change in a library folder starts a scan: the FSEvents watcher (`Library.relevant`), the mount and unmount of a volume, a change of the folders, and the launch. Only music files (by audio extension), folders, and removals or renames start a scan. The cache files, every `.plist` (and `.plist.tmp`), the `.lrc` and `.lrc.tmp` lyrics, `.DS_Store`, and hidden paths never start a scan, except when `Cache.sqlite` is deleted, which starts a scan that builds the cache again. The watcher decides the deletion from the event flags (`ItemRemoved` or `ItemRenamed` on the main cache file), so it does not depend on the state of the filesystem when the event arrives.
- `LibraryHarnessTests` runs a live `Library` with the FSEvents watcher on a temporary folder. After each change it waits until the albums in memory, the cache, and the full-text index agree with the filesystem, then it waits to check that a quiet period writes nothing. The harness library takes its folders from the initializer (`Library(loudness:folders:)`), so it never reads or writes the saved folders in `UserDefaults`, and the `deinit` removes the volume observers and stops and releases the stream.
- The search opens new connections after every step, so it always reads the current cache file.
- A failed write leaves the last good state, and the next scan repairs every difference, because each scan compares every file with every row.

- SQLite is used only as a cache of the libraries. It holds nothing that the app cannot build again from the music files. Each library folder has its own cache at its root (`Cache.sqlite`), wherever the folder is, with the paths relative to the folder (from its real path, `realpath`), so the cache moves with the music. It is the only data that is not a binary plist.
- Tables: `tracks` (integer `id`, unique `path`, `modified`, `size`, nullable `hash`, and the tags), the index `tracks_album` on `album_id`, `covers` (`album_id`, JPEG `data`), and the FTS5 table `search` (`title`, `artist`, `album`, external content of `tracks`, `tokenize = 'trigram remove_diacritics 1'`), kept in sync by the `tracks_insert`, `tracks_delete`, and `tracks_update` triggers. Upserts use `ON CONFLICT(path) DO UPDATE`, because external content FTS does not support `REPLACE`.
- Settings: `page_size = 65536` (set before WAL creates the file), `mmap_size = 1073741824` (the maximum of the system SQLite, `MAX_MMAP_SIZE`), WAL, `synchronous = FULL`, `fullfsync = ON`, `checkpoint_fullfsync = ON`, and an infinite `busy_timeout`. The cache has no version. To change the schema, delete the `Cache.sqlite` files: the app creates them again. A file that does not open is deleted and created again.
- The settings are tuned for a large library, not for one collection. They were measured on a synthetic library of 200,000 songs, 20,000 albums, and 20,000 covers of 77 KB (1.6 GB, release build, 3 runs). Against 16 KB pages with 256 MB of mmap, 64 KB pages with 1 GiB of mmap write the whole cache 1.5 times faster (2.4 s), read all covers 1.7 times faster (0.09 s), remove orphan covers 5.7 times faster (7 ms), and make the file 3.6 % smaller. Reading all tracks (40 ms) and search (5 ms for 20 searches) do not change. Without the `album_id` index, the removal of orphan covers is 5 times slower. `covers` with `WITHOUT ROWID` is slower, because its rows are large. `detail = column` breaks the search (it allows only terms of up to 3 characters).
- The scan walks each folder by its real path (`Cache.root`, from `realpath`), so the paths are the same through any symlink.
- Each scan walks all the library folders (the path, the type, the modification date, and the size, without opening the files). A file with the same date and size uses the cached tags. A file with a new size is read again. A file with the same size and a new date is hashed (SHA-256 from CryptoKit, which uses the SHA instructions of Apple silicon, on a read-only mapping): the same hash keeps the cached tags, another hash reads the tags again. A new file gets no hash, so the first scan does not read every file completely. A file that is gone, or that cannot be read, leaves the cache.
- Every scan writes its adds, changes, removes, new covers, and the removal of orphan covers in one transaction (`BEGIN IMMEDIATE` to `COMMIT`, or `ROLLBACK`). Scans run one at a time, in order, so an older scan never commits after a newer one. A failed write leaves the last good state, and the next scan repairs every difference, because it compares every file with every row.
- The scan is progressive and runs after the window opens. `Library.load` calls `progress` with a full snapshot (albums, index, covers) after each step: first the cache (at once, before the walk), then the walked state (files that are gone leave, changed files keep their old tags), then each batch of 256 read files. The UI shows each snapshot. Covers of new albums come with the last snapshot. When a newer scan replaces it (a file changes, or a folder is added), `progress` returns `false`, and `load` stops without a write, so the cache keeps the last full scan. Adding a folder starts a scan at once.
- Search: the fuzzy search finds the matches, and the FTS matches (only when every word has 3 or more characters) come first, in `bm25` order. FTS matches are always fuzzy matches too, so the FTS never removes a result.
- Boot time, from the launch to the window with the full library (4906 songs, 3 launches): 1.94 to 2.51 s without the cache (0.1.106), 0.66 to 0.82 s with it.

## Atomic writes

- Every write of app data is atomic and durable: the binary plists with `Persist`, and the cache with SQLite transactions with `fullfsync`. Never write a partial state.

## Data files

The app keeps its data in `~/Library/Application Support/Overdrive`:

| File | Content |
| --- | --- |
| `Session.plist` | The queue, the order, the song, the position, shuffle, repeat, the scrobble state, and the open screen. One atomic and durable write. |
| `Loudness.plist` | The EBU R128 loudness of each song. |
| `Scrobbles.plist` | The pending and rejected scrobbles. One atomic and durable write before each send. |
| `lastfm.plist` | The Last.fm session key and user name. |
| `Videos.plist` | The YouTube video ID of each song. |
| `Rules/` | The compiled ad block rules of the web view. |
| `Lyrics/` | The lyrics from LRCLIB and lyrics.ovh, only non-empty files. When a song has no lyrics, the app tries again every time it opens the song. |

`Likes.plist` and `Playlists/` live at the root of the first library folder, computed live from `Library.folders` (fallback `~/Music/Library` when there are no folders), so they travel with the music: `Likes.plist` is the paths of the liked songs, and `Playlists/` holds one binary plist for each playlist with its song paths, plus a backup copy when a playlist is deleted. There is no migration anywhere: a changed folder only changes where the files are read and written.

Every file that the app produces for its data is a binary plist. Do not add plain text, JSON, or other formats for app data. The only exception is the library cache (`Cache.sqlite` at the root of each library folder, see "Library cache").

All file writes, replacements, moves, and deletes must be atomic and durable. Use `Persist.write`, `Persist.move`, and `Persist.remove`. They call `F_FULLFSYNC`, rename, and sync the directory. Never write in place and never use `Data.write` directly.

Every song path that Overdrive stores in its data files is home-relative with `~/` when it is under the home directory, in the current files and in all future files. Paths outside the home directory are absolute. The Overdrive directories come from the current home directory at runtime.

## Behavior

- Search: when an album opens from a search, it selects every song that matched the query and scrolls to the first one. If no song matched, it selects the current song.
- Tables: a double-click on Songs, a playlist, or Liked Songs plays the row and opens its album. The action calls `go(.playing)`, which reveals the album of the track that the player starts, and replaces the path of the page, so no album stays under it in the navigation stack.
- Keyboard: the app never moves the focus by itself, except to the search field at launch. A local key monitor in `ContentView` reads the keys of the main window (identifier `main`) when the focus is not in a text field other than the search field, and posts `Key` notifications. Command-F moves the focus to the search field. Command-A selects every song of the visible table (the `Keys` modifier calls `selectAll`), except in the sidebar and in a text field. Only the view on top of the navigation stack (`\.active`) reacts to them, through the `Keys` modifier. Tab moves the focus between the search field and the side bar. Control-Return opens the context menu: the app sends a right mouse down event directly to the view under the selected item, so SwiftUI fills the menu for that row. It does not move the pointer. Escape closes the video, then goes back when an album or an artist is open (even while the search field has text, so a search result stays when you return, and Command-] goes forward into it again; when the history is empty it pops the open screen), then leaves the lyrics editor, then the search field clears its text. Space, Delete, Left Arrow, and Right Arrow go to the player and the list only when the search field does not have the focus with text in it. Each screen except the album screen shows the number of songs and the total time in its subtitle.
- Menus: `TrackMenu`, `CopyMenu`, `FileMenu`, and `GoMenu` are the only definitions of the song actions. The context menus and the Song menu of the menu bar use them, so they show the same items and the same shortcuts. The visible list publishes its selection with `focusedSceneValue(\.selection)` (the `Selected` modifier, only when the view is `active`), and `SongMenu` reads it with `@FocusedValue`. Do not give a plain key (without Command) to an item that can be in the menu bar, because the menu bar would take that key from text fields.
- History: `Navigation` (in `Navigation.swift`) is the only owner of the current screen (the page and the navigation path) and of two stacks in memory: back and forward. `open` (side bar, new playlist, search links) and `show` (album, artist) push the old screen and clear the forward stack, unless the screen does not change. Escape goes back with `goBack` (which keeps the forward stack, so Command-] returns to the screen it left), and falls back to popping the open screen when the history is empty. Opening the current page goes to its root. `restore` puts back the saved path at launch without history. `remove` drops a deleted playlist from the history, opens the fallback page if the playlist is open, and merges repeated neighbors. `refresh` replaces the albums in the history after a rescan, cuts paths at albums that are gone, and merges repeated neighbors. Every visited page (`pages`) has its own `NavigationStack`, and the hidden pages stay alive in a `ZStack` with the path that they had (`path(of:)`), so tables, lists, and the grid keep their scroll and selection without any restore. Only the hidden pages are not `active`. Every stack sets the same title and subtitle of the current screen. A screen inside a page (an album, or the albums of an artist) is built again, so each history entry also keeps a `Position` (the offset and the selection) that does not change the identity of the screen. The visible screen writes it to the `Tracker` object through the `Remember` modifier (`onScrollGeometryChange`), every move stores it in the entry that it leaves, and the screen that opens restores it with `ScrollPosition.scrollTo(y:)` in `onAppear`, before the first frame. Do not try to read or set the scroll of a `Table` or a `List`: SwiftUI on macOS has no API for it (`scrollPosition` is ignored and `onScrollGeometryChange` does not work with `Table`). The history is not saved to disk. `NavigationTests` covers 100% of `Navigation.swift` (check it with `swift test --enable-code-coverage` and `llvm-cov report`). Back and forward use Command-[ and Command-], the toolbar arrows, the trackpad swipe (`Navigator`, an `NSResponder` after the window in the responder chain, returns `true` from `wantsScrollEventsForSwipeTracking(on: .horizontal)`, so the scroll views pass horizontal gestures to it, and it calls `trackSwipeEvent`; macOS decides the threshold and the direction, and an arrow at the edge follows the gesture; `swipe(with:)` handles three-finger swipes), and mouse buttons 4 and 5 (`otherMouseDown(with:)`). A deleted playlist leaves the history. The history is not saved to disk.
- Search: the app never clears the query by itself. Only Escape, Command-K, and the clear button of the field clear it. The query also filters the playlists and Liked Songs.
- Volume: the app measures each song one time (EBU R128, reference -14 LUFS, gain limited by the peak, maximum +12 dB). The background worker stops in Low Power Mode and when the Mac is hot. With shuffle off, it uses the album gain. With shuffle on, it uses the track gain.
- Last.fm: the app marks each batch on the disk before it sends it. It removes a scrobble only when Last.fm accepts it. Code 5 (daily limit) keeps the scrobble. Codes 6, 7, and 13 isolate the bad scrobble. Codes 1 to 4 move it to the rejected list. When the result of a send is not known, the app looks at `user.getRecentTracks` before it sends again, and sends it again one day before the 14-day limit if it cannot look.
- YouTube: the app searches with the YouTube page itself (`/youtubei/v1/search` with the context of the page), so it needs no API key. It plays the first result that has the song name and the artist, ignores "Topic" channels, and checks with `oembed` that the video can play outside YouTube. The ad block uses a content rule list and removes `adPlacements`, `adSlots`, and `playerAds` from the player response.
- Lyrics: the docked view has no status label and no confirmation dialog. A save button (`square.and.arrow.down`) shows when `Lyrics.remote` is true (the lyric came from the internet or the cache) and the text is not empty; `persist` saves it next to the song. The auto-save on edit also writes the `.lrc` and clears `remote`, so the button leaves once the lyric is next to the music. `Lyrics.edit` (the editor binding) sets the text and schedules a save one second after the last change, so edits save next to the song by themselves, and deleting all the text removes the `.lrc`. The pending task captures the text and the track, and `save` writes only to that track, so two songs can never cross-write; the single `saver` slot means there is at most one pending save. `Lyrics.settle` flushes the pending edit at once (atomic, `Persist.write`) and then runs the action, so every navigation and every track change (starting to edit another lyric) writes the previous edit immediately, before the new debounce waits. On `NSApplication.willTerminateNotification`, `ContentView` calls `Lyrics.flush`, which cancels the pending task and saves at once, so a quit never loses an edit. Downloaded lyrics stay only in the cache until the user changes them. A lyric is valid only when it is not nil and not empty: an empty `.lrc` or cache file never counts, deleting all the text removes both the `.lrc` and the cache key, and a song without lyrics is tried again on every open. The `.lrc` next to the song is read first: when a saved lyric exists, the app never consults the internet. `edit` cancels the in-flight lookup task and clears `loading` at once, so what the user types always wins over the network (a result that was already cached is ignored, and the cache files are disposable); `apply` also guards on an empty text. There is no generation counter. Both the docked view and the floating panel show a small `ProgressView` in the header while `loading` is true. The docked view is always visible whenever a track is loaded (playing or paused), on every screen: `ContentView.shown` only checks that `lyrics.visible` is true and `lyrics.track` is not nil. The split view and the docked view share one `HStack`, so the lyrics take real space and never cover the content.
- Floating lyrics: `Lyrics.floating` moves the lyrics between the docked view in the main window and a floating panel. `LyricsPanel` is a borderless, nonactivating `NSPanel` at level `.floating`, movable by the background (`isMovableByWindowBackground`), with `becomesKeyOnlyIfNeeded` so the text editor gets keys without activating the app, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, a clear background, and a material drawn by `FloatingLyrics`. `ContentView` creates the panel once, on the first undock, with an `NSHostingView` of `FloatingLyrics` that shares the same `Lyrics` and `Player` objects, and orders it in and out on `floating` changes. The initial frame is at the top right, below the menu bar (`visibleFrame`). The panel never closes the lyrics: the close button only sets `floating` back to `false`, and the docked view returns. A track change keeps the panel open, because `Lyrics.show` only changes the track. The floating view shows the cover, the title, the artist, and the album, the synced lines seek like the docked view, and the same editor (`Lyrics.edit`, auto-save) edits the lyrics. Controls > Show Lyrics in a Floating Window (Command-U) posts `.floatLyrics`, which `ContentView` receives: it calls `Lyrics.show` for the current song and sets `floating`, so every song can float, with or without lyrics. The footer has the same playback controls as the main window (previous, play or pause, next, and a seek slider with the same scrub state) bound to the same `Player`. While `floating` is true, the docked view leaves.

## Deploy

Do these steps for each deploy:

1. Commit the change and push it to `main`.
2. Push a new tag. Increase the last tag by one, for example `v0.1.67` to `v0.1.68`.
3. Wait for the `Release` GitHub Action of the tag to finish:
   `gh run watch <run-id> --exit-status`. If it fails, stop and report the failure.
4. Update the local app on this host to the new version:
   1. Stop the app: `pkill -x Overdrive`.
   2. Remove the old version and install the new version: `brew update && brew upgrade --cask overdrive`.
   3. Start the new version: `open -a Overdrive`.
   4. Make sure that the version is correct:
      `defaults read /Applications/Overdrive.app/Contents/Info.plist CFBundleShortVersionString`.
