import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum LiveProtocol { pingtai, list }

class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    this.endpoints = const [],
    this.script = '',
    this.headers = const {},
    this.epg = '',
    this.proxies = const [],
    this.group = '',
    this.adult = false,
    this.builtin = true,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final LiveProtocol protocol;

  /// 同一面板的多个镜像。它们共享内容但各自维护分类子集，合并后按分类路由。
  final List<String> endpoints;
  final String script;

  String get endpoint => endpoints.isEmpty ? '' : endpoints.first;
  final Map<String, String> headers;
  final String epg;

  /// 取流代理前缀。源站直连被拒时按顺序作为候选线路拼在原始地址前。
  final List<String> proxies;

  /// 列表型源没有分组信息时的默认分组名。
  final String group;

  /// 成人站源。绿色模式开启时整个源不出现在直播里。
  final bool adult;
  final bool builtin;
  final bool enabled;

  /// 是否支持按页续载。整类一次返回的源不参与滚动加载。
  bool get paginated => protocol == LiveProtocol.list;

  /// 随包内置的直播源，直接从全剧TV 搬过来，装好即用、无需任何配置。
  static const values = <LiveSource>[
    LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: [
        'http://api.vipmisss.com:81/xcdsw',
        'http://api.hclyz.com:81/mf',
      ],
      adult: true,
    ),
  ];

  /// 运行时注入的外部直播源（由模块/设置页配置），与内置列表合并。
  static List<LiveSource> externalSources = <LiveSource>[];

  static bool _externalLoaded = false;

  /// 从应用文档目录的 live_sources.json 读取外置直播源（不随包内置）。
  /// 支持两种格式：
  ///   [{"id":"..","name":"..","endpoints":["地址1","地址2"],"adult":false}]
  ///   {"sources":[ ... 同上 ... ]}
  /// 文件缺失或损坏时静默跳过，只加载一次。
  static Future<void> loadExternal() async {
    if (_externalLoaded) return;
    _externalLoaded = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}live_sources.json',
      );
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      final list = switch (decoded) {
        final List l => l,
        final Map m => m['sources'] as List?,
        _ => null,
      };
      if (list == null) return;
      for (final item in list) {
        if (item is! Map) continue;
        final endpoints = [
          for (final e in (item['endpoints'] as List? ?? const [])) '$e',
        ].where((e) => e.trim().isNotEmpty).toList();
        if (endpoints.isEmpty) continue;
        final id = '${item['id'] ?? item['name'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        final source = LiveSource(
          id: id,
          name: '${item['name'] ?? id}',
          description: '${item['description'] ?? ''}',
          protocol: LiveProtocol.pingtai,
          endpoints: endpoints,
          group: '${item['group'] ?? ''}',
          adult: item['adult'] == true,
          builtin: false,
        );
        externalSources.removeWhere((s) => s.id == id);
        externalSources.add(source);
      }
    } catch (_) {
      // 配置损坏时忽略，保持空态提示，不影响应用其它功能。
    }
  }

  static List<LiveSource> get all => <LiveSource>[
    ...values,
    ...externalSources,
  ];

  /// 绿色模式放行的分类白名单：只展示公开电视 / 广播 / 新闻类频道，
  /// 未被白名单命中的分类一律隐藏。配置外部源时可按需扩充关键词。
  static final _greenCategory = RegExp(
    r'(卫视|央视|CCTV|CGTN|电视直播|广播|新闻|体育|财经|少儿|纪录|地方台|剧场|电影|电视剧)',
    caseSensitive: false,
  );

  /// 绿色模式下的直播可见性：成人源整源隐藏，成人分类单独隐藏。
  static List<LiveSource> visible(bool greenMode) => [
    for (final source in all)
      if (!greenMode || !source.adult) source,
  ];

  static bool hidesCategory(String name, {required bool greenMode}) =>
      greenMode && !_greenCategory.hasMatch(name);

  /// 在既有内置源之外追加一个源，仅用于验证绿色模式的整源过滤。
  static List<LiveSource> spreadWith(
    LiveSource extra, {
    required bool greenMode,
  }) => [
    for (final source in [...all, extra])
      if (!greenMode || !source.adult) source,
  ];

  static LiveSource? byId(String id) =>
      all.where((source) => source.id == id).firstOrNull;

  static bool isBuiltin(String id) => all.any((source) => source.id == id);

  LiveSource copyWith({bool? enabled}) => LiveSource(
    id: id,
    name: name,
    description: description,
    protocol: protocol,
    endpoints: endpoints,
    script: script,
    headers: headers,
    epg: epg,
    proxies: proxies,
    group: group,
    adult: adult,
    builtin: builtin,
    enabled: enabled ?? this.enabled,
  );
}
