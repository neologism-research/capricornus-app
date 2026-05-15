import Foundation
import CoreLocation
import Combine
import AVFoundation

@MainActor
class BackendServer: ObservableObject {
    @Published var status = "Not started"
    @Published var isConnected = false
    @Published var lastTranscript = ""
    @Published var lastResponse = ""
    @Published var logs: [String] = []
    @Published var isLivePlaying = false
    @Published var isManualRecording = false
    @Published var whisperStatus = "Starting..."

    private let wsServer = WebSocketServer()
    private var llm: LLMService
    private let locationManager: LocationManager
    private let livePlayer = LiveAudioPlayer()
    private var ttsPlayer: AVAudioPlayer?

    // Audio buffering — gated by ESP32 AFE VAD events or manual button
    private var pcmBuffer = Data()
    private var isProcessing = false
    private var isRecording = false
    private var isTTSActive = false          // true while TTS audio is playing/sending
    private var silenceTimer: Task<Void, Never>? = nil
    private var lastSpeechDate = Date.distantPast  // updated on every speech event
    private var pendingAudio: Data? = nil  // speech captured while isProcessing, replayed after

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        print(entry)
        DispatchQueue.main.async { [weak self] in
            self?.logs.insert(entry, at: 0)
            if (self?.logs.count ?? 0) > 100 { self?.logs.removeLast() }
        }
    }

    init(locationManager: LocationManager) {
        self.locationManager = locationManager
        let savedKey = UserDefaults.standard.string(forKey: "deepseek_api_key") ?? ""
        let savedPrompt = UserDefaults.standard.string(forKey: "system_prompt") ?? "你是一个室内导航助手。请用普通话简洁清晰地引导用户。每次回答不超过两句话。"
        self.llm = LLMService(apiKey: savedKey, systemPrompt: savedPrompt)
        self.llm.onStatusUpdate = { [weak self] status in
            DispatchQueue.main.async { self?.whisperStatus = status }
        }
        self.llm.startModelLoad()
    }

    func updateAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "deepseek_api_key")
        llm.apiKey = key
    }

    func updateSystemPrompt(_ prompt: String) {
        UserDefaults.standard.set(prompt, forKey: "system_prompt")
        llm.systemPrompt = prompt
    }

    func toggleLivePlay() {
        if livePlayer.isPlaying { livePlayer.stop() } else { livePlayer.start() }
        isLivePlaying = livePlayer.isPlaying
    }

    func sendTextQuery(_ text: String) {
        guard !text.isEmpty, !isProcessing else { return }
        Task { await processText(text) }
    }

    // MARK: - Manual force-listen button

    func toggleManualListen() {
        if isManualRecording {
            // Second tap: stop and process what we captured
            isManualRecording = false
            isRecording = false
            let captured = pcmBuffer
            pcmBuffer = Data()
            log("Manual: stopped — captured \(captured.count) bytes")
            if isProcessing {
                pendingAudio = captured
            } else {
                Task { await self.processAudio(captured) }
            }
        } else {
            // First tap: start recording, bypass VAD
            silenceTimer?.cancel()  // stop any in-flight VAD watcher
            silenceTimer = nil
            isManualRecording = true
            isRecording = true
            pcmBuffer = Data()
            log("Manual: recording started")
        }
    }

    func start() {
        wsServer.onLog = { [weak self] message in self?.log(message) }

        wsServer.onVadState = { [weak self] speaking in
            guard let self = self else { return }
            guard !self.isManualRecording else { return }
            guard !self.isTTSActive else { return }  // ignore mic during TTS playback

            if speaking {
                self.lastSpeechDate = Date()
                if !self.isRecording {
                    self.log("VAD: speech start — recording\(self.isProcessing ? " (buffering)" : "")")
                    self.isRecording = true
                    self.pcmBuffer = Data()
                }
                self.ensureSilenceWatcher()
            } else {
                // Don't cancel the watcher — just let it measure elapsed time from lastSpeechDate
                if self.isRecording {
                    self.ensureSilenceWatcher()
                }
            }
        }

        wsServer.onClientConnected = { [weak self] in
            self?.log("ESP32 connected")
            DispatchQueue.main.async { self?.isConnected = true; self?.status = "ESP32 connected" }
            self?.pcmBuffer = Data(); self?.isRecording = false; self?.isManualRecording = false
            self?.silenceTimer?.cancel(); self?.silenceTimer = nil
        }

        wsServer.onClientDisconnected = { [weak self] in
            self?.log("ESP32 disconnected")
            DispatchQueue.main.async { self?.isConnected = false; self?.status = "Waiting for ESP32..." }
            self?.pcmBuffer = Data(); self?.isRecording = false; self?.isManualRecording = false
            self?.silenceTimer?.cancel(); self?.silenceTimer = nil
        }

        wsServer.onAudioFrame = { [weak self] data in
            self?.livePlayer.feed(data)
            self?.handleAudioFrame(data)
        }

        do {
            try wsServer.start(port: 8080)
            log("WebSocket server started on port 8080")
            DispatchQueue.main.async { self.status = "Waiting for ESP32..." }
        } catch {
            log("Failed to start server: \(error)")
        }
    }

    // MARK: - Silence watcher

    // Polls every 200ms; fires processAudio once lastSpeechDate is 800ms old.
    // Speech events update lastSpeechDate but never cancel this task, so rapid
    // speech/silence toggling can't starve the pipeline.
    private func ensureSilenceWatcher() {
        guard silenceTimer == nil else { return }
        silenceTimer = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                guard self.isRecording else { self.silenceTimer = nil; return }
                guard -self.lastSpeechDate.timeIntervalSinceNow >= 1.5 else { continue }
                // 800ms of no speech
                self.silenceTimer = nil
                self.isRecording = false
                let captured = self.pcmBuffer
                self.pcmBuffer = Data()
                self.log("VAD: 800ms silence — captured \(captured.count) bytes")
                if self.isProcessing {
                    self.log("VAD: queued for after current pipeline")
                    self.pendingAudio = captured
                } else {
                    Task { await self.processAudio(captured) }
                }
                return
            }
        }
    }

    // MARK: - Audio pipeline

    private func playOnIphone(_ pcm: Data) {
        let wav = makeWAV(pcm: pcm)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            ttsPlayer = try AVAudioPlayer(data: wav)
            ttsPlayer?.play()
        } catch {
            log("TTS playback error: \(error.localizedDescription)")
        }
    }

    private func makeWAV(pcm: Data, sampleRate: Int = 16000) -> Data {
        let dataSize = UInt32(pcm.count)
        var wav = Data()
        func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: MemoryLayout<T>.size)) }
        wav.append(contentsOf: "RIFF".utf8); le(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8); wav.append(contentsOf: "fmt ".utf8)
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(UInt32(sampleRate)); le(UInt32(sampleRate * 2)); le(UInt16(2)); le(UInt16(16))
        wav.append(contentsOf: "data".utf8); le(dataSize); wav.append(pcm)
        return wav
    }

    private func handleAudioFrame(_ data: Data) {
        guard isRecording else { return }
        pcmBuffer.append(data)
    }

    // MARK: - Full pipeline: STT → DeepSeek → TTS → ESP32

    private func processAudio(_ pcmData: Data) async {
        guard !llm.apiKey.isEmpty else {
            log("No DeepSeek API key set"); await MainActor.run { status = "No API key" }; return
        }
        guard pcmData.count > 16000 else {
            log("Audio too short (\(pcmData.count) bytes = \(pcmData.count/32)ms), ignoring"); return
        }
        isProcessing = true
        defer {
            isProcessing = false
            if let queued = pendingAudio {
                pendingAudio = nil
                log("Replaying buffered speech (\(queued.count) bytes)")
                Task { await self.processAudio(queued) }
            }
        }

        do {
            await MainActor.run { status = "Transcribing..." }
            log("Transcribing \(pcmData.count) bytes...")
            let transcript = try await llm.transcribe(pcmData: pcmData)
            guard !transcript.isEmpty else {
                log("Empty transcript, skipping")
                await MainActor.run { status = "ESP32 connected" }
                return
            }
            log("Transcript: \(transcript)")
            await MainActor.run { lastTranscript = transcript; status = "Thinking..." }

            let response = try await llm.chat(transcript: transcript, coordinate: locationManager.coordinate)
            log("Response: \(response)")
            await MainActor.run { lastResponse = response; status = "Speaking..." }

            await MainActor.run { status = "ESP32 connected" }

            // TTS fires after pipeline is unblocked — play on iPhone and send to ESP32
            Task {
                do {
                    let pcmResponse = try await self.llm.synthesize(text: response)
                    self.log("TTS: \(pcmResponse.count) bytes → iPhone + ESP32")
                    self.isTTSActive = true
                    self.wsServer.sendJSON("{\"type\":\"tts\",\"state\":\"start\"}")
                    self.playOnIphone(pcmResponse)
                    let totalChunks = (pcmResponse.count + 1919) / 1920
                    let stopDelay = totalChunks * 60 + 1500
                    self.wsServer.sendPCM(pcmResponse)
                    try? await Task.sleep(nanoseconds: UInt64(stopDelay) * 1_000_000)
                    self.wsServer.sendJSON("{\"type\":\"tts\",\"state\":\"stop\"}")
                    // Extra 800ms buffer — ESP32 speaker rings out after last chunk
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.isTTSActive = false
                    self.log("TTS: playback window closed, mic re-enabled")
                } catch {
                    self.isTTSActive = false
                    self.log("TTS error: \(error.localizedDescription)")
                }
            }
        } catch {
            log("Pipeline error: \(error.localizedDescription)")
            await MainActor.run { status = "Error: \(error.localizedDescription)" }
        }
    }

    private func processText(_ text: String) async {
        guard !llm.apiKey.isEmpty else { log("No DeepSeek API key set"); return }
        isProcessing = true
        defer { isProcessing = false }
        log("Text query: \(text)")
        await MainActor.run { lastTranscript = text; status = "Thinking..." }
        do {
            let response = try await llm.chat(transcript: text, coordinate: locationManager.coordinate)
            log("Response: \(response)")
            await MainActor.run { lastResponse = response; status = "Ready" }
        } catch {
            log("Error: \(error.localizedDescription)")
            await MainActor.run { status = "Error: \(error.localizedDescription)" }
        }
    }
}
