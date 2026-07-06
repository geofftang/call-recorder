//
//  SettingsView.swift
//  Call Recorder
//

import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsView(settings: settings)
            }

            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsView()
            }

            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
        }
        .frame(width: 420, height: 280)
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Sources") {
                Toggle("Capture System Audio", isOn: $settings.captureSystemAudio)
                    .help("Record audio output from apps (the other side of the call)")

                Toggle("Capture Microphone", isOn: $settings.captureMicrophone)
                    .help("Record your mic (your side of the call)")
            }

            Section("Format") {
                Picker("Codec", selection: $settings.audioCodec) {
                    Text("AAC (compressed, smaller files)").tag(AudioCodec.aac)
                    Text("PCM (lossless, larger files)").tag(AudioCodec.pcm)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section("Recording") {
                KeyboardShortcuts.Recorder("Toggle Recording", name: .toggleRecording)
            }

            Section {
                Text("Shortcut works globally, even when Call Recorder is not focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    private static let recordingsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/executive-function-test/domains/recordings")

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(Self.recordingsDir)
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("~/…/domains/recordings")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "v\(appVersion) (dev)")
                LabeledContent("Source") {
                    Link("github.com/geofftang/call-recorder",
                         destination: URL(string: "https://github.com/geofftang/call-recorder")!)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    SettingsView(settings: SettingsStore())
}
