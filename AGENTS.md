# Agents

## Documentation

- Put every technical detail in this file: build, tests, fuzzing, release, data files, formats, protocols, and internal behavior.
- `README.md` is for users with no technical knowledge. Use plain words. Write what the app does and how to use it. Do not write about code, files, tools, or how the app works inside.

## Commits

Commit each change when it is complete. Do not ask before you commit.

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

## Data files

The app keeps its data in `~/Library/Application Support/Overdrive`:

| File | Content |
| --- | --- |
| `Session.plist` | The queue, the order, the song, the position, shuffle, repeat, the scrobble state, and the open screen. One atomic and durable write. |
| `Loudness.plist` | The EBU R128 loudness of each song. |
| `Scrobbles.plist` | The pending and rejected scrobbles. One atomic and durable write before each send. |
| `Likes.plist` | The paths of the liked songs. Loaded at boot and written on each like or unlike. |
| `Playlists/` | One binary plist for each playlist with its song paths. |
| `lastfm.plist` | The Last.fm session key and user name. |
| `Videos.plist` | The YouTube video ID of each song. |
| `Rules/` | The compiled ad block rules of the web view. |
| `Lyrics/` | The lyrics from LRCLIB and lyrics.ovh. An empty file means "no lyrics". |

Every file that the app produces for its data is a binary plist. Do not add plain text, JSON, or other formats for app data.

All file writes, replacements, moves, and deletes must be atomic and durable. Use `Persist.write`, `Persist.move`, and `Persist.remove`. They call `F_FULLFSYNC`, rename, and sync the directory. Never write in place and never use `Data.write` directly.

Every song path that Overdrive stores in its data files is home-relative with `~/` when it is under the home directory, in the current files and in all future files. Paths outside the home directory are absolute. The Overdrive directories come from the current home directory at runtime.

## Behavior

- Search: when an album opens from a search, it selects every song that matched the query and scrolls to the first one. If no song matched, it selects the current song.
- Keyboard: the app never moves the focus by itself, except to the search field at launch. A local key monitor in `ContentView` reads the keys of the main window (identifier `main`) when the focus is not in a text field other than the search field, and posts `Key` notifications. Command-F moves the focus to the search field. Only the view on top of the navigation stack (`\.active`) reacts to them, through the `Keys` modifier. Tab moves the focus between the search field and the side bar. Control-Return opens the context menu: the app sends a right mouse down event directly to the view under the selected item, so SwiftUI fills the menu for that row. It does not move the pointer. Escape closes the video, then leaves the lyrics editor, then the search field clears its text, then the app goes back. Space, Delete, Left Arrow, and Right Arrow go to the player and the list only when the search field does not have the focus with text in it. Each screen except the album screen shows the number of songs and the total time in its subtitle.
- History: `Navigation` (in `Navigation.swift`) is the only owner of the current screen (the page and the navigation path) and of two stacks in memory: back and forward. `open` (side bar, new playlist, search links) and `show` (album, artist, Escape) push the old screen and clear the forward stack, unless the screen does not change. Opening the current page goes to its root. `restore` puts back the saved path at launch without history. `remove` drops a deleted playlist from the history, opens the fallback page if the playlist is open, and merges repeated neighbors. `refresh` replaces the albums in the history after a rescan, cuts paths at albums that are gone, and merges repeated neighbors. The history is not saved to disk. `NavigationTests` covers 100% of `Navigation.swift` (check it with `swift test --enable-code-coverage` and `llvm-cov report`). Back and forward use Command-[ and Command-], the toolbar arrows, the trackpad swipe (`Navigator`, an `NSResponder` after the window in the responder chain, returns `true` from `wantsScrollEventsForSwipeTracking(on: .horizontal)`, so the scroll views pass horizontal gestures to it, and it calls `trackSwipeEvent`; macOS decides the threshold and the direction, and an arrow at the edge follows the gesture; `swipe(with:)` handles three-finger swipes), and mouse buttons 4 and 5 (`otherMouseDown(with:)`). A deleted playlist leaves the history. The history is not saved to disk.
- Search: the app never clears the query by itself. Only Escape, Command-K, and the clear button of the field clear it. The query also filters the playlists and Liked Songs.
- Volume: the app measures each song one time (EBU R128, reference -14 LUFS, gain limited by the peak, maximum +12 dB). The background worker stops in Low Power Mode and when the Mac is hot. With shuffle off, it uses the album gain. With shuffle on, it uses the track gain.
- Last.fm: the app marks each batch on the disk before it sends it. It removes a scrobble only when Last.fm accepts it. Code 5 (daily limit) keeps the scrobble. Codes 6, 7, and 13 isolate the bad scrobble. Codes 1 to 4 move it to the rejected list. When the result of a send is not known, the app looks at `user.getRecentTracks` before it sends again, and sends it again one day before the 14-day limit if it cannot look.
- YouTube: the app searches with the YouTube page itself (`/youtubei/v1/search` with the context of the page), so it needs no API key. It plays the first result that has the song name and the artist, ignores "Topic" channels, and checks with `oembed` that the video can play outside YouTube. The ad block uses a content rule list and removes `adPlacements`, `adSlots`, and `playerAds` from the player response.

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
