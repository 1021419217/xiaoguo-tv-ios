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

  // 小果 2.0 起站源不再随安装包提供，改由「模块」页外置安装 / 配置。
  // 这里保留数据模型与绿色模式能力，但不内置任何具体直播源地址。
  // 需要接入时由宿主把配置好的 LiveSource 列表写入 externalSources。
  static const values = <LiveSource>[];

  /// 运行时注入的外部直播源（由模块/设置页配置），与内置列表合并。
  static List<LiveSource> externalSources = <LiveSource>[];

  static List<LiveSource> get all => <LiveSource>[...values, ...externalSources];

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
