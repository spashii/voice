# What's new in Dictate

<!--
One entry per release, newest first: "## VERSION (YYYY-MM-DD)", then one "- " line per change:
a **short headline** and a sentence or two, written for the person using Dictate. Group related
changes into one line. Settings, About shows this file, and tools/release.sh puts
the entry for VERSION into the update feed, which Sparkle shows before installing. release.sh
stops when VERSION has no entry here.
-->

## 0.15.4

- **Agents can no longer start a recording.** Only you can. Agent access is now off for new installs; if you already used Dictate, it stays on. In Settings, Agents, Connect an agent app has Copy setup message, a message you paste into Claude or another agent to connect it. The Claude Code command now installs for all your projects.
- **Tell the call you're transcribing.** Record this call? has Copy notice, a line to paste into the call's chat.

## 0.15.3 (2026-11-14)

- **Dictate shows itself on first launch.** Welcome comes to the front, and opening Dictate again from Spotlight or Finder brings the right window up. Until you activate, Dictate keeps its Dock icon.
- **After an update.** Settings opens on About if you chose the update. If it installed on its own, a pill says Updated to the new version.
- **Send feedback.** About shows your activation ID with a Copy button. Send Feedback… in About or the menu bar menu opens a short form in your browser.

## 0.15.2 (2026-11-13)

- **Data retention.** Dictate deletes audio after 7 days and history after 30 days. You can change both in Settings, Setup. Developer mode keeps everything and asks before deleting when you turn it off.
- **Audio deleted.** A recording whose audio is gone says so in History where the player was.
- **Ask before you record.** The Record this call? prompt now says it.
- **Retry unsure words.** Retry unsure segments has a new name.

## 0.15.1 (2026-11-13)

- **Empty filters.** History fills the window again when a filter has nothing in it.

## 0.15.0 (2026-11-13)

- **Import audio files.** Drop an audio or video file on History, or choose Import Audio File… from the New menu. Agents can import too, once you turn their tool on.
- **One search for History.** It sits in the toolbar and finds recordings and the words inside them.
- **Corrections become key terms.** Fix a name in a transcript and Dictate remembers it.
- **Shorter call titles.** Three or four words. Right-click any recording to generate a new one.
- **Developer mode.** Turn it on in About to see how long titles, fixes and retries take.

## 0.14.2 (2026-11-13)

- **What’s new in About.** It shows the last three releases, and View more shows the rest.

## 0.14.1 (2026-11-13)

- **Two model groups.** Settings, Model has Speech for the speech model and Retry unsure segments, and Intelligence for fixing text and call titles.
- **Apple Intelligence by default.** It is the default Intelligence model, and the picker is always open.
- **Titles on by default.** Each call gets a title automatically.
- **Updates in About.** It shows when an update is available and what’s new.
- **Early access.** Dictate is now in early access.

## 0.14.0 (2026-11-13)

- **Call titles.** A model on your Mac names each call when it ends, and never replaces a name you gave it. History shows the call app first, then the title.
- **Apple Intelligence for fixes.** Fix the text before pasting can use it on Macs that have it, or Ollama. Choose in Settings, Model.
- **Agents can title recordings.** The tool is off until you turn it on in Settings, Agents.

## 0.13.1 (2026-11-13)

- **A clearer download.** The disk image opens on a window that shows where to drag Dictate.

## 0.13.0 (2026-11-13)

- **Activation.** Activate Dictate once with your email.
- **Edit History.** Rename and delete recordings, and select words to correct them. A corrected name is offered as a key term. Cmd+F searches inside the open recording.
- **Newest recordings in the menu.** It lists your five newest.
- **Secure keyboard input.** When another app has it on, the menu names that app and says the shortcuts are paused.
- **Blend Mic status.** Settings, Microphones says whether it is installed.

## 0.12.1 (2026-11-12)

- **Clearer transcripts.** Me is blue and Call is purple. On speakers, the other side of the call no longer shows up under Me.
- **Better History.** Search looks inside every transcript, long calls open and play faster, and VoiceOver and the keyboard work. Press Return on a block to play from there.
- **Agent setup.** Settings, Agents shows what to paste into an agent app with your token filled in, and warns when other machines can reach the server.
- **Microphone names.** Settings, Microphones names each microphone and explains the call audio choice.

## 0.12.0 (2026-11-12)

- **Voice is now Dictate.** Your recordings and settings move over on their own.
- **One window.** History and Settings share it. Open it from the menu or with Cmd+,.
- **Calls without Blend Mic.** Dictate records the other side straight from the call app. Allow call audio once in Setup.
- **A better History.** It has search and one block per speaker turn, underlines corrected words, plays from any line and saves audio with Save As. Each recording shows its time of day, and its time zone when that differs from yours.
- **Agent tools.** Settings, Agents turns each tool on or off and sets the address and token. On new installs, tools that record or change anything start off.
- **Smaller touches.** Suggested key terms leave out everyday English words, the live pill fades while the pointer is over it, and recordings that heard nothing stay out of History.

## 0.11.0 (2026-11-09)

- **Menu links.** The menu has Check for Updates, Report an Issue and View on GitHub.
