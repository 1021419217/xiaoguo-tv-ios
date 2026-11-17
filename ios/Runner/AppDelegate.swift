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

/// 应用内的站点验证页面。
///
/// Cloudflare 的托管挑战要执行 JS，纯 HTTP 客户端拿不到 cf_clearance。
/// 这里用 WKWebView 真的把站点打开，等标题不再是「Just a moment / 请稍候」、
/// 且 cookie 里出现 cf_clearance 之后，把 cookie 串和 navigator.userAgent
/// 一起交回去——cf_clearance 绑 UA，后续请求必须用同一串 UA。
///
/// 早先的实现用自建 UIWindow 悬浮在 Flutter 之上，会在一秒左右被系统收回
/// （key window 被 Flutter 抢回去），看起来就是「弹一下自动缩回」。改成
/// 从 Flutter 根控制器模态弹出，并由用户点「完成」兜底，不再自动消失。
final class ChallengeWebView: NSObject, WKNavigationDelegate {
  static let shared = ChallengeWebView()

  private var controller: UIViewController?
  private var webView: WKWebView?
  private var statusLabel: UILabel?
  private var host = ""
  private var target: URL?
  private var completion: ((String?, String?) -> Void)?
  private var poll: Timer?
  private var deadline: Date?
  private var finished = false

  func solve(url: URL, host: String, completion: @escaping (String?, String?) -> Void) {
    DispatchQueue.main.async {
      // 已经在验证中：把窗口提到前面，复用同一次会话，不重复弹。
      if self.controller != nil {
        self.completion = completion
        self.target = url
        self.host = host
        self.finished = false
        self.deadline = Date().addingTimeInterval(180)
        self.startPolling()
        self.webView?.load(URLRequest(url: url))
        return
      }
      guard let presenter = self.topController() else {
        completion(nil, nil)
        return
      }
      self.host = host
      self.target = url
      self.completion = completion
      self.finished = false
      self.deadline = Date().addingTimeInterval(180)

      let root = UIViewController()
      root.view.backgroundColor = .systemBackground
      root.modalPresentationStyle = .fullScreen

      let bar = UIView()
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.backgroundColor = .secondarySystemBackground
      let title = UILabel()
      title.translatesAutoresizingMaskIntoConstraints = false
      title.text = "站点验证"
      title.font = .systemFont(ofSize: 16, weight: .semibold)
      let close = UIButton(type: .system)
      close.translatesAutoresizingMaskIntoConstraints = false
      close.setTitle("关闭", for: .normal)
      close.addTarget(self, action: #selector(self.cancelTapped), for: .touchUpInside)
      let done = UIButton(type: .system)
      done.translatesAutoresizingMaskIntoConstraints = false
      done.setTitle("完成", for: .normal)
      done.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
      done.addTarget(self, action: #selector(self.doneTapped), for: .touchUpInside)
      bar.addSubview(title)
      bar.addSubview(close)
      bar.addSubview(done)

      let status = UILabel()
      status.translatesAutoresizingMaskIntoConstraints = false
      status.text = "正在打开站点，若出现勾选框请点一下…"
      status.font = .systemFont(ofSize: 13)
      status.textColor = .secondaryLabel
      status.numberOfLines = 2
      status.textAlignment = .center
      status.backgroundColor = .secondarySystemBackground

      let config = WKWebViewConfiguration()
      // 用默认（持久化）存储：验证拿到的 cookie 与后续 WebKit 请求共用同一份。
      config.websiteDataStore = .default()
      let web = WKWebView(frame: .zero, configuration: config)
      web.translatesAutoresizingMaskIntoConstraints = false
      web.navigationDelegate = self
      web.allowsBackForwardNavigationGestures = false
      root.view.addSubview(bar)
      root.view.addSubview(status)
      root.view.addSubview(web)
      let safe = root.view.safeAreaLayoutGuide
      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: safe.topAnchor),
        bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        bar.heightAnchor.constraint(equalToConstant: 48),
        title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
        done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        close.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -20),
        status.topAnchor.constraint(equalTo: bar.bottomAnchor),
        status.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        status.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        status.heightAnchor.constraint(equalToConstant: 34),
        web.topAnchor.constraint(equalTo: status.bottomAnchor),
        web.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      ])
      self.webView = web
      self.statusLabel = status
      self.controller = root
      presenter.present(root, animated: true)
      web.load(URLRequest(url: url))
      self.startPolling()
    }
  }

  private func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var current = scene?.windows.first { $0.isKeyWindow }?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let next = current?.presentedViewController, !next.isBeingDismissed {
      current = next
    }
    return current
  }

  private func startPolling() {
    poll?.invalidate()
    poll = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
      self?.check(auto: true)
    }
  }

  private func note(_ text: String) {
    DispatchQueue.main.async { self.statusLabel?.text = text }
  }

  @objc private func cancelTapped() { finish(nil, nil) }

  @objc private func doneTapped() { check(auto: false) }

  /// 检查页面状态。auto=true 时只在确实拿到通行 cookie 后才自动收尾，
  /// 不会因为标题短暂为空就把页面关掉。
  private func check(auto: Bool) {
    guard let web = webView else { return }
    if auto, let limit = deadline, Date() > limit {
      finish(nil, nil)
      return
    }
    web.evaluateJavaScript("document.title") { [weak self] value, _ in
      guard let self else { return }
      let title = ((value as? String) ?? "").lowercased()
      let waiting = title.isEmpty || title.contains("just a moment") || title.contains("请稍候")
        || title.contains("請稍候") || title.contains("attention required")
        || title.contains("checking") || title.contains("verifying")
      if auto, waiting {
        self.note("正在验证，请稍候…")
        return
      }
      self.harvest(manual: !auto)
    }
  }

  /// 把本站 cookie 全量取出来。cf_clearance 必须有；手动点「完成」时
  /// 就算没有也照样回传（可能该站用的是别的校验 cookie）。
  private func harvest(manual: Bool) {
    guard let web = webView else { return }
    let host = self.host
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let mine = cookies.filter { cookie in
        let domain = cookie.domain.lowercased().trimmingCharacters(
          in: CharacterSet(charactersIn: ".")
        )
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("." + host)
      }
      let hasClearance = mine.contains { $0.name == "cf_clearance" }
      if !hasClearance {
        if manual {
          self.note("还没拿到通行 cookie，若页面已能正常浏览，请再点一次「完成」")
        } else {
          self.note("已过验证页，正在等待通行 cookie…")
        }
        return
      }
      guard !mine.isEmpty else { return }
      let header = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      web.evaluateJavaScript("navigator.userAgent") { agent, _ in
        self.finish(header, agent as? String)
      }
    }
  }

  private func finish(_ cookie: String?, _ agent: String?) {
    guard !finished else { return }
    finished = true
    poll?.invalidate()
    poll = nil
    let callback = completion
    completion = nil
    let page = controller
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
    statusLabel = nil
    controller = nil
    page?.dismiss(animated: true) {
      callback?(cookie, agent)
    }
    if page == nil { callback?(cookie, agent) }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // 有的站点验证通过后标题不变，这里也主动探一次 cookie。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.check(auto: true)
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    // 挑战页本身会触发一次中断式导航，不能当成失败直接退出。
    if (error as NSError).code == NSURLErrorCancelled { return }
    note("页面加载中断：\((error as NSError).localizedDescription)")
  }
}
