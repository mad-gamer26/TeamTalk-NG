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

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private var appDelegate: AppDelegate? {
        UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let url = connectionOptions.urlContexts.first?.url {
            DispatchQueue.main.async {
                self.open(url, in: scene)
                self.appDelegate?.cleanupTemporaryDirectory(excluding: [url])
            }
        } else if let userActivity = connectionOptions.userActivities.first {
            DispatchQueue.main.async {
                _ = self.appDelegate?.continueUserActivity(userActivity, window: self.resolvedWindow(for: scene))
                self.appDelegate?.cleanupTemporaryDirectory()
            }
        } else {
            DispatchQueue.main.async {
                self.appDelegate?.cleanupTemporaryDirectory()
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        open(url, in: scene)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = appDelegate?.continueUserActivity(userActivity, window: resolvedWindow(for: scene))
    }

    func sceneWillResignActive(_ scene: UIScene) {
        appDelegate?.startBackgroundTaskIfNeeded()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        appDelegate?.stopBackgroundTaskLoop()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        let window = resolvedWindow(for: scene)
        appDelegate?.connectPendingControlCenterServer(window: window)
        appDelegate?.checkSoundPackUpdates(window: window)
    }

    private func open(_ url: URL, in scene: UIScene) {
        appDelegate?.openUrl(url, window: resolvedWindow(for: scene))
    }

    private func resolvedWindow(for scene: UIScene) -> UIWindow? {
        if let window = window {
            return window
        }

        guard let windowScene = scene as? UIWindowScene else {
            return nil
        }

        return windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
    }
}
