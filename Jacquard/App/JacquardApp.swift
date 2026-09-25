import CoreText
import SwiftUI

@main
struct JacquardApp: App {
    init() {
        // The UI face ships as a file rather than through Info.plist, so it is registered
        // here before the first view asks for it.
        if let url = Bundle.main.url(forResource: "Jura-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
