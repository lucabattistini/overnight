import AppKit

let application = NSApplication.shared
let overnightDelegate = AppDelegate()
application.delegate = overnightDelegate
application.setActivationPolicy(.accessory)
application.run()
