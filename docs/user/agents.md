# Agents

Agent access is off until you turn it on in Settings, Agents (an install that already had it on keeps it). While it is on, Dictate serves dictations and call transcripts over MCP at `http://127.0.0.1:7766/mcp`. Only this Mac can reach it. Every request carries the token in `~/Library/Application Support/Dictate/mcp-token`. To add it to Claude Code:

```sh
claude mcp add --transport http --scope user dictate http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Dictate/mcp-token)"
```

Show Config in the Agents settings opens the same command and a JSON config, with your address and token filled in. Copy setup message copies a message for Claude or another agent that says what to install. Start a new session afterwards so the tools appear. The token works like a password for your transcripts.

An agent can never start a recording; only you can. An agent can list, search and read your online calls and dictations. It can follow a live call with `wait_for_transcript`. More tools are off until you turn them on. They tag calls and set titles. They also stop a recording or import an audio file (see [Import](./import.md)). `dictate-cli mcp` serves the same thing when the app isn't running. [MCP.md](../MCP.md) has every tool.

The server listens on `127.0.0.1` unless you change the host in the Agents settings. It answers nothing without the token. The same page turns the server off and changes the port. It copies or regenerates the token (agents holding the old one stop working). It also switches each tool on or off. These tools start off: `stop_recording`, `correct_*`, `add_key_terms`, `remove_key_terms`, `tag_call`, `set_recording_title`, `undo_edit` and `import_audio_file`. They record or change something. Your agent reads what the other side of a call says, and that could steer it. A tool that is off is missing from the list agents see and refuses calls.
