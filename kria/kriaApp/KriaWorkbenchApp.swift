import AppKit
import SwiftUI

@main
struct KriaWorkbenchApp: App {
    var body: some Scene {
        WindowGroup("Kria 工作台") {
            WorkbenchView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
