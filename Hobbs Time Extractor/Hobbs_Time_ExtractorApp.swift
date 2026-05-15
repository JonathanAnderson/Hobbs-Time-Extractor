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

@main
struct Hobbs_Time_ExtractorApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 380, minHeight: 260)
        }
    }
}
