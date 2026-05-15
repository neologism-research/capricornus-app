//
//  ContentView.swift
//  capricornus-ios
//
//  Created by Mac on 10/5/2026.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var backend: BackendServer

    @State private var apiKey: String = UserDefaults.standard.string(forKey: "deepseek_api_key") ?? ""
    @State private var textInput: String = ""
    @State private var systemPrompt: String = "你是一个室内导航助手。请用普通话简洁清晰地引导用户。每次回答不超过两句话。"
    @State private var showSettings = false

    init() {
        let lm = LocationManager()
        _locationManager = StateObject(wrappedValue: lm)
        _backend = StateObject(wrappedValue: BackendServer(locationManager: lm))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    StatusRow(label: "Status", value: backend.status, color: backend.isConnected ? .green : .orange)
                    StatusRow(label: "ESP32", value: backend.isConnected ? "Connected" : "Disconnected", color: backend.isConnected ? .green : .red)
                    StatusRow(label: "STT", value: backend.whisperStatus, color: backend.whisperStatus == "Ready" ? .green : (backend.whisperStatus.hasPrefix("Mic") || backend.whisperStatus.hasPrefix("Failed") ? .red : .orange))
                    Button(action: { backend.toggleLivePlay() }) {
                        HStack {
                            Image(systemName: backend.isLivePlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            Text(backend.isLivePlaying ? "Live Audio: ON" : "Live Audio: OFF")
                        }
                        .foregroundStyle(backend.isLivePlaying ? .green : .secondary)
                    }
                }

                Section {
                    Button(action: { backend.toggleManualListen() }) {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: backend.isManualRecording ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(backend.isManualRecording ? .red : (backend.isConnected ? .blue : .secondary))
                                Text(backend.isManualRecording ? "Tap to Stop" : "Force Listen")
                                    .font(.caption)
                                    .foregroundStyle(backend.isManualRecording ? .red : .secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(!backend.isConnected)
                }

                Section("GPS") {
                    if let coord = locationManager.coordinate {
                        StatusRow(label: "Latitude", value: String(format: "%.6f", coord.latitude))
                        StatusRow(label: "Longitude", value: String(format: "%.6f", coord.longitude))
                    } else {
                        StatusRow(label: "Location", value: "Waiting...", color: .orange)
                    }
                }

                Section(header: HStack {
                    Text("Debug Log")
                    Spacer()
                    Button("Clear") { backend.logs.removeAll() }.font(.caption)
                }) {
                    if backend.logs.isEmpty {
                        Text("No logs yet").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(backend.logs, id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                }

                Section("Text Query") {
                    HStack {
                        TextField("Type a message...", text: $textInput)
                            .autocorrectionDisabled()
                        Button("Send") {
                            backend.sendTextQuery(textInput)
                            textInput = ""
                        }
                        .disabled(textInput.isEmpty)
                    }
                }

                Section("Last Conversation") {
                    if !backend.lastTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("User").font(.caption).foregroundStyle(.secondary)
                            Text(backend.lastTranscript)
                        }
                    }
                    if !backend.lastResponse.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Assistant").font(.caption).foregroundStyle(.secondary)
                            Text(backend.lastResponse)
                        }
                    }
                }
            }
            .navigationTitle("Capricornus Backend")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(apiKey: $apiKey, systemPrompt: $systemPrompt) {
                    backend.updateAPIKey(apiKey)
                    backend.updateSystemPrompt(systemPrompt)
                }
            }
            .onAppear {
                backend.start()
            }
        }
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Binding var systemPrompt: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek API Key") {
                    SecureField("sk-...", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                }
                Section {
                    Text("ESP32 should connect to ws://\(localIPAddress()):8080")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private func localIPAddress() -> String {
    var address = "unknown"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return address }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let current = ptr {
        let flags = Int32(current.pointee.ifa_flags)
        let isUp = (flags & IFF_UP) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        if isUp && !isLoopback {
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: host)
            }
        }
        ptr = current.pointee.ifa_next
    }
    return address
}

#Preview {
    ContentView()
}
