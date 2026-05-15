import Foundation
import CoreLocation
import AVFoundation
import Speech

class LLMService {
    var apiKey: String
    var systemPrompt: String
    var onStatusUpdate: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))

    init(apiKey: String, systemPrompt: String = "你是一个室内导航助手。请用普通话简洁清晰地引导用户。每次回答不超过两句话。") {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
    }

    func startModelLoad() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized: self?.onStatusUpdate?("Ready")
                case .denied:     self?.onStatusUpdate?("Mic permission denied")
                case .restricted: self?.onStatusUpdate?("STT restricted")
                default:          self?.onStatusUpdate?("STT unavailable")
                }
            }
        }
    }

    // On-device STT via SFSpeechRecognizer (Mandarin zh-Hans)
    func transcribe(pcmData: Data) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw LLMError.speechRecognizerUnavailable
        }

        // Near-silence guard
        let samples = pcmData.count / 2
        guard samples > 0 else { return "" }
        let rms: Float = pcmData.withUnsafeBytes { ptr -> Float in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress else { return 0 }
            var sum: Float = 0
            for i in 0..<samples { let f = Float(src[i]) / 32768.0; sum += f * f }
            return sqrt(sum / Float(samples))
        }
        guard rms > 0.01 else { return "" }

        // Build float32 AVAudioPCMBuffer from int16 PCM (SFSpeechRecognizer needs float)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else {
            throw LLMError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples)
        pcmData.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.floatChannelData?[0] else { return }
            let scale: Float = 1.0 / 32768.0
            // Convert + DC removal
            var dcSum: Float = 0
            for i in 0..<samples { dst[i] = Float(src[i]) * scale; dcSum += dst[i] }
            let dc = dcSum / Float(samples)
            for i in 0..<samples { dst[i] -= dc }
            // Normalize to target RMS 0.1 — ESP32 mic is quiet; boosts signal for recognizer
            var sumSq: Float = 0
            for i in 0..<samples { sumSq += dst[i] * dst[i] }
            let curRMS = sqrt(sumSq / Float(samples))
            if curRMS > 0 {
                let gain = min(0.1 / curRMS, 8.0) // cap at ~18dB boost
                for i in 0..<samples { dst[i] = min(max(dst[i] * gain, -1.0), 1.0) }
            }
            // 10ms fade-in/out
            let rampLen = min(160, samples / 4)
            for i in 0..<rampLen {
                dst[i] *= Float(i) / Float(rampLen)
                dst[samples - 1 - i] *= Float(i) / Float(rampLen)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        // Use server-side recognition — much more accurate for zh-Hans than on-device model
        request.contextualStrings = [
            "导航", "电梯", "楼梯", "出口", "入口", "卫生间", "洗手间",
            "停车场", "大堂", "餐厅", "咖啡厅", "会议室", "办公室", "商店"
        ]
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text)
                } else if let error {
                    done = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // DeepSeek chat API (OpenAI-compatible format)
    func chat(transcript: String, coordinate: CLLocationCoordinate2D?) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var systemContent = systemPrompt
        if let coord = coordinate {
            systemContent += String(format: " The user's current GPS coordinates are: lat=%.7f, lng=%.7f.", coord.latitude, coord.longitude)
        }

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": systemContent],
                ["role": "user", "content": transcript]
            ],
            "max_tokens": 150
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.unexpectedResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // On-device TTS via AVSpeechSynthesizer → raw int16 PCM at 16kHz mono
    func synthesize(text: String) async throws -> Data {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        var collectedBuffers: [AVAudioPCMBuffer] = []

        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                if pcmBuffer.frameLength == 0 {
                    do {
                        let pcmData = try Self.convertBuffers(collectedBuffers)
                        continuation.resume(returning: pcmData)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    collectedBuffers.append(pcmBuffer)
                }
            }
        }
    }

    // Resample AVSpeechSynthesizer output (float32, varies Hz) → int16 16kHz mono
    private static func convertBuffers(_ buffers: [AVAudioPCMBuffer]) throws -> Data {
        guard let first = buffers.first else { return Data() }
        let sourceFormat = first.format
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LLMError.converterCreationFailed
        }

        let totalSourceFrames = buffers.reduce(0) { $0 + AVAudioFrameCount($1.frameLength) }
        let outputCapacity = AVAudioFrameCount(Double(totalSourceFrames) * 16000.0 / sourceFormat.sampleRate) + 1
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw LLMError.bufferCreationFailed
        }

        var bufferIndex = 0
        var frameOffset: AVAudioFrameCount = 0
        var inputExhausted = false

        let status = converter.convert(to: outputBuf, error: nil) { _, outStatus in
            while bufferIndex < buffers.count {
                let src = buffers[bufferIndex]
                let remaining = src.frameLength - frameOffset
                if remaining == 0 { bufferIndex += 1; frameOffset = 0; continue }
                guard let slice = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: remaining) else {
                    outStatus.pointee = .noDataNow; return nil
                }
                slice.frameLength = remaining
                for ch in 0..<Int(sourceFormat.channelCount) {
                    if let s = src.floatChannelData?[ch], let d = slice.floatChannelData?[ch] {
                        d.update(from: s.advanced(by: Int(frameOffset)), count: Int(remaining))
                    }
                }
                frameOffset += remaining
                outStatus.pointee = .haveData
                return slice
            }
            if !inputExhausted { inputExhausted = true; outStatus.pointee = .endOfStream }
            else { outStatus.pointee = .noDataNow }
            return nil
        }

        guard status != .error, let int16Ptr = outputBuf.int16ChannelData else {
            throw LLMError.conversionFailed
        }
        return Data(bytes: int16Ptr[0], count: Int(outputBuf.frameLength) * 2)
    }

    enum LLMError: LocalizedError {
        case speechRecognizerUnavailable
        case bufferCreationFailed
        case converterCreationFailed
        case conversionFailed
        case unexpectedResponse(String)

        var errorDescription: String? {
            switch self {
            case .speechRecognizerUnavailable: return "Speech recognizer not available"
            case .bufferCreationFailed:        return "Audio buffer creation failed"
            case .converterCreationFailed:     return "Audio converter creation failed"
            case .conversionFailed:            return "Audio conversion failed"
            case .unexpectedResponse(let msg): return "API error: \(msg)"
            }
        }
    }
}
