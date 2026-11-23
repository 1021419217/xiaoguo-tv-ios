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
