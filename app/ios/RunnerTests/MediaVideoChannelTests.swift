import AVFoundation
import Flutter
import UIKit
import XCTest
@testable import Runner

/// Exercises `dsh/media_video`'s iOS implementation through its real
/// MethodChannel: the tests hand it synthetic clips written by AVAssetWriter in
/// this process, so nothing here needs the Host, the engine or a device camera.
final class MediaVideoChannelTests: XCTestCase {
  private var messenger: VideoTestMessenger!
  private var textures: VideoTestTextures!
  private var channel: MediaVideoChannel!
  private var calls: FlutterMethodChannel!

  override func setUp() {
    super.setUp()
    messenger = VideoTestMessenger()
    textures = VideoTestTextures()
    channel = MediaVideoChannel(messenger: messenger, textures: textures)
    calls = FlutterMethodChannel(name: "dsh/media_video", binaryMessenger: messenger)
  }

  override func tearDown() {
    channel = nil
    calls = nil
    messenger = nil
    textures = nil
    super.tearDown()
  }

  func testOpenRejectsAPathOutsideTheContainer() {
    let outcome = invoke("open", ["path": "/etc/hosts"])
    guard case let .failure(error) = outcome else { return XCTFail("expected an error") }
    XCTAssertEqual(error.code, "invalid")
    XCTAssertEqual(textures.registered, 0)
  }

  func testOpenRejectsANonVideoContainer() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip.txt")
    try Data("not a video".utf8).write(to: file)
    let outcome = invoke("open", ["path": file.path])
    guard case let .failure(error) = outcome else { return XCTFail("expected an error") }
    XCTAssertEqual(error.code, "invalid")
  }

  func testOperationsOnAnUnknownTextureReportClosed() {
    for method in ["play", "pause", "seek", "state"] {
      let outcome = invoke(method, ["texture": 42, "positionMs": 0])
      guard case let .failure(error) = outcome else { return XCTFail("\(method) should fail") }
      XCTAssertEqual(error.code, "closed", method)
    }
  }

  func testPosterOfAMissingFileIsInvalid() {
    let outcome = invoke("poster", ["path": NSTemporaryDirectory() + "missing.mp4"])
    guard case let .failure(error) = outcome else { return XCTFail("expected an error") }
    XCTAssertEqual(error.code, "invalid")
  }

  func testOpensPlaysSeeksAndClosesARealClip() throws {
    let file = try SyntheticVideo.write(duration: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: file) }

    let opened = invoke("open", ["path": file.path], timeout: 25)
    guard case let .success(value) = opened else { return XCTFail("open failed: \(opened)") }
    let map = try XCTUnwrap(value as? [String: Any])
    let texture = try XCTUnwrap(map["texture"] as? Int)
    XCTAssertGreaterThan(texture, 0)
    XCTAssertEqual(map["width"] as? Int, 320)
    XCTAssertEqual(map["height"] as? Int, 240)
    XCTAssertGreaterThan(map["durationMs"] as? Int ?? 0, 500)
    XCTAssertEqual(textures.registered, 1)

    guard case .success = invoke("play", ["texture": texture]) else { return XCTFail("play failed") }
    // AVPlayer answers play() before the item leaves .waitingToPlay; the viewer
    // polls the same way, so wait for the first frame instead of asserting at once.
    var playing: [String: Any]?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if case let .success(state) = invoke("state", ["texture": texture]),
        let values = state as? [String: Any], values["playing"] as? Bool == true {
        playing = values
        break
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(playing?["playing"] as? Bool, true)
    XCTAssertEqual(playing?["durationMs"] as? Int, map["durationMs"] as? Int)

    guard case .success = invoke("seek", ["texture": texture, "positionMs": 400]) else {
      return XCTFail("seek failed")
    }
    guard case let .success(seeked) = invoke("state", ["texture": texture]),
      let position = (seeked as? [String: Any])?["positionMs"] as? Int else { return XCTFail("no state") }
    XCTAssertGreaterThanOrEqual(position, 300)

    guard case .success = invoke("pause", ["texture": texture]) else { return XCTFail("pause failed") }
    guard case .success = invoke("close", ["texture": texture]) else { return XCTFail("close failed") }
    XCTAssertEqual(textures.unregistered, [Int64(texture)])
    guard case let .failure(error) = invoke("state", ["texture": texture]) else {
      return XCTFail("a closed clip still answers")
    }
    XCTAssertEqual(error.code, "closed")
  }

  func testSeekClampsPastTheEnd() throws {
    let file = try SyntheticVideo.write(duration: 1, size: CGSize(width: 160, height: 120))
    defer { try? FileManager.default.removeItem(at: file) }
    let opened = invoke("open", ["path": file.path], timeout: 25)
    guard case let .success(value) = opened, let map = value as? [String: Any],
      let texture = map["texture"] as? Int, let duration = map["durationMs"] as? Int else {
      return XCTFail("open failed: \(opened)")
    }
    guard case .success = invoke("seek", ["texture": texture, "positionMs": duration * 10]) else {
      return XCTFail("seek failed")
    }
    guard case let .success(state) = invoke("state", ["texture": texture]),
      let position = (state as? [String: Any])?["positionMs"] as? Int else { return XCTFail("no state") }
    XCTAssertLessThanOrEqual(position, duration + 50)
    _ = invoke("close", ["texture": texture])
  }

  // MARK: - helpers

  private enum Outcome {
    case success(Any?)
    case failure(FlutterError)
  }

  private func invoke(_ method: String, _ arguments: [String: Any], timeout: TimeInterval = 5) -> Outcome {
    let done = expectation(description: method)
    var outcome: Outcome?
    messenger.invoke(method, arguments: arguments) { value in
      outcome = value as? FlutterError == nil ? .success(value) : .failure(value as? FlutterError ?? FlutterError(
        code: "unknown", message: nil, details: nil))
      done.fulfill()
    }
    wait(for: [done], timeout: timeout)
    return outcome ?? .failure(FlutterError(code: "timeout", message: "no answer", details: nil))
  }
}

private final class VideoTestMessenger: NSObject, FlutterBinaryMessenger {
  private var next: Int64 = 0
  private var handlers: [String: (Int64, FlutterBinaryMessageHandler)] = [:]
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?)
    -> FlutterBinaryMessengerConnection {
    next += 1
    if let handler { handlers[channel] = (next, handler) } else { handlers.removeValue(forKey: channel) }
    return next
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    handlers = handlers.filter { $0.value.0 != connection }
  }
  func invoke(_ method: String, arguments: [String: Any], reply: @escaping (Any?) -> Void) {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let data = codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))
    guard let handler = handlers["dsh/media_video"]?.1 else { reply(FlutterMethodNotImplemented); return }
    handler(data) { data in
      guard let data else { reply(FlutterMethodNotImplemented); return }
      do {
        reply(try codec.decodeEnvelope(data))
      } catch {
        reply(error as? FlutterError ?? FlutterError(code: "codec", message: "\(error)", details: nil))
      }
    }
  }
}

private final class VideoTestTextures: NSObject, FlutterTextureRegistry {
  private var next: Int64 = 0
  var registered = 0
  var unregistered: [Int64] = []
  func register(_ texture: FlutterTexture) -> Int64 {
    next += 1
    registered += 1
    _ = texture
    return next
  }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) { unregistered.append(textureId) }
}

/// Writes a short silent H.264 clip into the temporary directory. Skips the test
/// when the simulator has no usable encoder instead of pretending to pass.
enum SyntheticVideo {
  static func write(duration: Int, size: CGSize) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-video-\(UUID().uuidString).mp4")
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
      throw XCTSkip("AVAssetWriter is unavailable")
    }
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ])
    guard writer.canAdd(input) else { throw XCTSkip("H.264 encoding is unavailable") }
    writer.add(input)
    guard writer.startWriting() else { throw XCTSkip("writer refused to start: \(writer.error?.localizedDescription ?? "")") }
    writer.startSession(atSourceTime: .zero)
    let frames = duration * 10
    for frame in 0..<frames {
      guard let pool = adaptor.pixelBufferPool else { throw XCTSkip("no pixel buffer pool") }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      guard let pixel = buffer else { throw XCTSkip("no pixel buffer") }
      CVPixelBufferLockBaseAddress(pixel, [])
      if let base = CVPixelBufferGetBaseAddress(pixel) {
        memset(base, Int32(frame % 255), CVPixelBufferGetDataSize(pixel))
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
      adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
      throw XCTSkip("writer failed: \(writer.error?.localizedDescription ?? "")")
    }
    return url
  }
}
