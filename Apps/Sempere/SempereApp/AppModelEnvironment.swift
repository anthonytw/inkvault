import OSLog
import SwiftUI

/// `@Environment(AppModel.self)` that cannot trap: SwiftUI traps when a view
/// reads an Observable object no ancestor provides, and on Mac Catalyst a view
/// can be updated outside its window's environment (build 8 / Mac build 5
/// crashed at launch right after the vault opened: "No Observable object of
/// type AppModel found"). The app has one model, so a view without one gets
/// it (`AppModel.current`) and the site is logged to find the view.
@MainActor
@propertyWrapper
struct AppModelEnvironment: DynamicProperty {
    @Environment(AppModel.self) private var injected: AppModel?
    private let site: StaticString
    private let line: UInt

    init(file: StaticString = #fileID, line: UInt = #line) {
        site = file
        self.line = line
    }

    var wrappedValue: AppModel {
        if let injected { return injected }
        guard let shared = AppModel.current else {
            preconditionFailure("No AppModel in the environment at \(site):\(line), and none created yet")
        }
        Self.log.fault("AppModel not in the environment at \(String(describing: self.site), privacy: .public):\(self.line); using the app's")
        return shared
    }

    private static let log = Logger(subsystem: "io.github.anthonytw.sempere", category: "environment")
}

extension AppModel {
    /// The app's model (`SempereApp.init`); nil in tests that build their own.
    @MainActor static var current: AppModel?
}
