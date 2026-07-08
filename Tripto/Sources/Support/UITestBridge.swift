#if DEBUG
import Foundation

/// M3 verify-drill only: writes small facts (server-generated tokens, ids)
/// to a JSON file in the app's own Documents directory so the host machine
/// driving the simulator — no GUI tap automation available in this
/// environment, see `WelcomeView`/`HomeView`'s `-uitest…` autopilot doc
/// comments — can read back values it has no other way to observe, via
/// `xcrun simctl get_app_container <device> io.navbytes.tripto data`.
/// Never compiled into a release build; harmless if the file is never read
/// (it isn't wired into any user-facing flow).
enum UITestBridge {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uitest-bridge.json")
    }

    static func write(_ facts: [String: String]) {
        var merged = read()
        for (key, value) in facts { merged[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func read() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }
}
#endif
