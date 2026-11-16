import Flutter
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var companionVoice: IOSCompanionVoice?

  /// iOS suspends the process behind the app, and a paired Host then has to be
  /// reached again from scratch. A background task keeps the process, and its
  /// sockets, alive across a quick switch away -- the system allows about 30
  /// seconds -- so returning usually finds the tunnel still up. Ending it in
  /// the expiration handler matters: overrunning it gets the app killed.
  private var linkGrace: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before launch finishes, or the tap that launched the app is lost.
    UNUserNotificationCenter.current().delegate = NotifyTaps.shared
    forgetPreviousInstall()
    observeLinkGrace()
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    let preflight = ProcessInfo.processInfo.arguments.contains("--dsh-phone-preflight")
      || ProcessInfo.processInfo.environment["DSH_PHONE_PREFLIGHT"] == "1"
    IOSPhoneSelfRunner.diagnostic("launch preflight=\(preflight)")
    if preflight {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        Task { @MainActor in
          let owner = IOSPhoneSelfRunner.shared
          print("DSH_SELF_PREFLIGHT configured=\(owner.isConfigured)")
          IOSPhoneSelfRunner.diagnostic("preflight configured=\(owner.isConfigured)")
          for cycle in 1...2 {
            IOSPhoneSelfRunner.diagnostic("preflight cycle=\(cycle)")
            let result = await owner.prepare(ownerID: "device-preflight", current: { true })
            switch result {
            case .success:
              IOSPhoneSelfRunner.diagnostic("preflight ready cycle=\(cycle)")
            case .failure(let error):
              IOSPhoneSelfRunner.diagnostic("preflight failure=\(error)")
              owner.stop(ownerID: "device-preflight")
              return
            }
            owner.stop(ownerID: "device-preflight")
          }
          fflush(stdout)
        }
      }
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Notifications rather than the app delegate's own callbacks: the app runs
  /// on scenes, and these fire whichever scene is in front.
  private func observeLinkGrace() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.beginLinkGrace() }
    center.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.endLinkGrace() }
  }

  private func beginLinkGrace() {
    guard linkGrace == .invalid else { return }
    linkGrace = UIApplication.shared.beginBackgroundTask(withName: "dsh.link-grace") { [weak self] in
      self?.endLinkGrace()
    }
  }

  private func endLinkGrace() {
    guard linkGrace != .invalid else { return }
    UIApplication.shared.endBackgroundTask(linkGrace)
    linkGrace = .invalid
  }

  /// The Keychain outlives an uninstall and UserDefaults doesn't. On a fresh install
  /// anything in there belongs to the last one, and must not sign this one in.
  private func forgetPreviousInstall() {
    let marker = "dsh.installed"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: marker) else { return }
    SecItemDelete([kSecClass: kSecClassGenericPassword] as CFDictionary)
    defaults.set(true, forKey: marker)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPlugin") {
      DshPlugin.register(with: registrar)
      IOSPhoneControl.shared.register(messenger: registrar.messenger())
      IOSPhoneLink.shared.register(messenger: registrar.messenger(), presenter: { topViewController() })
      IOSPetOverlay.shared.register(registrar: registrar)
      companionVoice?.dispose()
      companionVoice = IOSCompanionVoice(messenger: registrar.messenger(), pipAudioConfigured: {
        IOSPetOverlay.shared.statusSnapshot["audioSessionConfigured"] as? Bool == true
      })
      IOSPetOverlay.shared.onTaskPauseRequested = { IOSPhoneControl.shared.pausePhoneTask(id: $0) }
      IOSPetOverlay.shared.onTaskStopConfirmed = { IOSPhoneControl.shared.stopPhoneTaskConfirmed(id: $0) }
      IOSPetOverlay.shared.onTaskResumeConfirmed = { IOSPhoneControl.shared.resumePhoneTask(id: $0) }
    }
  }
}
