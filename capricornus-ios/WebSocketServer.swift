import Network
import Foundation

class WebSocketServer {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "websocket-server")

    var onAudioFrame: ((Data) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onVadState: ((Bool) -> Void)?  // true = speech, false = silence
    var onLog: ((String) -> Void)?

    private func log(_ message: String) {
        print(message)
        onLog?(message)
    }

    func start(port: UInt16 = 8080) throws {
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log("[WebSocketServer] Listener failed: \(error)")
            case .ready:
                self?.log("[WebSocketServer] Listening on port \(port)")
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    func stop() {
        activeConnection?.cancel()
        listener?.cancel()
        activeConnection = nil
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        // Drop any existing connection — one ESP32 at a time
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onClientConnected?()
                self?.receive(from: connection)
            case .failed, .cancelled:
                self?.onClientDisconnected?()
                if self?.activeConnection === connection {
                    self?.activeConnection = nil
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if let error = error {
                log("[WebSocketServer] Receive error: \(error)")
                self.onClientDisconnected?()
                return
            }
            if let data = data, !data.isEmpty,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .binary:
                    self.onAudioFrame?(data)
                case .text:
                    if let text = String(data: data, encoding: .utf8) {
                        log("[WebSocketServer] Received text: \(text)")
                        if text.contains("\"type\":\"hello\"") {
                            self.replyHello(to: connection)
                        } else if text.contains("\"type\":\"vad\"") {
                            let speaking = text.contains("\"state\":\"speech\"")
                            self.log("[WebSocketServer] VAD: \(speaking ? "speech" : "silence")")
                            self.onVadState?(speaking)
                        }
                    }
                default:
                    break
                }
            }
            self.receive(from: connection)
        }
    }

    private func replyHello(to connection: NWConnection) {
        let hello = """
        {"type":"hello","session_id":"iphone-backend","version":1,"transport":"websocket","audio_params":{"format":"pcm","sample_rate":16000,"channels":1,"frame_duration":60}}
        """
        guard let data = hello.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hello", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        log("[WebSocketServer] Sent hello reply")
    }

    func sendJSON(_ json: String) {
        guard let connection = activeConnection, let data = json.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "json", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func sendPCM(_ pcmData: Data) {
        guard let connection = activeConnection else { return }
        let chunkSize = 1920  // 960 samples × 2 bytes = 60ms at 16kHz
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "pcm-response", metadata: [metadata])
            connection.send(content: chunk, contentContext: context, isComplete: true, completion: .idempotent)
            offset += chunkSize
        }
    }
}
