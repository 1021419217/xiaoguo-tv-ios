import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFoundation
import MediaPlayer
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var originalBrightness: CGFloat?
  private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private var screen: UIScreen? { keyWindow?.screen }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "battery" {
          let device = UIDevice.current
          device.isBatteryMonitoringEnabled = true
          guard device.batteryLevel >= 0 else {
            result(nil)
            return
          }
          result(["level": Int((device.batteryLevel * 100).rounded()),
                  "charging": device.batteryState == .charging || device.batteryState == .full])
          return
        }
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "challenge":
          // 站点人机验证：开一个真正的 WKWebView 过 Cloudflare 挑战，
          // 拿到 cf_clearance 与它自己的 UA 回给 Dart，再由 Dart 交给 Go 模块。
          guard let urlText = arguments?["url"] as? String,
                let address = URL(string: urlText) else {
            result(nil)
            return
          }
          let host = (arguments?["host"] as? String) ?? address.host ?? ""
          ChallengeWebView.shared.solve(url: address, host: host) { cookie, agent in
            guard let cookie, !cookie.isEmpty else {
              result(nil)
              return
            }
            result(["cookie": cookie, "ua": agent ?? ""])
          }
          return
        case "getBrightness":
          result(self.screen.map { Double($0.brightness) })
          return
        case "setBrightness":
          guard let screen = self.screen, let value = arguments?["brightness"] as? Double else {
            result(nil)
            return
          }
          if self.originalBrightness == nil { self.originalBrightness = screen.brightness }
          screen.brightness = CGFloat(min(max(value, 0.01), 1))
          result(true)
          return
        case "resetBrightness":
          if let original = self.originalBrightness { self.screen?.brightness = original }
          self.originalBrightness = nil
          result(true)
          return
        case "volume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
          return
        case "setVolume":
          if let value = arguments?["volume"] as? Double {
            if self.volumeView.superview == nil { self.keyWindow?.addSubview(self.volumeView) }
            let slider = self.volumeView.subviews.first { $0 is UISlider } as? UISlider
            slider?.value = Float(min(max(value, 0), 1))
          }
          result(nil)
          return
        default:
          break
        }
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
  }
}

/// 应用内的站点验证窗口。
///
/// Cloudflare 的托管挑战要执行 JS，纯 HTTP 客户端拿不到 cf_clearance。
/// 这里用 WKWebView 真的把站点打开，等标题不再是「Just a moment / 请稍候」、
/// 且 cookie 里出现 cf_clearance 之后，把 cookie 串和 navigator.userAgent
/// 一起交回去——cf_clearance 绑 UA，后续请求必须用同一串 UA。
final class ChallengeWebView: NSObject, WKNavigationDelegate {
  static let shared = ChallengeWebView()

  private var window: UIWindow?
  private var webView: WKWebView?
  private var host = ""
  private var completion: ((String?, String?) -> Void)?
  private var poll: Timer?
  private var deadline: Date?

  func solve(url: URL, host: String, completion: @escaping (String?, String?) -> Void) {
    DispatchQueue.main.async {
      guard self.completion == nil else {
        completion(nil, nil)
        return
      }
      guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else {
        completion(nil, nil)
        return
      }
      self.host = host
      self.completion = completion
      self.deadline = Date().addingTimeInterval(90)

      let window = UIWindow(windowScene: scene)
      window.windowLevel = .alert + 1
      let root = UIViewController()
      root.view.backgroundColor = .systemBackground
      window.rootViewController = root
      window.makeKeyAndVisible()
      self.window = window

      let bar = UIView()
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.backgroundColor = .secondarySystemBackground
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.text = "正在验证站点…"
      label.font = .systemFont(ofSize: 15, weight: .semibold)
      let close = UIButton(type: .system)
      close.translatesAutoresizingMaskIntoConstraints = false
      close.setTitle("取消", for: .normal)
      close.addTarget(self, action: #selector(self.cancelTapped), for: .touchUpInside)
      bar.addSubview(label)
      bar.addSubview(close)

      let config = WKWebViewConfiguration()
      config.websiteDataStore = .default()
      let web = WKWebView(frame: .zero, configuration: config)
      web.translatesAutoresizingMaskIntoConstraints = false
      web.navigationDelegate = self
      root.view.addSubview(bar)
      root.view.addSubview(web)
      let safe = root.view.safeAreaLayoutGuide
      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: safe.topAnchor),
        bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        bar.heightAnchor.constraint(equalToConstant: 48),
        label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
        close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        web.topAnchor.constraint(equalTo: bar.bottomAnchor),
        web.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      ])
      self.webView = web
      web.load(URLRequest(url: url))
      self.poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
        self?.check()
      }
    }
  }

  @objc private func cancelTapped() { finish(nil, nil) }

  private func check() {
    guard let web = webView else { return }
    if let limit = deadline, Date() > limit {
      finish(nil, nil)
      return
    }
    web.evaluateJavaScript("document.title") { [weak self] value, _ in
      guard let self else { return }
      let title = (value as? String ?? "").lowercased()
      let waiting = title.isEmpty || title.contains("just a moment") || title.contains("请稍候")
        || title.contains("請稍候") || title.contains("attention required")
      if waiting { return }
      // 标题已经变成真实页面，再等 cookie 落地。
      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        let mine = cookies.filter { c in
          let domain = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
          return !domain.isEmpty && (self.host == domain || self.host.hasSuffix("." + domain))
        }
        guard mine.contains(where: { $0.name == "cf_clearance" }) else { return }
        let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        web.evaluateJavaScript("navigator.userAgent") { agent, _ in
          self.finish(header, agent as? String)
        }
      }
    }
  }

  private func finish(_ cookie: String?, _ agent: String?) {
    poll?.invalidate()
    poll = nil
    let callback = completion
    completion = nil
    webView?.stopLoading()
    webView = nil
    window?.isHidden = true
    window = nil
    callback?(cookie, agent)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    // 挑战页本身会触发一次中断式导航，不能当成失败直接退出。
    if (error as NSError).code == NSURLErrorCancelled { return }
  }
}
