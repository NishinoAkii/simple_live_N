# Changelog

## 1.27.1 (12701)

### New

- Reopening the last set of extra windows restores each window, the main window included, to how it was closed: position, size, sound, danmaku, quality, Fill window, keep on top and the chat panel.
- A room opened in a new extra window uses that room's last volume, mute, danmaku on/off, quality, audio output, Fill window and window size.
- A room's remembered mute state takes precedence over "Mute new extra windows", and unmuting restores the previous volume.

### Fixed

- After switching rooms, unfinished loads from the previous room (info, SC, stream addresses) no longer end up in the new room or remove a Douyin follow.
- Refreshing while a room is still loading no longer opens a second danmaku connection.

## 1.27.0 (12700)

### New

- Fill window on desktop: the picture fills the current window without changing its size. The button is between PiP and Full screen in the bottom bar.
- Reopening the last set of extra windows restores each window's Fill window and keep-on-top state.
- Accounts, tokens, cookies and the WebDAV password are now stored encrypted. Plain values left by the original app or older versions are still read and are encrypted at the next start.
- A Hardware decoding switch in the player settings, which applies to the current window for this session only.
- The video info has a Format line, and the server list shows each server's CDN node.

### Fixed

- Bilibili HLS streams broke up after a while, and refreshing did not help. Segments now download through a local relay, and the stream reopens by itself when the streamer restarts it.
- When the picture keeps failing to decode, the app retries the stream, then switches servers, then falls back to software decoding, and says so in the chat.
- Bilibili servers now list FLV first.
- In the follows list, "Live" no longer wraps to the next line when the name is long.

## 1.26.0 (12600)

### New

- Screenshots and recording in the live room, at the right of the top bar and next to the lock button in fullscreen. For screenshots you choose which layers and which area to capture. Recording saves the stream as it is, up to 2 minutes, or as a GIF. You can save, copy or delete the result (videos can't be copied on phones).
- A button next to Back shows or hides the video info; pick what it shows under Room settings.
- In-app updates: the app checks for a new version at startup, or when you tap Me → Check for updates, and verifies the SHA-256 of the download before installing.
- The Check for updates page can set a translation source for downloading and updating interface translations.
- A keep-on-top button in the live room on desktop.
- Up to 6 extra windows. Each remembers its own position, size and sound settings, and the last set can be reopened in one go. New extra windows start muted, each can use its own audio output, and they close together with the main window.

### Fixed

- On desktop, the lower half of the live room's More menu turned into a grey area that could not be used.
- On Windows, a window snapped to a screen edge reopened slightly off.

The Windows 7 package does not include in-app updates or keep on top.

## 1.24.0 (12400)

First version, based on upstream Simple Live 1.11.7. The following was added or improved compared with upstream. Some of these features have not yet been tested on real devices or in real live rooms.

### Platforms and live sources

- Three new platforms, Twitch, Kick and YouTube, where you can browse recommendations and categories, search, watch streams and read the live chat. A Twitch or Kick room link can be pasted into the search box to open the room.
- Live source subscriptions (Me → Live source subscriptions) add new platforms through JavaScript scripts, and updating a script does not require reinstalling the app. Before a script is installed or updated, the app lists the permissions it needs and asks you to confirm any new ones. How to write a script is described in [doc/live_source_api.md](doc/live_source_api.md) (in Chinese).
- The available sources are AcFun, Kuaishou, Steam and 88zhibo (sports). Subscription URL: `https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/index.json`

### Search and follows

- Search offers combined results, direct jumps to a room number, suggestions as you type (pinyin and initials work too) and a search history.
- You can log in with Douyu, Twitch, Kick and YouTube accounts and import your follows from them. Twitch subscriber or Turbo accounts can also watch restricted qualities after logging in.
- With "Go-live alerts" turned on for a followed room, the app shows a system notification when the stream starts, and tapping it opens the room.
- The follows page can be grouped by source, tag or live status, sorted in several ways and searched by name (pinyin included). It also offers compact list and card layouts.
- Switching to the follows page checks which streamers are live.

### Watching

- When a stream drops or stalls, the app reconnects automatically and switches lines if needed. On a slow network it waits a little longer before reconnecting.
- "Speed up to catch up" (off by default) plays slightly faster when too much is buffered, keeping the picture close to live.
  - You can set the target buffer (2 s by default, 0.5 to 10 s) and the max speed (1.5x by default, 1.01x to 2x).
  - It starts once the buffer is more than 1 s above the target and speeds up more the further behind it is (about 2x at 5 s over), never above the max speed. Back within the target, playback returns to normal speed.
  - It goes by the lowest buffer level of the last 10 seconds, so segmented streams such as Twitch and Kick don't speed up every time a segment arrives, and at least 4 s always stay buffered.
  - On a stall it returns to normal speed at once and pauses catching up: 15 s for segmented streams, 5 s for others.
- The control bar has a pause button. "Audio only" plays just the sound and shows the streamer's card in place of the video; on phones it keeps playing with the screen locked.
- Quality can be set to "Remember last", stored separately for Wi-Fi and mobile data.
- The stream pauses or lowers its volume when another app plays sound, and pauses when headphones are unplugged (Android, iOS). The "Play alongside other apps" setting turns this off.
- Android has a "Fullscreen orientation" setting. On iOS, danmaku also appear in the picture-in-picture window.
- "Show video info" overlays the frame rate, bitrate and similar details on the video.
- Some live rooms are now displayed in a different way.

### Danmaku and chat

- Emotes appear as images for Bilibili, Douyu, Huya, Douyin, YouTube, Twitch (including 7TV, BTTV and FFZ) and Kick (including 7TV). Turn off "Show emote images in danmaku" in the danmaku settings to show them as text.
- The whole chat history is kept (up to 100,000 messages by default) and can be searched in the room.
- Tapping a message shows the user's fan badge, level and roles. From there you can copy or search the message, or show only that user's danmaku.
- You can block a user (permanently, for the current visit or for a set time) and add notes to users. Both work by user ID, so they still apply after a name change.
- The "Gifts" page lists every gift, and paid gifts and Super Chats pop up in the lower-left corner of the video. The "Rankings" page shows the contribution rankings that some platforms provide, and on every platform a ranking of the gifts received during the current stream.
- During co-streaming, PK or multi-guest sessions, a tag in the lower-left corner of the video shows the type and the avatar and name of whoever joined (the other streamer in a PK). When people are queuing, tap the tag to see the queue.
- Live figures from the platform, such as viewer and like counts, appear next to the streamer's name.
- A room announcement card sits at the top of the chat: the title, the streamer's announcement (or the room description when there is none) and how long the stream has been live. It can be folded into a small bar or closed for the current room, and it folds itself in that room once the chat fills the panel or you scroll the chat; turn off "Show room announcement above chat" in the settings to hide it.
- "Danmaku smoothing" buffers messages that arrive in bursts and shows them at an even pace. Scrolling danmaku also move more smoothly than before.
- New settings: "Filter repeated danmaku", "Danmaku delay", "Colored danmaku", "Colored usernames" and "Show badges before names".
- Danmaku and chat settings can be applied to a single room or a single platform.
- Danmaku can be exported as ASS subtitle files. An "OBS bridge" for OBS and similar tools is also available, off by default.

### Desktop

- On Windows, up to 4 live rooms can be open in separate windows.
- Keyboard shortcuts: F fullscreen, D danmaku on/off, M mute, R refresh, C collapse chat, Space pause. Every key can be changed.
- The app remembers window position and size, and "GPU preference" chooses which graphics card to use.
- The side panel in a live room can be resized by dragging.
- On Windows, video is rendered directly with Direct3D 11, which lowers CPU use. Crashes on exit are fixed, as are crashes and frozen video while watching on NVIDIA graphics cards.

### Sync and other changes

- WebDAV auto-sync (off by default) keeps one archive per day in the cloud, up to 10.
- The watch history shows each room's cover, title and live category.
- When devices in different time zones sync, watch history and follow times are converted to the local time zone.
- LAN sync is encrypted when both devices run this version. With the official app, content is still sent in plaintext, but accounts are never sent.
- Platform accounts, cookies and the WebDAV password are stored encrypted in backups and exported settings.
- The interface is available in Simplified Chinese, Traditional Chinese and English, and translations for other languages can be imported. To install the Japanese or Spanish translation, enter the translation list URL `https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/translations.json` under "Me → Appearance settings → Language → Download from URL", then pick the language.
- With "Debug mode" on, the app keeps logs, and "Export logs" saves them in one step when something goes wrong.
- Watching uses less CPU, and memory grows more slowly during long sessions.
