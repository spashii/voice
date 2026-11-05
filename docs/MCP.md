# Voice over MCP

Agents read dictations and call transcripts, live calls included, through an MCP server: Claude Code, Codex or any MCP client on this Mac, and, if you choose, on your other devices over Tailscale.

| From | Address |
| --- | --- |
| This Mac | `http://127.0.0.1:7766/mcp` |
| Your tailnet, once you set up Tailscale Serve | `https://<your Mac's tailnet name>:8443/mcp` |

Every request carries `Authorization: Bearer <token>`, from this Mac too; without it the answer is 401.

## Who serves it

Voice hosts the server while it runs, unless Settings, General, "Agents can read transcripts" is off. That row shows both addresses and copies the token. When Voice isn't running nothing answers, and the tailnet address returns 502.

`voice-cli mcp` serves the same thing without the app, against the same database:

```sh
Core/.build/release/voice-cli mcp            # [--port N] [--db PATH]
```

Only one of the two can hold port 7766; the second to start reports that the port is in use. The server listens on 127.0.0.1 only.

## The token

`~/Library/Application Support/Voice/mcp-token`: 32 random bytes in hex, mode 0600, made by whichever of the app or `voice-cli mcp` starts first. To change it, delete the file and restart whatever serves; every client then needs the new one.

To add Voice to Claude Code on this Mac:

```sh
claude mcp add --transport http --scope user voice http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Voice/mcp-token)"
```

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

Serve terminates TLS and connects from 127.0.0.1, so the token is what keeps other tailnet devices out. Voice's Settings show the tailnet address once Serve forwards to it.

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
| `list_dictations` | dictations newest first; `since`, `limit` |
| `get_dictation` | one dictation with raw and final text, timings and segments |
| `start_recording`, `stop_recording` | record a call from the source in Settings, Calls, and stop it once the last words are transcribed; only the app can, so `voice-cli mcp` answers with an error |
| `correct_dictation` | `id`, `text`: stores the correction beside the dictation's text, which reads and search then return with `corrected: true` and `original_text`, and pastes nothing |
| `correct_segment` | `call_id`, `segment_id` (the `id` from `get_transcript` in format segments), `text`: the same for one segment of a call |
| `list_key_terms` | the key terms from Settings, with the tokens they take of whisper's prompt, counted with whisper.cpp's tokenizer, and its limit of 224 |
| `add_key_terms` | `terms`: adds those not already listed in any case, refusing the whole add when the prompt would pass 224 tokens and naming the tokens left and the terms that fit |
| `remove_key_terms` | `terms`: removes them from the list, matching without case |
| `list_edits` | `since`, `target`, `limit`: every correction, key-term change and tag change agents made, newest first, with time, client, kind, target, before and after |
| `undo_edit` | `id`: reverts one edit, putting a correction back to the text before it and a key-term or tag change back as it was, and records the undo as an edit |

`since` takes ISO 8601 (`2026-11-04T09:00:00Z`, or `2026-11-04` for local midnight) or a span back from now (`90m`, `24h`, `7d`).

Resources: `call://current/transcript` and `call://{id}/transcript`, both sides merged by time as `[mm:ss] Me: ...` and `[mm:ss] Call: ...`.

To follow a live call, take the cursor from `current_call`, then call `wait_for_transcript` with it again and again, passing back the cursor each answer returns, until `ended` is true. A wait returns as soon as a segment lands (the server looks every 500 ms), when the call ends, or at the timeout with no segments and the same cursor.

## The call store

`CallStore` (Core) keeps calls in `voice.sqlite` beside the dictations:

- `calls`: id, started_at, ended_at, app_bundle_id, app_name, device_uid, split, audio_path, status (recording, transcribing, done, failed), title, error. `audio_path` names the call's WAV while it records and, once the transcript is complete, its .m4a. Times are seconds since 1970, as for dictations.
- `call_segments`: id, call_id, channel (me, call, mix), start_ms and end_ms from the start of the call, text, avg_logprob, no_speech_prob, compression_ratio, created_at. The id is AUTOINCREMENT: it rises across all calls and is never reused, which makes it the wait cursor.
- `call_tags`: call_id, tag (compared without case).
- `transcript_search`: an FTS5 index over segment text and each dictation's final text, kept current by triggers on `call_segments` and `dictations`.
- `voice_migrations`: the names of the migrations applied. A schema change is a new name at the end of `CallStore.migrations`; a shipped one never changes.

The recorder writes with `createCall`, `appendSegments`, `markTranscribing`, `finishCall`, `failCall`, `setTitle` and `tagCall`, and calls `failInterruptedCalls` at launch so a call cut off by a crash stops counting as current.

`CallRecorder` (Core) writes each call to `~/Library/Application Support/Voice/calls/<ms>-<id>.wav` at the device's rate, me on the left and the call on the right, and transcribes each side at its pauses while the call runs. While the call records the WAV is the source of truth: at launch the app takes the calls still marked live, fails them with `failInterruptedCalls`, then rebuilds their transcripts from the file (`voice-cli call --rebuild ID` does the same by hand). When a call's status becomes `done`, `CallAudio` re-encodes the WAV as AAC (`<ms>-<id>.m4a`, the WAV's own sample rate and channels, 48 kbps a channel, about 45 MB an hour of stereo against 690 MB), checks that the .m4a opens with the WAV's channels and a duration within 0.5 s, then points the call at it and deletes the WAV. If any step fails the WAV and the path stay and the failure is logged (`log show --predicate 'category == "call-audio"'`); the app retries at the next launch. Rebuild reads either format. Settings, Keep history, 30 days deletes calls older than that, with their audio, as it does dictations; calls still recording or transcribing are never deleted. The source is the input chosen in Settings, Calls, Record from; until one is chosen, the split Blend mix from `~/Library/Application Support/Blend/devices.json`, else the system default input as one channel.

## Testing

```sh
cd Core && swift test                                   # store, index, cursor, server, source, chunker
.build/release/voice-cli call --file stereo.wav         # plays a WAV as a live call: left me, right call
.build/release/voice-cli call --remove                  # deletes those test calls and their audio
.build/release/voice-cli watch-calls --raw              # call detection, and every process using audio
.build/release/voice-cli fake-call                      # a live call, a segment every 2 s; prints its id
.build/release/voice-cli fake-call --remove             # deletes every call fake-call wrote
```

```sh
curl -s -X POST http://127.0.0.1:7766/mcp \
  -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Voice/mcp-token)" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"current_call","arguments":{}}}'
```

The server is written on Network.framework rather than the MCP Swift SDK: the SDK's HTTP transports leave the listener to the host, and its stateless one matches answers to requests by JSON-RPC id alone, so two agents sending the same id at once would get each other's answers.
