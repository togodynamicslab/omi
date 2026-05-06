import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Holds the STT bridge for the live-transcription preview so it stays
  // alive for the lifetime of the app (per 2026-05-05 dogfood: the
  // "Pendant → BLE → iOS STT" path).
  private var sttBridge: SttBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
  }
}
