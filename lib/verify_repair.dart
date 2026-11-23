import 'app_device.dart';
import 'core_bridge.dart';

/// 把页面用「验证过的那台 WKWebView」抓回来，写进 Go 侧的页缓存。
///
/// Cloudflare 的放行绑在真 WebKit 的整条指纹上（TLS / HTTP2 / UA），Go 的
/// tls-client 模拟不出来；模块取页命中这份缓存就不用自己去闯 TLS 那一关。
/// 返回成功载入的页数。
Future<int> primeVerifyPages(
  AppRepository repository,
  Iterable<String> urls,
  String host,
) async {
  var primed = 0;
  for (final url in urls) {
    final pageHost = Uri.tryParse(url)?.host ?? host;
    final html = await AppDevice.webFetch(url, pageHost);
    if (html == null || html.isEmpty) continue;
    if (await repository.setWebPage(url, html)) primed++;
  }
  return primed;
}

/// 验证完成后第一次请求仍然失败时调用。
///
/// 失败的那次请求会被 host 层重新登记进待抓队列（当前分类 / 详情页往往不在
/// 验证前那一批里），把它们再抓一遍就能补上缺口。补进了页面返回 true，
/// 调用方据此再重试一次。
Future<bool> primePendingAfterFailure(
  AppRepository repository,
  String host,
) async {
  final pending = await repository.pendingWebPages();
  if (pending.isEmpty) return false;
  return await primeVerifyPages(repository, pending, host) > 0;
}

/// 同一个站点的自动验证尝试间隔：失败时不要让每个请求都重开一次 WebView。
const _autoVerifyCooldown = Duration(seconds: 45);
final _lastAutoVerify = <String, DateTime>{};

String _autoKey(String host) => host.toLowerCase().trim();

/// 自动静默过验证：不弹窗，直接让原生离屏 WebView 拿凭据，成功后补抓页面。
///
/// 返回 true 表示这次拿到了凭据（调用方可以重试请求）；false 表示没拿到，
/// 由界面退回手动「去验证」。同一主机 45 秒内只会尝试一次。
Future<bool> autoVerifyIfNeeded(
  AppRepository repository,
  String baseUrl,
  String host,
) async {
  if (baseUrl.isEmpty || host.isEmpty) return false;
  final key = _autoKey(host);
  final now = DateTime.now();
  final last = _lastAutoVerify[key];
  if (last != null && now.difference(last) < _autoVerifyCooldown) return false;
  _lastAutoVerify[key] = now;

  final solved = await AppDevice.silentSolve(baseUrl, host);
  if (solved == null) return false;

  final pending = await repository.pendingWebPages();
  final blocked = await repository.blockedUrl(host);
  final urls = [
    ...pending,
    if (blocked.isNotEmpty && !pending.contains(blocked)) blocked,
  ];
  await repository.saveChallenge(
    host,
    solved.cookie,
    userAgent: solved.userAgent,
  );
  await primeVerifyPages(repository, urls, host);
  return true;
}
