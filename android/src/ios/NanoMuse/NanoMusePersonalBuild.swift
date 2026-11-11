import Foundation

/// Capabilities of the separate app used for free-account installation.
/// nanoMuse Cloud does not depend on Apple's iCloud entitlement.
enum NanoMusePersonalBuild {
    #if NANOMUSE_PERSONAL
    static let supportsAppleCloud = false
    static let supportsExtensions = false
    #else
    static let supportsAppleCloud = true
    static let supportsExtensions = true
    #endif
}
