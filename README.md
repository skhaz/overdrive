<p align="center"><img src=".github/icon.png" width="128" alt="Overdrive icon"></p>

# Overdrive

[![GitHub release](https://img.shields.io/github/v/release/skhaz/overdrive)](https://github.com/skhaz/overdrive/releases/latest)

A music player for the Mac (macOS 26 or later). It plays the music that is already on your Mac. You do not have to import anything.

![Overdrive plays an album](.github/screenshot.png)

## Features

- **Uses your music folders.** Add a folder and your albums show at once. New songs that you put in the folder show automatically.
- **Plays all common formats:** AAC, ALAC, MP3, FLAC, Opus, Vorbis, WAV, and AIFF.
- **Album covers** from your music files or from the image in the album folder.
- **Lyrics** that move with the song. If a song has no lyrics, the app finds them on the internet. You can also type and save your own.
- **Same volume for all songs**, so you do not have to change the volume between songs.
- **Last.fm:** keeps a list of the songs that you listen to in your Last.fm profile.
- **Music videos from YouTube** in a small window that stays on top.
- **Playlists** and a queue (Play Next and Add to Queue).
- **Liked songs.** Like any song and find them all in **Liked Songs** in the sidebar.
- **Continues where you stopped.** When you open the app again, it shows the same song, at the same time.
- **Keyboard media keys** and Control Center play, pause, and change songs.
- **Apple Music does not open by accident** while you use Overdrive.
- **Song details:** the quality and the size of each song file.
- **Mp3tag:** if you have Mp3tag, you can open your songs in it to edit their names and details.

## Install

Install [Homebrew](https://brew.sh), open Terminal, and type:

```sh
brew install --cask skhaz/tap/overdrive
```

## How to use

### Add your music

Drag a music folder to the window, or choose Overdrive > Settings > Folders > Add Folder. You can add more than one folder. The app also finds the songs in the folders inside it.

### Find and play

- Use the sidebar to see **Albums**, **Artists**, or **Songs**.
- Type in the search field to find an artist, an album, or a song. The search stays until you clear it with Escape, Command-K, or the clear button.
- To go back to the previous screen, click the back arrow at the top, press Command-[, or swipe to the right on the trackpad. To go forward again, click the forward arrow, press Command-], or swipe to the left. The side buttons of a mouse also work.
- Double-click a song to play it. On an album, click **Play** or **Shuffle**.
- Use the bar at the bottom to play, pause, go to the previous or next song, shuffle, repeat, go to a different part of the song, and change the volume.
- Click the cover or the name in the bottom bar to open the album that plays.

The song that plays shows in color and is selected in the list.

### Use the menu of a song

Right-click a song, an album, or the bottom bar. You can:

- **Play Next** or **Add to Queue**.
- **Add to Playlist**.
- **Watch Video on YouTube**.
- **Go to Album** or **Go to Artist**.
- **Copy** the song name, the artist, the album, or "Artist - Song Name".
- See the **Information** of the song file. Click an item to copy it.
- **Open in Mp3tag** or **Show in Finder**.

To do this for more than one song, select the songs with Command-click or Shift-click, then right-click one of them.

### Make playlists

1. Click **+** in the sidebar, or choose File > New Playlist.
2. Right-click songs or albums and choose **Add to Playlist**.
3. Drag the songs in the playlist to change the order.
4. To remove a song, right-click it and choose **Remove from Playlist**, or press Delete.

To delete a playlist, right-click it in the sidebar. The app keeps a backup copy in the Playlists folder (Music > Library > Playlists).

### Like songs

Click the heart in the bottom bar to like the song that plays. You can also right-click any song or album and choose **Like Song**. A heart shows next to each liked song in the lists.

Click **Liked Songs** in the sidebar, below Songs, to see all liked songs. To remove a like, right-click the song and choose **Unlike Song**, or click the heart again while the song plays.

### Lyrics

The lyrics show at the right side when a song plays. Click a line to go to that part of the song. To change the lyrics, edit the text and click **Save** (Command-S). The app saves the lyrics next to the song. To remove the lyrics, delete all the text and click **Save**.

### Watch the music video

1. Right-click a song and choose **Watch Video on YouTube**.
2. The first time, sign in to your Google account in the window. Passkeys do not work in this window, so click **Try another way** and use your phone, or your password and a code.
3. The video plays in a small window in a corner of the screen. The song in Overdrive pauses.

Drag the window to move it to a different corner. Put the pointer on the video to see the close button. When you play a song in Overdrive, the video window closes.

### Connect Last.fm

Choose Overdrive > Settings > Last.fm. Type your Last.fm username (not the email) and password, and click **Connect**.

### Settings

| Setting | What it does |
| --- | --- |
| Folders | The folders with your music. |
| Last.fm | Connect or disconnect your Last.fm account. |
| YouTube > Open Videos In | Show the videos in the small window (default) or in your web browser. |
| YouTube > Window Corner | The corner of the screen for the video window. |
| YouTube > Sign Out | Sign out of YouTube. |

To turn off the same volume for all songs, choose Controls > Normalize Volume.

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Up Arrow, Down Arrow | Go to the previous or next item |
| Shift-Up Arrow, Shift-Down Arrow | Add the previous or next song to the selection |
| Left Arrow, Right Arrow | Go to the previous or next album (when the search field is empty) |
| Return | Open the album or the artist, or play the song. If the song plays, pause it |
| Space | Play or pause (when the search field is empty) |
| Escape | Close the video. Stop to edit the lyrics. Clear the search. Go back |
| Delete | Remove the selected songs from the playlist, or delete the selected playlist in the side bar |
| Tab | Go between the side bar and the main area |
| Command-[ | Go back to the previous screen |
| Command-] | Go forward again |
| Control-Return | Open the menu of the item, as with a right-click |
| Command-Right Arrow | Next song |
| Command-Left Arrow | Previous song |
| Option-Command-Right Arrow | Go forward 10 seconds |
| Option-Command-Left Arrow | Go back 10 seconds |
| Command-Up Arrow | Increase the volume |
| Command-Down Arrow | Decrease the volume |
| Command-L | Show the album of the song that plays |
| Option-Command-L | Like or unlike the song that plays |
| Option-Command-S | Shuffle on or off |
| Option-Command-R | Repeat: off, all songs, or one song |
| Command-E | Edit the lyrics |
| Command-N | New playlist |
| Command-R | Look for new music in your folders |
| Command-K | Clear the search |
| Command-S | Save the lyrics |
| Command-, | Settings |
| Media keys | Previous song, play or pause, next song |

## Good to know

- The app never changes your songs. It only saves the lyrics that you save.
- When you play an album in order, the quiet and loud songs of the album stay as the artist made them.
- No Last.fm play is lost. If there is no internet, the app sends them later.
- The video window opens at once, and you stay signed in to YouTube.
- YouTube can show an ad. With YouTube Premium, there are no ads.

## Credits

The app icon is "iPod Orange" by p_bluealt, from [macOSicons](https://macosicons.com/icon/ipod-orange-siHDxmuV8f). The MIT license does not apply to the icon.
