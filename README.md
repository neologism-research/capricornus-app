# Capricornus iOS

An iOS companion app for the Capricornus ESP32 hardware device. The app acts as an AI voice backend — it receives audio from the ESP32 over WebSocket, runs speech recognition, sends the transcript to an LLM, and plays the synthesised response back through both the iPhone speaker and the ESP32.

## How it works

```
ESP32 (mic) → WebSocket (port 8080) → iPhone
                                         ↓
                                  Apple Speech STT
                                         ↓
                                  DeepSeek Chat API
                                         ↓
                                  Apple TTS (AVSpeech)
                                         ↓
                              iPhone speaker + ESP32 speaker
```

1. The ESP32 connects to `ws://<iPhone-local-IP>:8080` and streams 16kHz mono PCM audio.
2. The app uses Voice Activity Detection (VAD) events from the ESP32 to detect speech start/end.
3. After 800 ms of silence, the buffered audio is transcribed using Apple's on-device Speech framework (Mandarin `zh-Hans`).
4. The transcript is sent to the DeepSeek chat API with an optional GPS location in the system prompt.
5. The LLM response is synthesised to speech using `AVSpeechSynthesizer` and resampled to 16kHz int16 PCM.
6. Audio is played on the iPhone and streamed back to the ESP32 in 1920-byte (60 ms) chunks.

---

## Building

**Requirements**
- Xcode 16+
- iOS 17+ deployment target
- Physical iPhone (microphone + AVAudioEngine required; Simulator will not work)

**Steps**
1. Open `capricornus-ios.xcodeproj` in Xcode.
2. Set your development team under **Signing & Capabilities**.
3. Build and run on a physical device.
4. On first launch, grant Microphone, Speech Recognition, and Location permissions when prompted.

**Required Info.plist keys** (add if missing)

| Key | Example value |
|-----|---------------|
| `NSMicrophoneUsageDescription` | "Needed to capture audio from the ESP32 microphone." |
| `NSSpeechRecognitionUsageDescription` | "Used to transcribe speech from the ESP32." |
| `NSLocationWhenInUseUsageDescription` | "Optionally included in the AI context for navigation." |

> The current `Info.plist` does not include the location key — location requests will silently fail until it is added.

---

## Configuration

All runtime settings are in the in-app **Settings** panel (gear icon):

| Setting | Storage key | Required |
|---------|-------------|----------|
| DeepSeek API key | `deepseek_api_key` (UserDefaults) | Yes |
| System prompt | `system_prompt` (UserDefaults) | No (defaults to indoor navigation prompt) |

The app also shows the iPhone's local IPv4 address in Settings — give this to the ESP32 firmware so it knows where to connect.

---

## Connecting the ESP32

1. Make sure the iPhone and ESP32 are on the same Wi-Fi network.
2. Open Settings in the app and note the **Local IP** address.
3. Flash that IP into the ESP32 firmware as the WebSocket target (`ws://<IP>:8080`).
4. The app listens on **port 8080** automatically when launched.

WebSocket handshake the ESP32 must send:
```json
{ "type": "hello", "version": 1 }
```
The app replies with session config (16kHz, 1ch, PCM, 60ms frames) and begins accepting binary audio frames.

---

## File reference

### Active

| File | Purpose |
|------|---------|
| `capricornus_iosApp.swift` | App entry point; keeps screen on during demo |
| `ContentView.swift` | Main UI — connection status, debug log, settings modal |
| `BackendServer.swift` | Core orchestrator: WebSocket → STT → LLM → TTS pipeline |
| `LLMService.swift` | Three-stage pipeline: Apple STT → DeepSeek chat → Apple TTS |
| `WebSocketServer.swift` | TCP/WebSocket server on port 8080; handles ESP32 protocol |
| `LocationManager.swift` | Wraps `CLLocationManager`, publishes GPS coordinate |
| `LiveAudioPlayer.swift` | Jitter-buffered real-time playback of ESP32 audio on iPhone speaker |

### Not currently used

| File | Notes |
|------|-------|
| `QwenOmniService.swift` | Alternative speech-to-speech backend using Alibaba Qwen3 Omni. Fully implemented but not wired into `BackendServer`. |
| `QwenAudioPlayer.swift` | Simple `AVAudioPlayer` wrapper — `BackendServer` plays audio directly instead. |
| `AudioConverter.swift` | WAV header builder and MP3→PCM converter — logic is duplicated inline elsewhere. |

### Declared but unused dependency

**WhisperKit** is listed as a Swift package in `project.pbxproj` but is never imported. The app uses Apple's built-in `Speech` framework instead. It can be removed from the project without impact.

---

## Known issues / TODOs

- `NSLocationWhenInUseUsageDescription` missing from `Info.plist` — add it for GPS to work.
- WhisperKit package dependency is declared but unused — safe to remove.
- `QwenOmniService` provides a speech-to-speech alternative to the current DeepSeek pipeline but needs to be wired into `BackendServer` to be usable.
- System prompt is hardcoded for indoor navigation in Chinese — expose language selection if other use cases are needed.
