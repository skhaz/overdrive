import AppKit

enum AppleMusic {
    private nonisolated static let identifier = "com.apple.Music"

    static func block() {
        terminate()

        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == identifier else { return }

                Log.app.info("blocked apple music", metadata: ["pid": "\(app.processIdentifier)", "phase": "launch"])
                app.forceTerminate()
            }
        }

        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                terminate()
            }
        }
    }

    private static func terminate() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            Log.app.info("blocked apple music", metadata: ["pid": "\(app.processIdentifier)", "phase": "poll"])
            app.forceTerminate()
        }
    }
}
