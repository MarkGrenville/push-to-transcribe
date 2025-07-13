import Cocoa
import Foundation

// Create and configure the NSApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Run as background app

// Create and set the app delegate
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
app.run() 