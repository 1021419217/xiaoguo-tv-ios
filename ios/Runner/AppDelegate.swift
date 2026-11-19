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
        case "webFetch":
          // 用验证过的 WebView 抓页面，指纹与过验证那次一致，绕开 Go 客户端被拦的问题。
          guard let urlText = arguments?["url"] as? String,
                let address = URL(string: urlText) else {
            result(nil)
            return
          }
          let host = (arguments?["host"] as? String) ?? address.host ?? ""
          ChallengeWebView.shared.webFetch(url: address, host: host) { html in
            result(html)
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
private final class ChallengeHostController: UIViewController {
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

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

  /// 验证通过的 WKWebView 按 host 常驻。Cloudflare 的放行绑着整条浏览器指纹
  /// （TLS/JS/HTTP2），Go 的 tls-client 模拟不出来。同一台 WebView 再发 fetch 才
  /// 能和「过验证那次」的指纹完全一致——这正是 iDuanJu 复用 WebView 取页的做法。
  private var solved: [String: WKWebView] = [:]
  private var solvedOrder: [String] = []
  private let maxSolvedWebViews = 3

  /// 用一个已验证的 WebView 抓页面 HTML。若该 host 还没有常驻 WebView，
  /// 就用持久化 cookie store 新建一台（验证 cookie 已同步进去），加载目标页后取文本。
  func webFetch(url: URL, host: String, completion: @escaping (String?) -> Void) {
    DispatchQueue.main.async {
      let key = Self.hostKey(host)
      // 同 registrable domain 的验证 WebView 也复用：www 验证完去抓 m/www
      // 子域时，cookie 虽然共享，但 TLS/JS 指纹只有原来那台 WebView 对得上。
      let cachedKey = self.solved[key] != nil
        ? key
        : self.solved.keys.first { candidate in
            key == candidate || key.hasSuffix("." + candidate)
              || candidate.hasSuffix("." + key)
          }
      let web: WKWebView
      if let cachedKey, let cached = self.solved[cachedKey] {
        web = cached
      } else {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: config)
        self.retain(web, for: key)
      }
      // 用页面上下文里的 fetch 取原始 HTML：和验证同 origin、同 cookie、同指纹。
      // 目标页若还没加载，先 load 一次；onFinish 后再取。
      self.fetchPage(web, url: url, completion: completion)
    }
  }

  /// 常驻 WebView 只保留最近验证过的几台，避免验证站点越多内存越大。
  private func retain(_ web: WKWebView, for key: String) {
    solvedOrder.removeAll { $0 == key }
    solvedOrder.append(key)
    solved[key] = web
    while solvedOrder.count > maxSolvedWebViews {
      let oldest = solvedOrder.removeFirst()
      solved[oldest]?.removeFromSuperview()
      solved[oldest] = nil
    }
  }

  private static func hostKey(_ host: String) -> String {
    var key = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if key.hasPrefix("www.") { key = String(key.dropFirst(4)) }
    return key
  }

  private static func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func fetchPage(_ web: WKWebView, url: URL, completion: @escaping (String?) -> Void) {
    // callAsyncJavaScript 在页面 world 执行 fetch，带上同源 cookie；返回的是原始文本，
    // 交给 Go 模块按服务端 HTML 解析（和验证前模块拿到的结构一致）。
    let js = """
    (async function() {
      try {
        const r = await fetch(u, {credentials: 'include', cache: 'no-store'});
        return await r.text();
      } catch (e) { return ''; }
    })()
    """
    func doFetch() {
      // 用 async/await 形式（该 SDK 下 callAsyncJavaScript 只有这个重载，
      // 不接受 completionHandler 闭包/尾随闭包）。结果可能不是 String，做两级转换。
      Task { @MainActor in
        let value = try? await web.callAsyncJavaScript(
          js, arguments: ["u": url.absoluteString], in: nil, contentWorld: .page
        )
        let html = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        completion(html.isEmpty ? nil : html)
      }
    }
    func waitAndFetch(_ tries: Int) {
      if !web.isLoading || tries >= 50 {
        doFetch()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          waitAndFetch(tries + 1)
        }
      }
    }
    // fetch 必须和目标同源才带得上 cf_clearance。常驻的验证 WebView 通常就在
    // 该 host 上；若不在（比如验证的是主域、要抓的是镜像），先导航过去再取。
    let sameHost = web.url?.host?.lowercased() == url.host?.lowercased()
    if sameHost {
      doFetch()
    } else {
      web.load(URLRequest(url: url))
      waitAndFetch(0)
    }
  }

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

      let background = UIColor(red: 0.043, green: 0.043, blue: 0.055, alpha: 1)
      let elevated = UIColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1)
      let root = ChallengeHostController()
      root.view.backgroundColor = background
      root.overrideUserInterfaceStyle = .dark
      root.modalPresentationStyle = .fullScreen

      let bar = UIView()
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.backgroundColor = elevated
      let hairline = UIView()
      hairline.translatesAutoresizingMaskIntoConstraints = false
      hairline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
      let title = UILabel()
      title.translatesAutoresizingMaskIntoConstraints = false
      title.text = "站点验证"
      title.font = .systemFont(ofSize: 18, weight: .semibold)
      title.textColor = .white
      let close = UIButton(type: .system)
      close.translatesAutoresizingMaskIntoConstraints = false
      var closeConfig = UIButton.Configuration.plain()
      closeConfig.image = UIImage(systemName: "xmark")
      closeConfig.baseForegroundColor = UIColor.white.withAlphaComponent(0.92)
      close.configuration = closeConfig
      close.addTarget(self, action: #selector(self.cancelTapped), for: .touchUpInside)
      let done = UIButton(type: .system)
      done.translatesAutoresizingMaskIntoConstraints = false
      var doneConfig = UIButton.Configuration.filled()
      var doneTitle = AttributedString("完成")
      doneTitle.font = .systemFont(ofSize: 15, weight: .semibold)
      doneConfig.attributedTitle = doneTitle
      doneConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.92)
      doneConfig.baseForegroundColor = UIColor.black
      doneConfig.cornerStyle = .capsule
      doneConfig.contentInsets = NSDirectionalEdgeInsets(
        top: 8, leading: 18, bottom: 8, trailing: 18)
      done.configuration = doneConfig
      done.addTarget(self, action: #selector(self.doneTapped), for: .touchUpInside)
      bar.addSubview(title)
      bar.addSubview(close)
      bar.addSubview(done)
      bar.addSubview(hairline)

      let status = UILabel()
      status.translatesAutoresizingMaskIntoConstraints = false
      status.text = "正在打开站点，若出现勾选框请点一下…"
      status.font = .systemFont(ofSize: 13)
      status.textColor = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)
      status.numberOfLines = 2
      status.textAlignment = .center
      status.backgroundColor = background

      let config = WKWebViewConfiguration()
      // 用默认（持久化）存储：验证拿到的 cookie 与后续 WebKit 请求共用同一份。
      config.websiteDataStore = .default()
      let web = WKWebView(frame: .zero, configuration: config)
      web.translatesAutoresizingMaskIntoConstraints = false
      web.navigationDelegate = self
      web.allowsBackForwardNavigationGestures = false
      web.isOpaque = false
      web.backgroundColor = background
      web.scrollView.backgroundColor = background
      root.view.addSubview(bar)
      root.view.addSubview(status)
      root.view.addSubview(web)
      let safe = root.view.safeAreaLayoutGuide
      NSLayoutConstraint.activate([
        bar.topAnchor.constraint(equalTo: safe.topAnchor),
        bar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        bar.heightAnchor.constraint(equalToConstant: 56),
        close.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
        close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        close.widthAnchor.constraint(equalToConstant: 38),
        close.heightAnchor.constraint(equalToConstant: 38),
        title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 6),
        title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        done.heightAnchor.constraint(equalToConstant: 38),
        hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
        hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        hairline.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        hairline.heightAnchor.constraint(equalToConstant: 1),
        status.topAnchor.constraint(equalTo: bar.bottomAnchor),
        status.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        status.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        status.heightAnchor.constraint(equalToConstant: 40),
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
      // 手动点「完成」也不能在挑战页还没过的时候收尾，否则会把无效
      // cookie 存下来，表现就是验证完仍然一直 403、怎么点都没内容。
      if waiting {
        self.note("验证还没完成，请等页面跳转后再点「完成」")
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
      // 自动收尾只认 Cloudflare 的通行 cookie；手动点「完成」时放宽，
      // 让 hCaptcha / PerimeterX 这类非 CF 的校验也能把 cookie 存下来。
      if !manual && !hasClearance {
        self.note("已过验证页，正在等待通行 cookie…")
        return
      }
      guard !mine.isEmpty else {
        if manual {
          self.note("没有拿到任何 cookie，请确认页面已正常打开后再点「完成」")
        }
        return
      }
      // 自动轮询只提示、不替用户收尾：91 这类站会先出年龄确认页，
      // 旧 cookie 已经存在时若自动 finish，页面 0.5 秒就消失，用户根本
      // 来不及点「我已满 18 岁」。统一由用户点「完成」再收尾。
      if !manual {
        self.note("已检测到通行 cookie，请点右上角「完成」继续")
        return
      }
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
    let web = webView
    // 拿到通行 cookie 就说明这台 WebView 过了验证，留着复用它的指纹取页。
    // 从验证页视图里摘出来、垫到 keyWindow 底层保活（离屏后 WKWebView 的
    // 渲染与 JS 上下文可能被系统回收，垫在底层既不被看见也不会被收走）。
    if cookie != nil, let web = web {
      let key = Self.hostKey(host)
      // 同一 host 若已有旧的常驻 WebView，先移除，避免叠加。
      solved[key]?.removeFromSuperview()
      if let window = Self.keyWindow() {
        web.frame = window.bounds
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        window.insertSubview(web, at: 0)
      }
      web.navigationDelegate = nil
      retain(web, for: key)
    } else {
      web?.stopLoading()
      web?.navigationDelegate = nil
    }
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
