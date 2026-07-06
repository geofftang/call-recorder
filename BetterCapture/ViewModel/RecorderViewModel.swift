//
//  RecorderViewModel.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// The main view model managing recording state and coordination between services
@MainActor
@Observable
final class RecorderViewModel {

    // MARK: - Recording State

    enum RecordingState {
        case idle
        case recording
        case stopping
    }

    // MARK: - Published Properties

    private(set) var state: RecordingState = .idle
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: Error?
    private(set) var selectedContentFilter: SCContentFilter?

    /// The source rectangle for area selection (in display points, top-left origin)
    private(set) var selectedSourceRect: CGRect?

    /// The selected area in screen coordinates (bottom-left origin), used for the border frame overlay
    private var selectedScreenRect: CGRect?

    /// The screen on which the area selection was made
    private var selectedScreen: NSScreen?

    /// Whether the current selection is an area selection (as opposed to a picker selection)
    var isAreaSelection: Bool {
        selectedSourceRect != nil
    }

    var isRecording: Bool {
        state == .recording
    }

    var canStartRecording: Bool {
        selectedContentFilter != nil && state == .idle
    }

    var hasContentSelected: Bool {
        selectedContentFilter != nil
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Whether Presenter Overlay is currently active (camera composited into stream)
    private(set) var isPresenterOverlayActive = false

    // MARK: - Dependencies

    let settings: SettingsStore
    let audioDeviceService: AudioDeviceService
    let cameraDeviceService: CameraDeviceService
    let previewService: PreviewService
    let notificationService: NotificationService
    let permissionService: PermissionService
    private let captureEngine: CaptureEngine
    private let assetWriter: AssetWriter
    private let cameraSession = CameraSession()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "RecorderViewModel")

    // MARK: - Private Properties

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var videoSize: CGSize = .zero
    private let areaSelectionOverlay = AreaSelectionOverlay()
    private let selectionBorderFrame = SelectionBorderFrame()
    private let recordingOverlay = RecordingOverlayCoordinator()

    // MARK: - Initialization

    init() {
        self.settings = SettingsStore()
        self.audioDeviceService = AudioDeviceService()
        self.cameraDeviceService = CameraDeviceService()
        self.previewService = PreviewService()
        self.notificationService = NotificationService(settings: settings)
        self.permissionService = PermissionService()
        self.captureEngine = CaptureEngine()
        self.assetWriter = AssetWriter()

        captureEngine.delegate = self
        captureEngine.sampleBufferDelegate = assetWriter
        previewService.delegate = self
    }

    // MARK: - Permission Methods

    /// Requests required permissions on app launch, then auto-selects the primary display
    /// so recording is ready immediately without user picking content.
    func requestPermissionsOnLaunch() async {
        await permissionService.requestPermissions(includeMicrophone: settings.captureMicrophone)
        await autoSelectPrimaryDisplay()
    }

    /// Selects the primary display as the SCK content filter. Captures all system audio.
    func autoSelectPrimaryDisplay() async {
        guard let content = try? await SCShareableContent.current,
              let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        selectedContentFilter = filter
        try? await captureEngine.updateFilter(filter)
    }

    /// Refreshes the current permission states
    func refreshPermissions() {
        permissionService.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Toggles the recording state. If no content is selected, triggers the appropriate
    /// selection flow based on the user's content selection mode preference.
    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else if hasContentSelected {
            await startRecording()
        } else {
            // No content selected — trigger selection based on the user's preferred mode
            switch ContentSelectionMode.current {
            case .pickContent:
                presentPicker()
            case .selectArea:
                await presentAreaSelection()
            }
        }
    }

    /// Presents the system content sharing picker
    func presentPicker() {
        captureEngine.presentPicker()
    }

    /// Presents the area selection overlay on the display under the cursor
    func presentAreaSelection() async {
        // Dismiss any existing border frame so it doesn't overlap the selection overlay
        selectionBorderFrame.dismiss()

        guard let result = await areaSelectionOverlay.present() else {
            logger.info("Area selection cancelled")
            return
        }

        // Show the border frame immediately so the user sees the selection outline
        selectionBorderFrame.show(screenRect: result.screenRect)

        // Find the corresponding SCDisplay for the selected screen
        do {
            let content = try await SCShareableContent.current
            let screenNumber = result.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

            guard let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
                logger.error("Could not find SCDisplay for selected screen")
                return
            }

            // Create a content filter for the full display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Convert screen rect (NSScreen coordinates, bottom-left origin) to
            // sourceRect (display coordinates, top-left origin)
            let displayHeight = CGFloat(display.height)
            let screenOrigin = result.screen.frame.origin

            let localX = result.screenRect.origin.x - screenOrigin.x
            let localY = result.screenRect.origin.y - screenOrigin.y

            // Flip Y: NSScreen has origin at bottom-left, sourceRect uses top-left
            let flippedY = displayHeight - localY - result.screenRect.height

            // Snap dimensions to even pixel counts for codec compatibility
            let scale = result.screen.backingScaleFactor
            let pixelWidth = result.screenRect.width * scale
            let pixelHeight = result.screenRect.height * scale
            let evenPixelWidth = ceil(pixelWidth / 2) * 2
            let evenPixelHeight = ceil(pixelHeight / 2) * 2

            let sourceRect = CGRect(
                x: localX,
                y: flippedY,
                width: evenPixelWidth / scale,
                height: evenPixelHeight / scale
            )

            // Clear any existing picker selection (mutually exclusive)
            captureEngine.clearSelection()

            // Store the area selection and set the filter on the capture engine
            selectedSourceRect = sourceRect
            selectedScreenRect = result.screenRect
            selectedScreen = result.screen
            selectedContentFilter = filter
            try await captureEngine.updateFilter(filter)

            logger.info("Area selected: sourceRect=\(sourceRect.debugDescription), display=\(display.displayID)")

            // Update preview with the display filter and source rect
            await previewService.setContentFilter(filter, sourceRect: sourceRect)

            // Show the recording overlay on the screen where the area was selected
            // overlay suppressed — audio-only, record from menu bar

        } catch {
            selectionBorderFrame.dismiss()
            logger.error("Failed to get shareable content for area selection: \(error.localizedDescription)")
        }
    }

    /// Starts a new recording session
    func startRecording() async {
        guard canStartRecording else {
            logger.warning("Cannot start recording: no content selected or already recording")
            return
        }

        // Dismiss the recording overlay if it's still visible
        recordingOverlay.dismiss()

        do {
            state = .recording
            lastError = nil

            logger.info("Starting recording sequence...")

            // Stop any active live preview before starting recording
            logger.info("Stopping any active live preview...")
            await previewService.stopPreview()
            logger.info("Live preview stopped")

            // Determine video size from filter
            if let filter = selectedContentFilter {
                videoSize = await getContentSize(from: filter)
            }
            logger.info("Video size: \(self.videoSize.width)x\(self.videoSize.height)")

            // Access security-scoped output directory before writing
            _ = settings.startAccessingOutputDirectory()

            // Setup asset writer
            let outputURL = settings.generateOutputURL()
            try assetWriter.setup(url: outputURL, settings: settings)
            try assetWriter.startWriting()
            logger.info("AssetWriter ready")

            // Start camera for Presenter Overlay before capture so the system detects it
            if settings.presenterOverlayEnabled {
                await cameraSession.start(deviceID: settings.selectedCameraID)
            }

            // Start capture with the calculated video size
            logger.info("Starting capture engine...")
            try await captureEngine.startCapture(with: settings, videoSize: videoSize, sourceRect: selectedSourceRect)

            // Re-show the area selection border now that capture has started
            if isAreaSelection, let screenRect = selectedScreenRect {
                selectionBorderFrame.show(screenRect: screenRect)
            }

            // Start timer
            startTimer()

            logger.info("Recording started")

        } catch {
            state = .idle
            lastError = error
            cameraSession.stop()
            selectionBorderFrame.dismiss()
            settings.stopAccessingOutputDirectory()
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stops the current recording session
    func stopRecording() async {
        guard isRecording else { return }

        state = .stopping
        stopTimer()
        selectionBorderFrame.dismiss()

        do {
            // Stop capture and camera session
            try await captureEngine.stopCapture()
            cameraSession.stop()
            isPresenterOverlayActive = false

            // Finalize file
            let outputURL = try await assetWriter.finishWriting()

            state = .idle
            recordingDuration = 0

            logger.info("Recording stopped and saved to: \(outputURL.lastPathComponent)")

            // Move raw file to Kopia-backed recordings dir and fire dictate.py detached.
            let notifyURL = Self.moveToRecordingsAndTranscribe(outputURL, logger: logger) ?? outputURL

            // Brief delay to ensure screen sharing mode has fully stopped before sending notification
            try? await Task.sleep(for: .milliseconds(100))

            // Send notification
            notificationService.sendRecordingSavedNotification(fileURL: notifyURL)

            settings.stopAccessingOutputDirectory()

        } catch {
            state = .idle
            lastError = error
            assetWriter.cancel()
            settings.stopAccessingOutputDirectory()
            notificationService.sendRecordingFailedNotification(error: error)
            logger.error("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    /// Resets the area selection, removing the border frame and clearing state
    func resetAreaSelection() async {
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectedContentFilter = nil
        selectionBorderFrame.dismiss()
        recordingOverlay.dismiss()
        await previewService.stopPreview()
        previewService.clearPreview()
    }

    /// Starts the live preview stream (call when menu bar window opens)
    func startPreview() async {
        guard !isRecording else { return }
        await previewService.startPreview()
    }

    /// Stops the live preview stream (call when menu bar window closes)
    func stopPreview() async {
        await previewService.stopPreview()
    }

    // MARK: - Timer Management

    private func startTimer() {
        recordingStartTime = Date()
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Helper Methods

    private func getContentSize(from filter: SCContentFilter) async -> CGSize {
        // Apply scale if Capture Native Resolution setting is enabled
        let applyScale: Bool = settings.captureNativeResolution

        // If area selection is active, use the source rect dimensions.
        // The sourceRect is already snapped to even pixel counts in presentAreaSelection().
        if let sourceRect = selectedSourceRect {
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(
                width: applyScale ? sourceRect.width * scale : sourceRect.width,
                height: applyScale ? sourceRect.height * scale : sourceRect.height
            )
        }

        // Get the content rect from the filter
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        if rect.width > 0 && rect.height > 0 {
            return CGSize(
                width: applyScale ? rect.width * scale : rect.width,
                height: applyScale ? rect.height * scale : rect.height
            )
        }

        // Fallback to main screen size
        if let screen = NSScreen.main {
            return CGSize(
                width: applyScale ? screen.frame.width * screen.backingScaleFactor : screen.frame.width,
                height: applyScale ? screen.frame.height * screen.backingScaleFactor : screen.frame.height
            )
        }

        return CGSize(width: 1920, height: 1080)
    }
}

// MARK: - Dictate Handoff

extension RecorderViewModel {

    // Vault root for this machine — vault name is the stable identifier.
    private static let vaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/executive-function-test")

    /// Moves the raw recording into domains/recordings/{date}-{slug}/, then fires dictate.py
    /// detached so transcription runs without blocking the UI.
    /// Returns the moved audio URL (for notification), or nil if the move failed.
    @discardableResult
    private static func moveToRecordingsAndTranscribe(_ outputURL: URL, logger: Logger) -> URL? {
        let (slug, date) = deriveSlugAndDate(from: outputURL)
        let folderName = "\(date)-\(slug)"
        let destFolder = vaultRoot
            .appendingPathComponent("domains/recordings")
            .appendingPathComponent(folderName)
        let destAudio = destFolder.appendingPathComponent("audio.m4a")

        do {
            try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: outputURL, to: destAudio)
            logger.info("Moved recording → recordings/\(folderName)/audio.m4a")
        } catch {
            logger.error("Failed to move recording to recordings dir: \(error.localizedDescription)")
            return nil
        }

        // Ensure Homebrew binaries (ffmpeg, python3) are on PATH when app is launched from Finder.
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath

        // Mixed stereo file so any player (QuickTime, VLC, IINA) can play both sides.
        let mixedAudio = destFolder.appendingPathComponent("mixed.m4a")
        let mixProcess = Process()
        mixProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mixProcess.arguments = [
            "ffmpeg", "-y", "-i", destAudio.path,
            "-filter_complex", "[0:a:0][0:a:1]amix=inputs=2[a]",
            "-map", "[a]", "-c:a", "aac", "-b:a", "256k",
            mixedAudio.path,
        ]
        mixProcess.environment = env
        mixProcess.standardOutput = FileHandle.nullDevice
        mixProcess.standardError = FileHandle.nullDevice
        try? mixProcess.run()
        mixProcess.waitUntilExit()

        // Log file for diagnosing transcription failures.
        let logPath = destFolder.appendingPathComponent("transcription.log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice

        let dictateScript = vaultRoot.appendingPathComponent("system/scripts/dictate.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", dictateScript.path,
            destAudio.path,
            "--diarize", "--store",
            "--slug", slug,
        ]
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            logger.info("dictate.py launched for recordings/\(folderName)")
        } catch {
            logger.error("Failed to launch dictate.py: \(error.localizedDescription)")
        }

        return mixedAudio
    }

    /// Derives a short slug and date string from the output filename.
    /// Filename format: "CallRecording_2026-06-19-13.14.15.m4a"
    private static func deriveSlugAndDate(from url: URL) -> (slug: String, date: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        if let u = stem.firstIndex(of: "_") {
            let rest = String(stem[stem.index(after: u)...])
            let c = rest.components(separatedBy: "-")
            if c.count >= 4 {
                let date = "\(c[0])-\(c[1])-\(c[2])"
                let time = c[3].replacingOccurrences(of: ".", with: "")
                return ("call-\(time)", date)
            } else if c.count >= 3 {
                return ("call", "\(c[0])-\(c[1])-\(c[2])")
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return ("call", f.string(from: Date()))
    }
}

// MARK: - CaptureEngineDelegate

extension RecorderViewModel: CaptureEngineDelegate {

    func captureEngine(_ engine: CaptureEngine, didUpdateFilter filter: SCContentFilter) {
        // Clear any area selection (picker and area selections are mutually exclusive)
        selectedSourceRect = nil
        selectedScreenRect = nil
        selectedScreen = nil
        selectionBorderFrame.dismiss()

        selectedContentFilter = filter
        logger.info("Content filter updated")

        // Capture a static thumbnail for the preview
        Task {
            await previewService.setContentFilter(filter)
        }

        // Show the recording overlay. For picker selections there is no stored screen
        // (selectedScreen is nil), so the overlay positions itself below the status item.
        // overlay suppressed — audio-only, record from menu bar
    }

    func captureEngine(_ engine: CaptureEngine, didStopWithError error: Error?) {
        // Check if user clicked "Stop Sharing" in the menu bar
        let isUserStopped = (error as? SCStreamError)?.code == .userStopped

        if let error, !isUserStopped {
            lastError = error
            logger.error("Capture stopped with error: \(error.localizedDescription)")
        }

        // Clean up if we were recording
        if isRecording {
            if isUserStopped {
                // User clicked "Stop Sharing" - gracefully save the recording
                logger.info("User stopped sharing via system UI, saving recording...")
                Task {
                    await stopRecording()
                }
            } else {
                // Stream error during recording - try to save what we have
                logger.warning("Stream stopped unexpectedly, attempting to save recording...")
                Task {
                    await stopRecording()
                }
            }
        }
    }

    func captureEngine(_ engine: CaptureEngine, presenterOverlayDidChange isActive: Bool) {
        isPresenterOverlayActive = isActive
        logger.info("Presenter Overlay \(isActive ? "activated" : "deactivated")")
    }

    func captureEngineDidCancelPicker(_ engine: CaptureEngine) {
        logger.info("Picker was cancelled, clearing selection and preview")

        // Clear the selected content filter
        selectedContentFilter = nil

        // Dismiss the overlay if it was shown after a previous selection
        recordingOverlay.dismiss()

        // Stop and clear the preview
        Task {
            await previewService.cancelCapture()
            previewService.clearPreview()
        }
    }
}

// MARK: - PreviewServiceDelegate

extension RecorderViewModel: PreviewServiceDelegate {

    func previewServiceDidStopByUser(_ service: PreviewService) {
        logger.info("User stopped sharing via system UI, clearing selection")

        // Clear the selection
        selectedContentFilter = nil

        // Clear the content filter in capture engine and deactivate picker
        captureEngine.clearSelection()
        captureEngine.deactivatePicker()
    }
}
