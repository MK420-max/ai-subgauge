import ServiceManagement

/// SMAppService binds mainApp to the running application bundle, including its installed path.
struct LoginItemService {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void

    static let main = LoginItemService(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() })

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try register() }
        else { try unregister() }
    }
}
