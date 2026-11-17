import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemManager {
    private(set) var isEnabled: Bool = false
    var lastErrorMessage: String?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        lastErrorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            lastErrorMessage = error.localizedDescription
            refreshStatus()
        }
    }
}
