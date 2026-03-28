# sd-talk

Offline voice chat on Linux handheld/Desktop:

- microphone input via PipeWire
- speech-to-text via `whisper.cpp`
- LLM via `llama-server` inside `distrobox`
- text-to-speech via Piper

## Files

- `sd-talk.sh`: interactive voice chat loop
- `sd-talk-daemon.py`: background controller for hotkeys and one-shot invocations
- `sd-talk-hotkey.py`: Steam Deck button listener
- `sd-talkctl.py`: simple client for the daemon socket
- `vibevoice-tts-backend.py`: placeholder backend entrypoint for future VibeVoice TTS integration
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

Select the TTS backend explicitly:

```bash
TTS_BACKEND=piper ./sd-talk.sh --auto --keep-llm
```

Run a single auto interaction and exit:

```bash
./sd-talk.sh --once --keep-llm
```

## Steam Deck L4 Hotkey

The repo includes a daemon and a Steam Deck hotkey listener:

- map `L4` to keyboard `F12` in Steam Input
- short press `L4`/`F12`: toggle resident auto mode
- long press `L4`/`F12` for about 1 second: interrupt or stop the current session
- desktop notifications and a short system sound confirm each action
- on KDE/X11, the listener grabs `F12` globally; evdev is only used as a fallback

Manual control:

```bash
./.venv/bin/python sd-talk-daemon.py
./.venv/bin/python sd-talkctl.py status
./.venv/bin/python sd-talkctl.py toggle_auto
./.venv/bin/python sd-talkctl.py interrupt
```

### User services

Install the provided user service files:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/sd-talk-daemon.service ~/.config/systemd/user/
cp systemd/sd-talk-hotkey.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sd-talk-daemon.service sd-talk-hotkey.service
```

If you want a different key or timing, override these environment variables in the hotkey service:

- `SD_TALK_TRIGGER_KEYSYM`: defaults to `F12` for the X11 global hotkey path
- `SD_TALK_EVENT_DEVICE`: optional single input device override for the evdev fallback path
- `SD_TALK_TRIGGER_KEY_CODE`: defaults to `88` for `KEY_F12`
- `SD_TALK_LONG_PRESS_SECONDS`: defaults to `1.0`
- `SD_TALK_SOUND_AUTO_ON`: defaults to `message-new-instant`
- `SD_TALK_SOUND_AUTO_OFF`: defaults to `service-logout`
- `SD_TALK_SOUND_INTERRUPT`: defaults to `bell`

## Auto mode tuning

`--auto` uses WebRTC VAD via the repo-local `.venv`.

Optional config values:

- `TTS_BACKEND`: `piper` or `vibevoice`; default is `piper`
- `VIBEVOICE_TTS_BIN`: backend entrypoint used when `TTS_BACKEND=vibevoice`; default is `./vibevoice-tts-backend.py`
- `VIBEVOICE_MODEL`: optional model identifier/path passed to the VibeVoice backend script
- `AUTO_RECORD_PYTHON`: Python interpreter for auto mode, defaults to `./.venv/bin/python`
- `WAKE_WORD`: optional wake word or phrase; if set, speech must begin with this phrase and the phrase is stripped before sending text to the LLM
- `WAKE_ARM_SECONDS`: legacy setting; the current behavior accepts the next utterance after a wake-only phrase
- `TTS_LEAD_IN_MS`: silence added before playback to avoid clipped opening syllables; default is `250`
- `VAD_MODE`: WebRTC aggressiveness from `0` to `3`; higher values reject more noise
- `VAD_START_FRAMES`: how many loud frames are needed before recording starts
- `VAD_SILENCE_FRAMES`: how many quiet frames stop a recording after speech started; default is `6`
- `VAD_MAX_SECONDS`: hard cap for one utterance
- `VAD_PRE_ROLL_FRAMES`: how much audio to keep just before speech start
- `INTERRUPT_TTS`: set to `1` to allow user speech to interrupt playback in auto mode
- `INTERRUPT_VAD_MODE`: VAD aggressiveness used only while monitoring for interruption
- `INTERRUPT_START_FRAMES`: speech frames needed to interrupt playback
- `INTERRUPT_SILENCE_FRAMES`: quiet frames needed to finish an interruption utterance
- `INTERRUPT_MAX_SECONDS`: max recording window per interruption attempt
- `INTERRUPT_PRE_ROLL_FRAMES`: pre-roll kept for interruption capture

Wake-only acknowledgements are cached under `~/.cache/sd-talk/tts` and are prewarmed in the background when auto mode starts, so repeated wake-ups respond faster.

At the moment, the `vibevoice` path is only a stub interface. The main script can switch backends cleanly, but actual VibeVoice inference still needs to be implemented inside [vibevoice-tts-backend.py](/home/deck/sd-talk/vibevoice-tts-backend.py).

## Notes

- `sd-talk.sh` reuses an already-running `llama-server` on the configured port.
- Without `--keep-llm`, `sd-talk.sh` only stops the server if it started that server itself.
- Startup logs go to `/tmp/llama-server.log` by default.
- Auto mode is resident: after each response it goes back to listening automatically.
- In auto mode, playback can be interrupted by speaking again.
