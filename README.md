<p align="center"><img src=".github/icon.png" width="128" alt="Overdrive icon"></p>

# Overdrive

[![Release](https://github.com/skhaz/overdrive/actions/workflows/release.yml/badge.svg)](https://github.com/skhaz/overdrive/actions/workflows/release.yml)
[![GitHub release](https://img.shields.io/github/v/release/skhaz/overdrive)](https://github.com/skhaz/overdrive/releases/latest)

A music player for macOS 26 or later. It plays the music in your folders, with no database and no import.

![Overdrive plays an album](.github/screenshot.png)

## Features

- **Your folders are the library.** The app scans the music folders at launch and when they change. It writes to them only when you save lyrics.
- **All AVFoundation formats:** AAC, HE-AAC, ALAC, MP3, FLAC, Opus, Vorbis, WAV, AIFF, and CAF.
- **Album covers** from the embedded artwork or from an image in the album folder.
- **Lyrics panel** with synced lyrics. It reads `.lrc` files, gets missing lyrics from [LRCLIB](https://lrclib.net), and lets you edit and save them.
- **Same volume for all songs** (EBU R128), per album or per song.
- **Last.fm scrobbles** that are never lost and never sent two times.
- **YouTube music videos** in a small window that stays on top, with ads blocked.
- **Playlists** as plain text files.
- **Queue:** Play Next and Add to Queue.
- **Session restore:** the queue, the song, the position, and the open screen are the same when you open the app again.
- **Media keys** and Now Playing in Control Center.
- **Apple Music cannot open** while the app is open, so the media keys always control Overdrive.
- **File information:** format, sample rate, channels, bit depth, bit rate, and size.
- **Mp3tag:** open songs and albums in Mp3tag from the context menu.

## Install

```sh
brew install --cask skhaz/tap/overdrive
```

To uninstall:

```sh
brew uninstall --zap --cask overdrive
```

The `--zap` option also removes the settings, the Last.fm session, and the lyrics cache. It does not remove the `.lrc` files in your music folders.

## How to use

### Add your music

Drag a music folder to the window, or choose Overdrive > Settings > Folders > Add Folder. You can add more than one folder. The app finds the songs in all subfolders.

### Find and play

- Use the sidebar to see **Albums**, **Artists**, or **Songs**.
- Type in the search field to find an artist, an album, or a song.
- Double-click a song to play it. On an album, click **Play** or **Shuffle**.
- Use the player bar at the bottom to play, pause, go to the previous or next song, shuffle, repeat, seek, and change the volume.
- Click the cover or the title in the player bar to open the album that plays.

The song that plays is selected in the list and shows in the accent color.

### Use the context menu

Right-click a song, an album, or the player bar. You can:

- **Play Next** or **Add to Queue**.
- **Add to Playlist**.
- **Watch Video on YouTube**.
- **Go to Album** or **Go to Artist**.
- **Copy** the song name, the artist, the album, or "Artist - Song Name".
- See the **Information** of the file. Click an item to copy its value.
- **Open in Mp3tag** or **Show in Finder**.

To use the menu on more than one song, select the songs with Command-click or Shift-click, then right-click one of them.

### Make playlists

1. Click **+** in the sidebar, or choose File > New Playlist.
2. Right-click songs or albums and choose **Add to Playlist**.
3. Drag the songs in the playlist to change the order.
4. To remove a song, right-click it and choose **Remove from Playlist**, or press Delete.

To delete a playlist, right-click it in the sidebar. The app keeps a backup named `{name}.backup`.

### Read and edit lyrics

The lyrics panel opens when a song plays. Click a line of synced lyrics to go to that time. Edit the text and click **Save** (Command-S) to write the `.lrc` file next to the song. Save an empty text to delete the file.

### Watch the music video

1. Right-click a song and choose **Watch Video on YouTube**.
2. The first time, sign in to Google in the window. Passkeys do not work in an app window, so click **Try another way** and use your phone or your password and a code.
3. The video plays in a window in a corner of the screen. The song in Overdrive pauses.

Drag the window to move it to a different corner. Move the pointer on the video to see the close button. When you play a song in Overdrive, the window closes.

### Scrobble to Last.fm

Choose Overdrive > Settings > Last.fm. Type your Last.fm username (not the email) and password, and click **Connect**.

### Settings

| Setting | What it does |
| --- | --- |
| Folders | The music folders of the library. |
| Last.fm | Connect or disconnect the Last.fm account. Shows the scrobbles that wait to be sent. |
| YouTube > Open Videos In | Floating Window (default) or Default Browser. |
| YouTube > Window Corner | The corner of the video window. |
| YouTube > Sign Out | Signs out of YouTube. |
| Controls > Normalize Volume | Turns the same volume for all songs on or off. |

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Command-N | New playlist |
| Command-R | Rescan the library |
| Command-S | Save the lyrics |
| Command-, | Settings |
| Media keys | Previous, play or pause, next |

## How it works

### Volume

- The app measures each song one time and keeps the result. It measures slowly in the background, and stops in Low Power Mode and when the Mac is hot.
- When you play an album in order, the app changes the volume of the full album, so the quiet and loud songs stay as they are. With shuffle on, it changes the volume of each song.
- The volume never goes above the peak of the song, so the sound does not clip.

### Last.fm

- The app writes each scrobble to the disk before it sends it, and removes it only when Last.fm accepts it.
- With no network, the scrobbles wait and the app sends them later.
- If the app does not know if Last.fm got a scrobble, it looks at your recent tracks on Last.fm before it sends it again. This prevents duplicates.
- Scrobbles that Last.fm rejects show in Settings.

### YouTube

- The app searches YouTube for the artist and the song name, and plays the first result that has both. It ignores audio-only "Topic" channels and videos that cannot play outside YouTube.
- The app keeps YouTube loaded in the background, so the video starts at once. It loads YouTube again every hour while the window is closed. This also keeps you signed in.
- The app blocks the known ad requests. YouTube can change this at any time, so an ad can show. With YouTube Premium, there are no ads.

### Playlists

Each playlist is a text file in `~/Music/Library/Playlists`, with the path of one song on each line. The paths are relative to the `Playlists` folder. If you edit a file in a different app, choose File > Rescan Library.

### Files

The app keeps its data in `~/Library/Application Support/Overdrive`:

| File | Content |
| --- | --- |
| `Session.plist` | The queue, the song, the position, and the open screen |
| `Loudness.plist` | The volume of each song |
| `Scrobbles.plist` | The scrobbles that wait to be sent |
| `lastfm.plist` | The Last.fm session key |
| `Videos.plist` | The YouTube video of each song |
| `Lyrics/` | The lyrics from LRCLIB |

The app writes the session and the scrobbles in one atomic write, so a crash or a power loss cannot damage them.

## Development

Build:

```sh
./build.sh
```

To build with Last.fm, set the API key from https://www.last.fm/api/account/create:

```sh
LASTFM_KEY=... LASTFM_SECRET=... ./build.sh
```

Test:

```sh
swift test
```

The tests use a fake Last.fm server, so they do not send scrobbles to a real account.

Release:

1. Commit the change and push it to `main`.
2. Push a new tag, for example `v0.1.12`. The GitHub Action runs the tests, builds the app, creates the GitHub release, and updates the cask in `skhaz/homebrew-tap`.
3. When the action completes, install the release with `brew update && brew upgrade --cask overdrive`.

Do all tests on the release from Homebrew, the same as a real installation. Use a local build only to debug or to profile.

## Credits

The app icon is "iPod Orange" by p_bluealt, from [macOSicons](https://macosicons.com/icon/ipod-orange-siHDxmuV8f). The MIT license does not apply to the icon.
