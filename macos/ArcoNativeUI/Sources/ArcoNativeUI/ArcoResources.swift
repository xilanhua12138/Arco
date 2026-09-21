import Foundation

/// SwiftPM looks beside the executable; packaged macOS apps store resources in Contents/Resources.
enum ArcoResources {
    static let bundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return packagedBundle(in: Bundle.main)
        }
        return Bundle.module
    }()

    static func packagedBundle(in application: Bundle) -> Bundle? {
        application.resourceURL
            .map { $0.appendingPathComponent("ArcoNativeUI_ArcoNativeUI.bundle") }
            .flatMap { Bundle(url: $0) }
    }
}

/// Exercises the installed app's resources and the same renderer used when joining a meeting.
@_spi(Packaging) @MainActor
public func arcoResourceSelfTest() -> Bool {
    let renderer = LiveKitAuraView.Renderer()
    guard let bundle = ArcoResources.bundle else {
        print("Resource check failed: packaged resource bundle is missing (renderer safely skipped)")
        return false
    }
    for (name, ext, directory) in [("LiveKitAura.metal", "txt", "Aura"), ("Syne", "ttf", "Fonts"), ("feishu-before", "png", "MeetingAudioGuide"), ("feishu-during", "png", "MeetingAudioGuide"), ("feishu-menu", "png", "MeetingAudioGuide")] {
        guard bundle.url(forResource: name, withExtension: ext, subdirectory: directory) != nil else {
            print("Resource check failed: \(directory)/\(name).\(ext)")
            return false
        }
    }
    guard renderer.isReady else {
        print("Resource check failed: Aura Metal pipeline did not initialize")
        return false
    }
    print("Resource check passed: \(bundle.bundleURL.path); Aura Metal pipeline initialized")
    return true
}
