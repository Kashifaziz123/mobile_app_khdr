import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var downloadSaver: IOSDownloadSaver?
  private var downloadChannelConfigured = false

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

    configureDownloadChannelIfPossible()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func configureDownloadChannelIfPossible() {
    guard !downloadChannelConfigured else {
      return
    }
    downloadChannelConfigured = true
    // Use Flutter's plugin registrar rather than a FlutterViewController.
    // This is safe with the scene-based lifecycle used by this app.
    guard let registrar = self.registrar(forPlugin: "KhdrDownloadHandler") else {
      downloadChannelConfigured = false
      return
    }
    let downloadChannel = FlutterMethodChannel(
      name: "com.khdr/downloader",
      binaryMessenger: registrar.messenger()
    )
    downloadChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveDownloadedFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        let isImage = arguments["isImage"] as? Bool
      else {
        result(FlutterError(code: "invalid_arguments", message: "Missing download path.", details: nil))
        return
      }

      let saver = IOSDownloadSaver()
      self?.downloadSaver = saver
      saver.save(fileURL: URL(fileURLWithPath: path), isImage: isImage, result: result) { [weak self] in
        self?.downloadSaver = nil
      }
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

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
    } else {
      application.applicationIconBadgeNumber = 0
    }
  }
}

private final class IOSDownloadSaver: NSObject {
  private var result: FlutterResult?
  private var completion: (() -> Void)?
  private var temporaryFileURL: URL?

  func save(
    fileURL: URL,
    isImage: Bool,
    result: @escaping FlutterResult,
    completion: @escaping () -> Void
  ) {
    self.result = result
    self.completion = completion
    self.temporaryFileURL = fileURL

    DispatchQueue.main.async {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        self.finish(FlutterError(code: "missing_file", message: "The downloaded file is no longer available.", details: nil))
        return
      }
      // Odoo sometimes responds with application/octet-stream or an URL with
      // no image extension. Inspect the actual file so those images are not
      // skipped by the Dart filename/MIME heuristic.
      if isImage || UIImage(contentsOfFile: fileURL.path) != nil {
        self.saveImageToPhotos(fileURL)
      } else {
        self.finish("documents")
      }
    }
  }

  private func saveImageToPhotos(_ fileURL: URL) {
    if #available(iOS 14, *) {
      saveImageToPhotosAddOnly(fileURL)
    } else {
      saveImageToPhotosLegacy(fileURL)
    }
  }

  @available(iOS 14, *)
  private func saveImageToPhotosAddOnly(_ fileURL: URL) {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    switch status {
    case .authorized, .limited:
      addImage(fileURL)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
        DispatchQueue.main.async {
          guard let self else { return }
          if newStatus == .authorized || newStatus == .limited {
            self.addImage(fileURL)
          } else {
            self.finish(FlutterError(code: "photos_permission_denied", message: "Allow Photos access to save downloaded images.", details: nil))
          }
        }
      }
    default:
      finish(FlutterError(code: "photos_permission_denied", message: "Allow Photos access to save downloaded images.", details: nil))
    }
  }

  private func saveImageToPhotosLegacy(_ fileURL: URL) {
    switch PHPhotoLibrary.authorizationStatus() {
    case .authorized:
      addImage(fileURL)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization { [weak self] newStatus in
        DispatchQueue.main.async {
          guard let self else { return }
          if newStatus == .authorized {
            self.addImage(fileURL)
          } else {
            self.finish(FlutterError(code: "photos_permission_denied", message: "Allow Photos access to save downloaded images.", details: nil))
          }
        }
      }
    default:
      finish(FlutterError(code: "photos_permission_denied", message: "Allow Photos access to save downloaded images.", details: nil))
    }
  }

  private func addImage(_ fileURL: URL) {
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
    }) { [weak self] success, error in
      DispatchQueue.main.async {
        if success {
          self?.finish("photos")
        } else if let image = UIImage(contentsOfFile: fileURL.path) {
          // Some image encodings are not accepted by PhotoKit directly even
          // though UIKit can decode them. Re-encode through UIKit as a final
          // Photos-library fallback.
          self?.saveUIKitImageToPhotos(image)
        } else {
          self?.finish(FlutterError(code: "photos_save_failed", message: error?.localizedDescription ?? "iOS could not save this image to Photos.", details: nil))
        }
      }
    }
  }

  private func saveUIKitImageToPhotos(_ image: UIImage) {
    UIImageWriteToSavedPhotosAlbum(
      image,
      self,
      #selector(image(_:didFinishSavingWithError:contextInfo:)),
      nil
    )
  }

  @objc private func image(
    _ image: UIImage,
    didFinishSavingWithError error: Error?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    if let error {
      finish(FlutterError(code: "photos_save_failed", message: error.localizedDescription, details: nil))
    } else {
      finish("photos")
    }
  }

  private func finish(_ value: Any?) {
    // Keep every completed download in the app Documents directory, which is
    // exposed in Files under On My iPhone > Alkhudor App.
    temporaryFileURL = nil
    let callback = result
    result = nil
    callback?(value)
    let done = completion
    completion = nil
    done?()
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
