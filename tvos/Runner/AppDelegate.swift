import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
    WebDAVClient.register(with: messenger)
    JellyfinDiscovery.register(with: messenger)
    CacheCleaner.register(with: messenger)
  }
}
