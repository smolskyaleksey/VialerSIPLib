//
//  AppDelegate.swift
//  Copyright © 2016 Devhouse Spindle. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    struct Configuration {
        struct Notifications {
            static let IncomingCall = "AppDelegate.Notifications.IncomingCall"
        }

    }

    var window: UIWindow?

    // MARK: - Lifecycle

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        DDLogWrapper.setup()
        setupVialerEndpoint()
        return true
    }

    fileprivate func setupVialerEndpoint() {
        let endpointConfiguration = VSLEndpointConfiguration()
        endpointConfiguration.userAgent = "VialerSIPLib Example App"
        let tcp = VSLTransportConfiguration(transportType: .TCP)!
        tcp.port = 5061
        let udp = VSLTransportConfiguration(transportType: .UDP)!
        udp.port = 5061
        let tls = VSLTransportConfiguration(transportType: .TLS)!
        tls.port = 5062
        endpointConfiguration.transportConfigurations = [tcp, udp, tls]
        endpointConfiguration.srtpOption = .mandatory

        do {
            try VialerSIPLib.sharedInstance().configureLibrary(withEndPointConfiguration: endpointConfiguration)
            VialerSIPLib.sharedInstance().setIncomingCall{ (call) in
                NotificationCenter.default.post(name: Notification.Name(rawValue: Configuration.Notifications.IncomingCall), object: call)
            }
        } catch let error {
            DDLogWrapper.logError("Error setting up VialerSIPLib: \(error)")
        }
    }
}
