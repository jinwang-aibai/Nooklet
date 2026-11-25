import Foundation
import NookletCore

func checkStatusPreferences() throws {
    let old = Data("""
    {"menu":["memory","thermal"],"island":["cpu"],"islandEnabled":true,"menuIconVisible":false}
    """.utf8)
    var preferences = try JSONDecoder().decode(DisplayPreferences.self, from: old)
    try expectEqual(preferences.menu, [.memory, .thermal, .gpu, .network, .processes])
    try expectEqual(preferences.island, [.cpu])
    try expect(preferences.islandEnabled)
    try expectFalse(preferences.menuIconVisible)
    try expectEqual(preferences.menuBarMetrics, [.network])
    try expectEqual(preferences.options(for: .network).fields, [.upload, .download])

    preferences.menu = []
    preferences.liveMenuEnabled = false
    preferences.liveMenu = [.disk, .cpu]
    preferences.liveOrder = [.disk, .disk, .processes, .cpu]
    var options = preferences.options(for: .disk)
    options.fields = [.write, .upload]
    options.arrangement = .vertical
    preferences.liveOptions[.disk] = options
    let restored = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(preferences))
    try expectEqual(restored, preferences)
    try expectEqual(restored.dashboardMetrics, [])
    try expectEqual(restored.menuBarMetrics, [.disk, .cpu])
    try expectEqual(restored.options(for: .disk).fields, [.write])

    preferences.resetMenuBar()
    try expectEqual(preferences.menuBarMetrics, [.network])
    try expectEqual(preferences.dashboardMetrics, [])
    try expectFalse(preferences.menuIconVisible)
}

func checkStatusTransferRates() throws {
    var sampler = TransferSampler<String>()
    try expectNil(sampler.sample(["en0": TransferCounters(100, 250)], time: 2))
    let first = sampler.sample(["en0": TransferCounters(2_100, 4_250), "en1": TransferCounters(50_000, 100_000)], time: 4)
    try expectEqual(first?.first, 1_000)
    try expectEqual(first?.second, 2_000)
    let reset = sampler.sample(["en1": TransferCounters(600, 102_000)], time: 5)
    try expectEqual(reset?.first, 0)
    try expectEqual(reset?.second, 2_000)
    try expectNil(sampler.sample(["en1": TransferCounters(650, 8_102_000)], time: 35))
    let resumed = sampler.sample(["en1": TransferCounters(750, 8_102_300)], time: 36)
    try expectEqual(resumed?.first, 100)
    try expectEqual(resumed?.second, 300)
}

func checkProcessReadings() throws {
    var sampler = ProcessSampler()
    let memory: (Int32) -> Int64? = { [84: 100, 101: 200, 102: 10, 103: 50][$0] }
    let readings = sampler.readings(from: """
         42 149:25.65  63.1 Tue Nov 17 00:12:05 2026 95000 WindowServer
         84   0:44.50 122.5 Tue Nov 17 00:15:01 2026  4000 Background Worker
        101   0:10.99   0.0 Tue Nov 17 00:13:37 2026     0 Idle Worker
        102   0:01.22   0.1 Tue Nov 17 00:14:01 2026     0 Light Worker
        103   0:03.00    -- Tue Nov 17 00:14:10 2026    -- Unavailable
        104   0:01.00  99.9 Tue Nov 17 00:15:10 2026     0 ps
        105   0:00.00   0.0 Tue Nov 17 00:14:01 2026     0 No Memory
        invalid
        """, time: 10, excluding: 104, memory: memory)
    try expectEqual(readings.byCPU.map(\.id), [84, 42, 102, 101, 105])
    try expectEqual(readings.byCPU.first?.name, "Background Worker")
    try expectEqual(readings.byCPU.first?.cpu, 1.225)
    try expectEqual(readings.byCPU[1].cpu, 0.631)
    try expectEqual(readings.byCPU[0].memory, 100)
    try expectFalse(readings.byCPU[0].memoryIsResident)
    try expectEqual(readings.byCPU[1].memory, 95_000 * 1024)
    try expect(readings.byCPU[1].memoryIsResident)
    try expectNil(readings.byCPU[4].memory)
    try expectEqual(readings.byMemory.map(\.id), [42, 101, 84, 103, 102])
    try expectNil(readings.byMemory[3].cpu)

    let next = sampler.readings(from: """
         42 149:26.70   1.0 Tue Nov 17 00:12:05 2026 95000 WindowServer
         84   0:46.00   0.0 Tue Nov 17 00:15:01 2026  4000 Background Worker
        101   0:10.99   3.2 Tue Nov 17 00:13:37 2026     0 Idle Worker
        102   0:01.40   0.1 Tue Nov 17 00:14:13 2026     0 Reused PID
        """, time: 13, excluding: 104, memory: memory)
    try expectEqual(next.byCPU.map(\.id), [84, 42, 102, 101])
    try expectEqual(next.byCPU[0].cpu, 0.5)
    try expect(abs((next.byCPU[1].cpu ?? 0) - 0.35) < 0.0001)
    try expectEqual(next.byCPU[2].cpu, 0.001)
    try expectEqual(next.byCPU[3].cpu, 0)
}
