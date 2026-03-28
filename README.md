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

Run voice chat in auto-listen mode:

```bash
./sd-talk.sh --auto --keep-llm
```

Run auto mode with a wake word:

```bash
WAKE_WORD="小幫手" ./sd-talk.sh --auto --keep-llm
```

## Auto mode tuning

`--auto` uses WebRTC VAD via the repo-local `.venv`.

Optional config values:

- `AUTO_RECORD_PYTHON`: Python interpreter for auto mode, defaults to `./.venv/bin/python`
- `WAKE_WORD`: optional wake word or phrase; if set, speech must begin with this phrase and the phrase is stripped before sending text to the LLM
- `WAKE_ARM_SECONDS`: legacy setting; the current behavior accepts the next utterance after a wake-only phrase
- `TTS_LEAD_IN_MS`: silence added before playback to avoid clipped opening syllables
- `VAD_MODE`: WebRTC aggressiveness from `0` to `3`; higher values reject more noise
- `VAD_START_FRAMES`: how many loud frames are needed before recording starts
- `VAD_SILENCE_FRAMES`: how many quiet frames stop a recording after speech started
- `VAD_MAX_SECONDS`: hard cap for one utterance
- `VAD_PRE_ROLL_FRAMES`: how much audio to keep just before speech start
- `INTERRUPT_TTS`: set to `1` to allow user speech to interrupt playback in auto mode
- `INTERRUPT_VAD_MODE`: VAD aggressiveness used only while monitoring for interruption
- `INTERRUPT_START_FRAMES`: speech frames needed to interrupt playback
- `INTERRUPT_SILENCE_FRAMES`: quiet frames needed to finish an interruption utterance
- `INTERRUPT_MAX_SECONDS`: max recording window per interruption attempt
- `INTERRUPT_PRE_ROLL_FRAMES`: pre-roll kept for interruption capture

## Notes

- `sd-talk.sh` reuses an already-running `llama-server` on the configured port.
- Without `--keep-llm`, `sd-talk.sh` only stops the server if it started that server itself.
- Startup logs go to `/tmp/llama-server.log` by default.
- Auto mode is resident: after each response it goes back to listening automatically.
- In auto mode, playback can be interrupted by speaking again.
