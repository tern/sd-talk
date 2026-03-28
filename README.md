# sd-talk

Offline voice chat on Linux handheld/Desktop:

- microphone input via PipeWire
- speech-to-text via `whisper.cpp`
- LLM via `llama-server` inside `distrobox`
- text-to-speech via Piper

## Files

- `sd-talk.sh`: interactive voice chat loop
- `start-llm.sh`: start `llama-server`
- `stop-llm.sh`: stop `llama-server`
- `status-llm.sh`: show whether `llama-server` is running
- `llm-common.sh`: shared LLM startup/shutdown helpers

## Setup

1. Copy `config.example` to `~/.config/sd-talk/config`
2. Adjust model paths and language settings
3. Run `./setup.sh` if Piper is not installed yet

## Usage

Start the model server only:

```bash
./start-llm.sh
```

Check server status:

```bash
./status-llm.sh
```

Stop the model server:

```bash
./stop-llm.sh
```

Run voice chat and stop the model server on exit if this session started it:

```bash
./sd-talk.sh
```

Run voice chat but keep the model server alive after exit:

```bash
./sd-talk.sh --keep-llm
```

## Notes

- `sd-talk.sh` reuses an already-running `llama-server` on the configured port.
- Without `--keep-llm`, `sd-talk.sh` only stops the server if it started that server itself.
- Startup logs go to `/tmp/llama-server.log` by default.
