import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      IntentBridge.shared.setInitialURL(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    IntentBridge.shared.handleOpenURL(url)
    return true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DreamPlayer") else {
      return
    }
    let messenger = registrar.messenger()
    registrar.register(
      AvPlayerViewFactory(messenger: messenger),
      withId: "dreamplayer/exo_player"
    )
    FileBrowser.register(with: messenger)
    IntentBridge.shared.configure(with: messenger)
    SMBClient.register(with: messenger)
    WebDAVClient.register(with: messenger)
  }
}
