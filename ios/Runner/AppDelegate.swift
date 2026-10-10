import Flutter
import UIKit
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import AVFoundation
import ShazamKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosAudioProbe: IOSAudioProbe?
  private var iosMicRecognition: IOSMicrophoneRecognition?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let probe = IOSAudioProbe()
    iosAudioProbe = probe
    let mic = IOSMicrophoneRecognition()
    iosMicRecognition = mic
    let channel = FlutterMethodChannel(name: "lyriko/ios_audio_probe", binaryMessenger: engineBridge.pluginRegistry.registrar(forPlugin: "LyrikoIOSAudioProbe")!.messenger())
    channel.setMethodCallHandler { [weak probe, weak mic] call, result in
      guard let probe, let mic else { result(FlutterError(code: "UNAVAILABLE", message: "Audio probe unavailable", details: nil)); return }
      switch call.method {
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


// Diagnostic-only probe. Audio is not recorded or uploaded.
@available(iOS 27.0, *)
private final class IOSAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate, SHSessionDelegate {
  private var stream: SCStream?
  private var shazamSession: SHSession?
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
    // Load only the 3-song local catalog. No network Shazam lookup.
    guard let url = Bundle.main.url(forResource: "lyriko_demo", withExtension: "shazamcatalog") else {
      fail("Missing lyriko_demo.shazamcatalog in Runner target resources")
      return
    }
    do {
      let catalog = try SHCustomCatalog(dataRepresentation: Data(contentsOf: url))
      let session = SHSession(catalog: catalog)
      session.delegate = self
      shazamSession = session
    } catch {
      fail("Could not load ShazamKit catalog: \(error.localizedDescription)")
      return
    }
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
        guard let url = Bundle.main.url(forResource: "lyriko_demo", withExtension: "shazamcatalog"),
              let data = try? Data(contentsOf: url),
              let catalog = try? SHCustomCatalog(dataRepresentation: data) else { return }
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
    guard let url = Bundle.main.url(forResource: "lyriko_demo", withExtension: "shazamcatalog") else {
      result(FlutterError(code: "MISSING_CATALOG", message: "Missing lyriko_demo.shazamcatalog", details: nil))
      return
    }
    do {
      let catalog = try SHCustomCatalog(dataRepresentation: Data(contentsOf: url))
      self.catalog = catalog
      let newSession = SHSession(catalog: catalog)
      newSession.delegate = self
      session = newSession
    } catch {
      result(FlutterError(code: "CATALOG_ERROR", message: error.localizedDescription, details: nil))
      return
    }
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
          try avSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
          try avSession.setActive(true)
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
