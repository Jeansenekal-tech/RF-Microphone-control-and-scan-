import XCTest
@testable import UniqueAVCore

final class ShureProtocolTests: XCTestCase {
    func testTokensKeepBracedNames() {
        XCTAssertEqual(ShureProtocol.tokens("REP 1 CHAN_NAME {Lead Vox}"), ["REP", "1", "CHAN_NAME", "Lead Vox"])
    }

    func testExtractFramesKeepsPartial() {
        var buf = "junk< REP 1 FREQUENCY 578350 >< REP 2 CHAN_NAME {Gtr} >< REP 3 FR"
        let frames = ShureProtocol.extractFrames(&buf)
        XCTAssertEqual(frames, ["REP 1 FREQUENCY 578350", "REP 2 CHAN_NAME {Gtr}"])
        XCTAssertEqual(buf, "< REP 3 FR")
    }

    func testParseRepAndSample() {
        XCTAssertEqual(ShureProtocol.parse("REP 2 AUDIO_GAIN 030"), .rep(channel: 2, key: "AUDIO_GAIN", values: ["030"]))
        XCTAssertEqual(ShureProtocol.parse("REP MODEL {ULXD4Q}"), .rep(channel: nil, key: "MODEL", values: ["ULXD4Q"]))
        XCTAssertEqual(ShureProtocol.parse("SAMPLE 1 ALL AX 098 035"), .sample(channel: 1, values: ["AX", "098", "035"]))
        let s = ShureProtocol.decodeSample(["AX", "098", "035"])
        XCTAssertEqual(s, ShureProtocol.Sample(antenna: "A", rfDBm: -30, audioDBFS: -15))
    }

    func testCommands() {
        XCTAssertEqual(ShureProtocol.setFrequency(1, kHz: 578350), "< SET 1 FREQUENCY 578350 >")
        XCTAssertEqual(ShureProtocol.setGain(3, dB: 12), "< SET 3 AUDIO_GAIN 030 >")
        XCTAssertEqual(ShureProtocol.setName(1, "Vox {1}"), "< SET 1 CHAN_NAME {Vox 1} >")
    }
}

final class UHFRProtocolTests: XCTestCase {
    func testStarFramesAndReport() {
        let text = "* REPORT 1 CHAN_NAME {LEAD*VOX} ** REPORT 2 FREQUENCY 578350 *\r\n"
        let frames = ShureProtocol.extractStarFrames(text)
        XCTAssertEqual(frames, ["REPORT 1 CHAN_NAME {LEAD*VOX}", "REPORT 2 FREQUENCY 578350"])
        XCTAssertEqual(ShureProtocol.parse(frames[1]), .rep(channel: 2, key: "FREQUENCY", values: ["578350"]))
        XCTAssertEqual(ShureProtocol.parse(frames[0]), .rep(channel: 1, key: "CHAN_NAME", values: ["LEAD*VOX"]))
    }

    func testCommandConversion() {
        XCTAssertEqual(ShureProtocol.uhfr(ShureProtocol.setFrequency(1, kHz: 578350)), "* SET 1 FREQUENCY 578350 *")
        XCTAssertEqual(ShureProtocol.uhfr(ShureProtocol.frame("GET 2 TX_BAT")), "* GET 2 TX_BAT *")
    }
}

final class TinySATests: XCTestCase {
    func testSegmentsCoverSpanOnGrid() {
        let segs = TinySAProtocol.segments(startHz: 470e6, stopHz: 694e6, stepHz: 25e3)
        XCTAssertEqual(segs.reduce(0) { $0 + $1.points }, 8961)
        XCTAssertTrue(segs.allSatisfy { $0.points <= 450 })
        XCTAssertEqual(segs.first?.startHz, 470e6)
        XCTAssertEqual(segs.last?.stopHz, 694e6)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(b.startHz - a.stopHz, 25e3, accuracy: 0.001) }
    }

    func testParseScanAndStrip() {
        let raw = "scan 470000000 470050000 3 3\r\n470000000 -9.1e+01 \r\n470025000 -88.5 \r\n470050000 -90 \r\nch> "
        let body = TinySAProtocol.stripResponse(raw, command: "scan 470000000 470050000 3 3")
        let pts = TinySAProtocol.parseScan(body)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].hz, 470e6)
        XCTAssertEqual(pts[0].dBm, -91)
        XCTAssertEqual(pts[1].dBm, -88.5)
    }

    func testCSVImportUnits() {
        let wwb = "Frequency (MHz),Level (dBm)\n470.000,-95.2\n470.025,-94\n"
        XCTAssertEqual(ScanCSV.parse(wwb).map { $0.kHz }, [470000, 470025])
        let hz = "470000000;-90\n470025000;-91"
        XCTAssertEqual(ScanCSV.parse(hz).map { $0.kHz }, [470000, 470025])
    }
}

final class CoordinatorTests: XCTestCase {
    func testCoordinatedSetIsClean() {
        var s = CoordSettings()
        s.startMHz = 470; s.stopMHz = 520
        let f = Coordinator.coordinate(count: 12, fixed: [], settings: s, region: .southAfrica)
        XCTAssertEqual(f.count, 12)
        let items = f.enumerated().map { NamedFrequency(label: "ch\($0.offset)", kHz: $0.element) }
        XCTAssertEqual(Coordinator.analyze(items, settings: s), [])
    }

    func testAnalyzeFindsIntermod() {
        let s = CoordSettings()
        // 2*500.000 - 501.000 = 499.000 lands on the third carrier.
        let items = [NamedFrequency(label: "A", kHz: 500_000), NamedFrequency(label: "B", kHz: 501_000),
                     NamedFrequency(label: "C", kHz: 499_000)]
        XCTAssertTrue(Coordinator.analyze(items, settings: s).contains { $0.victim == "C" && $0.kind == "3rd order 2-Tx" })
    }

    func testAvoidsScanSignalsAndRestrictedBands() {
        var s = CoordSettings()
        s.startMHz = 700; s.stopMHz = 740
        s.thresholdDBm = -80
        let f = Coordinator.coordinate(count: 5, fixed: [], settings: s, region: .southAfrica,
                                       level: { a, b in (a < 736_000 && b > 734_000) ? -60 : -100 })
        XCTAssertFalse(f.isEmpty)
        for k in f {
            XCTAssertFalse((703_000...733_000).contains(k), "inside IMT700 uplink")
            XCTAssertFalse((733_900...736_100).contains(k), "on top of a scanned signal")
        }
    }

    func testPerReceiverTuningLimits() {
        var s = CoordSettings()
        s.startMHz = 470; s.stopMHz = 700
        // Receiver A tunes 470-534 in 25 kHz steps, receiver B 606-662 in 125 kHz steps, C unrestricted.
        let a = TuningLimit(lowKHz: 470_000, highKHz: 534_000, stepKHz: 25)
        let b = TuningLimit(lowKHz: 606_000, highKHz: 662_000, stepKHz: 125)
        let r = Coordinator.coordinate(targets: [[0], [0], [0], [0], [0]], fixed: [], segmentCount: 1, settings: s,
                                       limits: [a, a, b, b, nil])
        XCTAssertEqual(r.compactMap { $0 }.count, 5)
        for k in [r[0]!, r[1]!] { XCTAssertTrue(a.allows(k)) }
        for k in [r[2]!, r[3]!] { XCTAssertTrue((606_000...662_000).contains(k)); XCTAssertEqual(k % 125, 0) }
        let items = r.compactMap { $0 }.enumerated().map { NamedFrequency(label: "c\($0.offset)", kHz: $0.element) }
        XCTAssertEqual(Coordinator.analyze(items, settings: s), [])
    }

    func testTimeOfUseAllowsReuse() {
        var s = CoordSettings()
        s.startMHz = 470; s.stopMHz = 470.4; s.use3Tx = false; s.use5th = false
        // Only two carriers fit 350 kHz apart in this tiny range.
        XCTAssertEqual(Coordinator.coordinate(count: 4, fixed: [], settings: s).count, 2)

        let act1 = UsageGroup(name: "Act 1", slots: Schedule.parseSlots("18:00-19:00"))
        let act2 = UsageGroup(name: "Act 2", slots: Schedule.parseSlots("19:30-21:00"))
        let segs = Schedule.segments([act1, act2])
        let m1 = Schedule.activeSegments(act1, segs), m2 = Schedule.activeSegments(act2, segs)
        XCTAssertTrue(m1.isDisjoint(with: m2))
        let r = Coordinator.coordinate(targets: [m1, m1, m2, m2], fixed: [], segmentCount: segs.count, settings: s)
        XCTAssertEqual(r.compactMap { $0 }.count, 4)
    }
}

final class ScheduleAndRegionTests: XCTestCase {
    func testParseAndOvernight() {
        let slots = Schedule.parseSlots("22:00-02:00, 1800-1930")
        XCTAssertEqual(slots, [TimeSlot(startMin: 1320, endMin: 120), TimeSlot(startMin: 1080, endMin: 1170)])
        XCTAssertEqual(slots[0].intervals, [1320..<1440, 0..<120])
        XCTAssertEqual(Schedule.format(slots), "22:00-02:00, 18:00-19:30")
        let late = UsageGroup(name: "Late", slots: [slots[0]])
        let early = UsageGroup(name: "Early", slots: Schedule.parseSlots("01:00-03:00"))
        XCTAssertTrue(Schedule.overlaps(late, early))
        XCTAssertTrue(Schedule.overlaps(nil, early))
    }

    func testSouthAfricaChannels() {
        let za = RegionProfile.southAfrica
        XCTAssertEqual(za.tvChannel(containingMHz: 470.5)?.number, 21)
        XCTAssertEqual(za.tvChannel(containingMHz: 690)?.number, 48)
        XCTAssertTrue(RegionProfile.none.tvChannels.isEmpty)
        XCTAssertEqual(RegionProfile.unitedStates.tvChannel(containingMHz: 607)?.number, 36)
    }
}

final class NetworkMathTests: XCTestCase {
    func testParseAndFormat() {
        XCTAssertEqual(IPv4.parse("192.168.1.20"), 0xC0A8_0114)
        XCTAssertNil(IPv4.parse("192.168.1"))
        XCTAssertNil(IPv4.parse("192.168.1.256"))
        XCTAssertNil(IPv4.parse("a.b.c.d"))
        XCTAssertEqual(IPv4.format(0x0A00_0001), "10.0.0.1")
    }

    func testMasksAndSubnets() {
        XCTAssertEqual(IPv4.prefixLength(mask: "255.255.255.0"), 24)
        XCTAssertEqual(IPv4.prefixLength(mask: "255.255.252.0"), 22)
        XCTAssertNil(IPv4.prefixLength(mask: "255.0.255.0"))
        XCTAssertTrue(IPv4.sameSubnet("192.168.1.20", "192.168.1.200", prefix: 24))
        XCTAssertFalse(IPv4.sameSubnet("192.168.1.20", "192.168.2.20", prefix: 24))
        XCTAssertTrue(IPv4.sameSubnet("10.0.1.5", "10.0.2.9", prefix: 22))
        XCTAssertEqual(IPv4.subnet("10.0.1.5", prefix: 22), "10.0.0.0/22")
    }

    func testDiscoveryHosts() {
        let h24 = IPv4.hosts(around: "192.168.1.20", prefix: 24)
        XCTAssertEqual(h24.count, 253)                       // 254 hosts minus ourselves
        XCTAssertFalse(h24.contains("192.168.1.20"))
        XCTAssertEqual(h24.first, "192.168.1.1")
        XCTAssertEqual(h24.last, "192.168.1.254")
        XCTAssertEqual(IPv4.hosts(around: "10.0.1.5", prefix: 22).count, 1021)   // whole /22
        XCTAssertEqual(IPv4.hosts(around: "10.20.30.40", prefix: 8).count, 253)    // too big -> /24
        XCTAssertEqual(IPv4.hosts(around: "10.0.0.1", prefix: 32), [])
    }

    func testLinkLocalAndARP() {
        XCTAssertTrue(IPv4.isLinkLocal("169.254.10.20"))
        XCTAssertFalse(IPv4.isLinkLocal("192.168.1.1"))
        let all = IPv4.linkLocalHosts(excluding: ["169.254.1.5"])
        XCTAssertEqual(all.count, 254 * 256 - 1)
        XCTAssertEqual(all.first, "169.254.1.0")
        XCTAssertFalse(all.contains("169.254.1.5"))
        let arp = """
        ? (169.254.12.34) at 0:e:dd:1:2:3 on en5 ifscope [ethernet]
        ? (169.254.200.7) at 0:e:dd:4:5:6 on en5 ifscope [ethernet]
        ? (192.168.1.1) at a4:2b:b0:0:0:1 on en0 ifscope [ethernet]
        ? (192.168.1.77) at (incomplete) on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        """
        XCTAssertEqual(IPv4.parseARP(arp), ["169.254.12.34", "169.254.200.7", "192.168.1.1"])
        XCTAssertEqual(IPv4.parseARP(arp, interface: "en5"), ["169.254.12.34", "169.254.200.7"])
    }
}
