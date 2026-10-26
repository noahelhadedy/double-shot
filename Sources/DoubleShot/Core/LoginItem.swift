import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS registered it but wants the user's OK in System Settings > Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns a line to show the user when it didn't simply work, nil when it did.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.engine.error("Could not change the login item: \(error.localizedDescription, privacy: .public)")
            return "Couldn't change this. Move Double Shot to your Applications folder and try again."
        }
        return needsApproval ? "Waiting for your OK in System Settings." : nil
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
