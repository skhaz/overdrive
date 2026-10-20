# Agents

## Commits

Commit each change when it is complete. Do not ask before you commit.

## YouTube

- The app has only one YouTube web view. The app makes it when it starts and keeps it until it quits. Do not make a second web view, and do not release or recreate it.
- The web view always keeps the YouTube player page loaded and ready, so a video starts at once. When the video window closes, stop the video, but keep the page loaded.
- When a video starts, pause the song that plays. When a song starts to play, close the video window.

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
