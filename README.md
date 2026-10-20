<p align="center"><img src=".github/icon.png" width="128" alt="Overdrive icon"></p>

# Overdrive

[![Release](https://github.com/skhaz/overdrive/actions/workflows/release.yml/badge.svg)](https://github.com/skhaz/overdrive/actions/workflows/release.yml)
[![GitHub release](https://img.shields.io/github/v/release/skhaz/overdrive)](https://github.com/skhaz/overdrive/releases/latest)

A music player for macOS 26 or later. It plays the music in your folders, with no database and no import.

![Overdrive plays an album](.github/screenshot.png)

## Features

- **Your folders are the library.** The app scans the music folders at launch and when they change. It writes to them only when you save lyrics.
- **Plays all common formats:** AAC, ALAC, MP3, FLAC, Opus, Vorbis, WAV, and AIFF.
- **Album covers** from the embedded artwork or from an image in the album folder.
- **Lyrics panel** with synced lyrics. It reads `.lrc` files, gets missing lyrics from [LRCLIB](https://lrclib.net), and lets you edit and save them.
- **Same volume for all songs**, per album or per song.
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

## Good to know

- The app never changes your music files. It writes only the `.lrc` lyrics files that you save.
- The volume of all songs is the same, so you do not have to change the volume between songs. When you play an album in order, the quiet and loud songs of the album stay as they are.
- No scrobble is lost. With no network, the scrobbles wait and the app sends them later.
- The video window opens at once, because the app keeps YouTube ready in the background. You stay signed in to YouTube.
- YouTube can show an ad, because the ad block cannot stop all ads. With YouTube Premium, there are no ads.
- Your playlists are saved in the Playlists folder, in Music > Library > Playlists. If you change a playlist there, choose File > Rescan Library.

## Credits

The app icon is "iPod Orange" by p_bluealt, from [macOSicons](https://macosicons.com/icon/ipod-orange-siHDxmuV8f). The MIT license does not apply to the icon.
