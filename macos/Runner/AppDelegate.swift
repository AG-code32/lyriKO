import Cocoa
import FlutterMacOS
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import ShazamKit

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Captures the Mac's system audio and feeds normalized PCM to ShazamKit.
/// All Flutter-facing state and SHSession calls are performed on the main actor.
@available(macOS 12.3, *)
final class LyrikoMacAudioRecognizer: NSObject, SCStreamOutput, SHSessionDelegate {
  private var channel: FlutterMethodChannel?
  private let audioQueue = DispatchQueue(label: "lyriko.system.audio", qos: .userInitiated)
  private var stream: SCStream?
  // Use only finite signatures; do not compete with a streaming session.
  private var signatureSession: SHSession?
  private var localCatalog: SHCustomCatalog?
  private var catalogBytes = 0
  private var signatureGenerator = SHSignatureGenerator()
  private var signatureFrames: Int64 = 0
  private var signatureAttempts = 0
  private var noMatchCount = 0
  private var signaturePending = false
  private var signatureRequestedAt = Date.distantPast
  private var shazamState = "waiting for audio"
  private var signatureResponse = "not requested"
  private var streamingResponse = "waiting for audio"
  private let signatureWindowFrames: Int64 = 44100 * 9
  private var phase = "idle"
  private var errorMessage = ""
  private var title = ""
  private var artist = ""
  private var positionMs = -1
  private var audioBuffers = 0
  private var submittedBuffers = 0
  private var streamedFrames: Int64 = 0
  private var conversionFailures = 0
  private var peakLevel = 0.0
  private var rmsLevel = 0.0
  private var startTime = Date()
  private var lastDiagnosticTime = Date.distantPast
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private let recognitionFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 44100,
    channels: 1,
    interleaved: false)!

  func install(on controller: FlutterViewController) {
    let newChannel = FlutterMethodChannel(
      name: "lyriko/macos_audio_recognition",
      binaryMessenger: controller.engine.binaryMessenger)
    channel = newChannel
    newChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "CLOSED", message: "Window closed", details: nil))
        return
      }
      switch call.method {
      case "start":
        Task { @MainActor in
          do {
            let arguments = call.arguments as? [String: String] ?? [:]
            try await self.start(serverUrl: arguments["serverUrl"] ?? "", token: arguments["token"] ?? "")
            result(nil)
          } catch {
            self.phase = "error"
            self.errorMessage = error.localizedDescription
            result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      case "status":
        Task { @MainActor in result(self.status()) }
      case "stop":
        Task { @MainActor in await self.stop(); result(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  @MainActor
  func start(serverUrl: String, token: String) async throws {
    await stop()
    phase = "starting"
    errorMessage = ""
    title = ""
    artist = ""
    positionMs = -1
    audioBuffers = 0
    submittedBuffers = 0
    streamedFrames = 0
    conversionFailures = 0
    peakLevel = 0
    rmsLevel = 0
    converter = nil
    converterInputFormat = nil
    signatureSession = nil
    localCatalog = nil
    catalogBytes = 0
    signatureGenerator = SHSignatureGenerator()
    signatureFrames = 0
    signatureAttempts = 0
    noMatchCount = 0
    signaturePending = false
    signatureRequestedAt = .distantPast
    shazamState = "waiting for audio"
    signatureResponse = "not requested"
    streamingResponse = "waiting for audio"
    startTime = Date()
    lastDiagnosticTime = .distantPast

    // Load the centrally published acoustic catalog BEFORE starting capture.
    // No calls to the Apple Music/Shazam online catalog are made.
    guard !token.isEmpty else {
      throw NSError(domain: "Lyriko", code: 1001, userInfo: [
        NSLocalizedDescriptionKey: "Missing LYRIKO_SERVER_TOKEN. Configure the same token used by the Windows server."
      ])
    }
    guard let base = URL(string: serverUrl),
          (base.scheme == "https" || base.scheme == "http"),
          let endpoint = URL(string: serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/catalog/shazam") else {
      throw NSError(domain: "Lyriko", code: 1002, userInfo: [
        NSLocalizedDescriptionKey: "Invalid LYRIKO_SERVER_URL"
      ])
    }
    var request = URLRequest(url: endpoint)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw NSError(domain: "Lyriko", code: 1003, userInfo: [
        NSLocalizedDescriptionKey: "Windows catalog HTTP \(code). Publish the catalog first (404 means missing catalog)."
      ])
    }
    guard !data.isEmpty else {
      throw NSError(domain: "Lyriko", code: 1004, userInfo: [
        NSLocalizedDescriptionKey: "Downloaded acoustic catalog is empty"
      ])
    }
    localCatalog = try SHCustomCatalog(dataRepresentation: data)
    catalogBytes = data.count

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw NSError(domain: "Lyriko", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No display available for system audio capture"])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = 16
    config.height = 16
    config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
    config.showsCursor = false
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 44100
    config.channelCount = 2

    let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
    try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    stream = newStream
    do {
      try await newStream.startCapture()
      phase = "listening"
    } catch {
      stream = nil
      throw error
    }
  }

  @MainActor
  func stop() async {
    let oldStream = stream
    stream = nil
    phase = "idle"
    if let oldStream = oldStream { try? await oldStream.stopCapture() }
    signatureSession = nil
    signatureGenerator = SHSignatureGenerator()
    signatureFrames = 0
    signaturePending = false
    streamedFrames = 0
    converter = nil
    converterInputFormat = nil
  }

  @MainActor
  func status() -> [String: Any] {
    // Preserve the keys expected by the existing Flutter UI.
    return [
      "phase": phase,
      "error": errorMessage,
      "title": title,
      "artist": artist,
      "positionMs": positionMs,
      "audioBuffers": audioBuffers,
      "submittedBuffers": submittedBuffers,
      "conversionFailures": conversionFailures,
      "rms": rmsLevel,
      "peak": peakLevel,
      "elapsedSeconds": Int(Date().timeIntervalSince(startTime)),
      "signatureAttempts": signatureAttempts,
      "catalogBytes": catalogBytes,
      "noMatchCount": noMatchCount,
      "shazamStatus": shazamState,
      "signatureResponse": signatureResponse,
      "streamingResponse": streamingResponse,
      "signaturePending": signaturePending,
      "signatureFrames": signatureFrames,
      "streamedFrames": streamedFrames
    ]
  }

  nonisolated func stream(_ stream: SCStream,
                          didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                          of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid,
          let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
    let count = CMSampleBufferGetNumSamples(sampleBuffer)
    guard count > 0,
          let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                     frameCapacity: AVAudioFrameCount(count)) else { return }
    pcm.frameLength = AVAudioFrameCount(count)
    let copyResult = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
    guard copyResult == noErr else {
      Task { @MainActor [weak self] in
        self?.conversionFailures += 1
        self?.errorMessage = "ScreenCaptureKit PCM copy failed (OSStatus \(copyResult))"
      }
      return
    }
    Task { @MainActor [weak self] in
      self?.processAudio(pcm)
    }
  }

  @MainActor
  private func processAudio(_ input: AVAudioPCMBuffer) {
    guard phase == "listening" else { return }
    audioBuffers += 1

    let sourceFormat = input.format
    if converter == nil || converterInputFormat == nil ||
       !converterInputFormat!.isEqual(sourceFormat) {
      converterInputFormat = sourceFormat
      converter = AVAudioConverter(from: sourceFormat, to: recognitionFormat)
      if converter == nil {
        conversionFailures += 1
        errorMessage = "Cannot convert system audio: \(sourceFormat)"
        return
      }
      print("Lyriko audio format: \(sourceFormat) -> \(recognitionFormat)")
    }
    guard let converter = converter else { return }

    let ratio = recognitionFormat.sampleRate / max(1, sourceFormat.sampleRate)
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 256)
    guard let output = AVAudioPCMBuffer(pcmFormat: recognitionFormat,
                                        frameCapacity: max(capacity, 1024)) else { return }
    var supplied = false
    var conversionError: NSError?
    let result = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
    if let conversionError = conversionError {
      conversionFailures += 1
      errorMessage = "Audio conversion: \(conversionError.localizedDescription)"
      return
    }
    guard result != .error, output.frameLength > 0,
          let samples = output.floatChannelData?[0] else {
      conversionFailures += 1
      return
    }

    var power = 0.0
    var peak = 0.0
    for index in 0..<Int(output.frameLength) {
      let sample = Double(samples[index])
      power += sample * sample
      peak = max(peak, abs(sample))
    }
    rmsLevel = sqrt(power / Double(output.frameLength))
    peakLevel = peak
    submittedBuffers += 1
    // Keep a sample count for diagnostics, but send audio only to the signature generator.
    // Concurrent SHSession streaming and signature requests obscured the actual error.
    streamedFrames += Int64(output.frameLength)
    streamingResponse = "disabled (signature-only recognition)"

    // A second recognition path submits a finite 9-second signature.
    // This also gives an explicit no-match/error callback if streaming never responds.
    if signaturePending && Date().timeIntervalSince(signatureRequestedAt) > 16 {
      signaturePending = false
      signatureSession = nil
      shazamState = "Signature request timed out; retrying"
      signatureResponse = "no callback within 16s"
      errorMessage = "ShazamKit: signature request timed out; retrying"
    }
    if !signaturePending && signatureAttempts < 3 {
      do {
        let timeInWindow = AVAudioTime(sampleTime: signatureFrames,
                                       atRate: recognitionFormat.sampleRate)
        try signatureGenerator.append(output, at: timeInWindow)
        signatureFrames += Int64(output.frameLength)
        if signatureFrames >= signatureWindowFrames {
          let signature = try signatureGenerator.signature()
          signatureGenerator = SHSignatureGenerator()
          signatureFrames = 0
          guard let catalog = localCatalog else {
            throw NSError(domain: "Lyriko", code: 1005, userInfo: [
              NSLocalizedDescriptionKey: "Local acoustic catalog is not loaded"
            ])
          }
          let newSession = SHSession(catalog: catalog)
          newSession.delegate = self
          signatureSession = newSession
          signaturePending = true
          signatureRequestedAt = Date()
          signatureAttempts += 1
          shazamState = "Signature #\(signatureAttempts) submitted"
          signatureResponse = "matching Windows acoustic catalog"
          errorMessage = ""
          newSession.match(signature)
        }
      } catch {
        conversionFailures += 1
        shazamState = "Signature generation failed"
        signatureResponse = "signature generation error"
        errorMessage = "ShazamKit signature: \(error.localizedDescription)"
        signatureGenerator = SHSignatureGenerator()
        signatureFrames = 0
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)
    if Date().timeIntervalSince(lastDiagnosticTime) >= 5 {
      lastDiagnosticTime = Date()
      print(String(format:
        "Lyriko audio: received=%d submitted=%d failures=%d RMS=%.5f peak=%.5f elapsed=%.0fs",
        audioBuffers, submittedBuffers, conversionFailures, rmsLevel, peakLevel, elapsed))
    }
    if elapsed > 8 && submittedBuffers > 30 && rmsLevel < 0.00001 && peakLevel < 0.0001 {
      errorMessage = "System audio is silent. Play YouTube with sound on the Mac."
    } else if errorMessage.hasPrefix("System audio is silent") && rmsLevel >= 0.0001 {
      errorMessage = ""
    }
  }

  nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first else { return }
    let matchedTitle = item.title ?? ""
    let matchedArtist = item.artist ?? ""
    let matchedOffset = item.predictedCurrentMatchOffset
    Task { @MainActor [weak self] in
      guard let self = self, self.phase == "listening", !matchedTitle.isEmpty,
            self.signatureSession === session else { return }
      self.title = matchedTitle
      self.artist = matchedArtist
      self.positionMs = max(0, Int(matchedOffset * 1000))
      self.phase = "matched"
      self.errorMessage = ""
      self.shazamState = "Matched: \(matchedArtist) — \(matchedTitle)"
      if self.signatureSession === session {
        self.signatureResponse = "matched"
      } else {
        self.streamingResponse = "matched"
      }
      print("Lyriko ShazamKit match: \(matchedArtist) - \(matchedTitle)")
    }
  }

  nonisolated func session(_ session: SHSession,
                           didNotFindMatchFor signature: SHSignature,
                           error: Error?) {
    Task { @MainActor [weak self] in
      guard let self = self, self.phase == "listening" else { return }
      let fromSignature = self.signatureSession === session
      guard fromSignature else { return }
      if fromSignature {
        self.signaturePending = false
        self.signatureSession = nil
      }
      if let error = error {
        self.shazamState = "Recognition error"
        let nativeError = error as NSError
        let errorDetails = "\(nativeError.domain) code \(nativeError.code): \(nativeError.localizedDescription)"
        if fromSignature {
          self.signatureResponse = "error: \(errorDetails)"
        } else {
          self.streamingResponse = "error: \(errorDetails)"
        }
        self.errorMessage = "ShazamKit: \(errorDetails)"
        // Error 202 is often a service/entitlement problem on sandboxed macOS apps.
        // Do not retry it indefinitely or mislabel it as a missing song.
        if nativeError.domain == "com.apple.ShazamKit" && nativeError.code == 202 {
          self.phase = "error"
          self.shazamState = "ShazamKit service error 202"
          self.errorMessage = "Local ShazamKit recognition error 202: \(errorDetails)"
        }
      } else {
        self.noMatchCount += 1
        self.shazamState = fromSignature
          ? "Signature #\(self.signatureAttempts): no match; retrying"
          : "Streaming: no match yet"
        if fromSignature {
          self.signatureResponse = "no match"
          if self.signatureAttempts >= 3 {
            self.phase = "error"
            self.shazamState = "No catalog match after 3 signatures"
            self.errorMessage = "No Shazam catalog match after 3 signatures."
          }
        } else {
          self.streamingResponse = "no match"
        }
        self.errorMessage = "ShazamKit: \(self.shazamState)"
      }
      print(self.errorMessage)
    }
  }
}
