/*
 * Copyright (c) 2005-2018, BearWare.dk
 * 
 * Contact Information:
 *
 * Bjoern D. Rasmussen
 * Kirketoften 5
 * DK-8260 Viby J
 * Denmark
 * Email: contact@bearware.dk
 * Phone: +45 20 20 54 59
 * Web: http://www.bearware.dk
 *
 * This source code is part of the TeamTalk SDK owned by
 * BearWare.dk. Use of this file, or its compiled unit, requires a
 * TeamTalk SDK License Key issued by BearWare.dk.
 *
 * The TeamTalk SDK License Agreement along with its Terms and
 * Conditions are outlined in the file License.txt included with the
 * TeamTalk SDK distribution.
 *
 */

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    let backgroundQueue = DispatchQueue.global(qos: DispatchQoS.QoSClass.background)
    var backgroundRunning: Bool = false
    var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var didCheckSoundPackUpdates = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        
        TT_SetLicenseInformation(REGISTRATION_NAME, REGISTRATION_KEY)
        
        // Default values are not set in Settings bundle, so we need to load them manually
        let defaults = UserDefaults.standard
        defaults.synchronize()
        
        var bundleDefaults = [String : AnyObject]()
        
        if let settingsBundle = Bundle.main.path(forResource: "Settings", ofType: "bundle") {
            
            let path = (settingsBundle as NSString).appendingPathComponent("Root.plist")
            let settings = NSDictionary(contentsOfFile: path)
            let preferences = settings!.object(forKey: "PreferenceSpecifiers") as! NSArray

            for prefSpecification in preferences {
                if let key = (prefSpecification as AnyObject).object(forKey: "Key") {
                    if defaults.object(forKey: key as! String) == nil {
                        let defValue = (prefSpecification as AnyObject).object(forKey: "DefaultValue")
                        bundleDefaults[key as! String] = defValue as AnyObject?
//                        println("Pref: " + (key as! String) + "=" + defValue)
                    }
                }
            }
            
        }

        if !bundleDefaults.isEmpty {
            defaults.register(defaults: bundleDefaults)
            defaults.synchronize()
        }

        ICloudSync.shared.startIfEnabled()

        saveControlCenterServers(loadLocalServers())
        observeControlCenterRequests()

        MonitorNotifications.shared.openHandler = { [weak self] ref, serverID, chat in
            self?.showMonitors(window: nil)?.show(ref: ref, serverID: serverID, chat: chat)
        }
        MonitorNotifications.shared.configure()
        MonitorCenter.shared.reload()
        MonitorCenter.shared.unmuteLeftoverLiveServers()
        MonitorCenter.shared.giveMonitorsGender()
        MonitorNotificationSounds.refresh()
        
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MonitorNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    /// Open the Monitors screen over the server list.
    @discardableResult
    func showMonitors(window: UIWindow?) -> MonitorListViewController? {
        let window = window ?? self.window ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }.first
        guard let nav = window?.rootViewController as? UINavigationController else { return nil }
        if let list = nav.viewControllers.first(where: { $0 is MonitorListViewController }) as? MonitorListViewController {
            return list
        }
        (nav.topViewController as? MainTabBarController)?.prepareForSessionSwitch()
        nav.popToRootViewController(animated: false)
        let list = MonitorListViewController()
        nav.pushViewController(list, animated: false)
        return list
    }

    func application(_ app: UIApplication,
                     open url: URL,
                     options opt: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        openUrl(url, window: window)
        return true
    }

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return continueUserActivity(userActivity, window: window)
    }

    func cleanupTemporaryDirectory(excluding excludedURLs: [URL] = []) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let excludedPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })

        do {
            let temporaryItems = try fileManager.contentsOfDirectory(at: temporaryDirectory,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: [])
            for item in temporaryItems {
                if excludedPaths.contains(item.standardizedFileURL.path) {
                    continue
                }
                try? fileManager.removeItem(at: item)
            }
        } catch {
            print("Failed to clean temporary directory")
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        startBackgroundTaskIfNeeded()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        stopBackgroundTaskLoop()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        connectPendingControlCenterServer(window: window)
        checkSoundPackUpdates(window: window)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(CONTROL_CENTER_PENDING_SERVER_NOTIFICATION as CFString),
            nil
        )
        ConnectedServerManager.shared.disconnectAll()
    }

    private func observeControlCenterRequests() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    guard UIApplication.shared.applicationState == .active else { return }
                    appDelegate.connectPendingControlCenterServer(window: appDelegate.window)
                }
            },
            CONTROL_CENTER_PENDING_SERVER_NOTIFICATION as CFString,
            nil,
            .deliverImmediately
        )
    }

    func openUrl(_ url: URL, window: UIWindow?) {
        let urlStr = url.absoluteString
//        print ("URL: " + url.absoluteString)
        if let serverName = ControlCenterConnectURL.serverName(from: url) {
            _ = connectToSavedServer(named: serverName, window: window)
        }

        else if urlStr.starts(with: AppInfo.TTLINK_PREFIX) || url.isFileURL {
            guard let nav = window?.rootViewController as? UINavigationController else { return }
            (nav.topViewController as? MainTabBarController)?.prepareForSessionSwitch()
            nav.popToRootViewController(animated: true)
            guard let svc = nav.viewControllers.first as? ServerListViewController else { return }
            svc.openUrl(url)
        }
    }

    func continueUserActivity(_ userActivity: NSUserActivity, window: UIWindow?) -> Bool {
        guard userActivity.activityType == SiriShortcutSupport.connectServerActivityType,
              let serverName = userActivity.userInfo?[SiriShortcutSupport.serverNameUserInfoKey] as? String else {
            return false
        }

        return connectToSavedServer(named: serverName, window: window)
    }

    func connectToSavedServer(named serverName: String, window: UIWindow?) -> Bool {
        guard let nav = window?.rootViewController as? UINavigationController else {
            return false
        }

        (nav.topViewController as? MainTabBarController)?.prepareForSessionSwitch()
        nav.popToRootViewController(animated: false)
        guard let serverList = nav.viewControllers.first as? ServerListViewController else {
            return false
        }

        return serverList.connectToSavedServer(named: serverName)
    }

    func connectPendingControlCenterServer(window: UIWindow?) {
        guard let serverName = ControlCenterServerStore.consumePendingServerName(),
              serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        _ = connectToSavedServer(named: serverName, window: window)
    }

    func checkSoundPackUpdates(window: UIWindow?) {
        guard didCheckSoundPackUpdates == false else {
            return
        }
        didCheckSoundPackUpdates = true

        SoundPackStore.shared.fetchCatalog { result in
            guard case .success(let catalogPacks) = result else {
                return
            }

            let updates = SoundPackStore.shared.updatesAvailable(in: catalogPacks)
            guard updates.isEmpty == false else {
                return
            }

            self.showSoundPackUpdatesAlert(updates: updates, window: window)
        }
    }

    private func showSoundPackUpdatesAlert(updates: [RemoteSoundPack], window: UIWindow?) {
        guard let presenter = topViewController(from: window?.rootViewController) else {
            return
        }

        let alert = UIAlertController(title: NSLocalizedString("Sound Pack Updates Available", comment: "sound pack"),
                                      message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Later", comment: "sound pack"), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("View", comment: "sound pack"), style: .default) { _ in
            let updatesViewController = SoundPackUpdatesViewController(packs: updates)
            if let navigationController = presenter as? UINavigationController {
                navigationController.pushViewController(updatesViewController, animated: true)
            }
            else if let navigationController = presenter.navigationController {
                navigationController.pushViewController(updatesViewController, animated: true)
            }
        })
        presenter.present(alert, animated: true)
    }

    private func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigationController = viewController as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController) ?? navigationController
        }
        if let tabBarController = viewController as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController) ?? tabBarController
        }
        if let presentedViewController = viewController?.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        return viewController
    }

    func startBackgroundTaskIfNeeded() {
        let hasConnectedSession = ConnectedServerManager.shared.sessions.contains { controller in
            guard let instance = controller.teamTalkInstance else { return false }
            return TT_GetFlags(instance) & CLIENT_CONNECTED.rawValue != 0
        }
        if hasConnectedSession {
            backgroundRunning = true
            backgroundQueue.async(execute: testBackgroundTask)
        }
    }

    func stopBackgroundTaskLoop() {
        backgroundRunning = false
    }

    func testBackgroundTask() {
        if (backgroundRunning) {
            endBackgroundTask()
            Thread.sleep(forTimeInterval: 5)
            backgroundQueue.async(execute: testBackgroundTask)
            registerBackgroundTask()
        }
    }
    
    func registerBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask (expirationHandler: {
            [unowned self] in
            self.endBackgroundTask()
        })
        assert(backgroundTask != UIBackgroundTaskIdentifier.invalid)
    }
    
    func endBackgroundTask() {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = UIBackgroundTaskIdentifier.invalid
    }
}
