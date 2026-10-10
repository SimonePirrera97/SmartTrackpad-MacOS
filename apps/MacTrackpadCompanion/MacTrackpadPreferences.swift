import Foundation

/// Read selected settings only; never modify the physical trackpad's preferences.
/// CFPreferences API: https://developer.apple.com/documentation/corefoundation/cfpreferencescopyvalue(_:_:_:_:)
/// Apple's preference keys are implementation details; omit absent/invalid keys.
enum MacTrackpadPreferences {
    static func snapshot() -> TrackpadPreferences? {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        func value(_ key: String, domain: CFString) -> Any? {
            CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
                ?? CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        func flag(_ key: String, domain: CFString) -> Bool? {
            guard let number = value(key, domain: domain) as? NSNumber,
                  number.doubleValue == 0 || number.doubleValue == 1 else { return nil }
            return number.boolValue
        }
        var snapshot = TrackpadPreferences()
        snapshot.tapToClick = flag("Clicking", domain: domain)
        snapshot.twoFingerSecondaryClick = flag("TrackpadRightClick", domain: domain)
        snapshot.threeFingerDrag = flag("TrackpadThreeFingerDrag", domain: domain)
        snapshot.naturalScroll = flag("com.apple.swipescrolldirection", domain: kCFPreferencesAnyApplication)
        return snapshot.valid ? snapshot : nil
    }
}
