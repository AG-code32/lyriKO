import Flutter
import UIKit
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import AVFoundation
import AVKit
import ShazamKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosAudioProbe: IOSAudioProbe?
  private var iosMicRecognition: IOSMicrophoneRecognition?
  private var lyricsPiPPrototype: IOSLyricsVideoPiPTest?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Isolated iOS PiP feasibility test. Recognition channels remain unchanged.
    let pipPrototype = IOSLyricsVideoPiPTest()
    lyricsPiPPrototype = pipPrototype
    let pipChannel = FlutterMethodChannel(
      name: "lyriko/ios_pip_prototype",
      binaryMessenger: engineBridge.pluginRegistry.registrar(forPlugin: "LyrikoIOSPiPPrototype")!.messenger()
    )
    pipPrototype.eventChannel = pipChannel
    pipChannel.setMethodCallHandler { [weak pipPrototype] call, result in
      guard let pipPrototype else {
        result(FlutterError(code: "PIP_UNAVAILABLE", message: "PiP prototype unavailable", details: nil))
        return
      }
      switch call.method {
      case "start": pipPrototype.start(result: result)
      case "stop": pipPrototype.stop(result: result)
      case "update": pipPrototype.update(arguments: call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }

    let probe = IOSAudioProbe()
    iosAudioProbe = probe
    let mic = IOSMicrophoneRecognition()
    iosMicRecognition = mic
    let channel = FlutterMethodChannel(name: "lyriko/ios_audio_probe", binaryMessenger: engineBridge.pluginRegistry.registrar(forPlugin: "LyrikoIOSAudioProbe")!.messenger())
    channel.setMethodCallHandler { [weak probe, weak mic] call, result in
      guard let probe, let mic else { result(FlutterError(code: "UNAVAILABLE", message: "Audio probe unavailable", details: nil)); return }
      switch call.method {
      case "prepareCatalog":
        let args = call.arguments as? [String: String] ?? [:]
        IOSRemoteCatalogStore.shared.prepare(
          serverURL: args["serverUrl"] ?? "", token: args["token"] ?? "", result: result)
      case "start": probe.start(result: result)
      case "stats": result(probe.stats())
      case "stop": probe.stop(result: result)
      case "startMic": mic.start(result: result)
      case "micStats": result(mic.stats())
      case "stopMic": mic.stop(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}


// The Windows server publishes the authoritative ShazamKit catalog.
// Download before Listen/Discover; keep the last validated catalog for offline use.
// This does not upload microphone or system audio to Windows.
private final class IOSRemoteCatalogStore {
  static let shared = IOSRemoteCatalogStore()
  private let lock = NSLock()
  private var loadedCatalog: SHCustomCatalog?

  private init() {}

  func current() -> SHCustomCatalog? {
    lock.lock(); defer { lock.unlock() }
    return loadedCatalog
  }

  private func store(_ catalog: SHCustomCatalog) {
    lock.lock(); loadedCatalog = catalog; lock.unlock()
  }

  private func cacheURL() throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return directory.appendingPathComponent("lyriko_windows_catalog.shazamcatalog")
  }

  func prepare(serverURL: String, token: String, result: @escaping FlutterResult) {
    let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !token.isEmpty, let url = URL(string: base + "/api/catalog/shazam"),
          url.scheme == "https" || (url.scheme == "http" && (url.host == "localhost" || url.host == "127.0.0.1")) else {
      result(FlutterError(code: "CATALOG_SETTINGS", message: "Configure the HTTPS Windows server URL and token in Server Settings", details: nil))
      return
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      var outcome: Result<SHCustomCatalog, Error>
      do {
        if let error { throw error }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? -1
          throw NSError(domain: "LyrikoCatalog", code: code, userInfo: [NSLocalizedDescriptionKey: "Windows catalog HTTP \(code)"])
        }
        guard let data, !data.isEmpty else {
          throw NSError(domain: "LyrikoCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Windows catalog is empty"])
        }
        let catalog = try SHCustomCatalog(dataRepresentation: data)
        // Persist only after ShazamKit validates the downloaded catalog.
        try data.write(to: self.cacheURL(), options: .atomic)
        outcome = .success(catalog)
      } catch {
        // Keep the last verified local copy when Windows is unreachable.
        if (response as? HTTPURLResponse) == nil,
           let cached = try? Data(contentsOf: self.cacheURL()),
           let catalog = try? SHCustomCatalog(dataRepresentation: cached) {
          outcome = .success(catalog)
        } else {
          outcome = .failure(error)
        }
      }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let catalog):
          self.store(catalog)
          result(true)
        case .failure(let error):
          result(FlutterError(code: "CATALOG_UNAVAILABLE", message: error.localizedDescription, details: nil))
        }
      }
    }.resume()
  }
}

// Diagnostic-only probe. Audio is not recorded or uploaded.
@available(iOS 27.0, *)
private final class IOSAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate, SHSessionDelegate {
  private var stream: SCStream?
  private var shazamSession: SHSession?
  private var catalog: SHCustomCatalog?
  private var matchedTitle = ""
  private var matchedArtist = ""
  private var matchedOffset = -1.0
  private var matchedEpochMs: Int64 = 0
  private var matchSequence = 0
  private var nextSessionResetMs: Int64 = 0
  private var shazamStatus = "not initialized"
  private var lastSignalEpochMs: Int64 = 0
  private var lastAudioEpochMs: Int64 = 0
  private let picker = SCContentSharingPicker.shared
  private let audioQueue = DispatchQueue(label: "lyriko.ios.audio-probe")
  private let lock = NSLock()
  private var buffers = 0
  private var bytes = 0
  private var sampleFrames = 0
  private var buffersWithPayload = 0
  private var buffersWithSignal = 0
  private var videoBuffers = 0
  private var rms = 0.0
  private var peak = 0.0
  private var audioFormat = "unknown"
  private var diagnosis = "waiting for audio"
  private var lastError = ""
  private var phase = "idle"

  func begin() {
    guard let catalog = IOSRemoteCatalogStore.shared.current() else {
      fail("Windows ShazamKit catalog has not been prepared")
      return
    }
    self.catalog = catalog
    let session = SHSession(catalog: catalog)
    session.delegate = self
    shazamSession = session
    lock.lock()
    phase = "picker"
    buffers = 0; bytes = 0; sampleFrames = 0
    buffersWithPayload = 0; buffersWithSignal = 0; videoBuffers = 0
    rms = 0; peak = 0; audioFormat = "unknown"
    diagnosis = "waiting for audio"; lastError = ""
    matchedTitle = ""; matchedArtist = ""; matchedOffset = -1
    matchedEpochMs = 0; matchSequence = 0; nextSessionResetMs = 0
    lastSignalEpochMs = 0; lastAudioEpochMs = 0
    shazamStatus = "listening"
    lock.unlock()
    picker.add(self)
    picker.isActive = true
    picker.present()
  }

  func snapshot() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return [
      "phase": phase, "audioBuffers": buffers, "audioBytes": bytes,
      "sampleFrames": sampleFrames, "payloadBuffers": buffersWithPayload,
      "signalBuffers": buffersWithSignal, "videoBuffers": videoBuffers,
      "rms": rms, "peak": peak, "format": audioFormat,
      "diagnosis": diagnosis, "error": lastError,
      "matchedTitle": matchedTitle, "matchedArtist": matchedArtist,
      "matchedOffset": matchedOffset, "shazamStatus": shazamStatus,
      "matchedEpochMs": matchedEpochMs, "matchSequence": matchSequence,
      "lastSignalEpochMs": lastSignalEpochMs,
      "lastAudioEpochMs": lastAudioEpochMs
    ]
  }

  func stop() async {
    if let stream { try? await stream.stopCapture() }
    stream = nil
    picker.remove(self)
    picker.isActive = false
    lock.lock(); shazamSession = nil; phase = "stopped"; lock.unlock()
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
    Task { @MainActor in
      do {
        if let old = self.stream { try? await old.stopCapture() }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.main)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.stream = capture
        try await capture.startCapture()
        self.lock.lock(); self.phase = "capturing"; self.lock.unlock()
      } catch {
        self.fail(error.localizedDescription)
      }
    }
  }

  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    lock.lock(); phase = "cancelled"; lock.unlock()
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) { fail(error.localizedDescription) }

  func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error.localizedDescription) }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard sampleBuffer.isValid else { return }
    if outputType == .screen {
      lock.lock(); videoBuffers += 1; lock.unlock()
      return
    }
    guard outputType == .audio else { return }

    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    var formatName = "no format description"
    var formatFlags: AudioFormatFlags = 0
    var bitsPerChannel: UInt32 = 0
    if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
      let subtype = CMFormatDescriptionGetMediaSubType(description)
      let code = fourCC(subtype)
      if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
        formatFlags = asbd.mFormatFlags
        bitsPerChannel = asbd.mBitsPerChannel
        formatName = "\(code) \(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch \(bitsPerChannel)bit"
      } else {
        formatName = code
      }
    }

    // A PCM CMSampleBuffer can have no CMBlockBuffer even when it contains audio.
    // Read its actual AudioBufferList rather than GetTotalSampleSize().
    var requiredSize = 0
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &requiredSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: nil
    )
    var payload = 0
    var sumSquares = 0.0
    var inspected = 0
    var maxAmplitude = 0.0
    var conversion = "unsupported PCM format"
    // The first call normally returns kCMSampleBufferError_ArrayTooSmall.
    // The required byte count is the authoritative allocation size.
    if requiredSize > 0 {
      let memory = UnsafeMutableRawPointer.allocate(
        byteCount: requiredSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
      )
      defer { memory.deallocate() }
      let bufferList = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
      var retainedBlock: CMBlockBuffer?
      let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: bufferList,
        bufferListSize: requiredSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: &retainedBlock
      )
      if status == noErr {
        // Keep retainedBlock alive until after the audio payload is inspected.
        withExtendedLifetime(retainedBlock) {
          for audioBuffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            let count = Int(audioBuffer.mDataByteSize)
            guard count > 0, let data = audioBuffer.mData else { continue }
            payload += count
            let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
            let isSigned = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
            if isFloat && bitsPerChannel == 32 {
              conversion = "float32 PCM"
              let floats = data.assumingMemoryBound(to: Float.self)
              for i in 0..<(count / MemoryLayout<Float>.size) {
                let value = Double(floats[i])
                if value.isFinite {
                  sumSquares += value * value
                  maxAmplitude = max(maxAmplitude, abs(value))
                  inspected += 1
                }
              }
            } else if isSigned && bitsPerChannel == 16 {
              conversion = "signed16 PCM"
              let values = data.assumingMemoryBound(to: Int16.self)
              for i in 0..<(count / MemoryLayout<Int16>.size) {
                let value = Double(values[i]) / 32768.0
                sumSquares += value * value
                maxAmplitude = max(maxAmplitude, abs(value))
                inspected += 1
              }
            }
          }
        }
      } else {
        conversion = "AudioBufferList OSStatus \(status)"
      }
    } else {
      conversion = "AudioBufferList size unavailable (OSStatus \(sizeStatus))"
    }
    // Give streaming PCM to ShazamKit, preserving the captured audio format.
    // Only feed valid signal; the source may be silent when playback is paused.
    if payload > 0 && inspected > 0 && maxAmplitude > 0.0001,
       let session = currentShazamSession(),
       let description = CMSampleBufferGetFormatDescription(sampleBuffer),
       let sourceASBD = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
      var asbd = sourceASBD.pointee
      if let avFormat = AVAudioFormat(streamDescription: &asbd),
         let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) {
        pcm.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        var requiredBytes = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
          sampleBuffer, bufferListSizeNeededOut: &requiredBytes,
          bufferListOut: nil, bufferListSize: 0,
          blockBufferAllocator: kCFAllocatorDefault,
          blockBufferMemoryAllocator: kCFAllocatorDefault,
          flags: 0, blockBufferOut: nil)
        if requiredBytes > 0 {
          let raw = UnsafeMutableRawPointer.allocate(
            byteCount: requiredBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
          defer { raw.deallocate() }
          let sources = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
          var retained: CMBlockBuffer?
          let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: sources, bufferListSize: requiredBytes,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &retained)
          if status == noErr {
            withExtendedLifetime(retained) {
              let sourceList = UnsafeMutableAudioBufferListPointer(sources)
              if sourceList.count == destination.count {
                for i in 0..<sourceList.count {
                  if let src = sourceList[i].mData, let dst = destination[i].mData {
                    let count = min(Int(sourceList[i].mDataByteSize), Int(destination[i].mDataByteSize))
                    memcpy(dst, src, count)
                  }
                }
                session.matchStreamingBuffer(pcm, at: nil)
              }
            }
          }
        }
      }
    }

    let latestRMS = inspected > 0 ? sqrt(sumSquares / Double(inspected)) : 0.0
    lock.lock()
    let timeMs = Int64(Date().timeIntervalSince1970 * 1000)
    buffers += 1
    lastAudioEpochMs = timeMs
    if latestRMS > 0.001 && maxAmplitude > 0.005 {
      lastSignalEpochMs = timeMs
    }
    sampleFrames += frames
    bytes += payload
    if payload > 0 { buffersWithPayload += 1 }
    if maxAmplitude > 0.0001 { buffersWithSignal += 1 }
    rms = latestRMS
    peak = maxAmplitude
    audioFormat = formatName
    diagnosis = conversion
    lock.unlock()
  }

  func session(_ session: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    var shouldReset = false
    lock.lock()
    // Discard callbacks from sessions that were already replaced.
    if session === shazamSession && phase == "capturing" {
      matchedTitle = item.title ?? ""
      matchedArtist = item.artist ?? ""
      matchedOffset = item.matchOffset
      matchedEpochMs = now
      matchSequence += 1
      shazamStatus = "matched #\(matchSequence)"
      if now >= nextSessionResetMs {
        nextSessionResetMs = now + 5000
        shouldReset = true
      }
    }
    lock.unlock()
    if shouldReset {
      // A custom-catalog SHSession may stop reporting after a successful match.
      // Re-arm it periodically while capture remains active, on the serial audio queue.
      audioQueue.asyncAfter(deadline: .now() + 2.0) { [weak self, weak session] in
        guard let self, let oldSession = session else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.phase == "capturing", self.shazamSession === oldSession else { return }
        guard let catalog = self.catalog else { return }
        let freshSession = SHSession(catalog: catalog)
        freshSession.delegate = self
        self.shazamSession = freshSession
        self.shazamStatus = "listening for next position"
      }
    }
  }

  private func currentShazamSession() -> SHSession? {
    lock.lock(); defer { lock.unlock() }
    return shazamSession
  }

  func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    lock.lock()
    shazamStatus = error == nil ? "still listening" : "error: \(error!.localizedDescription)"
    lock.unlock()
  }

  private func fourCC(_ value: FourCharCode) -> String {
    let chars: [UInt8] = [
      UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
    ]
    return String(bytes: chars, encoding: .ascii) ?? "\(value)"
  }

  private func fail(_ message: String) {
    lock.lock(); lastError = message; phase = "error"; lock.unlock()
  }
}

private final class IOSAudioProbe {
  private var capture: AnyObject?

  func start(result: @escaping FlutterResult) {
    guard #available(iOS 27.0, *) else {
      result(FlutterError(code: "IOS_VERSION", message: "Requires iOS 27", details: nil)); return
    }
    let instance = IOSAudioCapture()
    capture = instance
    instance.begin()
    result(true)
  }

  func stats() -> [String: Any] {
    if #available(iOS 27.0, *), let instance = capture as? IOSAudioCapture {
      return instance.snapshot()
    }
    return ["phase": "idle", "audioBuffers": 0, "audioBytes": 0, "error": ""]
  }

  func stop(result: @escaping FlutterResult) {
    if #available(iOS 27.0, *), let instance = capture as? IOSAudioCapture {
      Task { await instance.stop(); self.capture = nil; result(true) }
    } else { result(true) }
  }
}

// Discover (ambient music): entirely separate from the existing ScreenCaptureKit probe.
// Recognition uses the same local SHCustomCatalog, not Shazam's online database.
private final class IOSMicrophoneRecognition: NSObject, SHSessionDelegate {
  private var engine: AVAudioEngine?
  private var session: SHSession?
  private let lock = NSLock()
  private var phase = "idle"
  private var lastError = ""
  private var matchedTitle = ""
  private var matchedArtist = ""
  private var matchedOffset = -1.0
  private var bufferCount = 0
  private var lastSignalEpochMs: Int64 = 0
  private var lastBufferEpochMs: Int64 = 0
  private var microphoneRms: Double = 0
  // Retain an envelope of music volume, rather than interpreting room noise
  // above a fixed low threshold as ongoing playback.
  private var referenceRms: Double = 0
  private var lastMusicEpochMs: Int64 = 0
  // Discover's music gate is armed by an actual Shazam match. Room noise alone
  // cannot start it. Short quiet passages are tolerated with hysteresis.
  private var musicGateOpen = false
  private var belowMusicGateSinceMs: Int64 = 0
  private var aboveMusicGateSinceMs: Int64 = 0
  private var matchedEpochMs: Int64 = 0
  private var matchSequence = 0
  private var catalog: SHCustomCatalog?

  func start(result: @escaping FlutterResult) {
    // Microphone use is foreground-only for now.
    guard engine == nil else { result(true); return }
    guard let catalog = IOSRemoteCatalogStore.shared.current() else {
      result(FlutterError(code: "CATALOG_UNAVAILABLE", message: "Windows ShazamKit catalog has not been prepared", details: nil))
      return
    }
    self.catalog = catalog
    let newSession = SHSession(catalog: catalog)
    newSession.delegate = self
    session = newSession
    lock.lock()
    phase = "requesting permission"
    lastError = ""; matchedTitle = ""; matchedArtist = ""; matchedOffset = -1; bufferCount = 0
    lastSignalEpochMs = 0; lastBufferEpochMs = 0; microphoneRms = 0; referenceRms = 0; lastMusicEpochMs = 0
    musicGateOpen = false; belowMusicGateSinceMs = 0; aboveMusicGateSinceMs = 0
    matchedEpochMs = 0; matchSequence = 0
    lock.unlock()
    AVAudioApplication.requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { result(FlutterError(code: "UNAVAILABLE", message: "Microphone service unavailable", details: nil)); return }
        guard granted else {
          self.setPhase("denied", error: "Microphone permission denied. Enable it in iPhone Settings > Privacy & Security > Microphone.")
          result(FlutterError(code: "MIC_PERMISSION", message: "Microphone permission denied", details: nil))
          return
        }
        do {
          let avSession = AVAudioSession.sharedInstance()
          // Discover records from the iPhone's built-in microphone, never from
          // a Bluetooth hands-free microphone. Keep high-quality Bluetooth
          // playback (A2DP) available while recording ambient sound.
          try avSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothA2DP]
          )
          try avSession.setActive(true)
          guard let builtInMic = avSession.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw NSError(
              domain: "LyrikoDiscover",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "iPhone built-in microphone unavailable"]
            )
          }
          try avSession.setPreferredInput(builtInMic)
          let capture = AVAudioEngine()
          let node = capture.inputNode
          let format = node.outputFormat(forBus: 0)
          guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LyrikoDiscover", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input format available"])
          }
          node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, audioTime in
            guard let self else { return }
            guard let shazam = self.session else { return }
            shazam.matchStreamingBuffer(buffer, at: audioTime)
            // Activity is not evidence of music: capture noise continuously for
            // recognition, but run the lyric clock only after a Shazam-confirmed
            // song and while the signal resembles its recent loudness.
            var level = 0.0
            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
              let count = Int(buffer.frameLength)
              let samples = channels[0]
              var sum = 0.0
              var examined = 0
              for index in stride(from: 0, to: count, by: 8) {
                let value = Double(samples[index])
                sum += value * value
                examined += 1
              }
              level = sqrt(sum / Double(max(1, examined)))
            }
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            self.lock.lock()
            self.bufferCount += 1
            self.lastBufferEpochMs = timestamp
            self.microphoneRms = level
            if self.musicGateOpen {
              // More selective music activity gate: the room fan was keeping
              // the original 22%-of-reference threshold open after playback stopped.
              // Keep the matched-song level as the reference through quiet buffers;
              // otherwise the reference drifts down to the fan's background noise.
              let quietLimit = max(0.0015, self.referenceRms * 0.55)
              if level < quietLimit {
                if self.belowMusicGateSinceMs == 0 {
                  self.belowMusicGateSinceMs = timestamp
                } else if timestamp - self.belowMusicGateSinceMs >= 550 {
                  self.musicGateOpen = false
                  self.aboveMusicGateSinceMs = 0
                }
              } else {
                // Update the reference only for buffers that qualify as music.
                // Track louder material promptly, but decay very slowly to
                // avoid adapting to persistent background noise during pauses.
                let alpha = level > self.referenceRms ? 0.035 : 0.00015
                self.referenceRms = self.referenceRms * (1 - alpha) + level * alpha
                self.belowMusicGateSinceMs = 0
                self.lastSignalEpochMs = timestamp
                self.lastMusicEpochMs = timestamp
              }
            } else if self.matchSequence > 0 {
              // Require a larger, sustained rise before waking from a pause.
              // A sudden fan/transient alone should not usually restart lyrics.
              let wakeLimit = max(0.0020, self.referenceRms * 0.85)
              if level >= wakeLimit {
                if self.aboveMusicGateSinceMs == 0 {
                  self.aboveMusicGateSinceMs = timestamp
                } else if timestamp - self.aboveMusicGateSinceMs >= 300 {
                  self.musicGateOpen = true
                  self.belowMusicGateSinceMs = 0
                  self.lastSignalEpochMs = timestamp
                  self.lastMusicEpochMs = timestamp
                }
              } else {
                self.aboveMusicGateSinceMs = 0
              }
            }
            self.lock.unlock()
          }
          self.engine = capture
          capture.prepare()
          try capture.start()
          self.setPhase("listening")
          result(true)
        } catch {
          self.cleanup()
          self.setPhase("error", error: error.localizedDescription)
          result(FlutterError(code: "MIC_START", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func stats() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return [
      "phase": phase, "error": lastError, "matchedTitle": matchedTitle,
      "matchedArtist": matchedArtist, "matchedOffset": matchedOffset,
      "audioBuffers": bufferCount,
      "lastBufferEpochMs": lastBufferEpochMs,
      "microphoneRms": microphoneRms,
      "referenceRms": referenceRms,
      "musicGateOpen": musicGateOpen,
      "lastMusicEpochMs": lastMusicEpochMs,
      "lastSignalEpochMs": lastSignalEpochMs,
      "matchedEpochMs": matchedEpochMs,
      "matchSequence": matchSequence
    ]
  }

  func stop(result: @escaping FlutterResult) {
    cleanup()
    setPhase("stopped")
    result(true)
  }

  private func cleanup() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    session = nil
    catalog = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func setPhase(_ newPhase: String, error: String = "") {
    lock.lock(); phase = newPhase; lastError = error; lock.unlock()
  }

  func session(_ session: SHSession, didFind match: SHMatch) {
    guard let item = match.mediaItems.first else { return }
    lock.lock()
    guard self.session === session else { lock.unlock(); return }
    matchedTitle = item.title ?? ""
    matchedArtist = item.artist ?? ""
    matchedOffset = item.matchOffset
    matchedEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
    matchSequence += 1
    // Only a verified acoustic match can initially arm this music detector.
    // Reset reference on re-entry from silence, so changing songs works as before.
    if !musicGateOpen {
      referenceRms = max(0.0007, microphoneRms)
    }
    musicGateOpen = true
    belowMusicGateSinceMs = 0
    aboveMusicGateSinceMs = 0
    lastMusicEpochMs = matchedEpochMs
    lastSignalEpochMs = matchedEpochMs
    phase = "matched"
    lock.unlock()

    // Recreate the custom-catalog session for subsequent positional matches.
    // The AVAudioEngine tap remains active throughout Discover.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak session] in
      guard let self, let session else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      guard self.engine != nil, self.session === session, let catalog = self.catalog else { return }
      let newSession = SHSession(catalog: catalog)
      newSession.delegate = self
      self.session = newSession
      self.phase = "listening"
    }
  }

  func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
    if let error { setPhase("listening", error: error.localizedDescription) }
  }
}


// EXPERIMENTAL: validates whether iOS permits video-call PiP for Lyriko's
// lyric-like content. This is NOT production lyrics overlay or App Store approval.
@available(iOS 15.0, *)
private final class IOSLyricsPiPPrototype: NSObject, AVPictureInPictureControllerDelegate {
  private var controller: AVPictureInPictureController?
  private var sourceView: UIView?
  private var possibilityObserver: NSKeyValueObservation?
  private var pendingStart = false
  private var startInvoked = false
  private var stopping = false
  // A request is only successful once iOS confirms the PiP transition.
  private var startReply: FlutterResult?
  private var startTimeout: Timer?
  weak var eventChannel: FlutterMethodChannel?
  private var pipViewController: AVPictureInPictureVideoCallViewController?
  private var titleLabel: UILabel?
  private var previousLabel: UILabel?
  private var currentLabel: UILabel?
  private var nextLabel: UILabel?
  private var lines: [(text: String, start: Int, end: Int)] = []
  private var positionMs = 0
  private var playing = false
  private var lastUpdate = Date()
  private var displayTimer: Timer?

  func start(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(FlutterError(code: "PIP_UNSUPPORTED", message: "Picture in Picture is not supported", details: nil))
        return
      }
      if self.controller?.isPictureInPictureActive == true {
        result(true)
        return
      }
      if self.stopping {
        result(FlutterError(code: "PIP_STOPPING", message: "iOS is finishing the previous PiP session; try again", details: nil))
        return
      }
      if self.pendingStart {
        // A second TEST press must not leave the user permanently blocked.
        // If iOS has not accepted the request, cancel that pending attempt
        // and let the next press build a fresh controller.
        if self.startInvoked {
          result(FlutterError(code: "PIP_STARTING", message: "iOS is processing the PiP request", details: nil))
        } else {
          self.finishStart(error: FlutterError(code: "PIP_RETRY", message: "PiP request reset; press TEST again", details: nil))
          self.releaseController()
          result(FlutterError(code: "PIP_RETRY", message: "PiP request reset; press TEST again", details: nil))
        }
        return
      }
      guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) else {
        result(FlutterError(code: "PIP_WINDOW", message: "No active iOS window", details: nil))
        return
      }

      // A stopped PiP session is released in the native stop callback.
      // Never reuse a controller that iOS has already dismissed.
      if self.controller != nil { self.releaseController() }
      // PiP requires an inline source view. Keep it non-interactive and
      // unobtrusive; the lyrics are displayed in the PiP content view.
      let source = UIView(frame: CGRect(x: 2,
                                       y: window.safeAreaInsets.top + 2,
                                       width: 14, height: 14))
      source.backgroundColor = UIColor(white: 0.2, alpha: 0.08)
      source.isUserInteractionEnabled = false
      window.addSubview(source)
      self.sourceView = source

      let vc = AVPictureInPictureVideoCallViewController()
      vc.preferredContentSize = CGSize(width: 360, height: 240)
      let content = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
      content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      content.backgroundColor = .black
      func makeLabel(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        return label
      }
      let title = makeLabel(11, .semibold, UIColor.white.withAlphaComponent(0.60))
      let previous = makeLabel(15, .regular, UIColor.white.withAlphaComponent(0.55))
      let current = makeLabel(25, .bold, .white)
      let next = makeLabel(15, .regular, UIColor.white.withAlphaComponent(0.55))
      let stack = UIStackView(arrangedSubviews: [title, previous, current, next])
      stack.axis = .vertical
      stack.alignment = .fill
      stack.distribution = .fill
      stack.spacing = 9
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
      ])
      vc.view.addSubview(content)
      self.pipViewController = vc
      self.titleLabel = title
      self.previousLabel = previous
      self.currentLabel = current
      self.nextLabel = next
      self.refresh()

      let pipContentSource = AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: source, contentViewController: vc)
      let pip = AVPictureInPictureController(contentSource: pipContentSource)
      pip.delegate = self
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      self.controller = pip
      self.pendingStart = true
      self.startInvoked = false
      self.startReply = result
      self.scheduleStartTimeout()
      self.possibilityObserver = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
        DispatchQueue.main.async {
          guard let self, self.pendingStart, !self.startInvoked,
                observed.isPictureInPicturePossible else { return }
          self.startInvoked = true
          observed.startPictureInPicture()
        }
      }
      self.displayTimer = Timer.scheduledTimer(timeInterval: 0.12, target: self,
                                                selector: #selector(self.tick), userInfo: nil, repeats: true)
    }
  }

  private func scheduleStartTimeout() {
    startTimeout?.invalidate()
    // A timeout reports failure to Flutter, but does not destroy the PiP
    // controller. The next TEST press can retry using the same instance.
    startTimeout = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
      guard let self, self.startReply != nil else { return }
      self.finishStart(error: FlutterError(
        code: "PIP_TIMEOUT",
        message: "iOS did not confirm PiP startup; try TEST again",
        details: nil))
      // Only release when the system did not actually enter PiP.
      if self.controller?.isPictureInPictureActive != true {
        self.releaseController()
      }
    }
  }

  private func finishStart(error: FlutterError? = nil) {
    startTimeout?.invalidate()
    startTimeout = nil
    pendingStart = false
    startInvoked = false
    let reply = startReply
    startReply = nil
    if let error { reply?(error) }
    else { reply?(true) }
  }

  func update(arguments: Any?, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let data = arguments as? [String: Any] else {
        result(FlutterError(code: "PIP_DATA", message: "Invalid lyrics state", details: nil))
        return
      }
      if let title = data["title"] as? String, let artist = data["artist"] as? String {
        self.titleLabel?.text = "\(artist) — \(title)"
      }
      if let raw = data["lines"] as? [[String: Any]] {
        self.lines = raw.compactMap { entry in
          guard let text = entry["text"] as? String,
                let start = entry["startMs"] as? Int,
                let end = entry["endMs"] as? Int else { return nil }
          return (text: text, start: start, end: end)
        }
      }
      if let position = data["positionMs"] as? Int { self.positionMs = position }
      if let playing = data["playing"] as? Bool { self.playing = playing }
      self.lastUpdate = Date()
      self.refresh()
      result(true)
    }
  }

  @objc private func tick() {
    // Extrapolate locally if Flutter is suspended. This does not imply that
    // iOS continues acoustic recognition or can detect remote playback pauses.
    refresh()
  }

  private func refresh() {
    let elapsed = playing ? max(0, Int(Date().timeIntervalSince(lastUpdate) * 1000)) : 0
    let effectivePosition = positionMs + elapsed
    guard !lines.isEmpty else {
      currentLabel?.text = "Waiting for synced lyrics…"
      previousLabel?.text = nil
      nextLabel?.text = nil
      return
    }
    let active = lines.lastIndex(where: { $0.start <= effectivePosition }) ?? 0
    previousLabel?.text = active > 0 ? lines[active - 1].text : ""
    currentLabel?.text = lines[active].text
    nextLabel?.text = active + 1 < lines.count ? lines[active + 1].text : ""
  }

  private func releaseController() {
    // Do not release an active controller before iOS has finished stopping it.
    guard controller?.isPictureInPictureActive != true else { return }
    startTimeout?.invalidate()
    startTimeout = nil
    possibilityObserver?.invalidate()
    possibilityObserver = nil
    displayTimer?.invalidate()
    displayTimer = nil
    controller?.delegate = nil
    controller = nil
    sourceView?.removeFromSuperview()
    sourceView = nil
    pipViewController = nil
    titleLabel = nil
    previousLabel = nil
    currentLabel = nil
    nextLabel = nil
    pendingStart = false
    startInvoked = false
    stopping = false
  }

  func stop(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      if self.startReply != nil {
        self.finishStart(error: FlutterError(code: "PIP_CANCELLED", message: "PiP opening was cancelled", details: nil))
      }
      if self.controller?.isPictureInPictureActive == true {
        self.stopping = true
        self.controller?.stopPictureInPicture()
      } else if !self.stopping {
        self.releaseController()
      }
      result("PiP stop requested")
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    finishStart()
    eventChannel?.invokeMethod("pipState", arguments: ["state": "started"])
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
    stopping = true
    eventChannel?.invokeMethod("pipState", arguments: ["state": "stopping"])
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    // iOS has completed dismissal. The next TEST uses a new native session.
    if startReply != nil {
      finishStart(error: FlutterError(code: "PIP_STOPPED", message: "PiP stopped before startup completed", details: nil))
    }
    releaseController()
    eventChannel?.invokeMethod("pipState", arguments: ["state": "stopped"])
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    // The Flutter home screen remains available. Confirm restoration to iOS.
    completionHandler(true)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
                                  failedToStartPictureInPictureWithError error: Error) {
    NSLog("Lyriko PiP failed: %@", error.localizedDescription)
    finishStart(error: FlutterError(code: "PIP_START_FAILED", message: error.localizedDescription, details: nil))
    eventChannel?.invokeMethod("pipState", arguments: ["state": "failed", "message": error.localizedDescription])
    releaseController()
  }
}


// iOS PiP v12.3: 60 FPS / 30-second AVPlayer playback diagnostic.
// The MP4 is a valid 30-second, 60 FPS H.264 clip. No song recognition code is modified.
@available(iOS 15.0, *)
private final class IOSLyricsVideoPiPTest: NSObject, AVPictureInPictureControllerDelegate {
  weak var eventChannel: FlutterMethodChannel?
  private var controller: AVPictureInPictureController?
  private var sourceView: UIView?
  private var playerLayer: AVPlayerLayer?
  private var player: AVPlayer?
  private var item: AVPlayerItem?
  private var itemObservation: NSKeyValueObservation?
  private var possibleObservation: NSKeyValueObservation?
  private var playbackObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var startTimeout: Timer?
  private var pendingResult: FlutterResult?
  private var state = "idle"
  private var itemReady = false
  private var pipPossible = false
  private var didRequestStart = false
  private var audioPrevious: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  // Lyric rendering is independent of AVPlayer's 60 FPS H.264 clock.
  // A single cached CIImage is reused for every decoded frame.
  private let lyricsLock = NSLock()
  private var lyricsFrame: CIImage?
  private var lyricLines: [(text: String, start: Int, end: Int)] = []
  private var lyricTitle = ""
  private var lyricArtist = ""
  private var lyricPositionMs = 0
  private var lyricPlaying = false
  private var lyricUpdatedAt = Date()
  private var lyricRefreshTimer: Timer?
  private var lastRenderedIndex = -999
  private var lastRenderedHeading = ""
  private var lastRenderedText = ""

  func start(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard AVPictureInPictureController.isPictureInPictureSupported() else {
        result(FlutterError(code: "PIP_UNSUPPORTED", message: "PiP unsupported", details: nil)); return
      }
      if self.controller?.isPictureInPictureActive == true { result(true); return }
      guard self.state == "idle" else {
        result(FlutterError(code: "PIP_BUSY", message: "AVPlayer PiP state: \(self.state)", details: nil)); return
      }
      guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) else {
        result(FlutterError(code: "PIP_WINDOW", message: "No active window", details: nil)); return
      }
      do {
        let audio = AVAudioSession.sharedInstance()
        // Discover runs an AVAudioEngine microphone tap with a playAndRecord
        // session. Switching to playback while that engine is running can
        // invalidate its input route and prevent PiP from becoming possible.
        // playAndRecord is itself a playback-capable category: preserve it.
        if audio.category == .playAndRecord {
          self.audioPrevious = nil
          self.log("preserving Discover playAndRecord session (mode=\(audio.mode.rawValue))")
          // Do not call setActive/setCategory: Discover owns this live session.
        } else {
          self.audioPrevious = (audio.category, audio.mode, audio.categoryOptions)
          try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
          try audio.setActive(true)
          self.log("configured playback session for PiP")
        }
        let clip = try self.videoURL()
        let asset = AVURLAsset(url: clip)
        let item = AVPlayerItem(asset: asset)
        self.item = item
        // Observe the actual item directly. AVQueuePlayer + AVPlayerLooper
        // can replace currentItem before its observer is attached.
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player
        self.endObserver = NotificationCenter.default.addObserver(
          forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
          guard let self, self.item === item else { return }
          player.seek(to: .zero) { finished in
            if finished { DispatchQueue.main.async { player.play() } }
          }
        }

        let width: CGFloat = 112, height: CGFloat = 63
        let source = UIView(frame: CGRect(x: max(8, window.bounds.width - width - 12),
          y: window.safeAreaInsets.top + 72, width: width, height: height))
        source.backgroundColor = .black
        source.clipsToBounds = true
        source.layer.cornerRadius = 8
        source.isUserInteractionEnabled = false
        window.addSubview(source)
        self.sourceView = source
        let layer = AVPlayerLayer(player: player)
        layer.frame = source.bounds
        layer.videoGravity = .resizeAspect
        source.layer.addSublayer(layer)
        self.playerLayer = layer

        guard let pip = AVPictureInPictureController(playerLayer: layer) else {
          throw NSError(domain: "LyrikoPiP", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unable to create AVPlayer PiP controller"])
        }
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = pip
        self.state = "preparing"
        self.pendingResult = result
        self.log("preparing; video bytes=\((try? Data(contentsOf: clip).count) ?? -1)")

        self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
          DispatchQueue.main.async {
            guard let self, self.item === observed else { return }
            switch observed.status {
            case .readyToPlay:
              self.itemReady = true
              self.log("AVPlayerItem readyToPlay; duration=\(CMTimeGetSeconds(observed.duration))")
              self.tryStart()
            case .failed:
              self.fail("AVPlayerItem failed: \(observed.error?.localizedDescription ?? "unknown")")
            default:
              self.log("AVPlayerItem unknown (loading)")
            }
          }
        }
        self.playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
          DispatchQueue.main.async {
            guard let self, self.player === observed else { return }
            self.log("player timeControlStatus=\(observed.timeControlStatus.rawValue); reason=\(observed.reasonForWaitingToPlay?.rawValue ?? "none")")
          }
        }
        self.possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
          DispatchQueue.main.async {
            guard let self, self.controller === observed else { return }
            self.pipPossible = observed.isPictureInPicturePossible
            self.log("PiP possible=\(self.pipPossible)")
            self.tryStart()
          }
        }
        player.play()
        self.startTimeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
          guard let self, self.pendingResult != nil else { return }
          let error = self.item?.error?.localizedDescription ?? "none"
          let msg = "AVPlayer PiP timeout (state: \(self.state), itemStatus: \(self.item?.status.rawValue ?? -1), ready: \(self.itemReady), possible: \(self.pipPossible), active: \(self.controller?.isPictureInPictureActive == true), itemError: \(error))"
          self.log(msg)
          self.complete(FlutterError(code: "PIP_TIMEOUT", message: msg, details: nil))
          if self.state == "preparing" { self.cleanup() }
          // If iOS is already starting, await its delegate instead of tearing
          // down a live transition. The logs identify this separately.
        }
      } catch {
        self.log("setup error: \(error.localizedDescription)")
        self.complete(FlutterError(code: "PIP_SETUP", message: error.localizedDescription, details: nil))
        self.cleanup()
      }
    }
  }

  // Attach lyrics only after the stable H.264 player has entered PiP.
  // This avoids changing AVPlayerItem readiness / PiP eligibility during startup.
  private func enableLyricsRendering() {
    guard let item = item, item.videoComposition == nil else { return }
    let asset = item.asset
    let composition = AVVideoComposition(asset: asset) { [weak self] request in
      guard let self else {
        request.finish(with: request.sourceImage, context: nil)
        return
      }
      self.lyricsLock.lock()
      let overlay = self.lyricsFrame
      self.lyricsLock.unlock()
      let background = request.sourceImage
      if let overlay {
        request.finish(with: overlay.composited(over: background).cropped(to: background.extent), context: nil)
      } else {
        request.finish(with: background, context: nil)
      }
    }
    item.videoComposition = composition
    log("lyrics compositor attached after PiP didStart")
    refreshLyricsFrame(force: true)
    lyricRefreshTimer?.invalidate()
    lyricRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
      self?.refreshLyricsFrame(force: false)
    }
  }

  private func tryStart() {
    guard state == "preparing", itemReady, pipPossible, !didRequestStart,
          let pip = controller else { return }
    didRequestStart = true
    state = "starting"
    log("startPictureInPicture (item ready + PiP possible)")
    pip.startPictureInPicture()
  }

  func stop(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let pip = self.controller else { result(true); return }
      if pip.isPictureInPictureActive {
        self.state = "stopping"
        self.log("stop requested")
        pip.stopPictureInPicture()
      } else if self.state == "preparing" {
        self.complete(FlutterError(code: "PIP_CANCELLED", message: "PiP cancelled", details: nil))
        self.cleanup()
      } else {
        self.log("stop deferred while state=\(self.state)")
      }
      result(true)
    }
  }

  func update(arguments: Any?, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let data = arguments as? [String: Any] else {
        result(FlutterError(code: "PIP_DATA", message: "Invalid lyrics state", details: nil))
        return
      }
      if let title = data["title"] as? String { self.lyricTitle = title }
      if let artist = data["artist"] as? String { self.lyricArtist = artist }
      if let raw = data["lines"] as? [[String: Any]] {
        self.lyricLines = raw.compactMap { entry in
          guard let text = entry["text"] as? String,
                let start = (entry["startMs"] as? NSNumber)?.intValue,
                let end = (entry["endMs"] as? NSNumber)?.intValue else { return nil }
          return (text: text, start: start, end: end)
        }
      }
      if let position = (data["positionMs"] as? NSNumber)?.intValue {
        self.lyricPositionMs = position
      }
      if let playing = data["playing"] as? Bool { self.lyricPlaying = playing }
      self.lyricUpdatedAt = Date()
      self.refreshLyricsFrame(force: false)
      result(true)
    }
  }

  private func refreshLyricsFrame(force: Bool) {
    let elapsed = lyricPlaying ? max(0, Int(Date().timeIntervalSince(lyricUpdatedAt) * 1000)) : 0
    let position = lyricPositionMs + elapsed
    let index = lyricLines.lastIndex(where: { $0.start <= position }) ?? 0
    let heading = "\(lyricArtist) — \(lyricTitle)"
    let current = lyricLines.indices.contains(index) ? lyricLines[index].text : "Waiting for synced lyrics…"
    let previous = lyricLines.indices.contains(index - 1) ? lyricLines[index - 1].text : ""
    let next = lyricLines.indices.contains(index + 1) ? lyricLines[index + 1].text : ""
    let textKey = previous + "\u{001F}" + current + "\u{001F}" + next
    guard force || index != lastRenderedIndex || heading != lastRenderedHeading || textKey != lastRenderedText else { return }
    lastRenderedIndex = index
    lastRenderedHeading = heading
    lastRenderedText = textKey
    let size = CGSize(width: 320, height: 180)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { ctx in
      UIColor(red: 0.055, green: 0.045, blue: 0.11, alpha: 1).setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      func draw(_ value: String, y: CGFloat, height: CGFloat, fontSize: CGFloat,
                color: UIColor, weight: UIFont.Weight) {
        guard !value.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
          .foregroundColor: color, .paragraphStyle: style
        ]
        let rect = CGRect(x: 18, y: y, width: 284, height: height)
        (value as NSString).draw(in: rect, withAttributes: attributes)
      }
      draw(heading, y: 10, height: 22, fontSize: 11,
           color: UIColor.white.withAlphaComponent(0.72), weight: .medium)
      draw(previous, y: 43, height: 31, fontSize: 12,
           color: UIColor.white.withAlphaComponent(0.44), weight: .regular)
      draw(current, y: 76, height: 62, fontSize: 19,
           color: .white, weight: .bold)
      draw(next, y: 143, height: 32, fontSize: 12,
           color: UIColor.white.withAlphaComponent(0.44), weight: .regular)
    }
    guard let cg = image.cgImage else { return }
    // The AVVideoComposition render pipeline displays the previous overlay
    // rotated by 180 degrees (both axes inverted) on the iPhone. Correct that
    // orientation in CI space without changing the H.264 video track or PiP.
    let frame = CIImage(cgImage: cg)
      .transformed(by: CGAffineTransform(translationX: size.width, y: 0).scaledBy(x: -1, y: 1))
    lyricsLock.lock()
    lyricsFrame = frame
    lyricsLock.unlock()
  }


  private func videoURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyriko_pip_avplayer_v12_3_60fps.mp4")
    if !FileManager.default.fileExists(atPath: url.path) {
      guard let data = Data(base64Encoded: Self.embeddedVideoBase64) else {
        throw NSError(domain: "LyrikoPiP", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Embedded video data is invalid"])
      }
      try data.write(to: url, options: .atomic)
    }
    return url
  }

  private static let embeddedVideoBase64: String =
    "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAEUFbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAdTAAAQAAAQAA" +
    "AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA" +
    "RDB0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAdTAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA" +
    "AAAAAAAAAAAAAABAAAAAAUAAAAC0AAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAHUwAAACAAABAAAAAEOobWRpYQAAACBtZGhk" +
    "AAAAAAAAAAAAAAAAAAA8AAAHCABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAABDU21p" +
    "bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAQxNzdGJsAAAAv3N0c2QA" +
    "AAAAAAAAAQAAAK9hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAUAAtABIAAAASAAAAAAAAAABFUxhdmM2MS4xOS4xMDEgbGli" +
    "eDI2NAAAAAAAAAAAAAAAGP//AAAANWF2Y0MBZAAV/+EAGWdkABWs2UFBn58BEAAAAwAQAAAHgPFi2WABAAVo74VywP34+AAAAAAQ" +
    "cGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAABLRQAAAAAAAAAYc3R0cwAAAAAAAAABAAAHCAAAAQAAAAAwc3RzcwAAAAAAAAAIAAAA" +
    "AQAAAPsAAAH1AAAC7wAAA+kAAATjAAAF3QAABtcAACWgY3R0cwAAAAAAAASyAAAAAQAAAgAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAIAAAIAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAMAAAAAAQAAAQAAAAABAAACAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAAAgAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAIAAAIAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAMAAAAAAQAAAQAAAAABAAACAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAAAgAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEA" +
    "AAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEA" +
    "AAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAA" +
    "AgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAA" +
    "BAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAA" +
    "AAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAAC" +
    "AAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAE" +
    "AAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAA" +
    "AAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAA" +
    "AQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAA" +
    "AAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAAB" +
    "AAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAAB" +
    "AAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAA" +
    "AAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAIAAAIAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIA" +
    "AAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQA" +
    "AAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAA" +
    "AQAABAAAAAACAAABAAAAAAEAAAQAAAAAAgAAAQAAAAABAAAEAAAAAAIAAAEAAAAAAQAABAAAAAACAAABAAAAABxzdHNjAAAAAAAA" +
    "AAEAAAABAAAHCAAAAAEAABw0c3RzegAAAAAAAAAAAAAHCAAABm8AAABOAAAAKQAAABsAAAA0AAAAJAAAAB4AAAAgAAAAKgAAAB0A" +
    "AAA4AAAAIgAAABsAAAAeAAAAKgAAABsAAAAnAAAAIgAAABsAAAAfAAAAKgAAABsAAAAzAAAAIgAAABwAAAAbAAAAKgAAABgAAAA2" +
    "AAAAIwAAABkAAAAfAAAAKgAAABgAAAAvAAAAIgAAABsAAAAfAAAAKgAAABgAAAA2AAAAIwAAABwAAAAbAAAAKgAAABgAAAA4AAAA" +
    "IwAAABwAAAAeAAAAKgAAABoAAAAyAAAAIgAAABsAAAAgAAAAKgAAAB0AAAA7AAAAIwAAABwAAAAaAAAAKgAAABkAAAAtAAAAIwAA" +
    "ABwAAAAdAAAAKgAAABsAAAA2AAAAIwAAABsAAAAbAAAAKgAAABsAAAApAAAAIwAAABoAAAAaAAAAKgAAABsAAAAxAAAAIwAAABsA" +
    "AAAaAAAAKgAAABoAAAA2AAAAIwAAABwAAAAdAAAAKgAAABsAAAAsAAAAIgAAABsAAAAaAAAAKgAAABkAAAAzAAAAIwAAABwAAAAa" +
    "AAAAKgAAAB8AAAA7AAAAIgAAABwAAAAaAAAAKgAAABoAAAAyAAAAIgAAABsAAAAZAAAAKgAAAB0AAABIAAAAJAAAAB0AAAAaAAAA" +
    "KgAAABoAAAAvAAAAJAAAAB0AAAAfAAAAKgAAABkAAAA1AAAAIwAAABkAAAAZAAAAKgAAABsAAAApAAAAIwAAABsAAAAeAAAAKgAA" +
    "ABgAAAAyAAAAIwAAABwAAAAfAAAAKgAAABgAAAA3AAAAJAAAABwAAAAaAAAAKgAAABsAAAAsAAAAIwAAABsAAAAeAAAAKgAAABsA" +
    "AAA0AAAAIwAAABwAAAAZAAAAKgAAABkAAAA5AAAAIgAAABsAAAAaAAAAKgAAABsAAAA0AAAAIwAAABsAAAAaAAAAKgAAABgAAAA6" +
    "AAAAIwAAAB0AAAAaAAAAKgAAABoAAAAuAAAAJAAAABwAAAAeAAAAKgAAABoAAAA2AAAAIwAAABsAAAAaAAAAKgAAABgAAAAnAAAA" +
    "IwAAABwAAAAfAAAAKgAAABgAAAAzAAAAIwAAABwAAAAaAAAAKgAAABgAAAA3AAAAJAAAABwAAAAZAAAAKgAAABsAAAAtAAAAIwAA" +
    "ABoAAAAeAAAAKwAAABsAAAA2AAAAJAAAABsAAAAaAAAAKgAAABoAAAA4AAAAIwAAABsAAAAaAAAAKwAAABgAAAAwAAAAIwAAABsA" +
    "AAAbAAAAKgAAABgAAAA/AAAAIwAAABwAAAAbAAAAKgAAABgAAAAsAAAAJAAAABsAAAAeAAAAKgAAABsAAARvAAAAMQAAADQAAAAj" +
    "AAAAIQAAABwAAAAfAAAAEgAAACsAAAAkAAAAIAAAAB0AAAAdAAAAGAAAAC8AAAAkAAAAHgAAAB4AAAAdAAAAHgAAADMAAAAkAAAA" +
    "IQAAABkAAAAfAAAAHQAAACsAAAAjAAAAIQAAACAAAAAfAAAAGgAAADEAAAAjAAAAIQAAABoAAAAdAAAAGwAAADUAAAAjAAAAIQAA" +
    "ABoAAAAfAAAAHgAAADIAAAAjAAAAIQAAAB8AAAAfAAAAHgAAAD8AAAAkAAAAIQAAABkAAAAfAAAAHQAAACoAAAAkAAAAIQAAACAA" +
    "AAAdAAAAHQAAADEAAAAlAAAAIQAAABoAAAAdAAAAHQAAACcAAAAlAAAAIQAAAB4AAAAfAAAAHQAAAC4AAAAkAAAAIQAAABgAAAAf" +
    "AAAAHgAAADMAAAAkAAAAJQAAAB0AAAAfAAAAHgAAACUAAAAjAAAAIQAAABgAAAAdAAAAHgAAAC4AAAAkAAAAHQAAAB0AAAAfAAAA" +
    "HQAAADQAAAAkAAAAIQAAABgAAAAdAAAAGgAAADMAAAAkAAAAIQAAAB4AAAAdAAAAGgAAADYAAAAmAAAAIQAAABgAAAAdAAAAHgAA" +
    "ACkAAAAjAAAAJAAAAB4AAAAdAAAAHgAAADEAAAAjAAAAIQAAABAAAAAdAAAAHwAAACEAAAAkAAAAIQAAABMAAAAdAAAAHwAAACgA" +
    "AAAkAAAAIQAAABgAAAAdAAAAHgAAADAAAAAjAAAAIQAAABwAAAAdAAAAHgAAACUAAAAkAAAAIQAAABgAAAAdAAAAHQAAAC8AAAAk" +
    "AAAAIQAAABgAAAAdAAAAHQAAADMAAAAkAAAAIQAAAB0AAAAdAAAAHgAAAC8AAAAkAAAAIQAAABgAAAAdAAAAHQAAAD0AAAAlAAAA" +
    "IQAAABsAAAAdAAAAHQAAACwAAAAkAAAAIQAAABsAAAAdAAAAHQAAAC8AAAAlAAAAIQAAABgAAAAdAAAAHQAAACYAAAAkAAAAIQAA" +
    "ABgAAAAdAAAAHQAAAC0AAAAkAAAAIQAAABsAAAAdAAAAHQAAADIAAAAjAAAAIQAAAB0AAAAdAAAAHQAAACUAAAAjAAAAIQAAABgA" +
    "AAAdAAAAHQAAAC0AAAAjAAAAIQAAABgAAAAdAAAAHQAAADMAAAAjAAAAIQAAABgAAAAdAAAAHQAAACwAAAAjAAAAIQAAABsAAAAd" +
    "AAAAHQAAAEIAAAAkAAAAIQAAABAAAAAdAAAAHwAAACQAAAAkAAAAIQAAABAAAAAdAAAAHwAAACsAAAAlAAAAIQAAABAAAAAdAAAA" +
    "HwAAACkAAAAoAAAEpQAAAB0AAAAhAAAAIwAAADQAAAAlAAAAKAAAABwAAAAjAAAAIgAAADQAAAAkAAAAJwAAACIAAAAkAAAAIwAA" +
    "AC0AAAAjAAAAKAAAABsAAAAjAAAAIwAAADIAAAAlAAAAKAAAABsAAAAjAAAAIwAAADkAAAAlAAAAJwAAABsAAAAjAAAAIwAAAC8A" +
    "AAAkAAAAJwAAACEAAAAjAAAAIwAAADsAAAAlAAAAJwAAABsAAAAjAAAAIwAAACwAAAAkAAAAKAAAAB8AAAAjAAAAIwAAADIAAAAk" +
    "AAAAKAAAABsAAAAkAAAAIwAAACcAAAAkAAAAJwAAACAAAAAkAAAAIwAAAC0AAAAkAAAAIwAAABoAAAAjAAAAIwAAADIAAAAkAAAA" +
    "LAAAACAAAAAjAAAAIwAAACcAAAAkAAAAJwAAABoAAAAjAAAAIwAAADAAAAAkAAAAIwAAABoAAAAjAAAAIwAAADcAAAAkAAAAIwAA" +
    "ABoAAAAjAAAAIwAAADMAAAAkAAAAJwAAABoAAAAjAAAAIwAAAEUAAAAmAAAAJwAAABgAAAAjAAAAIwAAACUAAAAkAAAAJwAAABQA" +
    "AAAjAAAAIwAAACsAAAAkAAAAJwAAABAAAAAjAAAAIwAAAB8AAAAkAAAAJwAAABQAAAAjAAAAIwAAACgAAAAkAAAAJwAAABgAAAAj" +
    "AAAAIwAAADIAAAAjAAAAJwAAAB8AAAAjAAAAJAAAACcAAAAkAAAAJwAAABgAAAAjAAAAJAAAACwAAAAkAAAAJwAAABAAAAAjAAAA" +
    "IwAAAC4AAAAkAAAAJwAAABAAAAAjAAAAIwAAACkAAAAkAAAAJwAAABQAAAAjAAAAIwAAADgAAAAlAAAAJwAAAB8AAAAjAAAAIwAA" +
    "ACsAAAAkAAAAJwAAAB8AAAAjAAAAJAAAADEAAAAjAAAAKAAAABsAAAAjAAAAIwAAACgAAAAjAAAAIwAAABoAAAAjAAAAIwAAAC4A" +
    "AAAlAAAAJwAAABoAAAAjAAAAJAAAADIAAAAjAAAAIwAAAB4AAAAjAAAAIwAAACgAAAAjAAAAKAAAABoAAAAjAAAAJAAAADAAAAAl" +
    "AAAAJwAAABoAAAAjAAAAHwAAADcAAAAjAAAAIwAAABoAAAAjAAAAHwAAADAAAAAjAAAAKAAAABoAAAAjAAAAJAAAADwAAAAkAAAA" +
    "KAAAAB8AAAAjAAAAIwAAACoAAAAlAAAAJwAAAB8AAAAjAAAAJAAAADIAAAAkAAAAKAAAABsAAAAjAAAAHwAAACgAAAAjAAAAKAAA" +
    "ABwAAAAjAAAAIwAAADAAAAAkAAAAKAAAACAAAAAjAAAAIwAABHwAAAAjAAAAKAAAABsAAAAyAAAAIwAAABoAAAAiAAAAKgAAABsA" +
    "AAA5AAAAJAAAAB0AAAAfAAAAKgAAABsAAAA+AAAAJgAAABsAAAAeAAAAKwAAABgAAAAyAAAAIwAAABoAAAAeAAAAKgAAABgAAAA7" +
    "AAAAIwAAABoAAAAZAAAAKgAAABgAAAArAAAAJAAAABsAAAAZAAAAKgAAABsAAAA4AAAAIgAAABsAAAAeAAAAKgAAABgAAAApAAAA" +
    "IgAAABoAAAAcAAAAKgAAABgAAAAyAAAAIgAAABsAAAAdAAAAKgAAABgAAAA5AAAAJwAAABsAAAAiAAAAKwAAABgAAAAuAAAAIwAA" +
    "ABoAAAAaAAAAKQAAABgAAAA0AAAAJAAAABsAAAAZAAAAKgAAABgAAAA5AAAAIwAAABsAAAAeAAAAKwAAABoAAAAyAAAAIwAAABsA" +
    "AAAaAAAAKgAAABgAAAA9AAAAIwAAABsAAAAaAAAAKgAAABgAAAAsAAAAJAAAABsAAAAaAAAAKgAAABgAAAA1AAAAIwAAABsAAAAa" +
    "AAAAKgAAABgAAAApAAAAIwAAABoAAAAaAAAAKgAAABgAAAAwAAAAIwAAABsAAAAaAAAAKgAAABgAAAA2AAAAJAAAABsAAAAaAAAA" +
    "KgAAABgAAAAsAAAAIwAAABoAAAAeAAAAKgAAABgAAAA1AAAAJQAAABwAAAAaAAAAKgAAABgAAAA6AAAAIwAAABsAAAAZAAAAKgAA" +
    "ABgAAAAxAAAAIwAAABoAAAAZAAAAKgAAABgAAABAAAAAIwAAABsAAAAaAAAAKgAAABgAAAAsAAAAJQAAABwAAAAdAAAAKgAAABgA" +
    "AAA1AAAAIwAAABsAAAAZAAAAKgAAABgAAAAlAAAAIwAAABoAAAAZAAAAKgAAABgAAAA0AAAAJAAAABsAAAAaAAAAKgAAABoAAAA4" +
    "AAAAIwAAABsAAAAaAAAAKgAAABoAAAArAAAAIgAAABoAAAAdAAAAKgAAABgAAAAzAAAAIwAAABwAAAAaAAAAKgAAABgAAAA3AAAA" +
    "IwAAABwAAAAaAAAAKgAAABgAAAAyAAAAIwAAABsAAAAaAAAAKgAAABgAAAA9AAAAJAAAABsAAAAZAAAAKwAAABoAAAArAAAAJAAA" +
    "ABwAAAAcAAAAKgAAABoAAAA1AAAAIwAAABwAAAAZAAAAKgAAABgAAAAnAAAAJAAAABsAAAAdAAAAKgAAABgAAAAzAAAAJAAAABwA" +
    "AAAaAAAAKgAAABgAAAA2AAAAIwAAABwAAAAdAAAAKwAAABoAAAAtAAAAIgAAABsAAAAaAAAAKgAAABoAAAR2AAAALwAAADMAAAAg" +
    "AAAAGwAAACAAAAAhAAAAGgAAADgAAAAjAAAAHAAAACAAAAAeAAAAGgAAACsAAAAkAAAAHAAAABsAAAAeAAAAGgAAAEYAAAAjAAAA" +
    "HAAAABoAAAAeAAAAGgAAAC4AAAAjAAAAHgAAAB0AAAAeAAAAGgAAADEAAAAjAAAAHgAAABoAAAAeAAAAGQAAACgAAAAjAAAAHgAA" +
    "ABoAAAAeAAAAGQAAAC4AAAAjAAAAHAAAAB0AAAAeAAAAGgAAADQAAAAjAAAAIQAAABoAAAAeAAAAGgAAACcAAAAiAAAAHQAAABwA" +
    "AAAeAAAAHAAAAC8AAAAjAAAAHQAAABoAAAAeAAAAHAAAADIAAAAjAAAAHQAAAB8AAAAeAAAAHAAAADMAAAAiAAAAHQAAAB4AAAAe" +
    "AAAAHAAAAEMAAAAjAAAAHAAAABgAAAAeAAAAHAAAACoAAAAjAAAAHAAAAB0AAAAeAAAAGgAAADQAAAAjAAAAHAAAABsAAAAeAAAA" +
    "GgAAACgAAAAjAAAAHAAAABgAAAAeAAAAHAAAACwAAAAjAAAAHAAAAB0AAAAeAAAAGgAAADMAAAAjAAAAHAAAAB0AAAAeAAAAGgAA" +
    "AC0AAAAjAAAAHAAAABoAAAAeAAAAHAAAADEAAAAiAAAAHQAAABoAAAAeAAAAHAAAADYAAAAiAAAAHQAAABoAAAAeAAAAHAAAAC0A" +
    "AAAiAAAAIQAAAB0AAAAeAAAAHAAAAD0AAAAiAAAAHQAAABoAAAAeAAAAGgAAACoAAAAiAAAAHQAAAB0AAAAeAAAAGgAAADIAAAAi" +
    "AAAAIQAAABoAAAAeAAAAGgAAACUAAAAiAAAAHQAAAB0AAAAeAAAAGgAAAC4AAAAiAAAAHAAAABoAAAAeAAAAGgAAADEAAAAjAAAA" +
    "HAAAAB0AAAAeAAAAGgAAACgAAAAiAAAAHAAAABsAAAAeAAAAGgAAADMAAAAjAAAAHAAAABsAAAAeAAAAGgAAADoAAAAjAAAAHAAA" +
    "AB0AAAAeAAAAGgAAADYAAAAjAAAAHAAAABsAAAAeAAAAGgAAAEkAAAAkAAAAIQAAAB0AAAAeAAAAGgAAACsAAAAjAAAAHAAAAB0A" +
    "AAAeAAAAGgAAADEAAAAjAAAAHAAAABoAAAAeAAAAGgAAACYAAAAjAAAAHQAAAB4AAAAeAAAAHQAAAC4AAAAiAAAAHgAAABoAAAAe" +
    "AAAAHQAAADIAAAAiAAAAHgAAAB0AAAAeAAAAHQAAACcAAAAiAAAAHgAAABoAAAAeAAAAHQAAADIAAAAiAAAAHgAAABoAAAAeAAAA" +
    "HQAAACwAAAAgAAAEnQAAAB0AAAAfAAAAJQAAADIAAAAlAAAAJwAAAB0AAAAgAAAAIQAAAD8AAAAmAAAAJwAAAB8AAAAiAAAAIAAA" +
    "ACwAAAAlAAAAIQAAAB8AAAAiAAAAIwAAADEAAAAlAAAAKAAAABwAAAAiAAAAIQAAACsAAAAlAAAAJwAAABsAAAAiAAAAIAAAAC4A" +
    "AAAlAAAAJwAAABsAAAAhAAAAIgAAADcAAAAkAAAAJwAAACAAAAAhAAAAIgAAACsAAAAjAAAAJwAAAB4AAAAiAAAAGwAAADAAAAAl" +
    "AAAAJwAAABsAAAAgAAAAIgAAADUAAAAlAAAAJwAAACAAAAAgAAAAJQAAADUAAAAlAAAAJwAAACEAAAAgAAAAJQAAAEIAAAAlAAAA" +
    "JwAAABwAAAAgAAAAKAAAAC0AAAAmAAAAJwAAACEAAAAhAAAAIgAAADQAAAAmAAAAJwAAABwAAAAhAAAAIQAAACgAAAAmAAAAJwAA" +
    "ACEAAAAgAAAAJgAAAC4AAAAlAAAAJwAAABoAAAAiAAAAIwAAADEAAAAlAAAAJwAAABoAAAAiAAAAIwAAACYAAAAlAAAAJwAAAB4A" +
    "AAAgAAAAJwAAADAAAAAnAAAAJwAAABoAAAAgAAAAJgAAADcAAAAmAAAAJwAAABoAAAAgAAAAJgAAADcAAAAmAAAAJwAAAB8AAAAg" +
    "AAAAJgAAADoAAAAnAAAAJwAAABsAAAAgAAAAJQAAAC4AAAAlAAAAJwAAACAAAAAgAAAAKAAAADMAAAAlAAAAJwAAABsAAAAgAAAA" +
    "JwAAACcAAAAlAAAAJwAAAB8AAAAgAAAAIgAAAC4AAAAkAAAAJwAAABoAAAAgAAAAIAAAADAAAAAlAAAAJwAAABoAAAAgAAAAHAAA" +
    "ACcAAAAlAAAAJwAAABoAAAAgAAAAIgAAADEAAAAmAAAAJwAAABoAAAAgAAAAJAAAADUAAAAlAAAAJwAAAB4AAAAgAAAAJwAAADQA" +
    "AAAkAAAAJwAAABoAAAAgAAAAJwAAADoAAAAlAAAAJwAAAB4AAAAgAAAAJAAAACoAAAAmAAAAJwAAAB8AAAAiAAAAIwAAADMAAAAl" +
    "AAAAJwAAABoAAAAgAAAAJAAAACcAAAAlAAAAJwAAABoAAAAiAAAAIwAAAC8AAAAlAAAAJwAAAB8AAAAiAAAAIwAAADMAAAAmAAAA" +
    "JwAAABoAAAAiAAAAJAAAACsAAAAlAAAAJwAAAB0AAAAiAAAAJQAAAC4AAAAkAAAAJwAAABgAAAAiAAAAIwAAADMAAAAkAAAAJwAA" +
    "ABkAAAAiAAAAIwAAAC8AAAAkAAAAJwAAAB4AAAAiAAAAJQAABIAAAAAjAAAAKQAAABsAAAAzAAAAJAAAAB4AAAAhAAAAKgAAABoA" +
    "AAA5AAAAJgAAAB0AAAAfAAAAKgAAABwAAAAtAAAAJAAAABoAAAAdAAAAKgAAABwAAAA1AAAAJAAAABsAAAAiAAAAKgAAABsAAAA4" +
    "AAAAJAAAABsAAAAdAAAAKgAAABsAAAAvAAAAJAAAABsAAAAfAAAAKgAAABsAAAA1AAAAIwAAAB8AAAAaAAAAKgAAAB4AAAA8AAAA" +
    "IwAAABsAAAAZAAAAKgAAABwAAAAzAAAAIwAAABoAAAAaAAAAKgAAABwAAAA7AAAAIwAAABwAAAAaAAAAKgAAABsAAAAtAAAAJAAA" +
    "AB0AAAAfAAAAKgAAABwAAAA3AAAAIwAAAB0AAAAaAAAAKgAAABsAAAAoAAAAIwAAABwAAAAeAAAAKgAAABwAAAAxAAAAIwAAAB0A" +
    "AAAaAAAAKgAAABwAAAA4AAAAJAAAABsAAAAaAAAAKgAAABsAAAAsAAAAIwAAABoAAAAZAAAAKgAAABsAAAA1AAAAIwAAABsAAAAa" +
    "AAAAKgAAABwAAAA4AAAAIwAAABsAAAAaAAAAKwAAABsAAAAxAAAAIwAAABsAAAAaAAAAKwAAABsAAABDAAAAJQAAABsAAAAdAAAA" +
    "KgAAABwAAAAwAAAAIwAAABsAAAAdAAAAKgAAABwAAAAzAAAAIwAAABsAAAAaAAAAKgAAABsAAAApAAAAIwAAABoAAAAaAAAAKgAA" +
    "ABwAAAAxAAAAIwAAABsAAAAdAAAAKgAAABwAAAA2AAAAJQAAABwAAAAaAAAAKgAAABsAAAAtAAAAJwAAABoAAAAaAAAAKgAAABwA" +
    "AAA1AAAAJQAAABsAAAAaAAAAKgAAABsAAAA4AAAAIwAAABwAAAAaAAAAKgAAABsAAAAyAAAAIgAAABoAAAAdAAAAKgAAABwAAABK" +
    "AAAAIgAAABwAAAAbAAAAKgAAABwAAAAuAAAAJAAAABwAAAAaAAAAKgAAABwAAAA1AAAAIwAAABsAAAAeAAAAKgAAABsAAAApAAAA" +
    "JAAAABsAAAAZAAAAKgAAABsAAAAyAAAAJAAAABsAAAAZAAAAKgAAABwAAAA5AAAAJAAAABsAAAAaAAAAKgAAABsAAAAvAAAAJAAA" +
    "ABoAAAAeAAAAKgAAABwAAAA3AAAAJAAAABoAAAAaAAAAKgAAABwAAAA4AAAAIwAAABsAAAAaAAAAKgAAABwAAAAvAAAAIwAAABwA" +
    "AAAaAAAAKgAAABoAAAA7AAAAJAAAABsAAAAhAAAAKgAAABwAAAAuAAAAJAAAABwAAAAbAAAAKgAAABwAAAR3AAAAMQAAADYAAAAj" +
    "AAAAIQAAABwAAAAfAAAAEgAAACwAAAAkAAAAIAAAAB0AAAAdAAAAGAAAADEAAAAkAAAAHgAAAB4AAAAdAAAAHQAAADcAAAAkAAAA" +
    "HgAAABkAAAAfAAAAHQAAACoAAAAkAAAAIQAAABwAAAAdAAAAGwAAADcAAAAjAAAAIQAAABoAAAAdAAAAGgAAADUAAAAjAAAAIQAA" +
    "AB8AAAAfAAAAGwAAAC0AAAAkAAAAIQAAAA8AAAAfAAAAHQAAABRzdGNvAAAAAAAAAAEAAEU1AAAAYXVkdGEAAABZbWV0YQAAAAAA" +
    "AAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2MS43LjEw" +
    "MwAAAAhmcmVlAAEaTm1kYXQAAAKtBgX//6ncRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY0IHIzMTA4IDMxZTE5ZjkgLSBI" +
    "LjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDIzIC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5o" +
    "dG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT0y" +
    "IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRj" +
    "dD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz02IGxvb2thaGVh" +
    "ZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBj" +
    "b25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0" +
    "Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0xIGtleWludD0yNTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNo" +
    "PTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MzEuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBz" +
    "dGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAA7pliIQAK/+JAbDY/5lcCTE582MiR92/ZCLaGlgjJW6EdzY0KAAJex1v" +
    "1vPT54+6QlgAz1gAAhAflrOE5XOMABDGrCWTyiMRVirem5yt3Lfih9+3ZnKwRh47lv2Yl2u0gt2QoDz57ZMQclzyKKU0Dx7XGzAd" +
    "rzdm/6g2Wlm9Ug/5j/Q8cFn5cRXqAmvJJ+2I48irBUiYjX995BT8u+ND9HKuEuhPISabdFG6S2jRAPeNWTPQ1TiZ2IoLXTRCVVaz" +
    "0SbtTVdU/JOKeSbY8ezA6XC4HPj0o0ElNukSK2mmXF/wMomMemZGElwnSj/A9WYJMXZYD9y9RvuSIW06ujEOX+ON4+uu2xf3C3NM" +
    "1xLN30d86OaIygNLt7VbSgqihl+m110dHU6rCvlwHPsuKvhvd+hpyaBUnFT0g1LBp2BM3isjB97xl7KUEhdbQAm9VBN8nYPA7J/N" +
    "vPvDynNVnbJaOjgurirqEqFmdIWQDVhH56JmQ4gfAg4AIiLt8QPcwlm6TOzLgGG0Y2s8S/TXegWO02g9CPj9t5BpyJbrcUhyRpjb" +
    "phwkjaN7YSBFrEyeHjPKtJhaw3a0HoTkyLTRyeoMbF1v9U1wFHI+V17H9pTZiEu+Wg10oxNrFYBxFvGaYz3o+geoalc+7rX/DoWq" +
    "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"

  private func complete(_ error: FlutterError? = nil) {
    startTimeout?.invalidate(); startTimeout = nil
    let callback = pendingResult
    pendingResult = nil
    if let error { callback?(error) } else { callback?(true) }
  }

  private func fail(_ message: String) {
    log("failed: \(message)")
    complete(FlutterError(code: "PIP_FAILED", message: message, details: nil))
    cleanup()
  }

  private func log(_ message: String) {
    NSLog("Lyriko PiP v12.3: %@", message)
    eventChannel?.invokeMethod("pipState", arguments: ["state": state, "message": message])
  }

  private func cleanup() {
    guard controller?.isPictureInPictureActive != true else { return }
    startTimeout?.invalidate(); startTimeout = nil
    lyricRefreshTimer?.invalidate(); lyricRefreshTimer = nil
    lyricsLock.lock(); lyricsFrame = nil; lyricsLock.unlock()
    lastRenderedIndex = -999; lastRenderedHeading = ""; lastRenderedText = ""
    itemObservation?.invalidate(); itemObservation = nil
    possibleObservation?.invalidate(); possibleObservation = nil
    playbackObservation?.invalidate(); playbackObservation = nil
    if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
    endObserver = nil
    controller?.delegate = nil
    controller = nil
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    item = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    sourceView?.removeFromSuperview()
    sourceView = nil
    if let previous = audioPrevious {
      try? AVAudioSession.sharedInstance().setCategory(previous.0, mode: previous.1, options: previous.2)
    }
    audioPrevious = nil
    itemReady = false; pipPossible = false; didRequestStart = false
    state = "idle"
    log("idle (cleaned up)")
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
    guard controller === pip else { return }
    state = "active"
    log("didStart")
    complete()
    // Defer to the next runloop so PiP's initial AVPlayer transition completes.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.state == "active", self.controller === pip else { return }
      self.enableLyricsRendering()
    }
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pip: AVPictureInPictureController) {
    guard controller === pip else { return }
    state = "stopping"
    log("willStop")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
    guard controller === pip else { return }
    log("didStop")
    if pendingResult != nil {
      complete(FlutterError(code: "PIP_STOPPED", message: "PiP stopped before starting", details: nil))
    }
    cleanup()
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    guard controller === pip else { return }
    fail("AVPlayer failedToStart: \(error.localizedDescription)")
  }

  func pictureInPictureController(_ pip: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    completionHandler(true)
  }
}
