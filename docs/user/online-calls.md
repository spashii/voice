# Online calls

An online call has two sides. Dictate records your microphone as Me and the sound of the call app as Call, and transcribes each on its own. Ask the other side before you record, and don't record if they say no. Copy notice in the Record this call? prompt copies a line to paste into the call's chat.

1. Allow call audio once. Setup has a Call audio step. macOS asks to let Dictate record the sound of other apps. Dictate records only the call app's sound. Without it Dictate records your microphone alone.
2. Speakers or headphones. On speakers Dictate takes the call out of what your microphone hears, so its words stay under Call. Other sound from your Mac (music, for example) stays under Me. Turn this off with Cancel echo from the call in the Microphones settings.
3. Start recording. After a call app has used the microphone for 5 seconds (10 for a browser using the microphone and speakers), Dictate shows "Record this call?" with Record and Not now. ``Option+Shift+` `` and the menu's "Record This Call" start one too.
4. Read the transcript. Each side is cut at its pauses and transcribed while the call goes on, yours as Me and everyone else as Call. While it records, the call pill shows the last three lines. Click the call in the menu to copy it.
5. Stop. Recording stops 15 seconds after the call app stops using audio. You can also stop it with ``Option+Shift+` ``, from the menu or through an agent (if you turned `stop_recording` on). Once the transcript is complete, the audio becomes an AAC `.m4a`: about 45 MB an hour of stereo instead of 690 MB.

When a call ends, the intelligence model gives it a short title from its transcript. You choose that model in the Model settings: Apple Intelligence or an Ollama model. History and the menu show the title, with the app and time beside it. Without such a model the call is named after its app, such as "Slack call". It is just "Call" when Dictate doesn't know the app. A name you give it in History replaces the title. An automatic title never overwrites it. To stop the titles, turn off Add a title to each call automatically in the Model settings.

Quitting during an online call closes the WAV, and the next launch rebuilds the transcript from the file. A mute or a device switch doesn't end a recording: it ends only after 15 seconds with neither input nor output.

Dictate detects online calls in Zoom, Teams, Slack, Discord, FaceTime, WhatsApp, Signal, Telegram, Webex, Skype and Element, and in browsers (Meet, or any call in a tab). For any other app, start it from the menu.

## Which audio records

The Microphones settings have two choices for calls. Microphone for calls is Me. Call audio is the other side. Automatic is the call app Dictate finds. You can also pick an app from the list, for a call app Dictate doesn't know. A [Blend Mic](https://spashii.github.io/blend/) mix is there for someone who already uses one. If the chosen app isn't running or the microphone is unplugged, Dictate falls back to Automatic or the default microphone and says so.
