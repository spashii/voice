# How Voice works

Voice has three parts:

- **VoiceCore** (`Core/Sources/VoiceCore`, Swift 6): records, transcribes, cleans up, stores, detects calls and serves MCP. It has no UI code. It builds on whisper.cpp's prebuilt xcframework (release b5454, which is v1.9.5, with Metal built in) and the system SQLite.
- **voice-cli** (`Core/Sources/voice-cli`): runs the same code from a shell, with no window and no sound. Batch transcription, the call tests and the MCP server without the app all use it.
- **Voice.app** (`app/Voice`, SwiftUI and AppKit): the menu bar, the indicator, the call prompt, Settings, the global shortcuts (the KeyboardShortcuts package) and the paste. It decides when the core runs and shows the result. It has no recording or transcription logic of its own.

Beside them, `tools/` (zsh) builds, releases, syncs and fetches models, and `site/` is the website and the update feed.

```
microphone ─► Recorder ─► WAV on disk
                  └─► LiveTranscription ─► Transcriber ─┐
                                                        ├─► Pipeline ─► Store ─► Paster
                                      Ollama (optional) ┘

Blend mix ─► CallRecorder ─► WAV on disk, then AAC
                  └─► CallSession ─► SpeechChunker (one per side) ─► Transcriber ─► CallStore ─► MCP ─► agents
```

## VoiceCore

Audio in:

- `Audio.swift`: the 16 kHz mono format Whisper takes, `Audio.load` (any file to that format), `Paths` (everything under `~/Library/Application Support/Voice`), and the format an input node really delivers.
- `Devices.swift`: lists input devices and finds one by UID. The UID survives restarts and unplugging; the device ID doesn't.
- `Recorder.swift`: a microphone to a 16 kHz mono WAV. `Sink` converts and writes on the tap's thread, and `InputWatch` notices when the engine stops under it.

Speech to text:

- `Transcriber.swift`: whisper.cpp on the GPU, one decode at a time. Greedy decoding after Silero voice activity detection, with the key terms and the text before as the prompt. Per segment it keeps the mean log probability, no-speech probability, compression ratio, seconds of speech and words per second. In the app, segments with a mean log probability under -0.6 are decoded again with beam 5 and the segment before as the prompt, worst first, within half the first decode's time, and the surer text is kept. Every segment keeps a record of what the retry did.
- `Models.swift`: the two Whisper models (large v3 turbo and large v3), the voice activity model, where each downloads from, Whisper's language list and the models Ollama has.
- `Live.swift`: `Chunker` cuts a stream of samples at pauses, and `LiveTranscription` decodes the chunks in order on one worker.

Dictation:

- `Pipeline.swift`: a recording in, a stored dictation out. The app and voice-cli both go through it, so what voice-cli measures is what gets pasted.
- `Cleanup.swift`: the fix step's settings and its request to Ollama.
- `Recovery.swift`: finds WAVs the history doesn't know and repairs their headers.
- `Store.swift`: dictations and their segments, in SQLite.
- `RetryReference.swift`, `RetryReport.swift`: the references decoded while the Mac is idle (large v3 when downloaded, beam 5) and `voice-cli retry-report`, which scores the retries against them and prints aggregates only.
- `OpenSuperWhisperImport.swift`: copies OpenSuperWhisper's history in as dictations with origin `imported`, as a test set.

Calls:

- `Calls.swift`: the types (`Call`, `CallSegment` with channel me, call or mix, search hits) and how a transcript is written as text.
- `CallSource.swift`: reads Blend's `devices.json` and picks what to record.
- `CallDetector.swift`: polls Core Audio's process list. `CallTracker` turns each poll into the apps in a call, and `CallApps` holds the app lists and asks Blend's driver who reads a mix.
- `CallRecorder.swift`: `CallRecorder` (start, stop, rebuild, compress), `CallSession` (one call's audio on its way to the WAV and to Whisper), `CallChannels` (which input channel is which side) and `SpeechChunker` (cuts each side at pauses).
- `CallAudio.swift`: replaces a finished call's WAV with AAC and checks the result.
- `CallStore.swift`: calls, segments, tags, the search index, the migrations and the wait for new segments.

Agents:

- `MCPServer.swift`, `HTTP.swift`, `MCPRouter.swift`: MCP over HTTP on Network.framework. `MCPToken.swift` makes and reads the token.
- `SQLite.swift`: the connection `CallStore` uses. `Store` calls sqlite3 itself.

## The app

- `VoiceApp.swift`: the menu, and the quit sequence.
- `AppModel.swift`: the dictation state (idle, recording, transcribing, cleaning up, a notice), one pipeline per Whisper model, recovery at launch and the paste.
- `Calls.swift` (`CallsModel`): detection to prompt, the call shortcut, the source, record and stop, rebuild and compress at launch, and the warning when a call app reads the mix. Also the prompt panel and the menu and Settings parts.
- `AgentAccess.swift`: runs the MCP server while the app runs, with the Settings switch, the addresses and the token.
- `Updates.swift`: Sparkle, the Check for Updates button and the automatic switch.
- `Indicator.swift`, `Paster.swift`, `Preferences.swift`, `SettingsView.swift`, `Setup.swift`, `Downloads.swift`: the pills (a dictation's, and a call's while it records), the paste, UserDefaults, Settings, the first-run window and the model downloads.

## A dictation

1. **Shortcut.** `KeyboardShortcuts` calls `AppModel.toggle` on key up. A press while a dictation is being transcribed does nothing. The dictation runs the fix step only if its switch is on and no call is using Whisper.
2. **Start.** `AppModel.start` makes a `LiveTranscription` on the current pipeline's transcriber, with the language and key terms from Settings, shows the indicator, asks for the microphone and starts the `Recorder`.
3. **Record.** The recorder points an `AVAudioEngine` at the chosen microphone (or the default), taps it in the device's own format, converts to 16 kHz mono and appends to `recordings/<ms>.wav` as 16-bit PCM. After each write it passes the same samples to `LiveTranscription`.
4. **Chunk.** `Chunker` compares each 20 ms frame with a noise floor: the 15th percentile of the last 10 seconds, plus 10 dB. It closes a chunk after a 0.6 second pause (0.3 once the chunk passes 15 seconds) and never under 4 seconds. If no pause comes by 25 seconds, it cuts at the quietest 0.3 seconds. One worker decodes the chunks in order, each with the key terms and the last 50 words of the chunk before. The indicator shows the text so far.
5. **Stop.** The recorder closes the file. Under 0.3 seconds, the dictation is a history row with the audio and "Too short to transcribe".
6. **Transcribe.** `Pipeline.run` asks `LiveTranscription` to close its open tail and wait for the chunks, and their join is the transcript. If a chunk failed, or the speech model changed during the recording, it loads the WAV and decodes all of it.
7. **Fix.** In cleanup mode with text to fix, Whisper unloads and Ollama gets the prompt and the key terms as the system message, at temperature 0.2 with thinking off, and keeps its model for 2 minutes. If it fails, the dictation keeps Whisper's text and records the error.
8. **Store.** `Store.insert` writes the dictation and its segments in one transaction, with the time each stage took (record, load, transcribe, fix, paste).
9. **Paste.** `Paster` saves the clipboard, sets the text, sends Cmd+V with the modifier flags set outright (so an Option still held from the shortcut changes nothing), waits half a second and restores the clipboard if it still holds the text. Without Accessibility the text stays on the clipboard and a notice offers Allow.

At launch the app opens the history, prunes it, lists the inputs off the main thread, starts the MCP server and polls Ollama every 30 seconds. If setup is complete it loads Whisper ahead of the first dictation and recovers recordings: each WAV with no history row, oldest first, one at a time and only while Voice is otherwise idle. A recovered recording has its header rewritten from the file's length, is transcribed without pasting, and is dated by its file name.

At quit, the app stops the live session, closes the recording (kept, not deleted) and unloads Whisper, because ggml's Metal device asserts at exit while a model still holds it.

## A call

1. **Detect.** Every second `CallDetector` lists the processes using audio and credits each helper process to the app responsible for it. A call starts when a call app uses the microphone for 5 seconds, or a browser uses both microphone and speakers for 10. It ends once the app has used neither for 15 seconds. Voice, Blend, OpenSuperWhisper, Siri and macOS dictation are never calls.
2. **Prompt.** If Ask to record calls is on, nothing is recording and the app wasn't dismissed, `CallsModel` shows "Record this call?" in a panel that never takes focus. Not now lasts until that app's call ends. The call shortcut (Option+Shift+` unless changed) and the menu start a recording at any time, with or without a call app, and an agent can start one over MCP. A recording started for a call app ends with its call; one started with none runs until stopped. While it records, a second pill under the dictation one shows the clock and the key that stops it, and the menu bar glyph has all its pills filled and a dot.
3. **Source.** `CallSources.all` lists what Settings offers under Record from: Blend's connected mixes from its `devices.json` (Blend's `docs/MIXES-FOR-APPS.md` describes it), then the system default, then the other inputs. A split mix is labelled with its sides, such as "Blend Mic (you left, call right)"; anything else is recorded as one channel and labelled "mix". Until one is chosen, `CallSources.automatic` takes the split mix if there is one and the system default otherwise, and a chosen input that isn't connected falls back to the same, with a notice. In a split mix, a microphone is Me and an app or system sound is Call, whichever side Blend put them on. Two of a kind take their sources' names.
4. **Start.** `CallRecorder` points an engine at the source's device and taps it in the device's own format. A split source has to arrive as exactly two channels. If it doesn't, the call is created, failed with the reason and kept, and the same error is thrown. Otherwise the call is a row in `calls` with status recording and the WAV's path.
5. **Ingest.** On the tap's thread `CallSession` writes the WAV at the device's rate. A split call has Me on the left and Call on the right, whatever order the device used. For each side it takes that channel (or the average of all, for a mix that isn't split), brings it to 16 kHz and feeds a `SpeechChunker`.
6. **Chunk.** A frame is speech when it is 12 dB above a floor that falls at once and rises 0.3 dB a second, and above minus 50 dBFS. A chunk keeps 0.3 seconds before the speech and 0.2 after, ends after 0.5 seconds of quiet (0.25 once it passes 5 seconds), is cut at 15 seconds regardless, and is dropped if it has under 0.25 seconds of speech.
7. **Transcribe.** One worker takes the chunks of both sides in the order they were cut and decodes each on the shared `Transcriber`, with the key terms and the same side's previous text as the prompt. It appends the segments to `CallStore` as each chunk is done. A segment's times are the chunk's offset in the call plus Whisper's own.
8. **Read.** An agent waiting with a cursor sees a segment within half a second of its being written. The menu copies the transcript.
9. **Stop.** From the call shortcut, the menu, `stop_recording`, or when the tracker says the call app's call is over. The engine stops, the status becomes transcribing, both chunkers flush their open speech, and the worker finishes. The call is then done, or failed with the reason. A write error outranks a transcription error.
10. **Compress.** A done call's WAV is encoded as AAC beside it, 48 kbps a channel at the WAV's rate and channels (about 45 MB an hour of stereo against 690 MB). The encoder's output is checked: same channels and rate, a length within 0.5 seconds of the WAV's, and the first 4096 frames decode. Only then does the call point at the `.m4a` and the WAV go. This runs at low priority, after the call's words are in.
11. **If the input goes away.** The engine stops, and the call is finished as failed with "The input went away", keeping the WAV and the transcript so far. A configuration change that leaves the engine running changes nothing: the recording goes on.
12. **At launch.** Calls still marked live whose audio exists are rebuilt: `CallRecorder.rebuild` reads the WAV (header repaired first) or the `.m4a`, runs it through a session with no file, and replaces the segments once the first chunk has decoded. Other live calls are failed. Then every done call still holding a WAV is compressed.

Quitting during a call closes the WAV without waiting for the transcript and leaves the call marked recording. Quitting stays quick, and the next launch rebuilds it.

## Storage

- `voice.sqlite` holds everything: `dictations` and `segments` (Store), `calls`, `call_segments`, `call_tags` and the `transcript_search` index (CallStore), `segment_retries` and `retry_references`, and `voice_migrations`. Store runs the migrations too, so a process that opens only Store finds the schema current.
- Every store opens its own connection to the file: the app's history, the call recorder's, the MCP server's and voice-cli's. The journal is WAL, a writer waits up to 5 seconds for another, and a transaction that reads before it writes begins immediate, so another process can't overtake it between the two.
- CallStore opens Store first, so the dictation tables exist before the search index's triggers attach to them. Each migration is applied once and recorded by name. A shipped one never changes; a schema change is a new entry at the end.
- `transcript_search` is FTS5 (Porter stemming, no diacritics) over call segments and each dictation's final text, kept current by triggers. A search needs every word, and falls back to any word when nothing has them all.
- Foreign keys are off, so every delete names its children.
- Segment ids are AUTOINCREMENT, so an id is never reused after a delete. That is what lets one number work as a wait cursor across calls.
- Keep history set to 30 days deletes dictations and calls older than that, with their audio. It never deletes a call that is recording or transcribing, nor a dictation that is imported, nor an audio file a surviving row still uses.

## MCP

- One endpoint, `POST /mcp` on `127.0.0.1:7766`, JSON-RPC, one JSON answer per request. No event stream and no sessions, both of which the spec leaves optional, so a 60 second `wait_for_transcript` doesn't hold up anyone else.
- Every request needs the bearer token, from this Mac too. The comparison looks at every byte. If there is an `Origin` header, it has to be local or the request's own host, so a web page can't try. A body is limited to 4 MB with a token and 64 KB without, a batch to 10 messages, and a closed connection cancels its request.
- The app hosts it through `AgentAccess` while it runs. `voice-cli mcp` serves the same against the same file when it doesn't, and only one of the two can hold the port.
- Reads go to the database, often written by another process, so a wait looks at the file every 500 ms. `start_recording` and `stop_recording` go back into the app through `RecordingControl`, which `CallsModel` implements; voice-cli has none and answers with an error.
- If you set up Tailscale Serve, it puts HTTPS on your tailnet and reaches the server from `127.0.0.1`, so to the server a tailnet agent looks local. The token is what keeps other devices out.

[MCP.md](MCP.md) has the addresses, the tools and the call store's tables.

## Rules the code keeps

**No Core Audio on the main thread.** When coreaudiod stops answering, every Core Audio call blocks until it does. On the main thread that freezes the menu bar; on a queue of its own, it stalls one recording.

- `Recorder` and `CallRecorder` run every device call on their own serial queues, and their `start` and `stop` are async.
- `CallDetector` polls on its own queue.
- The app lists devices, chooses a call source and reads a mix's readers in detached tasks (`refreshDevices`, `refreshSources`, `checkMixReaders`).
- The tap's thread converts, writes and cuts chunks. It never waits for Whisper, which has its own queue.

**One whisper decode at a time.** A whisper.cpp context can't run two, and a second model on the GPU is more than a 16 GB Mac has.

- Every `Transcriber` runs its decodes on one serial queue they share (`voice.whisper`). Live dictation chunks and their retries, a whole-file decode, recovery, a call's chunks, a rebuild and the idle references all go through it, so they queue behind each other. Dictating during a call waits behind the call's pieces.
- The reference pass runs only with nothing recording, ten minutes without input, mains power, no memory pressure and no Ollama model loaded. A recording, or any input, stops its decode within a decoding step, and its model unloads when it stops.
- The app has one pipeline, and so one transcriber, per Whisper model. While a call uses Whisper, `currentPipeline` keeps handing out the same one, and `chooseWhisperModel` refuses a switch.
- Recovery at launch starts a file only while the app is idle.

**Whisper unloads before Ollama.** On a 16 GB Mac, Whisper's GPU memory plus a large model's is more than Metal allows. Ollama's runner then fails every request until its model is unloaded, and it can answer 200 with an empty, unfinished reply.

- `Pipeline.run` calls `unload` before it asks Ollama. Reloading Whisper takes about 0.4 seconds once the file is cached.
- Ollama keeps its model for 2 minutes only, which covers a run of dictations and then gives the memory back.
- A call's next chunk would reload Whisper while Ollama holds its model, so a dictation skips the fix while a call is using Whisper. The menu says "Whisper only during calls".

**The WAV is the source of truth until a call is converted.** A WAV is written as the audio arrives and stays readable however the app ends. Everything else is derived from it and can be made again.

- A call's transcript can be rebuilt from its WAV alone, which is why Me is always on the left whatever order the device used.
- The header of a WAV is final only once the file is closed. After a crash it still says the file is empty, so `Recovery.repairHeader` rewrites its sizes from the file's length. Only a WAV needs this.
- The `.m4a` replaces the WAV only after it opens with the same channels and rate, a length within 0.5 seconds and audio that decodes. On any failure the WAV and the call's path stay, the failure is logged (`log show --predicate 'category == "call-audio"'`) and the next launch tries again.
- Quitting doesn't wait for a conversion, and a conversion cut off by a quit leaves the WAV.
- A dictation's WAV is never converted. It is the record, and a failed transcription is tried again from it.

Smaller rules:

- Every recording gets a history row and its file is kept. A failure, a recording too short to transcribe or a quit mid-recording never deletes audio, and there is no Escape.
- Live text never covers audio the file lacks: samples go to `LiveTranscription` after the write.
- A write error is kept. Nothing is written after it, so the file stays whole, and a call that has one is failed with it. A dictation reports it.
- A call ends only after 15 seconds with neither input nor output, so a mute or a device switch doesn't make two recordings.
- A split call that doesn't arrive as two channels fails at once, since it would otherwise end as a finished call with a side missing.
- A rebuild keeps the call's old segments until its first chunk has decoded, so audio or a model that can't be read leaves the transcript it had.
- Only Voice reads the Blend mix it records. Blend leaves any app reading a mix out of that mix's System audio, so a call app set to it would be missing from the call side. Voice warns when one is.

## Choices

- **whisper.cpp's prebuilt framework.** It has Metal and its shaders built in, so the app and voice-cli link one binary and run the same decode.
- **The chunks are the dictation.** A whole-file decode on top would wait out the fix step's model and hold Whisper's queue against the next dictation. The file stays the record, and a failed chunk falls back to it.
- **A loudness gate to cut chunks, with Silero inside the decode.** Cutting only has to find a pause, not judge speech. Whisper's own voice activity detection still drops the silence in each chunk.
- **50 words of context, not all of it.** Whisper keeps the end of a long prompt and drops its start, which is where the key terms are.
- **A server on Network.framework rather than the MCP Swift SDK.** The SDK's HTTP transports leave the listener to the host, and its stateless one matches answers to requests by JSON-RPC id alone, so two agents sending the same id at once would get each other's answers.
- **Polling the file for new segments.** The writer may be another process, so nothing in memory can say a segment landed. One indexed query every 500 ms is cheap.
- **AAC after the transcript, not instead of the WAV.** A WAV survives any ending, and an hour of 48 kHz stereo is 690 MB. AAC at 48 kbps a channel keeps speech clear at about a sixteenth of that.
- **Key terms on, the fix off.** On a set of 39 real dictations the key terms took names from 5 of 13 to 9 of 13 for no added time. The fix reached 13 of 13 for a median 2.3 seconds more and 13 seconds at the 95th percentile, which is too slow for every dictation. The fix's default model is `qwen3.5:9b`, which runs at about 40 tokens a second in 7.7 GB on a 16 GB MacBook Air. The key terms start empty: the names worth listing are your own.
- **One shortcut to start and stop, and nothing else stops.** No stray key can throw a recording away. A call has a shortcut of its own, so dictating during a call never ends it.
- **The hardened runtime in Release only.** It won't load the embedded Whisper framework under a self-signed certificate, so Debug builds go without it. Releases are signed with a Developer ID and notarized, with it on.

## Limits

- Calls are detected from a fixed list of call apps and browsers. An app that isn't on it is never offered, though an agent can start a recording for it.
- One call is recorded at a time.
- A call has two sides, Me and Call, not one name for each person on the call.
- The language is one setting, for dictation and calls alike.
- The call path has no accuracy measurement of its own.
- The MCP server is up only while Voice runs. When Voice is closed the tailnet address returns 502.

## Tests

`cd Core && swift test` covers the store and its index, segment retries and their records, the references and the retry report, the cursor and the wait, the MCP server and its limits, call source choice, call detection, channel handling, rebuild, AAC conversion, the chunkers, recovery, input loss and write errors, the fix step and the pipeline, and the OpenSuperWhisper import. Ollama is stubbed with a `URLProtocol`. The tests that need Whisper run only when `VOICE_TEST_WHISPER_MODEL` points at a model.

`voice-cli` is the manual side. `call --file` plays a stereo WAV as a live call, `fake-call` writes a call that gains a segment every 2 seconds, and `watch-calls --raw` prints call detection and every process using audio. `live` compares the live chunks with a whole-file decode.
