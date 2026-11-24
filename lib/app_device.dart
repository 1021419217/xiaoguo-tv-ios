import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core_bridge.dart';

class AppDevice {
  const AppDevice({this.television = false, this.version = ''});
  final bool television;
  final String version;
  static const channel = MethodChannel('duanju/device');

  /// 站点人机验证：用原生 WKWebView 打开站点走一遍 Cloudflare 挑战，
  /// 成功后返回它拿到的 cookie 与 WebView 的真实 UA（cf_clearance 绑 UA）。
  static Future<({String cookie, String userAgent})?> solveChallenge(
    String url,
    String host,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('challenge', {
            'url': url,
            'host': host,
          })
          .timeout(const Duration(minutes: 4));
      final cookie = data?['cookie'];
      if (cookie is! String || cookie.isEmpty) return null;
      final agent = data?['ua'];
      return (
        cookie: cookie,
        userAgent: agent is String ? agent : '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 后台静默过验证：原生用离屏 WebView 自己把挑战跑完，不弹窗。
  /// 拿到凭据返回；超时或没拿到返回 null，调用方再退回手动「去验证」。
  static Future<({String cookie, String userAgent})?> silentSolve(
    String url,
    String host,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('silentChallenge', {
            'url': url,
            'host': host,
          })
          .timeout(const Duration(seconds: 35));
      final cookie = data?['cookie'];
      if (cookie is! String || cookie.isEmpty) return null;
      final agent = data?['ua'];
      return (cookie: cookie, userAgent: agent is String ? agent : '');
    } catch (_) {
      return null;
    }
  }

  /// 用那台验证过的 WKWebView 抓页面 HTML（指纹与过验证那次一致）。
  /// 返回原始 HTML；失败返回 null。仅在 iOS 有效。
  static Future<String?> webFetch(String url, String host) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      return await channel
          .invokeMethod<String>('webFetch', {'url': url, 'host': host})
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    }
  }

  static var _televisionMode = false;
  static var _phoneMode = false;

  static Future<AppDevice> detect({
    AppDevice fallback = const AppDevice(),
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      try {
        final info = await PackageInfo.fromPlatform();
        return AppDevice(version: info.version);
      } catch (_) {
        return fallback;
      }
    }
    try {
      final data = await channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final television = data?['television'];
      if (television is! bool) return fallback;
      final version = data?['version'];
      return AppDevice(
        television: television,
        version: version is String && version.isNotEmpty
            ? version
            : fallback.version,
      );
    } on PlatformException {
      return fallback;
    } on MissingPluginException {
      return fallback;
    } on TimeoutException {
      return fallback;
    }
  }

  static Future<bool> compatibleRendering() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('compatibleRendering') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setCompatibleRendering(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await channel.invokeMethod('setCompatibleRendering', {
        'enabled': enabled,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setTelevisionMode(bool enabled) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _televisionMode = enabled;
      return setPlayerOrientation(PlayerOrientation.auto);
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<void>('setTelevisionMode', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  static Future<void> setPhoneMode(bool enabled) {
    _phoneMode = enabled;
    return releaseOrientation();
  }

  static Future<void> releaseOrientation() => setPlayerOrientation(
    _phoneMode ? PlayerOrientation.lockedPortrait : PlayerOrientation.auto,
  );

  static Future<void> setPlayerOrientation(
    PlayerOrientation orientation,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await channel.invokeMethod<void>('setPlayerOrientation', {
          'mode': orientation.name,
        });
      } catch (_) {}
      return;
    }
    try {
      await SystemChrome.setPreferredOrientations(switch (_televisionMode
          ? PlayerOrientation.landscape
          : orientation) {
        PlayerOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        PlayerOrientation.lockedLandscape => const [
          DeviceOrientation.landscapeRight,
        ],
        PlayerOrientation.portrait || PlayerOrientation.lockedPortrait =>
          const [DeviceOrientation.portraitUp],
        PlayerOrientation.auto => const [],
      });
    } catch (_) {}
  }

  static Future<double?> brightness() async {
    try {
      return await channel.invokeMethod<double>('getBrightness');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await channel.invokeMethod<void>('setBrightness', {'brightness': value});
    } catch (_) {}
  }

  static Future<void> resetBrightness() async {
    try {
      await channel.invokeMethod<void>('resetBrightness');
    } catch (_) {}
  }

  static Future<double?> volume() async {
    try {
      return await channel.invokeMethod<double>('volume');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setVolume(double value) async {
    try {
      await channel.invokeMethod<void>('setVolume', {'volume': value});
    } catch (_) {}
  }

  static Future<String?> createDocument(String name, String mimeType) async {
    try {
      return await channel.invokeMethod<String>('createDocument', {
        'name': name,
        'mimeType': mimeType,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法创建文件');
    }
  }

  static Future<bool> requestVideoExport() async {
    try {
      return await channel.invokeMethod<bool>('requestVideoExport') ?? false;
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法申请存储权限');
    }
  }

  static Future<void> exportVideo(
    String source,
    String folder,
    String name,
  ) async {
    try {
      await channel.invokeMethod<void>('exportVideo', {
        'source': source,
        'folder': folder,
        'name': name,
      });
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '导出失败');
    }
  }

  static Future<void> deleteDocument(String uri) async {
    try {
      await channel.invokeMethod<bool>('deleteDocument', {'uri': uri});
    } catch (_) {}
  }

  static Future<({int level, bool charging})?> battery() async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('battery');
      final level = data?['level'];
      if (level is! int) return null;
      return (level: level, charging: data?['charging'] == true);
    } catch (_) {
      return null;
    }
  }
}

enum PlayerOrientation {
  landscape,
  lockedLandscape,
  portrait,
  lockedPortrait,
  auto,
}
