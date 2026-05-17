import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Holds the STT bridge for the live-transcription preview so it stays
  // alive for the lifetime of the app (per 2026-05-05 dogfood: the
  // "Pendant → BLE → iOS STT" path).
  private var sttBridge: SttBridge?

  // Holds the on-device intent bridge (Foundation Models parser + EventKit /
  // Shortcuts dispatcher). iOS 26+ only; lives behind an @available gate so
  // the rest of the app keeps targeting iOS 13. Typed as AnyObject so the
  // property declaration itself doesn't carry an availability constraint.
  private var intentBridge: AnyObject?

  // Dispatch-only bridge: EventKit calls for calendar / reminders / alarm /
  // timer, callable on any iOS version. Used by the cloud parser path when
  // Foundation Models isn't available (iOS 18, non-Apple-Intelligence devices).
  private var intentDispatchBridge: IntentDispatchBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Wire UNUserNotificationCenter so the Firebase Messaging plugin can
    // forward foreground notifications + tap callbacks. The actual APNS
    // token plumbing is handled by the firebase_messaging plugin's method
    // swizzling — we just need the delegate set and remote notifications
    // registered. Authorization is requested from Dart (notification_service)
    // so we don't double-prompt.
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Wire SttBridge by going through the plugin registry — that's the
    // public surface that exposes a binary messenger. The bridge isn't a
    // real plugin, just borrowing the registrar to get a messenger.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SttBridge") {
      sttBridge = SttBridge(messenger: registrar.messenger())
    }
    // Dispatch bridge: always wired. EventKit works on iOS 13+ so this is
    // safe and means the cloud-parser path has a target even when the
    // on-device LLM bridge below is gated out.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IntentDispatchBridge") {
      intentDispatchBridge = IntentDispatchBridge(messenger: registrar.messenger())
    }
    if #available(iOS 26.0, *) {
      if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IntentBridge") {
        intentBridge = IntentBridge(messenger: registrar.messenger())
      }
    }
  }

}
