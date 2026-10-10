import Foundation

/// Optional, read-only preference snapshot. Missing values leave client choices intact.
struct TrackpadPreferences: Codable, Sendable, Equatable {
    var version = 1
    var tapToClick: Bool?
    var twoFingerSecondaryClick: Bool?
    var threeFingerDrag: Bool?
    var naturalScroll: Bool?
    var valid: Bool {
        version == 1 && (tapToClick != nil || twoFingerSecondaryClick != nil || threeFingerDrag != nil || naturalScroll != nil)
    }
}
