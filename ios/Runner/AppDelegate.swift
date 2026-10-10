import Flutter
import UIKit
import ScreenCaptureKit
import CoreMedia
import AudioToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosAudioProbe: IOSAudioProbe?

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
    let channel = FlutterMethodChannel(name: "lyriko/ios_audio_probe", binaryMessenger: engineBridge.pluginRegistry.registrar(forPlugin: "LyrikoIOSAudioProbe")!.messenger())
    channel.setMethodCallHandler { [weak probe] call, result in
      guard let probe else { result(FlutterError(code: "UNAVAILABLE", message: "Audio probe unavailable", details: nil)); return }
      switch call.method {
      case "start": probe.start(result: result)
      case "stats": result(probe.stats())
      case "stop": probe.stop(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}


// Diagnostic-only probe. Audio is not recorded or uploaded.
@available(iOS 27.0, *)
private final class IOSAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
  private var stream: SCStream?
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
    lock.lock()
    phase = "picker"
    buffers = 0; bytes = 0; sampleFrames = 0
    buffersWithPayload = 0; buffersWithSignal = 0; videoBuffers = 0
    rms = 0; peak = 0; audioFormat = "unknown"
    diagnosis = "waiting for audio"; lastError = ""
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
      "diagnosis": diagnosis, "error": lastError
    ]
  }

  func stop() async {
    if let stream { try? await stream.stopCapture() }
    stream = nil
    picker.remove(self)
    picker.isActive = false
    lock.lock(); phase = "stopped"; lock.unlock()
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
    let latestRMS = inspected > 0 ? sqrt(sumSquares / Double(inspected)) : 0.0
    lock.lock()
    buffers += 1
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
