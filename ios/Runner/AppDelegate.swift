import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var downloadSaver: IOSDownloadSaver?
  private var downloadsFolderPicker: IOSDownloadsFolderPicker?
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
    guard !downloadChannelConfigured,
          let controller = flutterViewController()
    else {
      return
    }
    downloadChannelConfigured = true
    let downloadChannel = FlutterMethodChannel(
      name: "com.khdr/downloader",
      binaryMessenger: controller.binaryMessenger
    )
    downloadChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "configureDownloadFolder" {
        if IOSDownloadSaver.hasConfiguredDownloadsFolder {
          result(nil)
          return
        }
        let picker = IOSDownloadsFolderPicker()
        self?.downloadsFolderPicker = picker
        picker.selectFolder(result: result) { [weak self] in
          self?.downloadsFolderPicker = nil
        }
        return
      }
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

  private func flutterViewController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes
      .flatMap(\.windows)
      .compactMap(\.rootViewController)
      .compactMap { $0 as? FlutterViewController }
      .first
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
    configureDownloadChannelIfPossible()
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
      if isImage {
        self.saveImageToPhotos(fileURL)
      } else {
        self.copyToDownloadsFolder(fileURL)
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
        } else {
          self?.finish(FlutterError(code: "photos_save_failed", message: error?.localizedDescription ?? "iOS could not save this image to Photos.", details: nil))
        }
      }
    }
  }

  private func copyToDownloadsFolder(_ fileURL: URL) {
    do {
      guard let directory = try Self.configuredDownloadsFolder() else {
        finish(FlutterError(code: "downloads_folder_not_configured", message: "Choose the Downloads folder when the app opens before downloading files.", details: nil))
        return
      }
      guard directory.startAccessingSecurityScopedResource() else {
        finish(FlutterError(code: "downloads_folder_access_denied", message: "The app no longer has access to Downloads. Restart it and select Downloads again.", details: nil))
        return
      }
      defer { directory.stopAccessingSecurityScopedResource() }
      let destination = uniqueFileURL(in: directory, named: fileURL.lastPathComponent)
      try FileManager.default.copyItem(at: fileURL, to: destination)
      finish("downloads")
    } catch {
      finish(FlutterError(code: "downloads_save_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func uniqueFileURL(in directory: URL, named fileName: String) -> URL {
    let source = URL(fileURLWithPath: fileName)
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var index = 0
    var candidate = directory.appendingPathComponent(fileName)
    while FileManager.default.fileExists(atPath: candidate.path) {
      index += 1
      let suffix = " (\(index))"
      candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)")
    }
    return candidate
  }

  static let downloadsFolderBookmarkKey = "khdr.downloadsFolderBookmark"

  static var hasConfiguredDownloadsFolder: Bool {
    UserDefaults.standard.data(forKey: downloadsFolderBookmarkKey) != nil
  }

  static func configuredDownloadsFolder() throws -> URL? {
    guard let data = UserDefaults.standard.data(forKey: downloadsFolderBookmarkKey) else {
      return nil
    }
    var isStale = false
    let directory = try URL(
      resolvingBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    if isStale {
      let refreshed = try directory.bookmarkData(
        options: [.minimalBookmark],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(refreshed, forKey: downloadsFolderBookmarkKey)
    }
    return directory
  }

  static func setDownloadsFolder(_ directory: URL) throws {
    let bookmark = try directory.bookmarkData(
      options: [.minimalBookmark],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    UserDefaults.standard.set(bookmark, forKey: downloadsFolderBookmarkKey)
  }

  private func finish(_ value: Any?) {
    temporaryFileURL.map { try? FileManager.default.removeItem(at: $0) }
    temporaryFileURL = nil
    let callback = result
    result = nil
    callback?(value)
    let done = completion
    completion = nil
    done?()
  }
}

private final class IOSDownloadsFolderPicker: NSObject, UIDocumentPickerDelegate {
  private var result: FlutterResult?
  private var completion: (() -> Void)?

  func selectFolder(result: @escaping FlutterResult, completion: @escaping () -> Void) {
    self.result = result
    self.completion = completion
    DispatchQueue.main.async {
      guard let presenter = activeViewController() else {
        self.finish(FlutterError(code: "no_presenter", message: "Unable to show the Downloads folder selector.", details: nil))
        return
      }
      let alert = UIAlertController(
        title: "Choose Downloads Folder",
        message: "Select Downloads in the next screen. Odoo files will then save there automatically without asking again.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in
        self.finish(FlutterError(code: "downloads_folder_cancelled", message: "Choose Downloads to enable automatic file downloads.", details: nil))
      })
      alert.addAction(UIAlertAction(title: "Choose Downloads", style: .default) { _ in
        self.presentFolderPicker(from: presenter)
      })
      presenter.present(alert, animated: true)
    }
  }

  private func presentFolderPicker(from presenter: UIViewController) {
    let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.modalPresentationStyle = .formSheet
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let directory = urls.first else {
      finish(FlutterError(code: "downloads_folder_missing", message: "No Downloads folder was selected.", details: nil))
      return
    }
    guard directory.startAccessingSecurityScopedResource() else {
      finish(FlutterError(code: "downloads_folder_access_denied", message: "iOS did not grant access to the selected folder.", details: nil))
      return
    }
    defer { directory.stopAccessingSecurityScopedResource() }
    do {
      try IOSDownloadSaver.setDownloadsFolder(directory)
      finish(nil)
    } catch {
      finish(FlutterError(code: "downloads_folder_save_failed", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(FlutterError(code: "downloads_folder_cancelled", message: "Choose Downloads to enable automatic file downloads.", details: nil))
  }

  private func finish(_ value: Any?) {
    let callback = result
    result = nil
    callback?(value)
    let done = completion
    completion = nil
    done?()
  }
}

private func activeViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let root = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })?.rootViewController
  var visible = root
  while let presented = visible?.presentedViewController {
    visible = presented
  }
  return visible
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
