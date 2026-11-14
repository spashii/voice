# Dictate over MCP

Agents read dictations and call transcripts through an MCP server, live calls included. Claude Code, Codex or any MCP client on this Mac can connect. Your other devices can too if you set up Tailscale.

| From | Address |
| --- | --- |
| This Mac | `http://127.0.0.1:7766/mcp` |
| Your tailnet, once you set up Tailscale Serve | `https://<your Mac's tailnet name>:8443/mcp` |

Every request carries `Authorization: Bearer <token>`, from this Mac too; without it the answer is 401.

## Who serves it

Dictate hosts the server while it runs, unless "Agents can read transcripts" in the Agents settings is off. That page sets the host and port (the server restarts when they change), copies or regenerates the token, copies the setup for an agent app, and switches each tool on or off. Agent access is off for a new install and stays on for an install that had it on. The tools that stop a recording or change stored data are off until someone turns them on (existing choices are kept). No tool starts a recording. A tool that is off is missing from `tools/list` and refuses `tools/call`, for agents already connected too. When Dictate isn't running nothing answers, and the tailnet address returns 502.

`dictate-cli mcp` serves the same thing without the app, against the same database:

```sh
Core/.build/release/dictate-cli mcp            # [--port N] [--db PATH]
```

Only one of the two can hold port 7766; the second to start reports that the port is in use. `dictate-cli mcp` listens on 127.0.0.1 only.

## The token

`~/Library/Application Support/Dictate/mcp-token`: 32 random bytes in hex, mode 0600, made by whichever of the app or `dictate-cli mcp` starts first. To change it, press Regenerate in the Agents settings. With `dictate-cli mcp` alone, delete the file and restart it. Every client then needs the new one.

To add Dictate to Claude Code on this Mac:

```sh
claude mcp add --transport http --scope user dictate http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Dictate/mcp-token)"
```

The server reports `"name": "dictate"` and `"title": "Dictate"` in `serverInfo`. A client registered as `voice` keeps working.

From another device, use the tailnet address instead, and keep the token in that device's own secret store rather than in a shell history.

## The tailnet (optional)

Nothing leaves the Mac unless you do this. Tailscale Serve can forward HTTPS on port 8443 to the server, inside your tailnet only (Serve, not Funnel, so nothing is public). Run these on the Mac:

```sh
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
$TS serve --bg --https=8443 http://127.0.0.1:7766    # on; persists across restarts
$TS serve status                                      # what is served
$TS serve --https=8443 off                            # off
$TS status --json | jq -r .Self.DNSName               # your Mac's tailnet name
```

Serve terminates TLS and connects from 127.0.0.1, so the token is what keeps other tailnet devices out. Point Serve at the port set in Settings, Agents.

## Tools

| Tool | Does |
| --- | --- |
| `list_calls` | calls newest first; `since`, `tag`, `limit` |
| `get_call` | one call, its tags and segment count |
| `get_transcript` | `id` (or `current`), `channel` all, me, call or mix, `format` text or segments |
| `current_call` | the call being recorded, and the cursor to wait from |
| `wait_for_transcript` | `call_id` (default `current`), `cursor`, `timeout_s` up to 60: new segments and the next cursor |
| `search_transcripts` | full text over call segments and dictations; `query`, `limit` |
| `tag_call` | `id`, `add`, `remove` |
| `set_recording_title` | `id`, `title`: sets a call's or dictation's title, trimmed, up to 100 characters. It replaces any title, including one the user set, and is recorded as an edit that `undo_edit` reverts |
| `import_audio_file` | `path` (absolute, or starting with `~/`): imports an audio or video file from this Mac as one call and returns it at once with `status` transcribing and `file_name`, for `wait_for_transcript` by its id. The transcript is one track (channel mix, no Me or Call labels). Types: m4a, mp3, wav, aif, aiff, aifc, caf, aac, flac, m4b, mp4, mov, m4v; up to 2 GB. A file imported before returns its earlier call with `already_imported` true. Only the app can, so `dictate-cli mcp` answers with an error |
| `list_dictations` | dictations newest first; `since`, `limit` |
| `get_dictation` | one dictation with raw and final text, timings and segments, and `fix_edits` when Fix the text before pasting ran: each edit's segment, span, replacement, key_term, offset, and rejected with the reason when it wasn't applied |
| `stop_recording` | stops the call recording in progress and returns it once the last words are transcribed; agents can't start a recording, only a person can; only the app can stop one, so `dictate-cli mcp` answers with an error |
| `correct_dictation` | `id`, `text`: stores the correction beside the dictation's text, which reads and search then return with `corrected: true` and `original_text`, and pastes nothing |
| `correct_segment` | `call_id`, `segment_id` (the `id` from `get_transcript` in format segments), `text`: the same for one segment of a call |
| `list_key_terms` | the key terms from Settings, with the tokens they take of whisper's prompt, counted with whisper.cpp's tokenizer, and its limit of 224 |
| `add_key_terms` | `terms`: adds those not already listed in any case, refusing the whole add when the prompt would pass 224 tokens and naming the tokens left and the terms that fit |
| `remove_key_terms` | `terms`: removes them from the list, matching without case |
| `list_key_term_suggestions` | `status` pending (the default), accepted, dismissed or all, `limit`: the key terms Dictate proposed from corrections, each the words a correction put where whisper wrote others, with how whisper heard them, the correction it came from and its status; only Add in Settings puts one in the list, recorded as an `add_key_terms` edit, and Dismiss as a `dismiss_key_term` edit |
| `list_edits` | `since`, `target`, `limit`: every correction, key-term change and tag change agents made, and the corrections a person made in History (client `You`), newest first, with time, client, kind, target, before and after |
| `undo_edit` | `id`: reverts one edit, putting a correction back to the text before it and a key-term or tag change back as it was, and records the undo as an edit |

`since` takes ISO 8601 (`2026-11-04T09:00:00Z`, or `2026-11-04` for local midnight) or a span back from now (`90m`, `24h`, `7d`).

Resources: `call://current/transcript` and `call://{id}/transcript`, both sides merged by time as `[mm:ss] Me: ...` and `[mm:ss] Call: ...`.

To follow a live call, take the cursor from `current_call`, then call `wait_for_transcript` with it again and again, passing back the cursor each answer returns, until `ended` is true. A wait returns as soon as a segment lands (the server looks every 500 ms), when the call ends, or at the timeout with no segments and the same cursor.

## The call store

`CallStore` (Core) keeps calls in `voice.sqlite` beside the dictations:

- `calls`: id, started_at, ended_at, app_bundle_id, app_name, device_uid, split, audio_path, status (recording, transcribing, done, failed), title, title_source, file_name, error. `audio_path` names the call's WAV while it records and, once the transcript is complete, its .m4a. Times are seconds since 1970, as for dictations. `title_source` says who set the title: `auto`, `user` or `agent`, and null when nobody has. An automatic title only fills a call with neither a title nor a source. Dictations have the same two columns.
- `call_segments`: id, call_id, channel (me, call, mix), start_ms and end_ms from the start of the call, text, avg_logprob, no_speech_prob, compression_ratio, created_at. The id is AUTOINCREMENT: it rises across all calls and is never reused, which makes it the wait cursor.
- `call_tags`: call_id, tag (compared without case).
- `transcript_search`: an FTS5 index over segment text and each dictation's final text, kept current by triggers on `call_segments` and `dictations`.
- `voice_migrations`: the names of the migrations applied. A schema change is a new name at the end of `CallStore.migrations`; a shipped one never changes.

The recorder writes with `createCall`, `appendSegments`, `markTranscribing`, `finishCall`, `failCall`, `setTitle` and `tagCall`, and calls `failInterruptedCalls` at launch so a call cut off by a crash stops counting as current. The app's titler writes with `setAutoTitle`.

`CallRecorder` (Core) writes each call to `~/Library/Application Support/Dictate/calls/<ms>-<id>.wav` at the device's rate, me on the left and the call on the right, and transcribes each side at its pauses while the call runs. While the call records the WAV is the source of truth: at launch the app takes the calls still marked live, fails them with `failInterruptedCalls`, then rebuilds their transcripts from the file (`dictate-cli call --rebuild ID` does the same by hand). When a call's status becomes `done`, `CallAudio` re-encodes the WAV as AAC (`<ms>-<id>.m4a`, the WAV's own sample rate and channels, 48 kbps a channel, about 45 MB an hour of stereo against 690 MB), checks that the .m4a opens with the WAV's channels and a duration within 0.5 s, then points the call at it and deletes the WAV. If any step fails the WAV and the path stay and the failure is logged (`log show --predicate 'category == "call-audio"'`); the app retries at the next launch. Rebuild reads either format. Settings, Data retention deletes old calls and their audio as it does dictations (audio after 7 days and history after 30 by default, nothing while Developer mode is on); calls still recording or transcribing are never deleted. Me is the microphone and Call is the call app's sound (every helper process of a browser included), both from one BlendKit capture (`CallCapturing`; BlendKit is Blend Mic's engine, pinned to its 0.9.0 release in `Core/Package.swift` and `app/project.yml`, resolved in `Core/Package.resolved`) at 48 kHz and the same instants; a Blend mix is read as one two-channel device instead. `CallPlanner` picks them from the call audio choice in Settings, Microphones, and falls back to the microphone alone when the app can't be captured or the System Audio Recording permission is denied. The capture's events (the app's sound lost or silent, the microphone missing) become notices and never end the call. With an app as Call, BlendKit cancels the call's echo from Me when Settings, Microphones, Cancel echo from the call is on.

## Testing

```sh
cd Core && swift test                                   # store, index, cursor, server, source, chunker
.build/release/dictate-cli call --file stereo.wav         # plays a WAV as a live call: left me, right call
.build/release/dictate-cli call --remove                  # deletes those test calls and their audio
.build/release/dictate-cli watch-calls --raw              # call detection, and every process using audio
.build/release/dictate-cli fake-call                      # a live call, a segment every 2 s; prints its id
.build/release/dictate-cli fake-call --remove             # deletes every call fake-call wrote
```

```sh
curl -s -X POST http://127.0.0.1:7766/mcp \
  -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Dictate/mcp-token)" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"current_call","arguments":{}}}'
```

The server is written on Network.framework rather than the MCP Swift SDK: the SDK's HTTP transports leave the listener to the host, and its stateless one matches answers to requests by JSON-RPC id alone, so two agents sending the same id at once would get each other's answers.
