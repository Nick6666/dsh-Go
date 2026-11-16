import AVFoundation
import Flutter
import UIKit

/// Local materialized videos, the same contract Android implements in
/// `MediaVideoPlugin.kt`: `dsh/media_video` with one FlutterTexture per clip.
///
/// Frames come from an `AVPlayerItemVideoOutput` and are handed to the engine from
/// a display link, so the viewer's `Texture` widget shows the decoder's output
/// instead of a still. Nothing here opens a URL from the Host: the caller must
/// have materialized the file first, and the path must resolve inside the app
/// container.
final class MediaVideoChannel: NSObject {
  private let channel: FlutterMethodChannel
  private let textures: any FlutterTextureRegistry
  private var clips: [Int64: Clip] = [:]
  private var foreground = true

  init(messenger: any FlutterBinaryMessenger, textures: any FlutterTextureRegistry) {
    self.textures = textures
    channel = FlutterMethodChannel(name: "dsh/media_video", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(enteredBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(enteredForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    switch call.method {
    case "open": return open(args["path"] as? String, result: result)
    case "poster": return poster(args["path"] as? String, result: result)
    case "close":
      close((args["texture"] as? NSNumber)?.int64Value ?? -1)
      return result(nil)
    default: break
    }
    let id = (args["texture"] as? NSNumber)?.int64Value ?? -1
    guard let clip = clips[id], clip.ready else {
      return result(FlutterError(code: "closed", message: "video is closed", details: nil))
    }
    switch call.method {
    case "play":
      guard foreground else {
        return result(FlutterError(code: "background", message: "app is not in foreground", details: nil))
      }
      pauseOthers(than: id)
      activateAudio()
      clip.player.play()
      textures.textureFrameAvailable(id)
      result(nil)
    case "pause":
      clip.player.pause()
      result(nil)
    case "seek":
      let requested = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
      let target = min(max(requested, 0), Int64(clip.durationMs))
      clip.player.seek(to: CMTime(value: target, timescale: 1000),
        toleranceBefore: .zero, toleranceAfter: .zero)
      textures.textureFrameAvailable(id)
      result(nil)
    case "state":
      let position = clip.player.currentTime().seconds
      result([
        "positionMs": position.isFinite ? Int((position * 1000).rounded()) : 0,
        "durationMs": clip.durationMs,
        "playing": clip.player.timeControlStatus == .playing,
      ])
    default: result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - open

  private func open(_ path: String?, result: @escaping FlutterResult) {
    guard let path, let file = Self.localVideo(path) else {
      return result(FlutterError(code: "invalid", message: "a local video file is required", details: nil))
    }
    closeAll()
    let item = AVPlayerItem(url: file)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .pause
    let clip = Clip(player: player, output: output)
    let id = textures.register(clip)
    clip.textureId = id
    clip.pending = result
    clips[id] = clip
    let timeout = DispatchWorkItem { [weak self] in self?.close(id, code: "timeout") }
    clip.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

    Task { [weak self] in
      do {
        let asset = item.asset
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
          throw MediaVideoError.unsupported
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // A portrait clip is stored landscape plus a 90° transform; the viewer
        // lays the texture out with the size it gets here.
        let quarterTurn = abs(transform.b) == 1 && abs(transform.c) == 1
        let width = Int((quarterTurn ? size.height : size.width).rounded())
        let height = Int((quarterTurn ? size.width : size.height).rounded())
        guard width > 0, height > 0 else { throw MediaVideoError.unsupported }
        let milliseconds = Int((duration.seconds * 1000).rounded())
        await MainActor.run { self?.ready(id, width: width, height: height, durationMs: max(0, milliseconds)) }
      } catch {
        await MainActor.run { self?.close(id, code: "unsupported") }
      }
    }
  }

  private func ready(_ id: Int64, width: Int, height: Int, durationMs: Int) {
    guard let clip = clips[id], let pending = clip.pending else { return }
    clip.timeout?.cancel()
    clip.timeout = nil
    clip.pending = nil
    clip.ready = true
    clip.width = width
    clip.height = height
    clip.durationMs = durationMs
    if clip.link == nil {
      let link = CADisplayLink(target: Ticker(clip: clip, textures: textures), selector: #selector(Ticker.tick))
      link.add(to: .main, forMode: .common)
      clip.link = link
    }
    pending(["texture": id, "width": width, "height": height, "durationMs": durationMs])
  }

  // MARK: - poster

  private func poster(_ path: String?, result: @escaping FlutterResult) {
    guard let path, let file = Self.localVideo(path) else {
      return result(FlutterError(code: "invalid", message: "a local video file is required", details: nil))
    }
    // One decode at a time: a broken file must not pile up workers while cards
    // scroll past.
    guard !probing else { return result(nil) }
    probing = true
    let answered = Answered()
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      guard answered.claim() else { return }
      result(FlutterError(code: "timeout", message: "poster extraction timed out", details: nil))
    }
    posterQueue.async { [weak self] in
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 512, height: 512)
      var data: Data?
      if let image = try? generator.copyCGImage(at: .zero, actualTime: nil) {
        data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
      }
      DispatchQueue.main.async {
        guard answered.claim() else { return }
        self?.probing = false
        result(data.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }

  // MARK: - lifecycle

  @objc private func enteredBackground() {
    foreground = false
    pauseAll()
  }

  @objc private func enteredForeground() { foreground = true }

  private func activateAudio() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  private func pauseOthers(than id: Int64) {
    for (key, clip) in clips where key != id && clip.ready { clip.player.pause() }
  }

  private func pauseAll() {
    for clip in clips.values where clip.ready { clip.player.pause() }
  }

  private func closeAll() { for id in clips.keys { close(id) } }

  private func close(_ id: Int64, code: String = "closed") {
    guard let clip = clips.removeValue(forKey: id) else { return }
    clip.timeout?.cancel()
    clip.timeout = nil
    clip.pending?(FlutterError(code: code, message: "video unavailable", details: nil))
    clip.pending = nil
    clip.link?.invalidate()
    clip.link = nil
    clip.player.pause()
    clip.player.replaceCurrentItem(with: nil)
    clip.output.setDelegate(nil, queue: nil)
    textures.unregisterTexture(id)
  }

  // MARK: - paths

  /// Same rule as `MediaChannel.videoFile`: an absolute path inside the app
  /// container, a regular file, and a container AVFoundation plays.
  static func localVideo(_ path: String) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root + "/"),
      ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return file
  }

  private let posterQueue = DispatchQueue(label: "dsh.video.poster", qos: .utility)
  private var probing = false

  private enum MediaVideoError: Error { case unsupported }

  /// One answer per poster request, first claim wins.
  private final class Answered {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if done { return false }
      done = true
      return true
    }
  }

  /// Owns the display link for one clip; the clip itself stays free of ObjC.
  private final class Ticker: NSObject {
    private weak var clip: Clip?
    private let textures: any FlutterTextureRegistry
    init(clip: Clip, textures: any FlutterTextureRegistry) {
      self.clip = clip
      self.textures = textures
    }
    @objc func tick() {
      guard let clip, clip.player.timeControlStatus == .playing else { return }
      let time = clip.player.currentTime()
      guard clip.output.hasNewPixelBuffer(forItemTime: time) else { return }
      textures.textureFrameAvailable(clip.textureId)
    }
  }

  final class Clip: NSObject, FlutterTexture {
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput
    var textureId: Int64 = -1
    var width = 0
    var height = 0
    var durationMs = 0
    var ready = false
    var pending: FlutterResult?
    var timeout: DispatchWorkItem?
    var link: CADisplayLink?

    init(player: AVPlayer, output: AVPlayerItemVideoOutput) {
      self.player = player
      self.output = output
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
      let time = player.currentItem?.currentTime() ?? .zero
      guard output.hasNewPixelBuffer(forItemTime: time),
        let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
      return Unmanaged.passRetained(buffer)
    }
  }
}
