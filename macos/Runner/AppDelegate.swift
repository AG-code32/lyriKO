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
  // Stream first for low-latency matches; retain the proven signature fallback.
  private var streamingSession: SHSession?
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
  private let firstSignatureWindowFrames: Int64 = 44100 * 5
  private let retrySignatureWindowFrames: Int64 = 44100 * 9
  private var phase = "idle"
  private var errorMessage = ""
  private var title = ""
  private var artist = ""
  private var positionMs = -1
  private var matchSequence = 0
  private var matchedEpochMs: Int64 = 0
  private var musicGateOpen = false
  private var referenceRms = 0.0
  private var belowMusicGateSinceMs: Int64 = 0
  private var aboveMusicGateSinceMs: Int64 = 0
  private var lastMusicEpochMs: Int64 = 0
  private var lastBufferEpochMs: Int64 = 0
  private var hasMatched = false
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
    matchSequence = 0
    matchedEpochMs = 0
    musicGateOpen = false
    referenceRms = 0
    belowMusicGateSinceMs = 0
    aboveMusicGateSinceMs = 0
    lastMusicEpochMs = 0
    lastBufferEpochMs = 0
    hasMatched = false
    audioBuffers = 0
    submittedBuffers = 0
    streamedFrames = 0
    conversionFailures = 0
    peakLevel = 0
    rmsLevel = 0
    converter = nil
    converterInputFormat = nil
    signatureSession = nil
    streamingSession = nil
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
    if #available(macOS 15.0, *) {
      localCatalog = try SHCustomCatalog(dataRepresentation: data)
    } else {
      throw NSError(domain: "Lyriko", code: 1005, userInfo: [
        NSLocalizedDescriptionKey: "The custom ShazamKit catalog requires macOS 15 or later"
      ])
    }
    catalogBytes = data.count

    // Update automatically when the API song list changes. The existing catalog
    // remains usable if the refresh fails (for example, temporary network loss).
    do {
      try await refreshCatalogIfNeeded(serverUrl: serverUrl, token: token)
    } catch {
      print("Lyriko catalog refresh skipped: \(error.localizedDescription)")
    }

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

    // Feed ShazamKit immediately rather than waiting for a 5-second signature.
    if let catalog = localCatalog {
      let liveSession = SHSession(catalog: catalog)
      liveSession.delegate = self
      streamingSession = liveSession
      streamingResponse = "listening"
      shazamState = "Streaming recognition active"
    }

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

  // Rebuild only after a registered song or its version changes. The first
  // launch establishes the baseline for an already-published catalog.
  @MainActor
  private func refreshCatalogIfNeeded(serverUrl: String, token: String) async throws {
    guard #available(macOS 15.0, *) else { return }
    let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    func fetch(_ path: String) async throws -> Data {
      guard let url = URL(string: base + path) else {
        throw NSError(domain: "Lyriko", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
      }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 60
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "Lyriko", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Cannot fetch catalog source: \(path)"])
      }
      return data
    }
    let listing = try await fetch("/api/songs")
    guard let object = try JSONSerialization.jsonObject(with: listing) as? [String: Any],
          let songs = object["songs"] as? [[String: Any]] else { return }
    let available = songs.filter { ($0["audioAvailable"] as? Bool) == true }
    guard !available.isEmpty else { return }
    let fingerprint = available.compactMap { song -> String? in
      guard let id = song["id"] as? String else { return nil }
      return id + ":" + String(describing: song["version"] ?? 0)
    }.sorted().joined(separator: "|")
    let key = "lyriko.shazam.catalog.source.v1." + base
    let previous = UserDefaults.standard.string(forKey: key)
    if previous == nil {
      // Existing published catalog is already available: don't rebuild 9 songs
      // merely because this is the first launch with the new code.
      UserDefaults.standard.set(fingerprint, forKey: key)
      return
    }
    guard previous != fingerprint else { return }

    shazamState = "Updating acoustic catalog"
    let catalog = SHCustomCatalog()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    for song in available {
      guard let id = song["id"] as? String,
            let title = song["title"] as? String,
            let artist = song["artist"] as? String,
            let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
      let accessData = try await fetch("/api/songs/" + encodedId + "/audio-access")
      guard let access = try JSONSerialization.jsonObject(with: accessData) as? [String: Any],
            let audioPath = access["url"] as? String,
            audioPath.hasPrefix("/api/songs/") else {
        throw NSError(domain: "Lyriko", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Missing audio access for catalog song"])
      }
      let mp3 = try await fetch(audioPath)
      let local = temp.appendingPathComponent(id + ".mp3")
      try mp3.write(to: local, options: .atomic)
      let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: local))
      try catalog.addReferenceSignature(signature, representing: [
        SHMediaItem(properties: [.title: title, .artist: artist])
      ])
    }
    let catalogData = catalog.dataRepresentation
    guard !catalogData.isEmpty else { return }
    guard let endpoint = URL(string: base + "/api/catalog/shazam") else { return }
    var publish = URLRequest(url: endpoint)
    publish.httpMethod = "PUT"
    publish.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    publish.httpBody = catalogData
    publish.timeoutInterval = 120
    let (_, publishResponse) = try await URLSession.shared.data(for: publish)
    guard (publishResponse as? HTTPURLResponse)?.statusCode == 200 else {
      throw NSError(domain: "Lyriko", code: 2003, userInfo: [NSLocalizedDescriptionKey: "Cannot publish updated acoustic catalog"])
    }
    localCatalog = catalog
    catalogBytes = catalogData.count
    UserDefaults.standard.set(fingerprint, forKey: key)
    print("Lyriko acoustic catalog updated automatically: \(available.count) songs")
  }

  @MainActor
  func stop() async {
    let oldStream = stream
    stream = nil
    phase = "idle"
    if let oldStream = oldStream { try? await oldStream.stopCapture() }
    signatureSession = nil
    streamingSession = nil
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
      "matchSequence": matchSequence,
      "matchedEpochMs": matchedEpochMs,
      "musicGateOpen": musicGateOpen,
      "lastMusicEpochMs": lastMusicEpochMs,
      "lastBufferEpochMs": lastBufferEpochMs,
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
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    lastBufferEpochMs = nowMs
    // Like iOS Discover: arm the music gate only after a verified match.
    // A sustained drop below the matched music level pauses the lyric clock.
    if hasMatched {
      if musicGateOpen {
        let quietLimit = max(0.0008, referenceRms * 0.35)
        if rmsLevel < quietLimit {
          if belowMusicGateSinceMs == 0 { belowMusicGateSinceMs = nowMs }
          else if nowMs - belowMusicGateSinceMs >= 550 {
            musicGateOpen = false
            aboveMusicGateSinceMs = 0
          }
        } else {
          let alpha = rmsLevel > referenceRms ? 0.035 : 0.00015
          referenceRms = referenceRms * (1 - alpha) + rmsLevel * alpha
          belowMusicGateSinceMs = 0
          lastMusicEpochMs = nowMs
        }
      } else {
        let wakeLimit = max(0.001, referenceRms * 0.55)
        if rmsLevel >= wakeLimit {
          if aboveMusicGateSinceMs == 0 { aboveMusicGateSinceMs = nowMs }
          else if nowMs - aboveMusicGateSinceMs >= 250 {
            musicGateOpen = true
            belowMusicGateSinceMs = 0
            lastMusicEpochMs = nowMs
          }
        } else { aboveMusicGateSinceMs = 0 }
      }
    }
    // Start streaming on the very first audio buffer. A finite signature remains
    // as a fallback when streaming does not produce a match quickly enough.
    streamedFrames += Int64(output.frameLength)
    if let liveSession = streamingSession {
      liveSession.matchStreamingBuffer(output, at: nil)
      streamingResponse = "matching live audio"
    }

    // Fallback: preserve the already-working finite-signature path at 5 seconds.
    if signaturePending && Date().timeIntervalSince(signatureRequestedAt) > 12 {
      signaturePending = false
      signatureSession = nil
      shazamState = "Signature request timed out; retrying"
      signatureResponse = "no callback within 12s"
      errorMessage = "ShazamKit: signature request timed out; retrying"
    }
    if !hasMatched && !signaturePending && signatureAttempts < 3 {
      do {
        let timeInWindow = AVAudioTime(sampleTime: signatureFrames,
                                       atRate: recognitionFormat.sampleRate)
        try signatureGenerator.append(output, at: timeInWindow)
        signatureFrames += Int64(output.frameLength)
        let targetFrames = signatureAttempts == 0 ? firstSignatureWindowFrames : retrySignatureWindowFrames
        if signatureFrames >= targetFrames {
          let signature = try signatureGenerator.signature()
          signatureGenerator = SHSignatureGenerator()
          signatureFrames = 0
          guard let catalog = localCatalog else {
            throw NSError(domain: "Lyriko", code: 1005, userInfo: [
              NSLocalizedDescriptionKey: "Local acoustic catalog is not loaded"
            ])
          }
          // Stop streaming before requesting the fallback signature to avoid
          // simultaneous sessions processing the same audio indefinitely.
          streamingSession = nil
          streamingResponse = "fallback to finite signature"
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
            (self.signatureSession === session || self.streamingSession === session) else { return }
      let wasSignature = self.signatureSession === session
      self.title = matchedTitle
      self.artist = matchedArtist
      self.positionMs = max(0, Int(matchedOffset * 1000))
      self.matchSequence += 1
      self.matchedEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
      self.hasMatched = true
      self.musicGateOpen = true
      self.referenceRms = max(0.001, self.rmsLevel)
      self.lastMusicEpochMs = self.matchedEpochMs
      self.belowMusicGateSinceMs = 0
      self.aboveMusicGateSinceMs = 0
      self.signaturePending = false
      self.signatureSession = nil
      self.streamingSession = nil
      self.errorMessage = ""
      self.shazamState = "Matched #\(self.matchSequence): \(matchedArtist) — \(matchedTitle)"
      if wasSignature { self.signatureResponse = "matched" }
      else { self.streamingResponse = "matched" }
      // A custom-catalog session can stop delivering matches after success.
      // Keep ScreenCaptureKit running and re-arm a new streaming session.
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let self = self, self.phase == "listening",
              self.streamingSession == nil, let catalog = self.localCatalog else { return }
        let next = SHSession(catalog: catalog)
        next.delegate = self
        self.streamingSession = next
        self.streamingResponse = "tracking playback"
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
      let fromStreaming = self.streamingSession === session
      guard fromSignature || fromStreaming else { return }
      if fromStreaming {
        self.streamingSession = nil
        self.streamingResponse = error == nil ? "no match; continuing to listen" : "stream error; retrying"
        // Once the first track was found, keep listening for seeks and changes.
        if self.hasMatched {
          Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self = self, self.phase == "listening",
                  self.streamingSession == nil, let catalog = self.localCatalog else { return }
            let next = SHSession(catalog: catalog)
            next.delegate = self
            self.streamingSession = next
            self.streamingResponse = "tracking playback"
          }
        }
        return
      }
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
