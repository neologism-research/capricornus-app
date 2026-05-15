import Foundation
import AVFoundation

class QwenOmniService {
    var apiKey: String
    var systemPrompt: String
    var audioOutputEnabled: Bool = false

    private let endpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!

    init(apiKey: String, systemPrompt: String = "你是一个智能助手。请用普通话简洁清晰地回答。每次回答不超过两句话。") {
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
    }

    struct Response {
        let text: String
        let audioPCM: Data  // raw int16 16kHz mono PCM
    }

    // Audio input: send PCM as WAV, get text + audio back
    func processAudio(_ pcmData: Data) async throws -> Response {
        let wav = makeWAV(pcm: pcmData, sampleRate: 16000)
        let b64 = "data:audio/wav;base64," + wav.base64EncodedString()
        let userContent: [[String: Any]] = [
            ["type": "input_audio", "input_audio": ["data": b64, "format": "wav"]]
        ]
        return try await send(userContent: userContent)
    }

    // Text input: send text, get text + audio back
    func processText(_ text: String) async throws -> Response {
        let userContent: [[String: Any]] = [
            ["type": "text", "text": text]
        ]
        return try await send(userContent: userContent)
    }

    private func send(userContent: [[String: Any]]) async throws -> Response {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": "qwen3-omni-flash",
            "messages": [
                ["role": "system", "content": [["type": "text", "text": systemPrompt]]],
                ["role": "user", "content": userContent]
            ],
            "modalities": audioOutputEnabled ? ["text", "audio"] : ["text"],
            "stream": true
        ]
        if audioOutputEnabled {
            body["audio"] = ["voice": "Cherry", "format": "wav"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw QwenError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        var fullText = ""
        var audioData = Data()
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        for line in lines {
            guard line.hasPrefix("data: "), !line.contains("[DONE]") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let chunkData = jsonStr.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                  let choices = chunk["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let content = delta["content"] as? String { fullText += content }
            // Decode each chunk's base64 separately to avoid padding issues from concatenation
            if let audioObj = delta["audio"] as? [String: Any],
               let b64 = audioObj["data"] as? String,
               let chunkBytes = Data(base64Encoded: b64) {
                audioData.append(chunkBytes)
            }
        }

        return Response(text: fullText.trimmingCharacters(in: .whitespacesAndNewlines), audioPCM: audioData)
    }

    // Build a minimal PCM WAV header
    private func makeWAV(pcm: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(littleEndian: chunkSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(littleEndian: UInt32(16))       // subchunk1 size
        wav.append(littleEndian: UInt16(1))         // PCM format
        wav.append(littleEndian: channels)
        wav.append(littleEndian: UInt32(sampleRate))
        wav.append(littleEndian: byteRate)
        wav.append(littleEndian: blockAlign)
        wav.append(littleEndian: bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        wav.append(littleEndian: dataSize)
        wav.append(pcm)
        return wav
    }

    enum QwenError: LocalizedError {
        case httpError(Int, String)
        case unexpectedResponse(String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body): return "HTTP \(code): \(body)"
            case .unexpectedResponse(let msg): return "Bad response: \(msg)"
            }
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }
}
