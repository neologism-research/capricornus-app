import AVFoundation

class LiveAudioPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Jitter buffer: accumulate at least 300ms before scheduling to avoid
    // starvation gaps from 10ms micro-packet delivery
    private var jitterBuffer = [Float]()
    private let jitterThreshold = 4800  // 300ms at 16kHz — absorbs Wi-Fi burst delay
    private let scheduleChunk = 9600    // schedule 600ms at a time to minimise overhead

    private(set) var isPlaying = false

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("[LiveAudioPlayer] Session error: \(error)")
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: playbackFormat)

        do {
            try eng.start()
            node.play()
            engine = eng
            playerNode = node
            jitterBuffer.removeAll(keepingCapacity: true)
            isPlaying = true
        } catch {
            print("[LiveAudioPlayer] Engine start error: \(error)")
        }
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        jitterBuffer.removeAll()
        isPlaying = false
    }

    func feed(_ data: Data) {
        guard isPlaying, let node = playerNode, let eng = engine, eng.isRunning else { return }
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }

        // Convert incoming int16 PCM to float and append to jitter buffer
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<sampleCount {
                jitterBuffer.append(Float(src[i]) * scale)
            }
        }

        // Only schedule once we have enough to fill the jitter threshold,
        // then drain in large chunks to keep scheduleBuffer calls low
        guard jitterBuffer.count >= jitterThreshold else { return }

        let frames = min(jitterBuffer.count, scheduleChunk)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let dst = buffer.floatChannelData?[0] {
            for i in 0..<frames { dst[i] = jitterBuffer[i] }
        }
        jitterBuffer.removeFirst(frames)
        node.scheduleBuffer(buffer, completionHandler: nil)
    }
}
