//
//  AssetWriter.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit
import os

/// Writes captured mic + system audio to a two-track .m4a. Video frames are discarded.
final class AssetWriter: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?

    private(set) var isWriting = false
    private(set) var outputURL: URL?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "AssetWriter")

    private var hasStartedSession = false
    private var sessionStartTime: CMTime = .zero

    private let lock = OSAllocatedUnfairLock()

    // MARK: - Setup

    func setup(url: URL, settings: SettingsStore) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)

        guard let assetWriter else {
            throw AssetWriterError.failedToCreateWriter
        }

        if settings.captureSystemAudio {
            let audioSettings = createAudioSettings(from: settings)
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
        }

        if settings.captureMicrophone {
            let micSettings = createAudioSettings(from: settings)
            microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            microphoneInput?.expectsMediaDataInRealTime = true
            if let microphoneInput, assetWriter.canAdd(microphoneInput) {
                assetWriter.add(microphoneInput)
            }
        }

        outputURL = url
        hasStartedSession = false
        sessionStartTime = .zero

        logger.info("AssetWriter configured for output: \(url.lastPathComponent)")
    }

    // MARK: - Writing

    func startWriting() throws {
        guard let assetWriter, assetWriter.status == .unknown else {
            throw AssetWriterError.writerNotReady
        }
        guard assetWriter.startWriting() else {
            throw AssetWriterError.failedToStartWriting(assetWriter.error)
        }
        isWriting = true
        logger.info("AssetWriter started writing")
    }

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let audioInput,
                audioInput.isReadyForMoreMediaData
            else { return }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !hasStartedSession {
                assetWriter.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                hasStartedSession = true
                logger.info("Session started at time: \(presentationTime.seconds)")
            }

            if !audioInput.append(sampleBuffer) {
                logger.error("Failed to append audio sample buffer")
            }
        }
    }

    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let microphoneInput,
                microphoneInput.isReadyForMoreMediaData
            else { return }

            if !microphoneInput.append(sampleBuffer) {
                logger.error("Failed to append microphone sample buffer")
            }
        }
    }

    // MARK: - Finalization

    func finishWriting() async throws -> URL {
        let (writerToFinish, url): (AVAssetWriter, URL)

        do {
            (writerToFinish, url) = try lock.withLockUnchecked {
                guard let assetWriter, isWriting else {
                    throw AssetWriterError.writerNotReady
                }
                guard let url = outputURL else {
                    throw AssetWriterError.noOutputURL
                }
                logger.info(
                    "Finishing writing - status: \(assetWriter.status.rawValue), session started: \(self.hasStartedSession)"
                )
                guard hasStartedSession else {
                    logger.error("No audio samples were written — session was never started")
                    throw AssetWriterError.noFramesWritten
                }
                audioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                return (assetWriter, url)
            }
        } catch AssetWriterError.noFramesWritten {
            cancel()
            throw AssetWriterError.noFramesWritten
        }

        await writerToFinish.finishWriting()

        return try lock.withLockUnchecked {
            guard let assetWriter else {
                throw AssetWriterError.writerNotReady
            }
            if assetWriter.status == .failed {
                let error = assetWriter.error
                logger.error("AssetWriter failed: \(error?.localizedDescription ?? "unknown error")")
                throw AssetWriterError.writingFailed(error)
            }
            isWriting = false
            hasStartedSession = false
            logger.info("AssetWriter finished writing to: \(url.lastPathComponent)")
            self.assetWriter = nil
            self.audioInput = nil
            self.microphoneInput = nil
            return url
        }
    }

    func cancel() {
        lock.withLockUnchecked {
            assetWriter?.cancelWriting()
            isWriting = false
            hasStartedSession = false
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            assetWriter = nil
            audioInput = nil
            microphoneInput = nil
            outputURL = nil
            logger.info("AssetWriter cancelled")
        }
    }

    // MARK: - Settings Helpers

    private func createAudioSettings(from settings: SettingsStore) -> [String: Any] {
        switch settings.audioCodec {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]
        case .pcm:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }
}

// MARK: - CaptureEngineSampleBufferDelegate

extension AssetWriter {

    func captureEngine(
        _ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        // Audio-only mode: video frames discarded
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendAudioSample(sampleBuffer)
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendMicrophoneSample(sampleBuffer)
    }
}

// MARK: - Errors

enum AssetWriterError: LocalizedError {
    case failedToCreateWriter
    case writerNotReady
    case failedToStartWriting(Error?)
    case writingFailed(Error?)
    case noOutputURL
    case noFramesWritten

    var errorDescription: String? {
        switch self {
        case .failedToCreateWriter:
            return "Failed to create the asset writer."
        case .writerNotReady:
            return "The asset writer is not ready for writing."
        case .failedToStartWriting(let error):
            return "Failed to start writing: \(error?.localizedDescription ?? "Unknown error")"
        case .writingFailed(let error):
            return "Writing failed: \(error?.localizedDescription ?? "Unknown error")"
        case .noOutputURL:
            return "No output URL was configured."
        case .noFramesWritten:
            return "No audio samples were captured. Check screen recording permissions."
        }
    }
}
