import AVFoundation
import Foundation
import Flutter

class RecorderStreamDelegate: NSObject, AudioRecordingStreamDelegate {
  var config: RecordConfig?

  private var audioEngine: AVAudioEngine?
  private var amplitude: Float = -160.0
  private let bus = 0
  private var onPause: () -> ()
  private var onStop: () -> ()
  private let manageAudioSession: Bool

  // Retained across the delegate's lifetime so the tap can be reinstalled on
  // the (recreated) inputNode after an audio route change. Without this the
  // host app's stream silently dies when the user plugs in or unplugs an
  // external microphone mid-session.
  private var recordEventHandler: RecordStreamHandler?
  private var dstFormat: AVAudioFormat?
  private var configChangeObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var shouldBeRunning: Bool = false
  private let recoveryQueue = DispatchQueue(label: "com.llfbandit.record.recovery")

  init(manageAudioSession: Bool, onPause: @escaping () -> (), onStop: @escaping () -> ()) {
    self.manageAudioSession = manageAudioSession
    self.onPause = onPause
    self.onStop = onStop
  }

  func start(config: RecordConfig, recordEventHandler: RecordStreamHandler) throws {
    let audioEngine = AVAudioEngine()

    try initAVAudioSession(config: config, manageAudioSession: manageAudioSession)
    try setVoiceProcessing(echoCancel: config.echoCancel, autoGain: config.autoGain, audioEngine: audioEngine)

    let dstFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(config.sampleRate),
      channels: AVAudioChannelCount(config.numChannels),
      interleaved: true
    )

    guard let dstFormat = dstFormat else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format is not supported: \(config.sampleRate)Hz - \(config.numChannels) channels."
      )
    }

    self.audioEngine = audioEngine
    self.config = config
    self.dstFormat = dstFormat
    self.recordEventHandler = recordEventHandler

    try installInputTap()

    audioEngine.prepare()
    try audioEngine.start()

    shouldBeRunning = true

    // Observe AVAudioEngine configuration changes. Fires when the engine's
    // I/O format changes, e.g. after a route change that alters sample rate
    // or channel count.
    configChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: audioEngine,
      queue: nil) { [weak self] _ in
        self?.scheduleRouteRecovery()
      }

    // Also observe AVAudioSession route changes. Covers plug/unplug events
    // where the format happens to match and the engine configuration change
    // notification does not fire.
    routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: nil) { [weak self] notification in
        self?.handleRouteChangeNotification(notification)
      }
  }

  func stop(completionHandler: @escaping (String?) -> ()) {
    shouldBeRunning = false

    if let observer = configChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      configChangeObserver = nil
    }
    if let observer = routeChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeChangeObserver = nil
    }

    if let audioEngine = audioEngine {
      do {
        try setVoiceProcessing(echoCancel: false, autoGain: false, audioEngine: audioEngine)
      } catch {}
    }

    audioEngine?.inputNode.removeTap(onBus: bus)
    audioEngine?.stop()
    audioEngine = nil
    recordEventHandler = nil
    dstFormat = nil

    completionHandler(nil)
    onStop()

    config = nil
  }

  func pause() {
    shouldBeRunning = false
    audioEngine?.pause()
    onPause()
  }

  func resume() throws {
    try audioEngine?.start()
    shouldBeRunning = true
  }

  func cancel() throws {
    stop { path in }
  }

  func getAmplitude() -> Float {
    return amplitude
  }

  private func updateAmplitude(_ samples: [Int16]) {
    var maxSample:Float = -160.0

    for sample in samples {
      let curSample = abs(Float(sample))
      if (curSample > maxSample) {
        maxSample = curSample
      }
    }

    amplitude = 20 * (log(maxSample / 32767.0) / log(10))
  }

  func dispose() {
    stop { path in }
  }

  // Little endian
  private func convertInt16toUInt8(_ samples: [Int16]) -> [UInt8] {
    var bytes: [UInt8] = []

    for sample in samples {
      bytes.append(UInt8(sample & 0x00ff))
      bytes.append(UInt8(sample >> 8 & 0x00ff))
    }

    return bytes
  }

  // Install the tap on the current inputNode using its live input format and
  // a fresh AVAudioConverter. Called both on initial start and on every
  // route-change recovery. The caller is responsible for removing any
  // pre-existing tap first.
  private func installInputTap() throws {
    guard let audioEngine = audioEngine,
          let dstFormat = dstFormat,
          let config = config else {
      return
    }

    // Re-read the current input format. After a route change the inputNode
    // is lazily recreated against the new hardware, so this reflects the
    // connected device's native sample rate and channel count.
    let srcFormat = audioEngine.inputNode.inputFormat(forBus: 0)

    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
      throw RecorderError.error(
        message: "Failed to start recording",
        details: "Format conversion is not possible."
      )
    }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

    audioEngine.inputNode.installTap(
      onBus: bus,
      bufferSize: AVAudioFrameCount(config.streamBufferSize ?? 1024),
      format: srcFormat) { [weak self] (buffer, _) -> Void in
        guard let self = self, let handler = self.recordEventHandler else {
          return
        }
        self.stream(
          buffer: buffer,
          dstFormat: dstFormat,
          converter: converter,
          recordEventHandler: handler
        )
      }
  }

  private func handleRouteChangeNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
      scheduleRouteRecovery()
    default:
      break
    }
  }

  private func scheduleRouteRecovery() {
    // Notifications may arrive on arbitrary threads. Serialize recovery onto
    // a dedicated queue so overlapping notifications coalesce naturally and
    // we never mutate the engine from AVFoundation's posting thread.
    recoveryQueue.async { [weak self] in
      self?.performRouteRecovery()
    }
  }

  private func performRouteRecovery() {
    // Respect user intent: if the recorder has been paused or stopped, do
    // not auto-resume just because a route changed.
    guard shouldBeRunning else { return }
    guard let audioEngine = audioEngine else { return }

    do {
      audioEngine.inputNode.removeTap(onBus: bus)
      try installInputTap()
      if !audioEngine.isRunning {
        try audioEngine.start()
      }
    } catch {
      print("[record_ios] Failed to recover from route change: \(error)")
    }
  }

  private func stream(
    buffer: AVAudioPCMBuffer,
    dstFormat: AVAudioFormat,
    converter: AVAudioConverter,
    recordEventHandler: RecordStreamHandler
  ) -> Void {
    let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    // Determine frame capacity
    let capacity = (UInt32(dstFormat.sampleRate) * dstFormat.channelCount * buffer.frameLength) / (UInt32(buffer.format.sampleRate) * buffer.format.channelCount)

    // Destination buffer
    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
      print("Unable to create output buffer")
      stop { path in }
      return
    }

    // Convert input buffer (resample, num channels)
    var error: NSError? = nil
    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
    if error != nil {
      return
    }

    if let channelData = convertedBuffer.int16ChannelData {
      // Fill samples
      let channelDataPointer = channelData.pointee
      let samples = stride(from: 0,
                           to: Int(convertedBuffer.frameLength),
                           by: buffer.stride).map{ channelDataPointer[$0] }

      // Update current amplitude
      updateAmplitude(samples)

      // Send bytes
      if let eventSink = recordEventHandler.eventSink {
        let bytes = Data(_: convertInt16toUInt8(samples))

        DispatchQueue.main.async {
          eventSink(FlutterStandardTypedData(bytes: bytes))
        }
      }
    }
  }

  // Set up AGC & echo cancel
  private func setVoiceProcessing(echoCancel: Bool, autoGain: Bool, audioEngine: AVAudioEngine) throws {
    if #available(iOS 13.0, *) {
      do {
        try audioEngine.inputNode.setVoiceProcessingEnabled(echoCancel)
        audioEngine.inputNode.isVoiceProcessingAGCEnabled = autoGain
      } catch {
        throw RecorderError.error(
          message: "Failed to setup voice processing",
          details: "Echo cancel error: \(error)"
        )
      }
    }
  }
}
