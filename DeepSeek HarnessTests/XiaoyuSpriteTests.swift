import AppKit
import XCTest
@testable import DeepSeek_Harness

final class XiaoyuSpriteTests: XCTestCase {
    func testMoodMappingAndAtlasRows() {
        let mappings: [(String, XiaoyuAnimation, Int, Int)] = [
            ("disconnected", .disconnected, 0, 1),
            ("idle", .idle, 1, 7),
            ("waiting", .waiting, 2, 6),
            ("authorizing", .authorizing, 3, 6),
            ("questioning", .questioning, 4, 6),
            ("done", .done, 5, 5),
            ("failed", .failed, 6, 8),
        ]

        for (mood, animation, row, count) in mappings {
            XCTAssertEqual(XiaoyuAnimation.animation(for: mood), animation)
            XCTAssertEqual(animation.row, row)
            XCTAssertEqual(animation.frameDurations.count, count)
        }
        XCTAssertEqual(XiaoyuAnimation.wave.row, 7)
        XCTAssertEqual(XiaoyuAnimation.wave.frameDurations.count, 4)
        XCTAssertEqual(XiaoyuAnimation.animation(for: "unknown"), .disconnected)
    }

    func testFrameTimingAndPlaybackPolicies() {
        XCTAssertEqual(XiaoyuAnimation.idle.totalDuration, 4.72, accuracy: 0.001)
        XCTAssertEqual(XiaoyuAnimation.renderInterval, 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertTrue(XiaoyuAnimation.waiting.frameDurations.allSatisfy { $0 == 0.20 })
        XCTAssertTrue(XiaoyuAnimation.authorizing.frameDurations.allSatisfy { $0 == 0.24 })
        XCTAssertTrue(XiaoyuAnimation.questioning.frameDurations.allSatisfy { $0 == 0.20 })
        XCTAssertTrue(XiaoyuAnimation.done.frameDurations.allSatisfy { $0 == 0.12 })
        XCTAssertTrue(XiaoyuAnimation.failed.frameDurations.allSatisfy { $0 == 0.16 })
        XCTAssertTrue(XiaoyuAnimation.wave.frameDurations.allSatisfy { $0 == 0.14 })
        XCTAssertEqual(XiaoyuAnimation.failed.playback, .onceThenHold)
        XCTAssertEqual(XiaoyuAnimation.failed.frameIndex(elapsed: 100), 7)
        XCTAssertEqual(XiaoyuAnimation.done.playback, .loop)
    }

    func testDisplayScaleUsesOneCalibrationPerAnimationRow() {
        let expected: [XiaoyuAnimation: CGFloat] = [
            .disconnected: 1.0,
            .idle: 1.0,
            .waiting: 0.97,
            .authorizing: 0.95,
            .questioning: 1.0,
            .done: 1.10,
            .failed: 1.02,
            .wave: 0.96,
        ]

        for animation in XiaoyuAnimation.allCases {
            XCTAssertEqual(animation.displayScale, expected[animation])
        }
    }

    func testWaveOnlyOverridesIdleForTwoRounds() {
        let trigger = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(XiaoyuAnimation.isWaveActive(
            mood: "idle",
            interactionTriggeredAt: trigger,
            at: trigger.addingTimeInterval(0.5)
        ))
        XCTAssertFalse(XiaoyuAnimation.isWaveActive(
            mood: "waiting",
            interactionTriggeredAt: trigger,
            at: trigger.addingTimeInterval(0.5)
        ))
        XCTAssertFalse(XiaoyuAnimation.isWaveActive(
            mood: "idle",
            interactionTriggeredAt: trigger,
            at: trigger.addingTimeInterval(XiaoyuAnimation.waveInteractionDuration + 0.001)
        ))
        XCTAssertEqual(XiaoyuAnimation.waveRepeatCount, 2)
    }

    func testDragDirectionUsesHorizontalMovementThreshold() {
        XCTAssertNil(XiaoyuDragDirection.direction(forHorizontalDelta: 1.99))
        XCTAssertEqual(XiaoyuDragDirection.direction(forHorizontalDelta: 2), .right)
        XCTAssertEqual(XiaoyuDragDirection.direction(forHorizontalDelta: -2), .left)
        XCTAssertEqual(
            XiaoyuDragDirection.direction(forHorizontalDelta: 0.5, threshold: 0.25),
            .right
        )
    }

    func testDragAnimationRowsAndTiming() {
        XCTAssertEqual(XiaoyuDragDirection.right.rawValue, 0)
        XCTAssertEqual(XiaoyuDragDirection.left.rawValue, 1)
        XCTAssertEqual(XiaoyuDragDirection.frameCount, 8)
        XCTAssertEqual(XiaoyuDragDirection.frameDuration, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(XiaoyuDragDirection.right.frameIndex(elapsed: 0), 0)
        XCTAssertEqual(XiaoyuDragDirection.right.frameIndex(elapsed: 0.08), 1)
        XCTAssertEqual(XiaoyuDragDirection.left.frameIndex(elapsed: 0.63), 7)
        XCTAssertEqual(XiaoyuDragDirection.left.frameIndex(elapsed: 0.64), 0)
    }

    func testBundledDragAtlasDimensionsAlphaAndOccupancy() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: XiaoyuDragSpriteAtlas.resourceName, withExtension: "png")
        )
        let data = try Data(contentsOf: url)
        let representation: NSBitmapImageRep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(representation.pixelsWide, XiaoyuDragSpriteAtlas.pixelWidth)
        XCTAssertEqual(representation.pixelsHigh, XiaoyuDragSpriteAtlas.pixelHeight)
        XCTAssertTrue(representation.hasAlpha)
        XCTAssertEqual(representation.bitsPerSample, 8)
        XCTAssertFalse(representation.isPlanar)

        let atlas = try XiaoyuDragSpriteAtlas(resourceURL: url)
        for direction in XiaoyuDragDirection.allCases {
            for index in 0..<XiaoyuDragDirection.frameCount {
                let frame = try XCTUnwrap(atlas.frame(for: direction, index: index))
                XCTAssertNotNil(frame.alphaInfo)
            }
        }
        XCTAssertNil(atlas.frame(for: .right, index: -1))
        XCTAssertNil(atlas.frame(for: .left, index: XiaoyuDragDirection.frameCount))
    }

    func testBundledAtlasDimensionsAlphaAndOccupancy() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: XiaoyuSpriteAtlas.resourceName, withExtension: "png")
        )
        let data = try Data(contentsOf: url)
        let representation: NSBitmapImageRep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(representation.pixelsWide, 1536)
        XCTAssertEqual(representation.pixelsHigh, 1664)
        XCTAssertTrue(representation.hasAlpha)
        XCTAssertEqual(representation.bitsPerSample, 8)
        XCTAssertFalse(representation.isPlanar)

        _ = try XiaoyuSpriteAtlas(resourceURL: url)
        let bytes: UnsafeMutablePointer<UInt8> = try XCTUnwrap(representation.bitmapData)
        let bytesPerRow = representation.bytesPerRow
        let samplesPerPixel = representation.samplesPerPixel
        let alphaOffset = samplesPerPixel - 1
        let usedCounts = [1, 7, 6, 6, 6, 5, 8, 4]

        for row in 0..<XiaoyuSpriteAtlas.rows {
            for column in 0..<XiaoyuSpriteAtlas.columns {
                var occupied = false
                for y in 0..<XiaoyuSpriteAtlas.cellHeight where !occupied {
                    for x in 0..<XiaoyuSpriteAtlas.cellWidth {
                        let offset = (row * XiaoyuSpriteAtlas.cellHeight + y) * bytesPerRow
                            + (column * XiaoyuSpriteAtlas.cellWidth + x) * samplesPerPixel
                            + alphaOffset
                        if bytes[offset] > 0 {
                            occupied = true
                            break
                        }
                    }
                }
                XCTAssertEqual(
                    occupied,
                    column < usedCounts[row],
                    "unexpected occupancy at row \(row), column \(column)"
                )
            }
        }
    }
}
