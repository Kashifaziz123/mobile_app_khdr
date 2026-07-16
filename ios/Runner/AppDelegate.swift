import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documentPickerResult: FlutterResult?
  private var documentPicker: UIDocumentPickerViewController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    // Set Firebase Messaging delegate so APNs token is bridged to FCM token
    Messaging.messaging().delegate = self

    // Set notification center delegate for foreground handling
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self

      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { granted, error in
          if granted {
            DispatchQueue.main.async {
              application.registerForRemoteNotifications()
            }
          }
        }
      )
    } else {
      let settings: UIUserNotificationSettings =
        UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
      application.registerUserNotificationSettings(settings)
      application.registerForRemoteNotifications()
    }

    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.khdr/downloader",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "APP_DELEGATE_UNAVAILABLE", message: nil, details: nil))
          return
        }
        switch call.method {
        case "exportFile":
          guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
            result(FlutterError(code: "INVALID_PATH", message: "A file path is required.", details: nil))
            return
          }
          self.exportFile(at: path, result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func exportFile(at path: String, result: @escaping FlutterResult) {
    guard documentPickerResult == nil else {
      result(FlutterError(code: "EXPORT_IN_PROGRESS", message: "Another file is being exported.", details: nil))
      return
    }

    let fileURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "The downloaded file no longer exists.", details: nil))
      return
    }

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(url: fileURL, in: .exportToService)
    }
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    documentPicker = picker
    documentPickerResult = result

    guard let root = activeRootViewController() else {
      finishDocumentExport(error: FlutterError(code: "NO_VIEW_CONTROLLER", message: nil, details: nil))
      return
    }
    root.present(picker, animated: true)
  }

  private func activeRootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
    guard let root = window?.rootViewController else { return nil }
    var current = root
    while let presented = current.presentedViewController {
      current = presented
    }
    return current
  }

  private func finishDocumentExport(error: FlutterError? = nil) {
    let result = documentPickerResult
    documentPickerResult = nil
    documentPicker = nil
    if let error = error {
      result?(error)
    } else {
      result?(true)
    }
  }

  // Bridge APNs device token to Firebase so it can map to an FCM token
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("Failed to register for remote notifications: \(error)")
  }
}

extension AppDelegate: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishDocumentExport()
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishDocumentExport()
  }
}

// MARK: - MessagingDelegate
extension AppDelegate: MessagingDelegate {
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    let dataDict: [String: String] = ["token": fcmToken ?? ""]
    NotificationCenter.default.post(
      name: Notification.Name("FCMToken"),
      object: nil,
      userInfo: dataDict
    )
  }
}

// MARK: - UNUserNotificationCenterDelegate
@available(iOS 10, *)
extension AppDelegate {
  // Show notification banner/sound/badge when app is in foreground
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.alert, .sound, .badge])
  }

  // Handle notification tap
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}

// MARK: - Badge clearing
extension AppDelegate {
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
    } else {
      application.applicationIconBadgeNumber = 0
    }
  }
}
