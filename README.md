<p align="center"><img src=".github/icon.png" width="128" alt="Overdrive icon"></p>

# Overdrive

[![Release](https://github.com/skhaz/overdrive/actions/workflows/release.yml/badge.svg)](https://github.com/skhaz/overdrive/actions/workflows/release.yml)
[![GitHub release](https://img.shields.io/github/v/release/skhaz/overdrive)](https://github.com/skhaz/overdrive/releases/latest)

Music player for macOS 26 or later.

![Overdrive plays an album](.github/screenshot.png)

- No database. It scans the music folders at launch and when they change. It writes to them only when you save lyrics.
- Plays all formats that AVFoundation supports: AAC, HE-AAC, ALAC, MP3, FLAC, Opus, Vorbis, WAV, AIFF, and CAF.
- Shows album covers from the embedded artwork or from an image in the album folder.
- Shows and edits lyrics in a panel.
- Makes the volume of all songs the same.
- Sends scrobbles to Last.fm. See [Last.fm](#lastfm).
- Plays the music video of a song from YouTube. See [YouTube](#youtube).
- Opens tracks and albums in Mp3tag from the context menu.
- Right-click a song and choose Information to see the format, sample rate, channels, bit depth, bit rate, and size of the file. Click an item to copy its value.
- Right-click a song or an album and choose Play Next or Add to Queue.
- Right-click a song, an album, an artist, or the player bar and choose Copy to copy the song name, the artist, or the album. For a song, Artist - Song Name copies the text as "Iron Maiden - The Wicker Man".
- Select more than one song with Command-click or Shift-click. Then right-click a selected song to use the menu on all selected songs. Right-click a song that is not selected to select it and use the menu on only that song.
- The song that plays, or the video that plays, is selected in the list of songs and shows in the accent color. When the song changes, the selection changes.
- Use the media keys to go to the previous song, play or pause, and go to the next song.
- While the app is open, Apple Music cannot open. The app closes Apple Music when it starts, when Apple Music opens, and every second.
- Press Control-P to clear the search field and type a new search.
- Click the cover or the title in the player bar to open the album that plays.
- When you quit the app, it saves the queue, the song, the position, play or pause, shuffle, repeat, the section, the open album or artist, and the search. When you open the app again, all of it is the same as before, but the song does not start to play. Click Play to continue. The app writes this state to `~/Library/Application Support/Overdrive/Session.plist` in one atomic write, so a crash or a power loss cannot leave a part of it.
- Sorts the songs of an album by the disc number and then by the track number.
- Uses the album artist tag for an album that has songs of different artists.

## Lyrics

The app shows the lyrics of the song that plays in a panel.

- The app reads the lyrics from the `.lrc` file next to the song, for example `Song.lrc` for `Song.mp3`.
- When a song starts to play, the panel opens, also if the song has no lyrics, so you can type them. When the song changes, the panel shows the lyrics of the new song.
- The panel shows only on a list of songs that has the song of the lyrics: the album of the song, Songs, or a playlist with the song. On Albums, Artists, the albums of an artist, or a different album, the panel does not show. When you go back to the album or the song, the panel shows again.
- You can select and copy the lyrics, also synced lyrics. Click a line of synced lyrics to go to that time. While you select text, the lyrics do not scroll.
- If there is no `.lrc` file, the app gets the lyrics from [LRCLIB](https://lrclib.net) one time and keeps them in `~/Library/Application Support/Overdrive/Lyrics`. It writes nothing to the music folder until you click Save.
- Click Save (Command-S) to write the `.lrc` file. Save with an empty text to delete the file.
- If the lyrics have unsaved changes, the app asks before it hides the panel or shows other lyrics. You can save, discard, or cancel and continue to edit.

## Volume

The app makes the loudness of all songs the same, so you do not have to change the volume between songs.

- The app measures each song one time (EBU R128) and keeps the result in `~/Library/Application Support/Overdrive/Loudness.plist`. It writes nothing to the music folder.
- The app measures the songs slowly in the background, so the Mac does not get hot. It stops in Low Power Mode and when the Mac is hot. A song that is not measured yet is measured before it starts to play. A song of more than 5 minutes starts at once and is measured for the next time.
- When you play an album in order, the app changes the volume of the full album, so the quiet and loud songs of the album stay as they are. When shuffle is on, the app changes the volume of each song.
- The volume of a song does not go above its peak, so the sound does not clip.
- When you change a song file, the app measures the song again.
- To turn it off, choose Controls > Normalize Volume.

## Last.fm

- The app keeps each scrobble in `~/Library/Application Support/Overdrive/Scrobbles.plist` before it sends it. The write is atomic and goes to the disk before the app continues.
- The app removes a scrobble from the queue only when Last.fm accepts it.
- When there is no network or Last.fm does not respond, the scrobbles stay in the queue. The app sends them when the network comes back, and tries again every minute.
- If Last.fm gets a scrobble but the response does not arrive, the app does not know if Last.fm kept it. Before it sends it again, the app looks at the recent tracks on Last.fm and sends only the scrobbles that are not there. This prevents duplicate scrobbles. These scrobbles do not stop the app from sending other scrobbles. If the app cannot look at the recent tracks, it sends them again one day before the 14-day limit of Last.fm, so a scrobble is never lost.
- When the daily scrobble limit of Last.fm is reached, the scrobbles stay in the queue for later.
- The app keeps a scrobble that Last.fm rejects (for example, a filtered artist or a timestamp more than 14 days old) and shows the count in Settings.

## Playlists

- Each playlist is a file in `~/Music/Library/Playlists`, for example `Rock.playlist`. The file has one path of a song on each line. The path is relative to the `Playlists` folder, so the playlists continue to work if the user name or the home folder changes.
- Click the + button in the sidebar or choose File > New Playlist (Command-N) to make a playlist.
- Right-click a song or an album and choose Add to Playlist. Add to Playlist does not add a song that is already in the playlist. In a playlist, the menu does not show the playlist that is open.
- Right-click a song in a playlist and choose Duplicate to have the same song two or more times.
- Drag a song in a playlist to change the order.
- Right-click a song in a playlist and choose Remove from Playlist, or select it and press Delete. The app asks before it removes the song. These actions also work on more than one selected song.
- When you open a playlist, the app clears the search field.
- Right-click a song in a playlist or in Songs and choose Go to Album or Go to Artist. Click Back to go back to the list.
- Right-click a playlist in the sidebar and choose Delete Playlist. The app asks first, then renames the file to `{name}.backup` in the same folder. To restore the playlist, rename the file back to `{name}.playlist` and choose File > Rescan Library.
- If you edit a playlist file in a different app, choose File > Rescan Library (Command-R).

## Credits

The app icon is "iPod Orange" by p_bluealt, from [macOSicons](https://macosicons.com/icon/ipod-orange-siHDxmuV8f). The MIT license does not apply to the icon.

## Install

```sh
brew install --cask skhaz/tap/overdrive
```

## Uninstall

```sh
brew uninstall --zap --cask overdrive
```

The `--zap` option also removes the settings, the Last.fm session, and the lyrics cache. It does not remove the `.lrc` files in the music folders.

## Build

```sh
./build.sh
```

Use a local build only to debug or to profile.

## Test

```sh
swift test
```

The tests use a fake Last.fm server, so they do not send scrobbles to a real account.

## Release

Do these steps for each change:

1. Commit the change and push it to `main`.
2. Push a new tag, for example `v0.1.12`. The GitHub Action builds the app, creates the GitHub release, and updates the cask in `skhaz/homebrew-tap`.
3. When the action completes, install the release:

```sh
brew update
brew upgrade --cask overdrive
```

Do all tests on the release from GitHub and Homebrew, the same as a real installation. Use a local build only to debug or profile. Do not run a local build as the installed app.

## Last.fm

1. Get an API key at https://www.last.fm/api/account/create.
2. Build with the key: `LASTFM_KEY=... LASTFM_SECRET=... ./build.sh`.
3. Open Settings, enter the Last.fm username (not the email) and password, and click Connect. The app keeps only the session key, in `~/Library/Application Support/Overdrive/lastfm.plist`.

## YouTube

Right-click a song and choose Watch Video on YouTube.

- The app searches YouTube for the artist and the song name. It plays the first result that has the song name and the artist in the title or the channel name. It ignores audio-only "Topic" channels and videos that cannot play outside YouTube. If no result agrees, the app tells you.
- The app keeps the video of each song in `~/Library/Application Support/Overdrive/Videos.plist`, so it searches for each song only one time.
- The video plays in a 16:9 window that stays on top of all windows, in a corner of the screen. Choose the corner in Settings > YouTube > Window Corner. When you drag the window and release it, it goes to the nearest corner. You can resize it and close it. The close button shows only when the pointer is on the video. The window shows only the video.
- The app pauses the song that plays. While the window is open, the media keys play and pause the video. When you close the window, the media keys control the songs again. When a song starts to play in the app, the window closes, so you do not hear two sounds at the same time.
- The app blocks the known ad requests and removes the ad data from the YouTube player response. YouTube can change this at any time, so an ad can show.
- Before the video plays, the app makes sure that you are signed in to YouTube. If you are not signed in, or the session is expired, the window shows the Google sign-in page, and the video plays after you sign in. With YouTube Premium, the videos have no ads. Passkeys do not work in the window, because macOS lets only Google apps use passkeys for Google in an app. Click Try another way and use your phone or your password and a code.
- The app keeps YouTube loaded in the background, so the video starts at once and the window opens only when the video plays. The app keeps the session after you quit. Every hour, while the window is closed, the app loads YouTube again, so Google renews the session and you do not have to sign in again. If you ask for a video while YouTube loads, the video starts when the load is complete.
- To sign out, choose Settings > YouTube > Sign Out.
- To open videos in the default browser, choose Settings > YouTube > Open Videos In > Default Browser.
