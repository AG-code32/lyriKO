import Cocoa
import FlutterMacOS
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import ShazamKit
import CryptoKit

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
  private var catalogGenerationStatus = "not checked"
  private var catalogReferenceCount = 0
  private var signatureGenerator = SHSignatureGenerator()
  private var signatureFrames: Int64 = 0
  private var signatureAttempts = 0
  private var noMatchCount = 0
  private var signaturePending = false
  private var signatureRequestedAt = Date.distantPast
  private var shazamState = "waiting for audio"
  private var signatureResponse = "not requested"
  private var streamingResponse = "waiting for audio"
  private let firstSignatureWindowFrames: Int64 = 44100 * 8
  private let retrySignatureWindowFrames: Int64 = 44100 * 8
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
  private var lastRecognizedTitle = ""
  private var lastRecognizedArtist = ""
  private var lastRecognizedAt = Date.distantPast
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
      case "refreshCatalog":
        Task { @MainActor in
          let arguments = call.arguments as? [String: String] ?? [:]
          do {
            try await self.refreshCatalogNow(serverUrl: arguments["serverUrl"] ?? "", token: arguments["token"] ?? "", force: true)
            result(["updated": true, "catalogBytes": self.catalogBytes, "referenceCount": self.catalogReferenceCount, "message": self.catalogGenerationStatus])
          } catch {
            result(FlutterError(code: "CATALOG_REFRESH_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      case "diagnoseReferences":
        Task { @MainActor in
          let arguments = call.arguments as? [String: String] ?? [:]
          do {
            let report = try await self.diagnoseReferences(
              serverUrl: arguments["serverUrl"] ?? "", token: arguments["token"] ?? "")
            result(report)
          } catch {
            result(FlutterError(code: "REFERENCE_DIAGNOSTIC_FAILED",
                                message: error.localizedDescription, details: nil))
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
    lastRecognizedTitle = ""
    lastRecognizedArtist = ""
    lastRecognizedAt = .distantPast
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
    catalogGenerationStatus = "checking"
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
          (base.scheme == "https" || base.scheme == "http") else {
      throw NSError(domain: "Lyriko", code: 1002, userInfo: [
        NSLocalizedDescriptionKey: "Invalid LYRIKO_SERVER_URL"
      ])
    }
    // Never use URLSession's cached catalog on a new DISCOVER session.
    let data = try await downloadCurrentCatalog(serverUrl: serverUrl, token: token)
    try activateCatalog(data)


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
      // Never block capture on downloading reference MP3s or rebuilding a catalog.
      // Keep the existing published catalog active while the updated one builds.
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        do {
          try await self.refreshCatalogNow(serverUrl: serverUrl, token: token)
        } catch {
          self.catalogGenerationStatus = "FAILED: \(error.localizedDescription)"
          print("Lyriko catalog refresh FAILED: \(error.localizedDescription)")
        }
      }
    } catch {
      stream = nil
      throw error
    }
  }

  // Called both after successful lyrics approval and when DISCOVER starts.
  // Idempotent: unchanged song metadata/version does not cause another rebuild.
  @MainActor
  private func refreshCatalogNow(serverUrl: String, token: String, force: Bool = false) async throws {
    guard !serverUrl.isEmpty && !token.isEmpty else {
      throw NSError(domain: "Lyriko", code: 2100, userInfo: [NSLocalizedDescriptionKey: "Server credentials unavailable"])
    }
    while catalogRefreshInProgress {
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    catalogRefreshInProgress = true
    defer { catalogRefreshInProgress = false }
    try await refreshCatalogIfNeeded(serverUrl: serverUrl, token: token, force: force)
  }

  // Always ask Windows for the current published catalog. The nonce also
  // bypasses intermediary caches in temporary Cloudflare tunnels.
  @MainActor
  private func downloadCurrentCatalog(serverUrl: String, token: String) async throws -> Data {
    let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: base + "/api/catalog/shazam?revision=" + UUID().uuidString) else {
      throw NSError(domain: "LyriKO", code: 2301, userInfo: [NSLocalizedDescriptionKey: "Invalid catalog URL"])
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("no-store, no-cache, max-age=0", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.timeoutInterval = 40
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw NSError(domain: "LyriKO", code: 2302, userInfo: [NSLocalizedDescriptionKey: "Catalog download failed: HTTP \(status)"])
    }
    return data
  }

  @MainActor
  private func activateCatalog(_ data: Data, referenceCount: Int? = nil) throws {
    guard #available(macOS 15.0, *) else {
      throw NSError(domain: "LyriKO", code: 2303, userInfo: [NSLocalizedDescriptionKey: "macOS 15 or newer is required"])
    }
    let incomingHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let newCatalog = try SHCustomCatalog(dataRepresentation: data)
    localCatalog = newCatalog
    catalogBytes = data.count
    if let count = referenceCount { catalogReferenceCount = count }
    catalogGenerationStatus = "active catalog SHA256 " + String(incomingHash.prefix(12))
    if phase == "listening" {
      // Swap both sessions atomically on MainActor, without stopping capture.
      signatureSession = nil
      streamingSession = nil
      signaturePending = false
      signatureAttempts = 0
      noMatchCount = 0
      signatureFrames = 0
      signatureGenerator = SHSignatureGenerator()
      let session = SHSession(catalog: newCatalog)
      session.delegate = self
      streamingSession = session
      streamingResponse = "new published catalog active"
      shazamState = "Catalog updated without restarting DISCOVER"
    }
  }

  private var catalogRefreshInProgress = false

  // Rebuild only after a registered song or its version changes. The first
  // launch establishes the baseline for an already-published catalog.
  @MainActor
  private func refreshCatalogIfNeeded(serverUrl: String, token: String, force: Bool = false) async throws {
    guard #available(macOS 15.0, *) else { return }
    let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    func fetch(_ path: String) async throws -> Data {
      let separator = path.contains("?") ? "&" : "?"
      guard let url = URL(string: base + path + separator + "revision=" + UUID().uuidString) else {
        throw NSError(domain: "Lyriko", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"])
      }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
      request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
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
    // Build a catalog revision from BOTH lyric versions and actual server MP3s.
    var audioAccess: [String: (path: String, revision: String)] = [:]
    var fingerprintParts: [String] = []
    for song in available {
      guard let id = song["id"] as? String,
            let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
      let accessData = try await fetch("/api/songs/" + encodedId + "/audio-access")
      guard let access = try JSONSerialization.jsonObject(with: accessData) as? [String: Any],
            let path = access["url"] as? String, path.hasPrefix("/api/songs/") else {
        throw NSError(domain: "LyriKO", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Missing audio access for catalog song"])
      }
      let revision = access["audioRevision"] as? String ?? "unversioned"
      audioAccess[id] = (path, revision)
      fingerprintParts.append(id + ":" + String(describing: song["version"] ?? 0) + ":" + revision)
    }
    let fingerprint = fingerprintParts.sorted().joined(separator: "|")
    let key = "lyriko.shazam.catalog.source.v5.full-rebuild." + base
    let previous = UserDefaults.standard.string(forKey: key)
    // A missing baseline does NOT prove the published catalog contains the
    // newly imported songs. Build once and persist the baseline only after
    // a successful upload; otherwise future recognition silently misses them.
    guard force || previous != fingerprint else {
      let remoteData = try await downloadCurrentCatalog(serverUrl: serverUrl, token: token)
      let activeHash = UserDefaults.standard.string(forKey: key + ".sha256")
      let remoteHash = SHA256.hash(data: remoteData).map { String(format: "%02x", $0) }.joined()
      if activeHash != remoteHash || catalogBytes != remoteData.count {
        // An external repair or old cached response must not strand DISCOVER.
        try activateCatalog(remoteData, referenceCount: available.count)
      }
      catalogGenerationStatus = "catalog verified (\(available.count) references expected)"
      return
    }

    print("LyriKO: rebuilding complete acoustic catalog for \(available.count) audio-ready songs")
    catalogGenerationStatus = "building 0/\(available.count)"
    let catalog = SHCustomCatalog()
    var verificationSamples: [(id: String, title: String, signature: SHSignature)] = []
    for song in available {
      guard let id = song["id"] as? String,
            let title = song["title"] as? String,
            let artist = song["artist"] as? String,
            let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
      guard let info = audioAccess[id] else {
        throw NSError(domain: "LyriKO", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Missing audio revision for song"])
      }
      let audioPath = info.path
      // Reuse unchanged reference MP3s between catalog rebuilds.
      let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LyriKO/ShazamReferences", isDirectory: true)
      try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
      let version = String(describing: song["version"] ?? 0)
      // IDs and versions originate from the authenticated private server.
      let safeName = (id + "_" + version + "_" + info.revision).replacingOccurrences(
        of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
      let local = cacheFolder.appendingPathComponent(safeName + ".mp3")
      if !FileManager.default.fileExists(atPath: local.path) {
        let mp3 = try await fetch(audioPath)
        try mp3.write(to: local, options: .atomic)
      }
      print("LyriKO: generating ShazamKit signature \(id) — \(title)")
      let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: local))
      try catalog.addReferenceSignature(signature, representing: [
        SHMediaItem(properties: [.title: title, .artist: artist])
      ])
      verificationSamples.append((id: id, title: title, signature: signature))
      catalogGenerationStatus = "building \(verificationSamples.count)/\(available.count): \(title)"
    }
    // A complete, nonempty set of reference signatures is required before publish.
    // Self-matching a full reference signature is not a reliable validation of
    // recognition against an independent excerpt; do not block publication on it.
    guard verificationSamples.count == available.count else {
      throw NSError(domain: "Lyriko", code: 2201, userInfo: [
        NSLocalizedDescriptionKey: "Only \(verificationSamples.count) of \(available.count) references generated"
      ])
    }
    catalogGenerationStatus = "publishing \(verificationSamples.count) references"
    let catalogData = catalog.dataRepresentation
    guard !catalogData.isEmpty else {
      throw NSError(domain: "Lyriko", code: 2206, userInfo: [NSLocalizedDescriptionKey: "Generated catalog is empty"])
    }
    guard let endpoint = URL(string: base + "/api/catalog/shazam") else { return }
    var publish = URLRequest(url: endpoint)
    publish.httpMethod = "PUT"
    publish.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    publish.httpBody = catalogData
    publish.timeoutInterval = 120
    let (receiptData, publishResponse) = try await URLSession.shared.data(for: publish)
    guard (publishResponse as? HTTPURLResponse)?.statusCode == 200 else {
      throw NSError(domain: "Lyriko", code: 2003, userInfo: [NSLocalizedDescriptionKey: "Cannot publish updated acoustic catalog"])
    }
    // A HTTP 200 alone does not prove that the intended catalog was stored.
    guard let receipt = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
          (receipt["bytes"] as? Int) == catalogData.count else {
      throw NSError(domain: "LyriKO", code: 2208, userInfo: [NSLocalizedDescriptionKey: "Catalog publication receipt does not match uploaded data"])
    }
    // Windows hashes the bytes read back from the published file. Compare
    // that receipt instead of a second GET that may return a stale cached copy.
    let localSHA = SHA256.hash(data: catalogData)
      .map { String(format: "%02x", $0) }.joined()
    guard let serverSHA = receipt["sha256"] as? String,
          serverSHA.lowercased() == localSHA else {
      throw NSError(domain: "LyriKO", code: 2209, userInfo: [
        NSLocalizedDescriptionKey: "Published catalog SHA-256 mismatch (local: \(localSHA), Windows returned a different hash)"
      ])
    }
    // The server verified the saved file by SHA-256. Switch the active
    // ShazamKit session immediately; no UI restart or DISCOVER toggle.
    try activateCatalog(catalogData, referenceCount: verificationSamples.count)
    catalogGenerationStatus = "published and activated \(verificationSamples.count) references"
    UserDefaults.standard.set(localSHA, forKey: key + ".sha256")
    UserDefaults.standard.set(fingerprint, forKey: key)
    print("LyriKO: published regenerated catalog containing \(verificationSamples.count) reference signatures (matching still requires live test)")
  }

  // Isolated reference test. Does not rebuild, publish or alter DISCOVER sessions.
  // A duration-validated excerpt from the SAME MP3 is independently fingerprinted and
  // queried against the serialized catalog currently published on Windows.
  // Decode real audio samples and build a query through the same PCM signature
  // generator used by live DISCOVER. No composition or reference signature reuse.
  private func makePCMQuerySignature(file: URL, startSeconds: Double,
                                     querySeconds: Double) throws -> SHSignature {
    let audio = try AVAudioFile(forReading: file)
    let sourceFormat = audio.processingFormat
    let targetFormat = recognitionFormat
    let startFrame = AVAudioFramePosition(startSeconds * sourceFormat.sampleRate)
    audio.framePosition = min(max(0, startFrame), audio.length)
    let generator = SHSignatureGenerator()
    let converter = sourceFormat.isEqual(targetFormat) ? nil : AVAudioConverter(from: sourceFormat, to: targetFormat)
    if !sourceFormat.isEqual(targetFormat) && converter == nil {
      throw NSError(domain: "LyriKO", code: 3120, userInfo: [NSLocalizedDescriptionKey: "Cannot convert MP3 PCM to 44.1 kHz mono"])
    }
    let requiredFrames = Int64(querySeconds * targetFormat.sampleRate)
    var written: Int64 = 0
    while written < requiredFrames {
      let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096)!
      try audio.read(into: buffer)
      if buffer.frameLength == 0 { break }
      let normalized: AVAudioPCMBuffer
      if let converter = converter {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 256)
        guard let resultBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1024)) else {
          throw NSError(domain: "LyriKO", code: 3121, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate converted PCM"])
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: resultBuffer, error: &error) { _, inputStatus in
          if supplied { inputStatus.pointee = .noDataNow; return nil }
          supplied = true
          inputStatus.pointee = .haveData
          return buffer
        }
        if let error = error { throw error }
        if status == .error { throw NSError(domain: "LyriKO", code: 3122, userInfo: [NSLocalizedDescriptionKey: "PCM converter failed"]) }
        normalized = resultBuffer
      } else {
        normalized = buffer
      }
      guard normalized.frameLength > 0 else { continue }
      // Limit query length to catalog's allowed window, including last buffer.
      let remaining = requiredFrames - written
      if Int64(normalized.frameLength) > remaining {
        normalized.frameLength = AVAudioFrameCount(remaining)
      }
      try generator.append(normalized, at: AVAudioTime(sampleTime: written, atRate: targetFormat.sampleRate))
      written += Int64(normalized.frameLength)
    }
    if written < Int64(3 * targetFormat.sampleRate) {
      throw NSError(domain: "LyriKO", code: 3123, userInfo: [NSLocalizedDescriptionKey: "Not enough decoded PCM for ShazamKit query"])
    }
    return generator.signature()
  }

  @MainActor
  private func diagnoseReferences(serverUrl: String, token: String) async throws -> String {
    guard #available(macOS 15.0, *) else {
      throw NSError(domain: "LyriKO", code: 3099, userInfo: [
        NSLocalizedDescriptionKey: "Direct ShazamKit catalog diagnostics require macOS 15 or newer"
      ])
    }
    guard !serverUrl.isEmpty && !token.isEmpty else {
      throw NSError(domain: "LyriKO", code: 3100, userInfo: [NSLocalizedDescriptionKey: "Configure server URL/token first"])
    }
    let base = serverUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    func get(_ path: String) async throws -> Data {
      guard let url = URL(string: base + path) else {
        throw NSError(domain: "LyriKO", code: 3101, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: " + path])
      }
      var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
      req.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.timeoutInterval = 90
      let (body, response) = try await URLSession.shared.data(for: req)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "LyriKO", code: 3102, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): " + path])
      }
      return body
    }

    let catalogData = try await downloadCurrentCatalog(serverUrl: serverUrl, token: token)
    let testCatalog = try SHCustomCatalog(dataRepresentation: catalogData)
    let minQuery = testCatalog.minimumQuerySignatureDuration
    let maxQuery = testCatalog.maximumQuerySignatureDuration
    guard minQuery.isFinite, maxQuery.isFinite, minQuery > 0, maxQuery > minQuery else {
      throw NSError(domain: "LyriKO", code: 3106, userInfo: [
        NSLocalizedDescriptionKey: "Unexpected catalog signature duration limits: \(minQuery)–\(maxQuery) seconds"
      ])
    }
    // Stay strictly within the catalog's limits. An 18-second query can fail
    // with ShazamKit error 201 even if the reference audio is valid.
    let querySeconds = min(max(8.0, minQuery + 1.0), maxQuery - 0.5)
    guard querySeconds > minQuery, querySeconds < maxQuery else {
      throw NSError(domain: "LyriKO", code: 3107, userInfo: [
        NSLocalizedDescriptionKey: "Catalog query duration window is too narrow"
      ])
    }
    let listingData = try await get("/api/songs")
    guard let listing = try JSONSerialization.jsonObject(with: listingData) as? [String: Any],
          let songs = listing["songs"] as? [[String: Any]] else {
      throw NSError(domain: "LyriKO", code: 3103, userInfo: [NSLocalizedDescriptionKey: "Invalid song listing"])
    }
    let testNames = ["Mattel", "Helena", "Give 'Em Hell, Kid", "To the End", "You Know What They Do to Guys Lik"]
    var lines = [
      "Published catalog: \(catalogData.count) bytes",
      String(format: "Allowed query duration: %.2f–%.2f s; target: %.2f s", minQuery, maxQuery, querySeconds),
      "Direct MP3 excerpt test (no YouTube capture):"
    ]
    for wanted in testNames {
      guard let song = songs.first(where: {
        ($0["title"] as? String ?? "").caseInsensitiveCompare(wanted) == .orderedSame
      }), let id = song["id"] as? String else {
        lines.append("\(wanted): NOT REGISTERED")
        continue
      }
      let title = song["title"] as? String ?? wanted
      guard let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
      do {
        let accessBytes = try await get("/api/songs/\(encodedId)/audio-access")
        guard let access = try JSONSerialization.jsonObject(with: accessBytes) as? [String: Any],
              let audioPath = access["url"] as? String, audioPath.hasPrefix("/api/songs/") else {
          throw NSError(domain: "LyriKO", code: 3104, userInfo: [NSLocalizedDescriptionKey: "Audio URL missing"])
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("LyriKO/ShazamReferences", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let version = String(describing: song["version"] ?? 0)
        let safeName = (id + "_" + version).replacingOccurrences(
          of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let revision = access["audioRevision"] as? String ?? "unversioned"
        let freshName = (safeName + "_" + revision).replacingOccurrences(
          of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let file = cache.appendingPathComponent(freshName + ".mp3")
        if !FileManager.default.fileExists(atPath: file.path) {
          try await get(audioPath).write(to: file, options: .atomic)
        }
        let asset = AVURLAsset(url: file)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite && duration > querySeconds + 0.5 else {
          throw NSError(domain: "LyriKO", code: 3105, userInfo: [NSLocalizedDescriptionKey: "MP3 is shorter than the required query duration"])
        }
        // Read the actual MP3 as decoded PCM, just like DISCOVER's audio pipeline.
        // AVMutableComposition.signature(from:) generated invalid diagnostic queries.
        let preferredStart = duration > 65 ? 35.0 : (duration > 35 ? 12.0 : 0.0)
        let start = min(preferredStart, duration - querySeconds - 0.25)
        let excerpt = try makePCMQuerySignature(file: file, startSeconds: start,
                                                 querySeconds: querySeconds)
        let actualSeconds = excerpt.duration
        let details = String(format: "MP3 %.1fs, PCM at %.1fs, signature %.2fs", duration, start, actualSeconds)
        guard actualSeconds.isFinite,
              actualSeconds >= minQuery,
              actualSeconds <= maxQuery else {
          lines.append("\(title): INVALID QUERY SIGNATURE (\(details); allowed \(String(format: "%.2f–%.2f", minQuery, maxQuery))s)")
          continue
        }
        let session = SHSession(catalog: testCatalog)
        let outcome = await session.result(from: excerpt)
        switch outcome {
        case .match(let match):
          let observed = match.mediaItems.first?.title ?? "(unknown)"
          let ok = observed.caseInsensitiveCompare(title) == .orderedSame
          lines.append("\(title): \(ok ? "MATCH" : "WRONG SONG") → \(observed) [\(details)]")
        case .noMatch:
          lines.append("\(title): NO MATCH [\(details)]")
        case .error(let error, _):
          let native = error as NSError
          lines.append("\(title): SHAZAM ERROR \(native.domain) \(native.code): \(native.localizedDescription) [\(details)]")
        @unknown default:
          lines.append("\(title): UNKNOWN RESULT")
        }
      } catch {
        lines.append("\(title): FAILED: \(error.localizedDescription)")
      }
    }
    let report = lines.joined(separator: "\n")
    print("LyriKO reference diagnostic:\n" + report)
    return report
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
    lastRecognizedTitle = ""
    lastRecognizedArtist = ""
    lastRecognizedAt = .distantPast
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
      "catalogGenerationStatus": catalogGenerationStatus,
      "catalogReferenceCount": catalogReferenceCount,
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
    // Continue periodic PCM queries after a match as well: this detects track
    // changes without stopping DISCOVER or waiting for a new button press.
    if !signaturePending {
      do {
        let timeInWindow = AVAudioTime(sampleTime: signatureFrames,
                                       atRate: recognitionFormat.sampleRate)
        try signatureGenerator.append(output, at: timeInWindow)
        signatureFrames += Int64(output.frameLength)
        let targetFrames = signatureAttempts == 0 ? firstSignatureWindowFrames : retrySignatureWindowFrames
        if signatureFrames >= targetFrames {
          let signature = signatureGenerator.signature()
          signatureGenerator = SHSignatureGenerator()
          signatureFrames = 0
          guard let catalog = localCatalog else {
            throw NSError(domain: "Lyriko", code: 1005, userInfo: [
              NSLocalizedDescriptionKey: "Local acoustic catalog is not loaded"
            ])
          }
          // Keep streaming active. A finite PCM query is an independent fallback,
          // and its callbacks are filtered by session identity.
          streamingResponse = streamingSession == nil
            ? "streaming restarting" : "streaming + PCM signature fallback"
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
      let isSameSong = self.hasMatched &&
        self.lastRecognizedTitle.caseInsensitiveCompare(matchedTitle) == .orderedSame &&
        self.lastRecognizedArtist.caseInsensitiveCompare(matchedArtist) == .orderedSame
      self.lastRecognizedTitle = matchedTitle
      self.lastRecognizedArtist = matchedArtist
      self.lastRecognizedAt = Date()
      if isSameSong {
        self.signaturePending = false
        self.signatureSession = nil
        self.signatureResponse = "same song confirmed"
        return
      }
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
      self.signatureAttempts = 0
      self.signatureFrames = 0
      self.signatureGenerator = SHSignatureGenerator()
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
        // Re-arm the streaming session after any no-match, including before
        // the first successful identification.
        if self.phase == "listening" {
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
          // No arbitrary attempt limit: keep identifying as long as DISCOVER is on.
          // The next 8-second PCM window begins automatically.
          self.shazamState = "No match yet; continuing to listen"
          self.errorMessage = ""
        } else {
          self.streamingResponse = "no match"
        }
        // A non-match is not an error: leave DISCOVER active without a red warning.
        self.errorMessage = ""
      }
      print(self.errorMessage)
    }
  }
}
