import Flutter
import XCTest
@testable import Runner

/// `streamingPcm` is pure transport here: 16 kHz mono PCM16 in, 640-byte frames
/// tagged with the Dart session out. No microphone, Host or recognizer involved.
final class StreamingPcmTests: XCTestCase {
  func testSplitterHoldsThePartialFrame() {
    var splitter = PcmFrameSplitter()
    // 400 bytes is short of one 640-byte frame, so nothing goes out yet.
    XCTAssertTrue(splitter.append(Data(repeating: 1, count: 400)).isEmpty)
    XCTAssertEqual(splitter.buffered, 400)
    // 700 bytes completes one frame and leaves 60 bytes buffered.
    let frames = splitter.append(Data(repeating: 2, count: 300))
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames[0].count, PcmFrameSplitter.bytesPerFrame)
    XCTAssertEqual(splitter.buffered, 60)
    // Another 580 bytes completes the next frame with nothing left over.
    let more = splitter.append(Data(repeating: 3, count: 580))
    XCTAssertEqual(more.count, 1)
    XCTAssertEqual(splitter.buffered, 0)
  }

  func testSplitterEmitsWholeFramesInOrder() {
    var splitter = PcmFrameSplitter()
    var input = Data()
    for index in 0..<(PcmFrameSplitter.bytesPerFrame * 3 + 100) {
      input.append(UInt8(index % 251))
    }
    let frames = splitter.append(input)
    XCTAssertEqual(frames.count, 3)
    XCTAssertEqual(frames.map(\.count), [640, 640, 640])
    XCTAssertEqual(frames[1].first, input[640])
    XCTAssertEqual(splitter.buffered, 100)
    splitter.reset()
    XCTAssertEqual(splitter.buffered, 0)
  }

  func testTapEmitsFramesForItsOwnSourceOnly() {
    let tap = StreamingPcmTap()
    var events: [[String: Any]] = []
    tap.emit = { events.append($0) }
    tap.start(session: 7, source: "call")

    tap.feed(Data(repeating: 0, count: 1280), source: "dictation")
    XCTAssertTrue(events.isEmpty)

    tap.feed(Data(repeating: 0, count: 1280), source: "call")
    XCTAssertEqual(events.count, 2)
    for event in events {
      XCTAssertEqual(event["type"] as? String, "pcm")
      XCTAssertEqual(event["rate"] as? Int, 16_000)
      XCTAssertEqual(event["pcmSession"] as? Int, 7)
      XCTAssertEqual((event["bytes"] as? FlutterStandardTypedData)?.data.count, 640)
    }
  }

  func testStopOnlyClosesItsOwnSession() {
    let tap = StreamingPcmTap()
    var events: [[String: Any]] = []
    tap.emit = { events.append($0) }
    tap.start(session: 9, source: "dictation")

    XCTAssertFalse(tap.stop(session: 8))
    XCTAssertEqual(tap.activeSession, 9)
    XCTAssertTrue(events.isEmpty)

    XCTAssertTrue(tap.stop(session: 9))
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0]["type"] as? String, "pcmReset")
    XCTAssertEqual(events[0]["reason"] as? String, "stopped")
    XCTAssertEqual(events[0]["source"] as? String, "dictation")
    XCTAssertEqual(tap.activeSession, 0)

    tap.feed(Data(repeating: 0, count: 640), source: "dictation")
    XCTAssertEqual(events.count, 1, "a stopped tap keeps quiet")
  }

  func testResetReportsPauseAndResumeWithoutEndingTheSession() {
    let tap = StreamingPcmTap()
    var events: [[String: Any]] = []
    tap.emit = { events.append($0) }
    tap.start(session: 3, source: "call")
    tap.reset("muted")
    tap.reset("resumed")
    XCTAssertEqual(events.map { $0["reason"] as? String }, ["muted", "resumed"])
    XCTAssertEqual(tap.activeSession, 3)

    XCTAssertFalse(tap.stop(session: 0), "a stop for another session is ignored")
    tap.stop(session: 3)
    XCTAssertEqual(events.count, 3)
    tap.reset("stopped")
    XCTAssertEqual(events.count, 3, "a cleared tap keeps quiet")
  }
}
