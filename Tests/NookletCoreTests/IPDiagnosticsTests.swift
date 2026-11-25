import Foundation
import NookletCore

func checkIPDiagnostics() throws {
    try expectEqual(IPAddresses.normalizedPublic("  8.8.8.8\n"), "8.8.8.8")
    try expectEqual(IPAddresses.normalizedPublic("::ffff:8.8.8.8"), "8.8.8.8")
    for privateAddress in ["192.168.1.1", "100.80.0.1", "169.254.1.1", "fe80::1", "fd00::1", "masked.local", "2001:db8::1"] {
        try expectNil(IPAddresses.normalizedPublic(privateAddress))
    }
    try expectEqual(IPAddresses.webRTCMatch("2606:4700:4700:0:0:0:0:1111", with: ["2606:4700:4700::1111"]), .matches)
    try expectEqual(IPAddresses.webRTCMatch("8.8.8.8", with: ["1.1.1.1"]), .different)
    try expectEqual(IPAddresses.webRTCMatch("2606:4700:4700::1111", with: ["1.1.1.1"]), .unverified)

    try expectEqual(ConnectivityTarget(name: " Example ", address: "example.com")?.url.scheme, "https")
    try expectNil(ConnectivityTarget(name: "", address: "https://example.com"))
    try expectNil(ConnectivityTarget(name: "Example", address: "https://user:password@example.com"))
    try expectNil(ConnectivityTarget(name: "Example", address: "file:///tmp/test"))
}
