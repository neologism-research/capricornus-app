import AVFoundation

class QwenAudioPlayer {
    private var audioPlayer: AVAudioPlayer?
    private var sessionConfigured = false

    func play(_ data: Data) {
        guard !data.isEmpty else { return }
        if !sessionConfigured {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                sessionConfigured = true
            } catch {
                print("[QwenAudioPlayer] Session error: \(error.localizedDescription)")
            }
        }
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            print("[QwenAudioPlayer] Playback error: \(error.localizedDescription)")
        }
    }
}
