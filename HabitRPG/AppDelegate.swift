//
//  AppDelegate.swift
//  Habitica
//
//  Created by Phillip on 11.08.17.
//  Copyright © 2017 HabitRPG Inc. All rights reserved.
//

import UIKit
import Amplitude
import Habitica_API_Client
import Habitica_Models
import RealmSwift
import ReactiveSwift
import Firebase
#if !targetEnvironment(macCatalyst)
import FirebaseAnalytics
#endif
import SwiftyStoreKit
import StoreKit
import UserNotifications
import FirebaseMessaging
import Down
import WidgetKit
import AppAuth
import AdServices
import iAd

class HabiticaAppDelegate: UIResponder, MessagingDelegate, UIApplicationDelegate {
    var window: UIWindow?
    var currentAuthorizationFlow: OIDExternalUserAgentSession?
    var isBeingTested = false
        
    var application: UIApplication?
    
    private let userRepository = UserRepository()
    private let contentRepository = ContentRepository()
    let taskRepository = TaskRepository()
    private let socialRepository = SocialRepository()
    internal let configRepository = ConfigRepository.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Measurements.start(identifier: "didFinishLaunchingWithOptions")
        Measurements.start(identifier: "task list loaded")
        logger = RemoteLogger()
        self.application = application
        
        if !isBeingTested {
            setupLogging()
            setupAnalytics()
            setupPurchaseHandling()
            setupFirebase()
        }
        setupRouter()
        handleLaunchArgs()
        setupNetworkClient()
        setupDatabase()
        configureNotifications()
        
        if let userInfo = launchOptions?[UIApplication.LaunchOptionsKey.remoteNotification] as? [AnyHashable: Any] {
            handlePushnotification(identifier: nil, userInfo: userInfo)
        }
        
        handleInitialLaunch()
        applySearchAdAttribution()
        Measurements.stop(identifier: "didFinishLaunchingWithOptions")
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if currentAuthorizationFlow?.resumeExternalUserAgentFlow(with: url) == true {
            currentAuthorizationFlow = nil
            return true
        }
        return RouterHandler.shared.handle(url: url)
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { context in
            RouterHandler.shared.handle(url: context.url)
        }
    }

    func handleLaunchArgs() {
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
            isBeingTested = true
            contentRepository.retrieveContent(force: true).observeCompleted {
            }
            UIView.setAnimationsEnabled(false)
            self.window?.layer.speed = 100
            AuthenticationManager.shared.initialize(withStorage: MemoryAuthenticationStorage())
        } else {
            AuthenticationManager.shared.initialize(withStorage: KeychainAuthenticationStorage())
        }
        let launchEnvironment = ProcessInfo.processInfo.environment
        if let userID = launchEnvironment["userid"] {
            AuthenticationManager.shared.currentUserId = userID
        }
        if let apiKey = launchEnvironment["apikey"] {
            AuthenticationManager.shared.currentUserKey = apiKey
        }
        
        if let stubs = launchEnvironment["STUB_DATA"]?.data(using: .utf8) {
            // swiftlint:disable:next force_try
            HabiticaServerConfig.stubs = try! JSONDecoder().decode([String: CallStub].self, from: stubs)
        }
        if let url = launchEnvironment["OPEN_URL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
                RouterHandler.shared.handle(urlString: url)
            })
        }
    }
    
    func setupFirebase() {
        Messaging.messaging().delegate = self
        
        let userDefaults = UserDefaults.standard
        #if !targetEnvironment(macCatalyst)
        Crashlytics.crashlytics().setCustomValue(-(NSTimeZone.local.secondsFromGMT() / 60), forKey: "timezone_offset")
        Crashlytics.crashlytics().setCustomValue(LanguageHandler.getAppLanguage().code, forKey: "app_language")
        Analytics.setUserProperty(LanguageHandler.getAppLanguage().code, forName: "app_language")
        Analytics.setUserProperty(configRepository.testingLevel.rawValue.lowercased(), forName: "app_testing_level")
        Analytics.setUserProperty(UIApplication.shared.alternateIconName, forName: "app_icon")
        Analytics.setUserProperty(userDefaults.string(forKey: "initialScreenURL"), forName: "launch_screen")
        #endif
    }
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken {
            print("Received FCM Token: \(token)")
        }
    }
    
    func saveDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "PushNotificationDeviceToken")
    }
    
    func setupLogging() {
        let userID = AuthenticationManager.shared.currentUserId
        FirebaseApp.configure()
        (logger as? RemoteLogger)?.setUserID(userID)
        logger.isProduction = HabiticaAppDelegate.isRunningLive()
    }
    
    func setupAnalytics() {
        Amplitude.instance().initializeApiKey(Secrets.amplitudeApiKey)
        Amplitude.instance().setUserId(AuthenticationManager.shared.currentUserId)
        let userDefaults = UserDefaults.standard
        Amplitude.instance().setUserProperties(["iosTimezoneOffset": -(NSTimeZone.local.secondsFromGMT() / 60),
                                                 "launch_screen": userDefaults.string(forKey: "initialScreenURL") ?? ""
        ])
    }
    
    func setupPurchaseHandling() {
        #if !targetEnvironment(simulator)
        PurchaseHandler.shared.completionHandler()
        #endif
    }
    
    func setupNetworkClient() {
        NetworkAuthenticationManager.shared.currentUserId = AuthenticationManager.shared.currentUserId
        NetworkAuthenticationManager.shared.currentUserKey = AuthenticationManager.shared.currentUserKey
        updateServer()
        AuthenticatedCall.errorHandler = HabiticaNetworkErrorHandler()
        AuthenticatedCall.notificationListener = {[weak self] notifications in
            guard let notifications = notifications else {
                return
            }
            let unshownNotifications = NotificationManager.handle(notifications: notifications)
            self?.userRepository.saveNotifications(unshownNotifications)
        }
        let configuration = URLSessionConfiguration.default
        AuthenticatedCall.defaultConfiguration.urlConfiguration = configuration
        
        let userDefaults = UserDefaults.standard
        for (key, etag) in userDefaults.dictionaryRepresentation().filter({ (key, _) -> Bool in
            return key.starts(with: "etag")
        }) {
            HabiticaServerConfig.etags[String(key.dropFirst(4))] = etag as? String
        }
    }
    
    func updateServer() {
        if isBeingTested {
            AuthenticatedCall.defaultConfiguration = HabiticaServerConfig.stub
            return
        }
        if let host = ProcessInfo.processInfo.environment["CUSTOM_DOMAIN"], let apiVersion = configRepository.string(variable: .apiVersion) {
            let config = ServerConfiguration(scheme: "https", host: host, apiRoute: "api/\(apiVersion.isEmpty ? "v3" : apiVersion)")
            AuthenticatedCall.defaultConfiguration = config
            return
        }
        if let chosenServer = UserDefaults().string(forKey: "chosenServer") {
            if chosenServer == "production" {
                let configRepository = ConfigRepository.shared
                if let host = configRepository.string(variable: .prodHost), let apiVersion = configRepository.string(variable: .apiVersion) {
                    let config = ServerConfiguration(scheme: "https", host: host, apiRoute: "api/\(apiVersion.isEmpty ? "v3" : apiVersion)")
                    AuthenticatedCall.defaultConfiguration = config
                } else {
                    AuthenticatedCall.defaultConfiguration = HabiticaServerConfig.production
                }
            } else {
                AuthenticatedCall.defaultConfiguration = HabiticaServerConfig.from(chosenServer)
            }
        } else {
            let configRepository = ConfigRepository.shared
            if let host = configRepository.string(variable: .prodHost), let apiVersion = configRepository.string(variable: .apiVersion), !host.isEmpty, !apiVersion.isEmpty {
                let config = ServerConfiguration(scheme: "https", host: host, apiRoute: "api/\(apiVersion)")
                AuthenticatedCall.defaultConfiguration = config
            } else {
                AuthenticatedCall.defaultConfiguration = HabiticaServerConfig.production
            }
        }
    }
    
    func setupDatabase() {
        var config = Realm.Configuration.defaultConfiguration
        config.deleteRealmIfMigrationNeeded = true
        if isBeingTested {
            // when running tests use a fresh in-memory database on each launch
            config.inMemoryIdentifier = String(Date().timeIntervalSince1970)
        } else {
            let fileUrl = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.habitrpg.habitica")?
                .appendingPathComponent("habitica.realm")
            if let url = fileUrl {
                config.fileURL = url
            }
            logger.log("Realm stored at: \(config.fileURL?.absoluteString ?? "")")
        }
        Realm.Configuration.defaultConfiguration = config
    }
    
    func setupRouter() {
        RouterHandler.shared.register()
    }
    
    func handleInitialLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "wasLaunchedBefore") {
            defaults.set(true, forKey: "wasLaunchedBefore")
            
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = 19
            components.minute = 0
            let newDate = Calendar.current.date(from: components)
            
            defaults.set(true, forKey: "dailyReminderActive")
            defaults.set(newDate, forKey: "dailyReminderTime")
            defaults.set(true, forKey: "appBadgeActive")
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            
            rescheduleDailyReminder()
        }
    }
    
    func retrieveTasks(_ completed: @escaping ((Bool) -> Void)) {
        taskRepository.retrieveTasks().observeResult { (result) in
            switch result {
            case .success:
                completed(true)
            case .failure:
                completed(false)
            }
        }
    }
    
    func scoreTask(_ taskId: String, direction: TaskScoringDirection, completed: @escaping (() -> Void)) {
        if let task = taskRepository.getEditableTask(id: taskId) {
            taskRepository.score(task: task, direction: direction).observeCompleted {
                completed()
            }
        } else {
            completed()
        }
    }
    
    func acceptQuestInvitation(_ completed: @escaping ((Bool) -> Void)) {
        userRepository.getUser().take(first: 1)
            .map({ (user) -> String? in
                return user.party?.id
            })
            .skipNil()
            .flatMap(.latest) {[weak self] (partyID) in
                return self?.socialRepository.acceptQuestInvitation(groupID: partyID) ?? Signal.empty
            }.on(failed: { _ in
                completed(false)
            }, value: { _ in
                completed(true)
            }).start()
    }
    
    func rejectQuestInvitation(_ completed: @escaping ((Bool) -> Void)) {
        userRepository.getUser().take(first: 1)
            .map({ (user) -> String? in
                return user.party?.id
            })
            .skipNil()
            .flatMap(.latest) {[weak self] (partyID) in
                return self?.socialRepository.rejectQuestInvitation(groupID: partyID) ?? Signal.empty
            }.on(failed: { _ in
                completed(false)
            }, value: { _ in
                completed(true)
            }).start()
    }
    
    func sendPrivateMessage(toUserID: String, message: String, completed: @escaping ((Bool) -> Void)) {
        socialRepository.post(inboxMessage: message, toUserID: toUserID).observeResult({ (result) in
            switch result {
            case .success:
                completed(true)
            case .failure:
                completed(false)
            }
        })
    }
    
    func displayNotificationInApp(text: String) {
        ToastManager.show(text: text, color: .purple)
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
    }
    
    func displayNotificationInApp(title: String, text: String) {
        ToastManager.show(text: "\(title)\n\(text)", color: .purple)
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
    }
    
    static func isRunningLive() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let isRunningTestFlightBeta  = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        let hasEmbeddedMobileProvision = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        if isRunningTestFlightBeta || hasEmbeddedMobileProvision {
            return false
        } else {
            return true
        }
        #endif
    }
    
    func applySearchAdAttribution() {
        if UserDefaults.standard.bool(forKey: "userWasAttributed") {
            return
        }
        DispatchQueue.global(qos: .background).async {
            do {
            let attributionToken = try AAAttribution.attributionToken()
            if let url = URL(string: "https://api-adservices.apple.com/api/v1/") {
                let request = NSMutableURLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(attributionToken.utf8)
                let task = URLSession.shared.dataTask(with: request as URLRequest) { [weak self] (data, _, error) in
                    if let error = error {
                        logger.log(error)
                        return
                    }
                    guard let data = data else {
                        return
                    }

                    do {
                        guard let data = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                            return
                        }

                        self?.handleCampaign(data)
                    } catch {
                        if (error as NSError).code == 3840 {
                            UserDefaults.standard.set(true, forKey: "userWasAttributed")
                            return
                        }
                        logger.log(error)
                    }
                }
                task.resume()
            }
            } catch {
                // pass
            }
        }
    }
    
    private func handleCampaign(_ data: [String: Any]) {
        guard let campaignId = data["campaignId"] as? Int else {
            return
        }

        var analyticsData = [String: Any]()
        analyticsData["attribution"] = data["iad-attribution"]
        analyticsData["campaignID"] = campaignId
        analyticsData["campaignName"] = data["iad-campaign-name"]
        analyticsData["purchaseDate"] = data["iad-purchase-date"]
        analyticsData["conversionDate"] = data["iad-conversion-date"]
        analyticsData["conversionType"] = data["iad-conversion-type"]
        analyticsData["clickDate"] = data["iad-click-date"]
        analyticsData["keyword"] = data["iad-keyword"]
        analyticsData["keywordMatchtype"] = data["iad-keyword-matchtype"]

        UserDefaults.standard.set(true, forKey: "userWasAttributed")
        Amplitude.instance().setUserProperties([
            "clickedSearchAd": data["iad-attribution"] ?? "",
            "searchAdName": data["iad-campaign-name"] ?? "",
            "searchAdConversionDate": data["iad-conversion-date"] ?? ""
        ])
    }
    
    static func isRunningScreenshots() -> Bool {
        #if !targetEnvironment(simulator)
        return false
        #else
        return UserDefaults.standard.bool(forKey: "FASTLANE_SNAPSHOT")
        #endif
    }
    
    func messaging(_ messaging: MessagingDelegate, didReceiveRegistrationToken fcmToken: String) {
        logger.log("Firebase registration token: \(fcmToken)")
        let dataDict: [String: String] = ["token": fcmToken]
        NotificationCenter.default.post(name: Notification.Name("FCMToken"), object: nil, userInfo: dataDict)
    }
    
    func displayInAppNotification(taskID: String, text: String) {
        let alertController = HabiticaAlertController(title: text)
        alertController.addAction(title: L10n.complete, style: .default, isMainAction: true, closeOnTap: true, identifier: nil) {[weak self] _ in
            self?.scoreTask(taskID, direction: .up) {}
        }
        alertController.addCloseAction()
        alertController.enqueue()
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.warning)
    }
}

