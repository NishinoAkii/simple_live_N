# Changelog

## 1.24.2 (12402)

### New

- On desktop, a pin button at the top right of the live room keeps the window above other windows; click it again to turn it off. Pinning or unpinning the main window applies to every open extra window, while the pin in an extra window affects only that window. The setting is not kept after the window closes, and leaving the small window restores the previous state. Not included in the Windows 7 package.
- On desktop, up to 6 extra windows can be open (previously 4). Each window remembers where you moved it and its size, and opens there next time.
- The app remembers the last set of extra windows (rooms, positions and opening order). Reopen them with the button next to Refresh on the watch history page or under Me → Desktop settings → Extra windows; rooms that are already open are not opened twice. At startup the app asks whether to reopen them by default, and Desktop settings can change this to always or never.

### Improved

- Closing the main window also closes the extra windows. If the main window quits unexpectedly, the extra windows close by themselves after a few seconds.

### Fixed

- On desktop, the live room's More menu showed a grey area below Screenshot, so Open in new window, Audio only, Sleep timer, Share room and the other items could not be used.

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
