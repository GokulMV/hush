import XCTest
@testable import Hush

final class LedgerTests: XCTestCase {
    func testOverlappingReasonsReleaseOnlyWhenLastOneGoes() {
        var ledger = Ledger()
        XCTAssertEqual(ledger.engage(.call, [.media]), [.media])
        XCTAssertEqual(ledger.engage(.away, [.mic, .media]), [.mic], "media was already held by the call")

        XCTAssertEqual(ledger.release(.away), [.mic], "coming back must not resume media the call paused")
        XCTAssertTrue(ledger.isHeld(.media))
        XCTAssertEqual(ledger.release(.call), [.media])
        XCTAssertFalse(ledger.isHeld(.media))
    }

    func testReleasingUnknownReasonFreesNothing() {
        var ledger = Ledger()
        _ = ledger.engage(.panic, [.mic])
        XCTAssertEqual(ledger.release(.ring), [])
        XCTAssertTrue(ledger.isEngaged(.panic))
    }

    func testClearDropsEveryReason() {
        var ledger = Ledger()
        _ = ledger.engage(.away, [.mic])
        _ = ledger.engage(.manual, [.mic])
        ledger.clear(.mic)
        XCTAssertFalse(ledger.isHeld(.mic))
        XCTAssertEqual(ledger.release(.away), [], "already cleared, nothing left to undo")
    }
}

final class PresenceTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testBriefGlanceAwayIsIgnored() {
        var tracker = PresenceTracker()
        tracker.awayAfter = 5
        XCTAssertNil(tracker.update(.absent, at: t0))
        XCTAssertNil(tracker.update(.absent, at: t0 + 3))
        XCTAssertNil(tracker.update(.present, at: t0 + 3.5))
        XCTAssertNil(tracker.update(.absent, at: t0 + 4), "timer restarts after you reappear")
        XCTAssertNil(tracker.update(.absent, at: t0 + 8.5))
        XCTAssertEqual(tracker.update(.absent, at: t0 + 9), .away)
    }

    func testPhoneToEarAndBack() {
        var tracker = PresenceTracker()
        XCTAssertNil(tracker.update(.phoneToEar, at: t0))
        XCTAssertNil(tracker.update(.phoneToEar, at: t0 + 0.5))
        XCTAssertEqual(tracker.update(.phoneToEar, at: t0 + 1.0), .onPhone)
        XCTAssertNil(tracker.update(.phoneToEar, at: t0 + 10))
        XCTAssertNil(tracker.update(.present, at: t0 + 11))
        XCTAssertEqual(tracker.update(.present, at: t0 + 11.75), .present)
    }

    func testDefaultAwayDelayIsTwoSeconds() {
        var tracker = PresenceTracker()
        XCTAssertNil(tracker.update(.absent, at: t0))
        XCTAssertNil(tracker.update(.absent, at: t0 + 1.75))
        XCTAssertEqual(tracker.update(.absent, at: t0 + 2), .away)
    }

    func testCustomAwayDelay() {
        var tracker = PresenceTracker()
        tracker.awayAfter = 20
        XCTAssertNil(tracker.update(.absent, at: t0))
        XCTAssertNil(tracker.update(.absent, at: t0 + 19))
        XCTAssertEqual(tracker.update(.absent, at: t0 + 20), .away)
    }
}

final class AppClassifierTests: XCTestCase {
    func testCallApps() {
        XCTAssertTrue(AppClassifier.isCallApp("us.zoom.xos"))
        XCTAssertTrue(AppClassifier.isCallApp("com.microsoft.teams2"))
        XCTAssertFalse(AppClassifier.isCallApp("com.google.Chrome.helper"))
    }

    func testMediaSources() {
        XCTAssertTrue(AppClassifier.isMediaSource("com.google.Chrome.helper"))
        XCTAssertTrue(AppClassifier.isMediaSource("com.apple.WebKit.GPU"), "Safari plays through WebKit.GPU")
        XCTAssertFalse(AppClassifier.isMediaSource("org.videolan.vlc"), "VLC is paused via AppleScript, not ⏯")
        XCTAssertTrue(AppClassifier.isMediaSource("com.colliderli.iina"), "other players still get ⏯")
        XCTAssertFalse(AppClassifier.isMediaSource("com.apple.notificationcenterui"), "system chimes are not media")
        XCTAssertFalse(AppClassifier.isMediaSource("us.zoom.xos"), "the call itself is not media")
        XCTAssertFalse(AppClassifier.isMediaSource("com.spotify.client"), "Spotify is handled by AppleScript")
    }

    func testSiriDoesNotCountAsACall() {
        XCTAssertFalse(AppClassifier.countsAsCall(micUser: "com.apple.SiriNCService", ownBundleID: nil))
        XCTAssertFalse(AppClassifier.countsAsCall(micUser: "com.gokulmv.hush", ownBundleID: "com.gokulmv.hush"))
        XCTAssertTrue(AppClassifier.countsAsCall(micUser: "us.zoom.xos", ownBundleID: "com.gokulmv.hush"))
    }
}

final class MeetingButtonLabelTests: XCTestCase {
    private func turnsOff(_ kind: MeetingControl.Kind, _ label: String) -> Bool {
        MeetingControl.labels(kind, on: false).contains { MeetingControl.matches(label, $0) }
    }

    private func turnsOn(_ kind: MeetingControl.Kind, _ label: String) -> Bool {
        MeetingControl.labels(kind, on: true).contains { MeetingControl.matches(label, $0) }
    }

    func testGoogleMeet() {
        XCTAssertTrue(turnsOff(.video, "Turn off camera (⌘ + e)"))
        XCTAssertTrue(turnsOn(.video, "Turn on camera (⌘ + e)"))
        XCTAssertTrue(turnsOff(.audio, "Turn off microphone (⌘ + d)"))
        XCTAssertTrue(turnsOn(.audio, "Turn on microphone (⌘ + d)"))
    }

    func testTeamsWebexZoomWeb() {
        XCTAssertTrue(turnsOff(.video, "Turn camera off (⌘+Shift+O)"))
        XCTAssertTrue(turnsOff(.audio, "Mute (⌘+Shift+M)"))
        XCTAssertTrue(turnsOn(.audio, "Unmute (⌘+Shift+M)"))
        XCTAssertTrue(turnsOff(.video, "Stop video"))
        XCTAssertTrue(turnsOn(.video, "Start Video"))
    }

    func testNeverMatchesTheOppositeOrUnrelatedButtons() {
        XCTAssertFalse(turnsOff(.video, "Turn on camera (⌘ + e)"), "must never switch the camera on")
        XCTAssertFalse(turnsOff(.audio, "Unmute (⌘+Shift+M)"), "\"unmute\" must not match \"mute\"")
        XCTAssertFalse(turnsOff(.audio, "Mute notifications"))
        XCTAssertFalse(turnsOff(.video, "Camera settings"))
    }
}

final class PhoneRuleTests: XCTestCase {
    private let face = CGRect(x: 0.39, y: 0.26, width: 0.27, height: 0.28)

    func testPhoneInHandCounts() {
        let phone = CGRect(x: 0.20, y: 0.10, width: 0.08, height: 0.15) // held low, looking at it
        let hand = [CGPoint(x: 0.21, y: 0.12), CGPoint(x: 0.24, y: 0.11), CGPoint(x: 0.27, y: 0.13),
                    CGPoint(x: 0.25, y: 0.09)]
        XCTAssertEqual(PhoneRule.verdict(phone: phone, hands: [hand], faces: [face]), "phone in your hand")
    }

    func testPhoneAtTheEarCountsEvenWithTheHandHidden() {
        let phone = CGRect(x: 0.64, y: 0.30, width: 0.06, height: 0.16) // right beside the face
        XCTAssertEqual(PhoneRule.verdict(phone: phone, hands: [], faces: [face]), "phone at your ear")
    }

    func testHandCarryingAPhoneToTheEarIsBesideTheFace() {
        // Point layout measured from a real Camera Preview frame of a phone held at the ear.
        let hand = [CGPoint(x: 0.68, y: 0.39), CGPoint(x: 0.70, y: 0.38), CGPoint(x: 0.73, y: 0.39),
                    CGPoint(x: 0.75, y: 0.37), CGPoint(x: 0.69, y: 0.35), CGPoint(x: 0.72, y: 0.34),
                    CGPoint(x: 0.78, y: 0.35), CGPoint(x: 0.84, y: 0.34), CGPoint(x: 0.70, y: 0.30),
                    CGPoint(x: 0.76, y: 0.31), CGPoint(x: 0.71, y: 0.27), CGPoint(x: 0.68, y: 0.23),
                    CGPoint(x: 0.73, y: 0.21), CGPoint(x: 0.80, y: 0.19), CGPoint(x: 0.86, y: 0.18)]
        XCTAssertTrue(PhoneRule.handBesideFace(hand, face: face))
    }

    func testChinRestIsNotBesideTheFace() {
        let chinFace = CGRect(x: 0.26, y: 0.28, width: 0.25, height: 0.31)
        let hand = [CGPoint(x: 0.08, y: 0.42), CGPoint(x: 0.13, y: 0.38), CGPoint(x: 0.19, y: 0.37),
                    CGPoint(x: 0.22, y: 0.39), CGPoint(x: 0.25, y: 0.40), CGPoint(x: 0.21, y: 0.33),
                    CGPoint(x: 0.24, y: 0.32), CGPoint(x: 0.17, y: 0.31), CGPoint(x: 0.23, y: 0.28),
                    CGPoint(x: 0.29, y: 0.52), CGPoint(x: 0.30, y: 0.49), CGPoint(x: 0.31, y: 0.45),
                    CGPoint(x: 0.33, y: 0.37), CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.37, y: 0.30),
                    CGPoint(x: 0.28, y: 0.35)]
        XCTAssertFalse(PhoneRule.handBesideFace(hand, face: chinFace))
    }

    func testEarRegionStaysInsideTheFrame() {
        let region = PhoneRule.earRegion(CGRect(x: 0.05, y: 0.6, width: 0.3, height: 0.35))
        XCTAssertGreaterThanOrEqual(region.minX, 0)
        XCTAssertLessThanOrEqual(region.maxY, 1)
    }

    func testPhoneLyingOnTheDeskDoesNotCount() {
        let phone = CGRect(x: 0.05, y: 0.02, width: 0.10, height: 0.06)
        XCTAssertNil(PhoneRule.verdict(phone: phone, hands: [], faces: [face]))
    }
}

final class LedgerDropTests: XCTestCase {
    func testAReasonThatPausedNothingDoesNotBlockResuming() {
        var ledger = Ledger()
        _ = ledger.engage(.call, [.media])       // call started, but nothing was playing…
        ledger.drop(.call, from: .media)          // …so the call holds nothing
        XCTAssertEqual(ledger.engage(.away, [.media]), [.media], "stepping away now pauses media itself")
        XCTAssertEqual(ledger.release(.away), [.media], "and coming back resumes it, not waiting for the call to end")
    }
}

final class UpdateAndChangelogTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(AppVersion("1.0.10") > AppVersion("1.0.9"))
        XCTAssertTrue(AppVersion("v1.2") > AppVersion("1.1.9"), "a leading v is ignored")
        XCTAssertTrue(AppVersion("1.0") == AppVersion("1.0.0"))
        XCTAssertFalse(AppVersion("1.0.0") > AppVersion("1.0.0"))
    }

    func testChangelogSectionsAndUpgradeRange() {
        let text = """
            # Changelog

            ## 1.2.0 — 2026-10-10
            - Newest

            ## 1.1.0
            - Middle

            ## 1.0.0 — first release
            - Oldest
            """
        let entries = Changelog.parse(text)
        XCTAssertEqual(entries.map(\.version), ["1.2.0", "1.1.0", "1.0.0"])
        XCTAssertEqual(entries.first?.notes, "- Newest")
        // What's New after upgrading 1.0.0 → 1.2.0 shows the two newer entries, not the old one.
        let newer = entries.filter { AppVersion($0.version) > AppVersion("1.0.0") && AppVersion($0.version) <= AppVersion("1.2.0") }
        XCTAssertEqual(newer.map(\.version), ["1.2.0", "1.1.0"])
    }
}
