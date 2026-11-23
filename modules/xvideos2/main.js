// XVIDEOS 站源模块 · 小果影视 模块 API 1
//
//   列表  /new/{n}            最新
//         /best/{yyyy-mm}/{n} 本月最佳
//         /tags/{tag}/{n}     标签（japanese / chinese / asian / amateur …）
//         /c/{Name-id}/{n}    分类（Big_Tits-23 / Anal-12 / Blowjob-15 …）
//   搜索  /?k={关键词}&p={n}
//   详情  /video.{code}/{slug}
//   作者  上传者 /{slug}、模特 /amateurs/{slug} 或 /pornstars/{slug}
//
// 播放源三层兜底：
//   1) setVideoHLS('…hls.m3u8')         → 抓 master 选最高不超过 1080p 的变体
//   2) setVideoUrlHigh/Low('…mp4')      → 包成单段 HLS
//   3) JSON-LD VideoObject.contentUrl   → 同样包成单段 HLS
// 第三层是 1.3.0 新加的：有些视频页面不再输出 setVideoHLS，但结构化数据里
// 仍然带 mp4 直链，之前只认前两层，表现就是「详情页没有找到播放地址」。
//
// 站点自带多语言，Accept-Language 带 zh-CN 时界面和分类名都是中文。
// 模块函数必须同步。

const SITE = 'https://www.xvideos.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

// 注意：App 的 ValidNativeCategory 会拒绝含 "/" "|" "\" 的分类 id
//（见 app_categories.go：strings.ContainsAny(category, "|/\\\x00\r\n")），
// 所以 id 必须是无斜杠的 slug，真实路径放在 path 里。
const CATEGORIES = [
  { id: 'new', name: '最新', path: '/new/' },
  { id: 'best', name: '本月最佳', path: '/best/' },
  { id: 'japanese', name: '日本', path: '/tags/japanese' },
  { id: 'chinese', name: '中文', path: '/tags/chinese' },
  { id: 'asian', name: '亞洲', path: '/tags/asian' },
  { id: 'amateur', name: '業餘', path: '/tags/amateur' },
  { id: 'bigtits', name: '巨乳', path: '/c/Big_Tits-23' },
  { id: 'bigass', name: '大屁股', path: '/c/Big_Ass-24' },
  { id: 'anal', name: '肛交', path: '/c/Anal-12' },
  { id: 'blowjob', name: '口交', path: '/c/Blowjob-15' },
  { id: 'mature', name: '成熟', path: '/c/Mature-38' },
  { id: 'blonde', name: '金髮', path: '/c/Blonde-20' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&Atilde;/g, 'ã').replace(/&otilde;/g, 'õ').replace(/&ccedil;/g, 'ç')
    .replace(/&aacute;/g, 'á').replace(/&eacute;/g, 'é').replace(/&iacute;/g, 'í')
    .replace(/&oacute;/g, 'ó').replace(/&uacute;/g, 'ú').replace(/&acirc;/g, 'â')
    .replace(/&ecirc;/g, 'ê').replace(/&ocirc;/g, 'ô').replace(/&agrave;/g, 'à')
    .replace(/\s+/g, ' ')
    .trim();
}

function get(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const headers = {};
  for (const k in HEADERS) headers[k] = HEADERS[k];
  headers['Referer'] = referer || SITE + '/';
  const res = host.fetch({ method: 'GET', url: url, headers: headers, followRedirects: true });
  if (res.status < 200 || res.status >= 300) throw new Error('XVIDEOS 返回 HTTP ' + res.status);
  return res.body || '';
}

function absolute(href) {
  const h = String(href == null ? '' : href).trim();
  if (!h) return '';
  if (h.indexOf('//') === 0) return 'https:' + h;
  if (h.indexOf('http') === 0) return h;
  return SITE + (h.charAt(0) === '/' ? h : '/' + h);
}

// 从作者/模特 li 片段里取显示名：名字后面可能跟着订阅数、icon，
// 按「到 user-subscribe / count / </a> 为止」截断再去标签。
function nameIn(seg) {
  const m = String(seg || '').match(/<span class="name">([\s\S]{0,300}?)(?:<span class="user-subscribe"|<span class="count"|<\/a>|<\/li>)/);
  return m ? clean(m[1]) : '';
}

function formatDuration(ms) {  const total = Math.round(Number(ms || 0) / 1000);
  if (total <= 0) return '';
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const ss = s < 10 ? '0' + s : String(s);
  if (h > 0) return h + ':' + (m < 10 ? '0' + m : m) + ':' + ss;
  return m + ':' + ss;
}

// 卡片：<div class="thumb"><a href="/video.{code}/{slug}"><img data-src="…">
//         <span class="video-hd-mark">1080p</span><span class="video-cc-mark">CC</span>
//       <div class="thumb-under"><p class="title"><a title="标题">标题 <span class="duration">10分钟</span>
//       <p class="metadata"><a href="/{uploader}"><span class="name">上传者</span></a> …
function parseCards(html) {
  const out = [];
  const seen = {};
  // 列表结构有两套：/new、/tags 卡片带 data-eid，/best 没有；
  // 模特/作者页外层是 thumb-block，主切分失败再按更宽松的容器切。
  let parts = html.split(/<div class="thumb">/);
  if (parts.length < 2) parts = html.split(/<div[^>]+class="[^"]*\bthumb-block\b[^"]*"[^>]*>/);
  if (parts.length < 2) parts = html.split(/<div[^>]+class="[^"]*\bthumb\b[^"]*"[^>]*>/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    const code = (seg.match(/href="\/video\.([a-z0-9]+)\//) || [])[1] || '';
    if (!code || seen[code]) continue;

    let title = '';
    const tAttr = seg.match(/<p class="title"[^>]*>\s*<a[^>]+title="([^"]+)"/) ||
                  seg.match(/class="title"[^>]*\stitle="([^"]+)"/) ||
                  seg.match(/<a[^>]+href="\/video\.[a-z0-9]+\/[^"]*"[^>]+\stitle="([^"]+)"/);
    if (tAttr) title = clean(tAttr[1]);
    if (!title) {
      const alt = seg.match(/<img[^>]+\salt="([^"]+)"/);
      if (alt) title = clean(alt[1]);
    }
    if (!title) {
      const t2 = seg.match(/class="title"[^>]*>([\s\S]*?)<\/p>/);
      if (t2) title = clean(t2[1].replace(/<span class="duration">[\s\S]*?<\/span>/g, ''));
    }
    if (!title) continue;
    seen[code] = 1;

    const img = seg.match(/<img[^>]+\sdata-src="(https:\/\/thumb[^"]+)"/) ||
                seg.match(/<img[^>]+\sdata-src="([^"]+)"/);
    const dur = seg.match(/<span class="duration">([^<]*)<\/span>/);
    const hd = seg.match(/class="video-hd-mark">([^<]*)</);

    // 字幕角标：视频卡片右上角的 CC 标记
    const tags = [];
    if (/class="video-cc-mark"/.test(seg)) tags.push('字幕');

    // 上传者：<p class="metadata"> 里第一个 <a href="/{slug}"><span class="name">
    let author = '';
    let authorId = '';
    let authorUrl = '';
    const up = seg.match(/<p class="metadata">[\s\S]{0,400}?<a href="\/([A-Za-z0-9_.\-]+)"[^>]*>\s*<span class="name">([^<]+)<\/span>/);
    if (up) {
      authorId = up[1];
      author = clean(up[2]);
      authorUrl = SITE + '/' + up[1];
    }

    out.push({
      sourceId: code,
      title: title,
      cover: img ? img[1].replace(/&amp;/g, '&') : '',
      durationText: dur ? clean(dur[1]) : '',
      badge: hd ? clean(hd[1]) : '',
      tags: tags,
      author: author,
      authorId: authorId,
      authorUrl: authorUrl
    });
  }
  return out;
}

// 详情页元数据：作者 / 女优 / 片商 / 日期 / 标签 / 时长 / 直链
//
// 页面结构（2026-11 实测）：
//   <div class="video-metadata …"><ul>
//     <li class="main-uploader"><a href="/{slug}"><span class="name">上传者</span>
//     <li class="model"><a href="/amateurs/{slug}"><span class="name">女优</span>
//   <a href="/tags/{tag}" class="is-keyword …">标签</a>
//   <script type="application/ld+json">{"@type":"VideoObject","uploadDate":…,"duration":"PT…","contentUrl":"…mp4"}</script>
function detailMeta(html) {
  const meta = {
    author: '', authorId: '', authorUrl: '',
    actors: [], maker: '', onlineDate: '', tags: [],
    durationMs: 0, contentUrl: ''
  };
  if (!html) return meta;

  const at = html.indexOf('class="video-metadata');
  const block = at >= 0 ? html.slice(at, at + 20000) : '';
  if (block) {
    // 名字可能被 icon / 订阅数包着（<span class="name"><span class="icon-…"/></span> 名字</span>），
    // 所以按「到 user-subscribe 或 </a> 为止」截一段再清标签。
    const upLi = block.match(/<li class="main-uploader">([\s\S]{0,1200}?)<\/li>/);
    if (upLi) {
      const href = upLi[1].match(/<a href="\/([A-Za-z0-9_.\-]+)"/);
      if (href) {
        meta.authorId = href[1];
        meta.authorUrl = SITE + '/' + href[1];
      }
      meta.author = nameIn(upLi[1]);
    }
    // 模特可能有多个，全部收进 actors
    const modelRe = /<li class="model">([\s\S]{0,1200}?)<\/li>/g;
    let m;
    while ((m = modelRe.exec(block)) !== null) {
      const name = nameIn(m[1]);
      if (name && meta.actors.indexOf(name) < 0) meta.actors.push(name);
    }
    // 片商 / 频道
    const ch = block.match(/<li class="(?:channel|pornstar-channel)">([\s\S]{0,1200}?)<\/li>/);
    if (ch) meta.maker = nameIn(ch[1]);
  }

  // 上传者缺失时退到旧模板的 uploader 区
  if (!meta.author) {
    const legacy = html.match(/class="[^"]*uploader[^"]*"[\s\S]{0,200}?<a href="\/([A-Za-z0-9_.\-]+)"[^>]*>([^<]{1,40})</);
    if (legacy) {
      meta.authorId = legacy[1];
      meta.author = clean(legacy[2]);
      meta.authorUrl = SITE + '/' + legacy[1];
    }
  }

  const tagRe = /<a href="\/tags\/([^"\/]+)"[^>]*class="[^"]*is-keyword[^"]*"[^>]*>([^<]{1,40})</g;
  let t;
  while ((t = tagRe.exec(html)) !== null) {
    const value = clean(t[2]) || clean(t[1]);
    if (value && meta.tags.indexOf(value) < 0 && meta.tags.length < 20) meta.tags.push(value);
  }

  const ldAt = html.indexOf('"@type": "VideoObject"');
  const ldText = ldAt >= 0 ? html.slice(Math.max(0, ldAt - 200), ldAt + 1600) : html;
  const date = ldText.match(/"uploadDate"\s*:\s*"(\d{4}-\d{2}-\d{2})/);
  if (date) meta.onlineDate = date[1];
  const dur = ldText.match(/"duration"\s*:\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/);
  if (dur) {
    meta.durationMs = (Number(dur[1] || 0) * 3600 + Number(dur[2] || 0) * 60 + Number(dur[3] || 0)) * 1000;
  }
  const cu = ldText.match(/"contentUrl"\s*:\s*"([^"]+)"/);
  if (cu) meta.contentUrl = cu[1].replace(/\\\//g, '/');
  return meta;
}

function monthPath() {
  const now = new Date();
  const m = now.getUTCMonth() + 1;
  return now.getUTCFullYear() + '-' + (m < 10 ? '0' + m : String(m));
}

function listPath(category, page) {
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = !category ? 'new' : String(category);
  const meta = CATEGORIES.filter(function (c) { return c.id === id; })[0];
  if (id === 'new') return '/new/' + p;
  if (id === 'best') return '/best/' + monthPath() + (p > 1 ? '/' + p : '');
  if (!meta) return '/new/' + p;
  return meta.path + (p > 1 ? '/' + p : '');
}

// 播放源三层兜底：HLS / 页面内 mp4 / 结构化数据 contentUrl
function sourcesOf(html, meta) {
  const hls = (html.match(/setVideoHLS\(\s*'([^']+)'/) || html.match(/setVideoHLS\(\s*"([^"]+)"/) || [])[1] || '';
  const high = (html.match(/setVideoUrlHigh\(\s*'([^']+)'/) || html.match(/setVideoUrlHigh\(\s*"([^"]+)"/) || [])[1] || '';
  const low = (html.match(/setVideoUrlLow\(\s*'([^']+)'/) || html.match(/setVideoUrlLow\(\s*"([^"]+)"/) || [])[1] || '';
  const fromLd = (meta && meta.contentUrl) || (html.match(/"contentUrl"\s*:\s*"([^"]+)"/) || [])[1] || '';
  const generic = (html.match(/https:\/\/[a-z0-9.\-]*xvideos-cdn\.com\/[^"'\s\\]+\.mp4[^"'\s\\]*/i) || [])[0] || '';
  return { hls: hls, high: high, low: low, mp4: high || low || fromLd.replace(/\\\//g, '/') || generic };
}

// master 里挑变体：优先 1080p 封顶，没有则取能拿到的最高
function bestVariant(masterText, baseUrl) {
  const lines = String(masterText || '').split(/\r?\n/);
  const variants = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.charAt(0) === '#') continue;
    const prev = (lines[i - 1] || '').trim();
    const res = prev.match(/RESOLUTION=(\d+)x(\d+)/);
    const bw = Number((prev.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const abs = line.indexOf('http') === 0 ? line : baseUrl.replace(/[^\/]*$/, '') + line;
    variants.push({ url: abs, height: res ? Number(res[2]) : 0, bandwidth: bw });
  }
  if (!variants.length) return '';
  const capped = variants.filter(function (v) { return v.height > 0 && v.height <= 1080; });
  const pool = capped.length ? capped : variants;
  let best = pool[0];
  for (const v of pool) {
    if (v.height > best.height || (v.height === best.height && v.bandwidth > best.bandwidth)) best = v;
  }
  return best.url;
}

function wrapMp4(mp4, durationMs) {
  const seconds = durationMs > 0 ? Math.max(1, Math.round(durationMs / 1000)) : 3600;
  const playlist = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:' + seconds,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    '#EXTINF:' + seconds + ',',
    mp4,
    '#EXT-X-ENDLIST',
    ''
  ].join('\n');
  return { url: mp4, playlist: playlist, durationMs: durationMs || 0 };
}

function prepareMedia(html, pageUrl) {
  const meta = detailMeta(html);
  const src = sourcesOf(html, meta);
  const durationMs = meta.durationMs;

  if (src.hls) {
    try {
      const master = get(src.hls, pageUrl);
      const variant = bestVariant(master, src.hls);
      if (variant) {
        const prepared = host.prepareWebMedia({ url: variant, referer: pageUrl, quality: 1080 }, 'XVIDEOS');
        if (prepared && prepared.playlist) {
          prepared.durationMs = prepared.durationMs || durationMs;
          return prepared;
        }
      }
    } catch (e) { /* 退回 master 本身 */ }
    return host.prepareWebMedia({ url: src.hls, referer: pageUrl, quality: 1080 }, 'XVIDEOS');
  }

  // 没有 HLS：用最高画质 MP4，包成单段 HLS（App 的 MP4 直读路径不稳）
  if (src.mp4) {
    const media = wrapMp4(src.mp4, durationMs);
    media.referer = pageUrl;
    return media;
  }

  // 走到这里说明页面里连 mp4 都没有，把原因带出去，方便定位是「视频没了」还是「解析漏了」
  let hint = '页面为空，可能被站点拦截';
  if (html && html.length > 0) {
    hint = html.indexOf('video-metadata') >= 0
      ? '页面有视频信息但没有播放源，可能该视频已被移除或限制地区'
      : '页面没有视频信息，可能视频已删除或链接失效';
  }
  throw new Error('XVIDEOS 没有找到播放地址：' + hint);
}

function readyKey(code) { return 'ready:' + code; }

function searchImpl(page, query) {
  const kw = clean(query || '');
  if (!kw) return { items: [], hasMore: false };
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  // xvideos 对查不到的词会直接 404，这里按「无结果」处理
  let body = '';
  try { body = get('/?k=' + encodeURIComponent(kw) + (p > 1 ? '&p=' + p : '')); } catch (e) { body = ''; }
  const raw = parseCards(body);
  for (const it of raw) {
    try { host.cacheSet('card:' + it.sourceId, JSON.stringify(it), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
  }
  return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
}

// 作者作品页：上传者频道页没有视频列表，能出作品的是模特/成人星页，
// 所以按「模特页 → 上传者频道页 → 名字搜索」依次试，第一个能出卡片的就用。
function authorPage(authorId, authorName, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = String(authorId == null ? '' : authorId).trim().replace(/^\/+|\/+$/g, '');
  const name = clean(authorName || '');
  if (!id && !name) return { items: [], hasMore: false, warning: '缺少作者信息' };

  const suffix = n > 1 ? '/' + n : '';
  const candidates = [];
  if (id) {
    candidates.push('/amateurs/' + id + suffix);
    candidates.push('/pornstars/' + id + suffix);
    candidates.push('/profiles/' + id + suffix);
    if (n <= 1) {
      candidates.push('/' + id);
      candidates.push('/model/' + id);
    }
  }

  for (const path of candidates) {
    try {
      const html = get(path);
      const raw = parseCards(html);
      if (!raw.length) continue;

      const items = raw.map(function (it) {
        if (!it.author && name) {
          it.author = name;
          it.authorId = id;
          it.authorUrl = SITE + '/' + id;
        }
        try { host.cacheSet('card:' + it.sourceId, JSON.stringify(it), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
        return toDrama(it);
      });

      // 分页控件里出现下一页的链接才算还有更多，光看条数会误判。
      const hasNext = new RegExp('/(?:amateurs|pornstars|profiles)/[^"\\s]*/' + (n + 1) + '(?=[^0-9]|$)|[?&]p=' + (n + 1) + '(?=[^0-9]|$)').test(html);
      return { items: items, hasMore: hasNext || items.length >= 20 };
    } catch (e) {
      try { host.log('XVIDEOS 作者页失败(' + path + '): ' + e.message); } catch (err) { /* 忽略 */ }
    }
  }

  // 只在第一页退回搜索，翻页时退回会把搜索结果当作者作品，出现重复卡片。
  if (name && n <= 1) {
    try {
      const r = searchImpl(n, name);
      if (r && r.items && r.items.length) {
        r.items = r.items.map(function (d) {
          if (!d.author) {
            d.author = name;
            if (id) {
              d.authorId = id;
              d.authorUrl = SITE + '/' + id;
            }
          }
          return d;
        });
        return { items: r.items, hasMore: r.hasMore };
      }
    } catch (e) { /* 走空结果 */ }
  }

  return { items: [], hasMore: false, warning: '沒有取到該作者的作品' };
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  const drama = {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
  // 卡片上的时长 / 清晰度 / 字幕走专用字段，塞进 desc 界面不读
  if (item.durationText) drama.durationText = item.durationText;
  if (item.badge) drama.badge = item.badge;
  if (item.tags && item.tags.length) drama.tags = item.tags.slice();
  if (item.author) {
    drama.author = item.author;
    if (item.authorId) drama.authorId = item.authorId;
    if (item.authorUrl) drama.authorUrl = item.authorUrl;
  }
  return drama;
}

module.exports = {
  validCategory(category) {
    return !category || category === 'new' || CATEGORIES.some(function (e) { return e.id === category; });
  },

  categories() {
    return CATEGORIES;
  },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('沒有分類 ' + category);
    const raw = parseCards(get(listPath(category, page)));
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify(it), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
  },

  search(page, query) {
    return searchImpl(page, query);
  },

  // App 点「作者」时调用：模特页 → 上传者频道页 → 名字搜索
  author(authorId, authorName, page) {
    return authorPage(authorId, authorName, page);
  },

  detail(sourceId) {
    const code = String(sourceId || '').trim().match(/^[a-z0-9]+$/);
    if (!code) throw new Error('視頻 ID 無效');
    const key = code[0];
    // 详情必须带一段 slug 或序号；/1 会被站点重定向到规范地址
    const pageUrl = SITE + '/video.' + key + '/1';

    let cached = null;
    try { cached = JSON.parse(String(host.cacheGet('card:' + key) || 'null')); } catch (e) { cached = null; }
    let title = (cached && cached.title) || '';
    let cover = (cached && cached.cover) || '';

    let html = '';
    try { html = get('/video.' + key + '/1'); } catch (e) { if (!title) throw e; }

    let meta = null;
    if (html) {
      meta = detailMeta(html);
      if (!meta.author) {
        try { host.log('XVIDEOS 詳情頁未解析到作者: ' + key); } catch (e) { /* 忽略 */ }
      }
      if (!title) {
        const t = html.match(/setVideoTitle\(\s*'((?:[^'\\]|\\.)*)'\s*\)/);
        if (t) title = clean(t[1].replace(/\\'/g, "'"));
        if (!title) {
          const og = html.match(/property="og:title"[^>]+content="([^"]*)"/);
          if (og) title = clean(og[1]).replace(/\s*-\s*XVIDEOS[\s\S]*$/i, '').trim();
        }
      }
      if (!cover) {
        const og = html.match(/property="og:image"[^>]+content="([^"]+)"/);
        if (og) cover = og[1].replace(/&amp;/g, '&');
      }
      // 详情页只缓存播放地址（几百字节），播放时再抓变体列表，
      // 这样详情页能秒开，不在详情里抓 master。
      try {
        const src = sourcesOf(html, meta);
        const pack = { hls: src.hls, mp4: src.mp4, durationMs: meta.durationMs };
        if (pack.hls || pack.mp4) host.cacheSet('srcs:' + key, JSON.stringify(pack), 5 * 60 * 1000);
      } catch (e) {
        try { host.log('XVIDEOS 播放地址缓存失敗: ' + e.message); } catch (err) { /* 忽略 */ }
      }
      try {
        host.cacheSet('card:' + key, JSON.stringify({
          sourceId: key, title: title, cover: cover,
          author: meta.author, authorId: meta.authorId, authorUrl: meta.authorUrl
        }), 30 * 60 * 1000);
      } catch (e) { /* 忽略 */ }
    }

    if (!title) title = key;

    const drama = {
      id: host.dramaId(key),
      source: host.source,
      sourceId: key,
      title: title,
      name: title,
      desc: '',
      intro: '',
      cover: cover,
      totalEpisode: 1
    };
    if (meta) {
      // 作者三件套：点进去看这个上传者的其他作品
      const author = meta.author || (cached && cached.author) || '';
      const authorId = meta.authorId || (cached && cached.authorId) || '';
      const authorUrl = meta.authorUrl || (cached && cached.authorUrl) || '';
      if (author) drama.author = author;
      if (authorId) drama.authorId = authorId;
      if (authorUrl) drama.authorUrl = authorUrl;
      if (meta.actors.length) drama.actors = meta.actors.slice();
      if (meta.maker) drama.maker = meta.maker;
      if (meta.onlineDate) drama.onlineDate = meta.onlineDate;
      if (meta.tags.length) drama.tags = meta.tags.slice();
      if (meta.durationMs > 0) drama.durationText = formatDuration(meta.durationMs);
    }

    return {
      drama: drama,
      chapters: [{
        id: host.chapterId(key, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'xvideos-play://' + key,
        pageUrl: pageUrl,
        referer: pageUrl
      }]
    };
  },

  resolveMedia(task) {
    // 2 分钟内重复点播直接复用上次结果（0 请求），过短过期或缓存缺失才重新解析
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) key = fromChapter[1];
    }
    try {
      const done = host.cacheGet('done:' + key);
      if (done) {
        const m = JSON.parse(done);
        if (m.url && m.playlist) {
          return {
            url: m.url,
            playlist: m.playlist,
            referer: m.referer || '',
            quality: 1080,
            durationMs: m.durationMs || 0,
            credentials: { referer: m.referer || '', userAgent: UA }
          };
        }
      }
    } catch (e) { /* 忽略 */ }

    const media = module.exports.resolveMediaOnce(task);
    try {
      if (media && media.url && media.playlist) {
        host.cacheSet('done:' + key, JSON.stringify({
          url: media.url,
          playlist: media.playlist,
          durationMs: media.durationMs || 0,
          referer: media.referer || ''
        }), 2 * 60 * 1000);
      }
    } catch (e) { /* 忽略 */ }
    return media;
  },

  resolveMediaOnce(task) {
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) key = fromChapter[1];
    }
    if (!key) throw new Error('無法確定視頻 ID');
    const pageUrl = SITE + '/video.' + key + '/1';

    // 详情页已经存好 master 地址，这里只要 master + 变体列表两个小请求
    try {
      const cached = host.cacheGet('srcs:' + key);
      if (cached) {
        const c = JSON.parse(cached);
        if (c.hls) {
          const master = get(c.hls, pageUrl);
          const variant = bestVariant(master, c.hls);
          if (variant) {
            const prepared = host.prepareWebMedia({ url: variant, referer: pageUrl, quality: 1080 }, 'XVIDEOS');
            if (prepared && prepared.playlist) {
              prepared.durationMs = prepared.durationMs || c.durationMs || 0;
              return prepared;
            }
          }
        }
        if (c.mp4) {
          const media = wrapMp4(c.mp4, c.durationMs || 0);
          media.referer = pageUrl;
          return media;
        }
      }
    } catch (e) { /* 走现场取 */ }

    const html = get('/video.' + key + '/1');
    return prepareMedia(html, pageUrl);
  }
};
