//
//  Hobbs_Time_ExtractorApp.swift
//  Hobbs Time Extractor
//
//  Updated by Jonathan Anderson on 5/15/26.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

// Required on iPhone (iOS 16+) for portrait-upside-down to be honoured at runtime.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        [.portrait, .portraitUpsideDown]
    }
}
#endif

// MARK: - FontSizeManager

final class FontSizeManager: ObservableObject {
    private static let scales: [CGFloat] = [0.75, 0.85, 1.0, 1.2, 1.4, 1.6]
    private static let defaultIndex = 2  // 1.0 = normal

    @AppStorage("fontSizeIndex") private var index: Int = defaultIndex

    var scale: CGFloat { Self.scales[index] }
    var canIncrease: Bool { index < Self.scales.count - 1 }
    var canDecrease: Bool { index > 0 }
    var isDefault: Bool { index == Self.defaultIndex }

    func increase() { if canIncrease { index += 1 } }
    func decrease() { if canDecrease { index -= 1 } }
    func reset()    { index = Self.defaultIndex }
}

// MARK: - App

@main
struct Hobbs_Time_ExtractorApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @StateObject private var fontSizeManager = FontSizeManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 380, minHeight: 260)
#if os(macOS)
                .environment(\.fontScale, fontSizeManager.scale)
#endif
        }
#if os(macOS)
        .commands {
            CommandMenu("View") {
                Button("Make Text Bigger") { fontSizeManager.increase() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!fontSizeManager.canIncrease)
                Button("Make Text Smaller") { fontSizeManager.decrease() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!fontSizeManager.canDecrease)
                Button("Default Text Size") { fontSizeManager.reset() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(fontSizeManager.isDefault)
            }
        }
#endif
    }
}
