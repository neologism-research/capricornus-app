import AVFoundation
import Foundation

struct AudioConverter {

    // Prepend a standard 44-byte WAV header to raw int16 PCM bytes
    static func makeWAV(pcmData: Data, sampleRate: Int32 = 16000, channels: Int16 = 1) -> Data {
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate) * Int32(channels) * Int32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = Int32(pcmData.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(littleEndian: Int32(16))      // subchunk size
        header.append(littleEndian: Int16(1))       // PCM format
        header.append(littleEndian: channels)
        header.append(littleEndian: sampleRate)
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        header.append(littleEndian: dataSize)
        header.append(pcmData)
        return header
    }

    // Decode MP3/AAC data to raw int16 PCM at 16kHz mono
    static func mp3ToPCM16(mp3Data: Data) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try mp3Data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let sourceFile = try AVAudioFile(forReading: tempURL)
        let sourceFormat = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)

        guard let sourceBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw ConversionError.bufferAllocationFailed
        }
        try sourceFile.read(into: sourceBuf)

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ConversionError.converterCreationFailed
        }

        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * 16000.0 / sourceFormat.sampleRate) + 1
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw ConversionError.bufferAllocationFailed
        }

        var inputConsumed = false
        let status = converter.convert(to: outputBuf, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuf
        }

        guard status != .error, let int16Ptr = outputBuf.int16ChannelData else {
            throw ConversionError.conversionFailed
        }

        let byteCount = Int(outputBuf.frameLength) * 2
        return Data(bytes: int16Ptr[0], count: byteCount)
    }

    enum ConversionError: Error {
        case bufferAllocationFailed
        case converterCreationFailed
        case conversionFailed
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
