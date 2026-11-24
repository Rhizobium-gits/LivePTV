import Foundation
import Testing
@testable import LivePTVUI

@Suite struct CameraPresetTests {
    @Test func normalisesMACFormats() {
        #expect(CameraPreset.normalizeMAC("02:11:2A:33:44:55") == "02:11:2a:33:44:55")
        #expect(CameraPreset.normalizeMAC("02-11-2a-33-44-55") == "02:11:2a:33:44:55")
        // 🐱 iOS can report BSSIDs without leading zeros.
        #expect(CameraPreset.normalizeMAC("02:11:2a:3:44:5") == "02:11:2a:03:44:05")
        #expect(CameraPreset.normalizeMAC("02:11:2a:33:44") == nil)
        #expect(CameraPreset.normalizeMAC("zz:11:2a:33:44:55") == nil)
    }

    @Test func loadsPlistFromBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["SSID": "Ace Pro 2 TEST.OSC", "Password": "secret", "MACAddress": "AA:BB:CC:DD:EE:0F", "Port": 6666]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Camera.local.plist"))
        let bundle = try #require(Bundle(url: dir))
        let preset = try #require(CameraPreset.load(from: bundle))
        #expect(preset.ssid == "Ace Pro 2 TEST.OSC" && preset.password == "secret")
        #expect(preset.macAddress == "aa:bb:cc:dd:ee:0f" && preset.port == 6666 && preset.host == nil)
    }

    @Test func missingPlistMeansNoPreset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preset-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try #require(Bundle(url: dir))
        #expect(CameraPreset.load(from: bundle) == nil)
    }
}
