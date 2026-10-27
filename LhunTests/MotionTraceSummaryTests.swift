import Testing
@testable import LhunKit

struct MotionTraceSummaryTests {
    @Test("A fractional visible keyboard tail does not stop before the card")
    func fractionalKeyboardTail() throws {
        let frames: [(at: Int, keys: Double?, bottom: Double)] = [
            (72, 393, 385),
            (74, 393.08, 385),
            (76, 412.29, 385),
            (77, 436.30, 416),
            (78, 465.13, 451),
            (79, 496.34, 483),
            (80, 528.10, 515),
            (81, 559.54, 545.5),
            (82, 589.32, 574.5),
            (83, 617.19, 601),
            (84, 642.95, 625.5),
            (85, 666.40, 647.5),
            (86, 687.53, 667),
            (87, 706.49, 685),
            (88, 723.33, 700.5),
            (89, 738.21, 714),
            (90, 751.32, 726),
            (91, 762.76, 736.5),
            (92, 772.80, 745.5),
            (93, 781.58, 753.5),
            (94, 789.08, 760.5),
            (95, 795.60, 766.5),
            (96, 801.22, 771.5),
            (97, 806.09, 776),
            (98, 810.23, 779.5),
            (99, 813.77, 783),
            (100, 816.83, 785.5),
            (101, 819.44, 788),
            (102, 821.65, 790),
            (103, 823.56, 791.5),
            (104, 825.16, 793),
            (105, 826.52, 794.5),
            (106, 827.69, 795.5),
            (107, 828.67, 796),
            (108, 829.50, 797),
            (109, 830.21, 797.5),
            (110, 830.81, 798),
            (111, 831.32, 798.5),
            (112, 831.75, 799),
            (113, 832.10, 799.5),
            (114, 832.40, 799.5),
            (115, 832.66, 800),
            (116, 832.87, 800),
            (117, 833.05, 800),
            (118, 833.21, 800.5),
            (119, 833.34, 800.5),
            (120, 833.44, 800.5),
            (123, nil, 801),
            (124, nil, 801),
            (125, nil, 801),
        ]
        let result = summary(frames, grids: ["121x12", "121x34"])
        let lag = try #require((result["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        #expect(result["keyboardReference"] as? String == "key row")
        #expect(lag["start"] == 1)
        #expect(lag["end"] == 0)
        #expect(result["reversals"] as? Int == 0)
        #expect(result["snaps"] as? Int == 0)
        #expect(result["regrids"] as? Int == 1)
    }

    @Test("A card stopping two frames after the visible keyboard still fails the one-frame guard", arguments: [0, 2])
    func keyboardDeparture(delay: Int) throws {
        let keys: [Double] = [100, 110, 120, 125]
        let bottom = Array(repeating: 92.0, count: delay) + [92, 102, 112, 117, 118, 118, 118]
        let frames: [(at: Int, keys: Double?, bottom: Double)] = bottom.enumerated().map { index, value in
            (index, index < keys.count ? keys[index] : nil, value)
        }
        let result = summary(frames, grids: ["84x36"])
        let lag = try #require((result["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        let end = try #require(lag["end"])
        #expect(lag["start"] == delay)
        #expect(end == delay)
        if delay > 1 {
            #expect(abs(end) > 1)
        }
    }

    @Test("A stationary key row cannot hide a late terminal when it disappears")
    func stationaryKeyboardDeparture() throws {
        let keys: [Double] = [100, 110, 120, 125, 125, 125]
        let bottom: [Double] = [92, 102, 112, 117, 117.5, 118, 118, 118]
        let frames: [(at: Int, keys: Double?, bottom: Double)] = bottom.enumerated().map { index, value in
            (index, index < keys.count ? keys[index] : nil, value)
        }
        let result = summary(frames, grids: ["84x36"])
        let lag = try #require((result["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        #expect(lag["start"] == 0)
        #expect(lag["end"] == 2)
    }

    @Test("A keyboard at the window edge has stopped before its window detaches")
    func keyboardAtWindowEdge() throws {
        let frames: [(at: Int, keys: Double?, bottom: Double)] = [
            (110, 829.46, 797),
            (111, 830.17, 797.5),
            (112, 830.78, 798),
            (113, 831.29, 798.5),
            (114, 831.72, 799),
            (115, 832.08, 799.5),
            (116, 832.39, 799.5),
            (117, 832.64, 800),
            (118, 832.86, 800),
            (119, 833.04, 800),
            (120, 833.20, 800.5),
            (121, 833.33, 800.5),
            (122, 833.44, 800.5),
            (123, 834, 801),
            (125, nil, 801),
            (126, nil, 801),
        ]
        let result = summary(frames, grids: ["121x12", "121x34"], windowBottom: 834)
        let lag = try #require((result["keyboardLag"] as? [String: [String: Int]])?["terminal"])
        #expect(result["keyboardReference"] as? String == "key row")
        #expect(lag["end"] == 0)
        #expect(result["reversals"] as? Int == 0)
        #expect(result["snaps"] as? Int == 0)
        #expect(result["regrids"] as? Int == 1)
    }

    private func summary(_ frames: [(at: Int, keys: Double?, bottom: Double)], grids: [String], windowBottom: Double? = nil) -> [String: Any] {
        let keys = Dictionary(uniqueKeysWithValues: frames.enumerated().compactMap { index, frame in
            frame.keys.map { (index, $0) }
        })
        let bottom = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($0.offset, $0.element.bottom) })
        let dropped = zip(frames, frames.dropFirst()).reduce(0) { $0 + max(0, $1.1.at - $1.0.at - 1) }
        return MotionTraceSummary.make(
            tracks: ["key row": keys, "terminal bottom": bottom], frameAt: frames.map(\.at),
            grids: ["terminal": grids], dropped: dropped, keyboardTimings: [], windowBottom: windowBottom
        )
    }
}
