//
//  IOSRecordingClient.swift
//  Quill (iOS)
//
//  AVAudioEngine-based recording for iOS. Captures mono 16kHz WAV to a temp file.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class IOSRecordingClient {
  static let shared = IOSRecordingClient()

  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var currentURL: URL?

  private let targetSampleRate: Double = 16000
  private let targetFormat: AVAudioFormat = {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!
  }()

  // Audio meter (for UI level indicator)
  @Published private(set) var averagePower: Float = 0

  private init() {}

  func requestPermission() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }

  func startRecording() throws -> URL {
    // Configure session
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)

    // Create output file URL
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quill-recording-\(UUID().uuidString).wav")
    currentURL = url

    // Build engine
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: targetSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    self.audioFile = audioFile

    // Converter from input format to target format
    let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    self.converter = converter

    inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
      guard let self, let converter = self.converter else { return }

      // Convert to 16kHz mono
      let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (self.targetSampleRate / buffer.format.sampleRate))
      guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: self.targetFormat,
        frameCapacity: max(frameCapacity, 1)
      ) else { return }

      var error: NSError?
      var done = false
      converter.convert(to: outputBuffer, error: &error) { _, status in
        if done {
          status.pointee = .noDataNow
          return nil
        }
        done = true
        status.pointee = .haveData
        return buffer
      }

      if error == nil {
        try? self.audioFile?.write(from: outputBuffer)
        // Compute meter
        if let data = outputBuffer.floatChannelData?[0] {
          let frameLen = Int(outputBuffer.frameLength)
          var sum: Float = 0
          for i in 0..<frameLen { sum += abs(data[i]) }
          let avg = frameLen > 0 ? sum / Float(frameLen) : 0
          Task { @MainActor in self.averagePower = min(1, avg * 3) }
        }
      }
    }

    engine.prepare()
    try engine.start()
    self.engine = engine
    return url
  }

  func stopRecording() -> URL? {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    audioFile = nil
    converter = nil
    averagePower = 0
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    return currentURL
  }
}
