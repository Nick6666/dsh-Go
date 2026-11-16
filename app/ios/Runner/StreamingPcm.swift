import Flutter
import Foundation

/// Cuts the 16 kHz mono PCM16 stream the engine's recognizer consumes into the
/// fixed 640-byte frames (20 ms) `dsh/voice/events` carries for `streamingPcm`.
///
/// The caller keeps feeding converted buffers; nothing here knows about the
/// microphone, so it stays testable without audio hardware.
struct PcmFrameSplitter {
  static let sampleRate = 16_000
  static let bytesPerFrame = 640

  private var pending = Data()

  /// Bytes buffered but not yet handed out as a whole frame.
  var buffered: Int { pending.count }

  mutating func reset() { pending.removeAll(keepingCapacity: true) }

  /// Returns every complete frame in the new data plus what was buffered.
  mutating func append(_ data: Data) -> [Data] {
    pending.append(data)
    guard pending.count >= Self.bytesPerFrame else { return [] }
    let count = pending.count / Self.bytesPerFrame
    var frames: [Data] = []
    frames.reserveCapacity(count)
    var offset = pending.startIndex
    for _ in 0..<count {
      frames.append(pending.subdata(in: offset..<(offset + Self.bytesPerFrame)))
      offset += Self.bytesPerFrame
    }
    pending.removeSubrange(pending.startIndex..<offset)
    return frames
  }
}

/// The one place `dsh/voice`'s `streamingPcm` frames come from: the call graph
/// in `IOSSpeechChannel` and the recorder session in `VoiceChannel` both feed it,
/// and `VoiceChannel` drains it onto `dsh/voice/events`. Nothing is buffered
/// beyond one partial frame, so a slow consumer drops nothing that was already
/// produced and never grows with the call.
final class StreamingPcmTap {
  static let shared = StreamingPcmTap()

  /// Set while `dsh/voice/events` has a listener; cleared when Dart cancels.
  var emit: (([String: Any]) -> Void)?

  private var session = 0
  private var source = ""
  private var frames = PcmFrameSplitter()

  var activeSession: Int { session }
  var activeSource: String { source }

  func start(session: Int, source: String) {
    self.session = session
    self.source = source
    frames.reset()
  }

  /// Stops [session]; a stop for an older session is ignored, as Dart can send
  /// the previous id after starting a new one.
  @discardableResult
  func stop(session: Int) -> Bool {
    guard session == self.session else { return false }
    let stopped = source
    self.session = 0
    source = ""
    frames.reset()
    emit?(["type": "pcmReset", "source": stopped, "reason": "stopped", "pcmSession": session])
    return true
  }

  /// [pcm] is 16 kHz mono PCM16, as both capture paths already produce.
  func feed(_ pcm: Data, source from: String) {
    guard session != 0, from == source else { return }
    for frame in frames.append(pcm) {
      emit?(["type": "pcm", "rate": PcmFrameSplitter.sampleRate,
        "bytes": FlutterStandardTypedData(bytes: frame), "pcmSession": session])
    }
  }

  /// Says the tap paused or resumed while the session stays alive.
  func reset(_ reason: String) {
    guard session != 0 else { return }
    emit?(["type": "pcmReset", "source": source, "reason": reason, "pcmSession": session])
  }
}
