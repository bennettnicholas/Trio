import Foundation
import SwiftUI

enum Adjustments {
    enum Config {}

    enum Tab: String, Hashable, Identifiable, CaseIterable {
        case overrides
        case tempTargets

        var id: String { rawValue }

        var name: String {
            switch self {
            case .overrides:
                return String(localized: "Overrides", comment: "Selected Tab")
            case .tempTargets:
                return String(localized: "Temp Targets", comment: "Selected Tab")
            }
        }
    }
}

protocol AdjustmentsProvider: Provider {}

/// Lets a tapped notification open the Adjustments tab on a chosen page. Used by the exercise
/// reminder: Temp Target (or a plain tap) opens temp targets, Override opens overrides.
/// The request waits here until the views are on screen, so it also works when the tap
/// launches Trio. Each view remembers the last request it handled, so neither depends on
/// the order SwiftUI updates them in. Only touch it on the main thread (views, or a
/// `Task { @MainActor in }`); it isn't marked `@MainActor` because Trio's views aren't.
@Observable final class AdjustmentsNavigationRequest {
    static let shared = AdjustmentsNavigationRequest()

    private(set) var tab: Adjustments.Tab = .tempTargets
    /// Goes up by one for every request
    private(set) var requestID = 0
    var handledByHome = 0
    var handledByAdjustments = 0

    func open(_ tab: Adjustments.Tab) {
        self.tab = tab
        requestID += 1
    }

    private init() {}
}
