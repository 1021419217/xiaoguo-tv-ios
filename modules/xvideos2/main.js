// XVIDEOS 站源模块 · 小果影视 模块 API 1
//
//   列表  /new/{n}            最新
//         /best/{yyyy-mm}/{n} 本月最佳
//         /tags/{tag}/{n}     标签（japanese / chinese / asian / amateur …）
//         /c/{Name-id}/{n}    分类（Big_Tits-23 / Anal-12 / Blowjob-15 …）
//   搜索  /?k={关键词}&p={n}
//   详情  /video.{code}/{slug}
//   播放  详情页里直接有：
//           setVideoHLS('https://hls-cdn77.xvideos-cdn.com/…/hls.m3u8')
//           setVideoUrlHigh('…mp4')  setVideoUrlLow('…mp4')
//         优先 HLS（master 里有 360p/480p/1080p），没有再退回 MP4 包成单段 HLS。
//
// 站点自带多语言，Accept-Language 带 zh-CN 时整个界面和分类名都是中文。
// 没有 Cloudflare 拦截，普通请求即可。
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

// 卡片：<div class="frame-block thumb-block" data-id="{数字}" data-eid="{code}">
//         <a href="/video.{code}/{slug}">
//           <img data-src="缩略图" …><span class="video-hd-mark">1080p</span>
//         <p class="title"><a href="…" title="标题">标题 <span class="duration">15分钟</span></a></p>
function parseCards(html) {
  const out = [];
  const seen = {};
  // 两种列表结构都按卡片容器切：<div class="thumb"><a … href="/video.{code}/{slug}">
  //   /new、/tags：卡片带 data-eid，标题在 <p class="title"><a title="…">
  //   /best：卡片没有 data-eid，标题在 <div class="title" title="…"><a …>
  // 模特/作者页的卡片外层类是 thumb-block（不带 "thumb" 单值），
  // 所以主切分失败时再按更宽松的容器切一次，避免作者页永远解析出 0 条。
  let parts = html.split(/<div class="thumb">/);
  if (parts.length < 2) parts = html.split(/<div[^>]+class="[^"]*\bthumb-block\b[^"]*"[^>]*>/);
  if (parts.length < 2) parts = html.split(/<div[^>]+class="[^"]*\bthumb\b[^"]*"[^>]*>/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    const code = (seg.match(/href="\/video\.([a-z0-9]+)\//) || [])[1] || '';
    if (!code || seen[code]) continue;

    let title = '';
    const tAttr = seg.match(/class="title"[^>]*\stitle="([^"]+)"/) ||
                  seg.match(/<p class="title"[^>]*>\s*<a[^>]+\stitle="([^"]+)"/) ||
                  seg.match(/<a[^>]+href="\/video\.[a-z0-9]+\/[^"]*"[^>]+\stitle="([^"]+)"/);
    if (tAttr) title = clean(tAttr[1]);
    if (!title) {
      const alt = seg.match(/<img[^>]+\salt="([^"]+)"/);
      if (alt) title = clean(alt[1]);
    }
    if (!title) {
      const t2 = seg.match(/class="title"[^>]*>([\s\S]*?)<\/div>/);
      if (t2) title = clean(t2[1].replace(/<span class="duration">[\s\S]*?<\/span>/g, ''));
    }
    if (!title) continue;

    seen[code] = 1;
    const img = seg.match(/<img[^>]+\sdata-src="(https:\/\/thumb[^"]+)"/) ||
                seg.match(/<source[^>]+\sdata-srcset="(https:\/\/[^"\s]+\.jpg)"/) ||
                seg.match(/<img[^>]+\sdata-src="([^"]+)"/);
    const dur = seg.match(/<span class="duration">([^<]*)<\/span>/);
    const hd = seg.match(/class="video-hd-mark">([^<]*)</);
    out.push({
      sourceId: code,
      title: title,
      cover: img ? img[1].replace(/&amp;/g, '&') : '',
      duration: dur ? clean(dur[1]) : '',
      quality: hd ? clean(hd[1]) : ''
    });
  }
  return out;
}
// ── 作者 / 上传者 ──────────────────────────────────────────────
// 关键教训：详情页里除了「本视频的作者」，还有推荐位、侧栏、其他卡片，
// 它们同样带作者链接。按「页面里第一个匹配」取会稳定取到站方固定的推荐位，
// 表现就是「每个视频点进去都是同一个作者、都是那几条作品」。
// 所以这里的做法是：
//   1) 先把「本视频的信息区」截出来（标题附近 → 相关推荐/评论之前）；
//   2) 在信息区里优先认「带作者类名的区块」和「作者标签 + 链接/文本」；
//   3) 认不到就在信息区里按出现次数投票，出现两次以上的才算；
//   4) 信息区没有才看全页，且必须明显胜出（≥3 次且多于其他候选之和）;
//   5) 最后才用结构化数据。全都不满足就返回 null（宁可没有，也不能全站同一个人）。

const AUTHOR_LINK_RE = /<a[^>]+href="([^"]*(?:\/model\/|\/pornstars?\/|\/profiles?\/|\/channels?\/|\/users?\/|\/uvideos\.php\?UID=|\/author\/|\/uploader\/|\/member\/)[^"]*)"[^>]*>([\s\S]{0,160}?)<\/a>/gi;

// 本视频的信息区：从标题前后开始，到「相关推荐 / 评论 / 标签」为止。
// 作者块有的模板在标题上方，所以起始位置往前多留 3000 字符。
function infoRegion(html) {
  if (!html) return '';
  let start = 0;
  const t = html.search(/<h1[\s>]|video-title|videoTitle|id="viewvideo-title"|class="[^"]*(?:video-detail|video-info)[^"]*"/i);
  if (t > 0) start = Math.max(0, t - 3000);
  const tail = html.slice(start);
  const c = tail.search(/相关视频|相關視頻|猜你喜欢|猜你喜歡|推荐视频|推薦視頻|相關推薦|related-videos|id="related"|comments?|评论|評論|留言|id="video-tags"/i);
  if (c > 0) return tail.slice(0, c);
  return tail;
}

function hostAbsolute(href) {
  const h = String(href == null ? '' : href).trim();
  if (!h) return '';
  if (h.indexOf('//') === 0) return 'https:' + h;
  if (h.indexOf('http') === 0) return h;
  return SITE + (h.charAt(0) === '/' ? h : '/' + h);
}

function authorIdOf(href) {
  const s = String(href || '');
  let m = s.match(/[?&]UID=(\d+)/i);
  if (m) return m[1];
  m = s.match(/\/(?:model|pornstars?|profiles?|channels?|users?|author|uploader|member|u)\/([A-Za-z0-9\-_.]+)/i);
  return m ? m[1] : '';
}

// 列出所有作者链接（保留重复，重复次数就是投票数）
function authorCandidates(html) {
  const out = [];
  if (!html) return out;
  AUTHOR_LINK_RE.lastIndex = 0;
  let m;
  while ((m = AUTHOR_LINK_RE.exec(html)) !== null) {
    const name = clean(m[2]);
    if (!name) continue;
    const id = authorIdOf(m[1]);
    if (!id && !name) continue;
    out.push({ author: name, authorId: id, authorUrl: hostAbsolute(m[1]) });
  }
  return out;
}

// 投票：返回出现次数最多的候选，以及它的票数和总票数
function voteAuthor(list) {
  const buckets = {};
  for (const a of list) {
    const key = String(a.authorId || a.author).toLowerCase();
    if (!key) continue;
    if (!buckets[key]) buckets[key] = { info: a, n: 0, names: {} };
    buckets[key].n += 1;
    buckets[key].names[a.author] = (buckets[key].names[a.author] || 0) + 1;
  }
  let best = null;
  let total = 0;
  for (const key in buckets) {
    total += buckets[key].n;
    if (!best || buckets[key].n > best.n) best = buckets[key];
  }
  return { best: best, total: total };
}

// 信息区里按「作者标签 / 作者类名区块」精确取
function labeledAuthor(region) {
  if (!region) return null;
  let m;

  m = region.match(/class="(?:[^"]*\s)?(?:author|uploader|video-user|user-info|model|pornstar|channel)[^"]*"[\s\S]{0,200}?<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,160}?)<\/a>/i);
  if (m) {
    const name = clean(m[2]);
    if (name) return { author: name, authorId: authorIdOf(m[1]), authorUrl: hostAbsolute(m[1]) };
  }

  m = region.match(/(?:作者|上传者|上传|发布者|UP主|up主|主演|演员|模特|女优|Owner|Uploader|Author|Uploaded\s*by|Model|Pornstar|Starring)\s*[:：]?\s*(?:<\/?[a-z][^>]*>\s*)*<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,160}?)<\/a>/i);
  if (m) {
    const name = clean(m[2]);
    if (name) return { author: name, authorId: authorIdOf(m[1]), authorUrl: hostAbsolute(m[1]) };
  }

  m = region.match(/(?:作者|上传者|发布者|UP主|up主|主演|演员|模特|女优|Owner|Uploader|Uploaded\s*by)\s*[:：]\s*(?:<\/?[a-z][^>]*>\s*)*([^<\r\n]{1,40})/i);
  if (m) {
    const name = clean(m[1]);
    if (name && name.length <= 30 && name.indexOf('/') < 0 && name.indexOf('http') < 0) {
      return { author: name, authorId: '', authorUrl: '' };
    }
  }
  return null;
}

// 投票结果属于弱证据：如果连续好几个不同的视频都投给同一个作者，
// 基本可以断定取到的是站方固定的推荐位，直接丢弃（宁可没有作者，也不能全站同一个人）。
function authorHistoryLooksBroken(key, info) {
  if (!info || !key) return false;
  const sig = String(info.authorId || info.author).toLowerCase();
  let hist = [];
  try { hist = JSON.parse(String(host.loadState('author-hist') || '[]')); } catch (e) { hist = []; }
  if (!hist || typeof hist.length !== 'number') hist = [];
  const distinct = {};
  for (const h of hist) {
    if (h && h.a === sig && h.k) distinct[h.k] = 1;
  }
  if (!distinct[key] && Object.keys(distinct).length >= 3) {
    try { host.log('作者疑似固定推荐位，已丢弃: ' + sig); } catch (e) { /* 忽略 */ }
    return true;
  }
  hist.unshift({ k: key, a: sig });
  if (hist.length > 12) hist = hist.slice(0, 12);
  try { host.saveState('author-hist', JSON.stringify(hist)); } catch (e) { /* 忽略 */ }
  return false;
}

function parseAuthor(html, key) {
  if (!html) return null;
  const region = infoRegion(html);

  // ① 信息区里的作者标签 / 作者区块（最贴近本视频）
  const labeled = labeledAuthor(region);
  if (labeled) return labeled;

  // ② 结构化数据：VideoObject 的 author 通常就是本条视频的作者。
  //    页面里出现多次就不可信（可能是推荐列表的 ItemList），跳过。
  const lds = html.match(/"author"\s*:\s*\{[^}]{0,300}?"name"\s*:\s*"([^"]{1,60})"/gi) || [];
  if (lds.length === 1) {
    const nm = lds[0].match(/"name"\s*:\s*"([^"]{1,60})"/i);
    if (nm) {
      const name = clean(nm[1]);
      if (name) return { author: name, authorId: '', authorUrl: '' };
    }
  }

  // ③ 信息区内投票：出现两次以上才认（出现一次的很可能只是推荐位擦边）
  const inRegion = voteAuthor(authorCandidates(region));
  if (inRegion.best && inRegion.best.n >= 2) {
    if (authorHistoryLooksBroken(key, inRegion.best.info)) return null;
    return inRegion.best.info;
  }

  // ④ 全页的作者标签 / 作者区块（信息区截取不准时的补救），但要确认全页也是同一个人
  const labeledAll = labeledAuthor(html);
  if (labeledAll) {
    const key = String(labeledAll.authorId || labeledAll.author).toLowerCase();
    const all = authorCandidates(html);
    const same = all.filter(function (a) { return String(a.authorId || a.author).toLowerCase() === key; }).length;
    if (all.length === 0 || same >= 1) return labeledAll;
  }

  // ⑤ 全页投票：必须明显胜出（≥3 次，且多于其他候选之和）
  const whole = voteAuthor(authorCandidates(html));
  if (whole.best && whole.best.n >= 3 && whole.best.n > (whole.total - whole.best.n)
      && !authorHistoryLooksBroken(key, whole.best.info)) {
    return whole.best.info;
  }

  return null;
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  const bits = [];
  if (item.quality) bits.push(item.quality);
  if (item.duration) bits.push(item.duration);
  const drama = {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: bits.join(' · '),
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
  // 作者三件套：有了它详情页才会出现作者胶囊，点进去看这个上传者的全部作品。
  if (item.author) {
    drama.author = item.author;
    if (item.authorId) drama.authorId = item.authorId;
    if (item.authorUrl) drama.authorUrl = item.authorUrl;
  }
  return drama;
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
  if (id === 'new') return '/new/' + p;                       // 站点没有 /new，只能从 /new/1 起
  if (id === 'best') return '/best/' + monthPath() + (p > 1 ? '/' + p : '');
  if (!meta) return '/new/' + p;
  return meta.path + (p > 1 ? '/' + p : '');
}

// 详情页里的播放地址
function sourcesOf(html) {
  const hls = (html.match(/setVideoHLS\(\s*'([^']+)'/) || html.match(/setVideoHLS\(\s*"([^"]+)"/) || [])[1] || '';
  const high = (html.match(/setVideoUrlHigh\(\s*'([^']+)'/) || html.match(/setVideoUrlHigh\(\s*"([^"]+)"/) || [])[1] || '';
  const low = (html.match(/setVideoUrlLow\(\s*'([^']+)'/) || html.match(/setVideoUrlLow\(\s*"([^"]+)"/) || [])[1] || '';
  const mp4 = (html.match(/setVideoUrl\(\s*'([^']+)'/) || [])[1] || '';
  return { hls: hls, high: high, low: low, mp4: mp4 };
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

function durationOf(html) {
  const m = html.match(/property="video:duration"[^>]+content="(\d+)"/);
  if (m) return Number(m[1]) * 1000;
  const iso = html.match(/"duration"\s*:\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/);
  if (iso) return ((Number(iso[1] || 0) * 3600) + (Number(iso[2] || 0) * 60) + Number(iso[3] || 0)) * 1000;
  return 0;
}

function prepareMedia(html, pageUrl) {
  const src = sourcesOf(html);
  const durationMs = durationOf(html);

  if (src.hls) {
    try {
      const master = get(src.hls, pageUrl);
      const variant = bestVariant(master, src.hls);
      if (variant) return host.prepareWebMedia({ url: variant, referer: pageUrl, quality: 1080 }, 'XVIDEOS');
    } catch (e) { /* 退回 master 本身 */ }
    return host.prepareWebMedia({ url: src.hls, referer: pageUrl, quality: 1080 }, 'XVIDEOS');
  }

  // 没有 HLS：用最高画质 MP4，包成单段 HLS（App 的 MP4 直读路径不稳）
  const mp4 = src.high || src.mp4 || src.low || '';
  if (mp4) {
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
    return { url: mp4, playlist: playlist, durationMs: durationMs, referer: pageUrl };
  }
  throw new Error('XVIDEOS 詳情頁沒有找到播放地址');
}

function readyKey(code) { return 'ready:' + code; }

// 搜索主体抽成函数，作者页取不到时复用（不依赖 this 绑定）。
function searchImpl(page, query) {
  const kw = clean(query || '');
  if (!kw) return { items: [], hasMore: false };
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  // xvideos 对查不到的词会直接 404，这里按「无结果」处理
  let body = '';
  try { body = get('/?k=' + encodeURIComponent(kw) + (p > 1 ? '&p=' + p : '')); } catch (e) { body = ''; }
  const raw = parseCards(body);
  for (const it of raw) {
    try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
  }
  return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
}

// 作者主页：profile 形态有三种，逐个试，第一个能解析出卡片的就用。
// 都失败再按作者名搜索兜底，保证「点进作者」不至于一片空白。
function authorPage(authorId, authorName, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = String(authorId == null ? '' : authorId).trim().replace(/^\/+|\/+$/g, '');
  const name = clean(authorName || '');
  if (!id && !name) return { items: [], hasMore: false, warning: '缺少作者信息' };

  const candidates = [];
  if (id) {
    if (n > 1) {
      candidates.push('/model/' + id + '/' + n);
      candidates.push('/model/' + id + '?p=' + n);
    } else {
      candidates.push('/model/' + id);
      candidates.push('/pornstars/' + id);
      candidates.push('/profiles/' + id);
    }
  }

  for (const path of candidates) {
    try {
      const html = get(path);
      const raw = parseCards(html);
      if (!raw.length) continue;

      const items = raw.map(function (it) {
        it.author = name || id;
        it.authorId = id;
        it.authorUrl = SITE + '/model/' + id;
        const drama = toDrama(it);
        try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
        return drama;
      });

      // 分页控件里出现下一页的链接才算还有更多，光看条数会误判。
      const hasNext = new RegExp('/model/[^"\\s]*/' + (n + 1) + '(?=[^0-9]|$)|[?&]p=' + (n + 1) + '(?=[^0-9]|$)').test(html);
      return { items: items, hasMore: hasNext || items.length >= 20 };
    } catch (e) {
      host.log('XVIDEOS 作者页失败(' + path + '): ' + e.message);
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
            if (id) { d.authorId = id; d.authorUrl = SITE + '/model/' + id; }
          }
          return d;
        });
        return { items: r.items, hasMore: r.hasMore };
      }
    } catch (e) { /* 走空结果 */ }
  }

  return { items: [], hasMore: false, warning: '沒有取到該作者的作品' };
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
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
  },

  search(page, query) {
    return searchImpl(page, query);
  },

  // App 点「作者」时调用：作者主页（model / profiles / pornstars 依次试）→ 名字搜索 → 空
  author(authorId, authorName, page) {
    return authorPage(authorId, authorName, page);
  },

  detail(sourceId) {
    const code = String(sourceId || '').trim().match(/^[a-z0-9]+$/);
    if (!code) throw new Error('視頻 ID 無效');
    const key = code[0];
    // 详情必须带一段 slug 或序号；/1 会被站点重定向到规范地址
    const pageUrl = SITE + '/video.' + key + '/1';

    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + key);
      if (c) { const card = JSON.parse(c); title = card.title || ''; cover = card.cover || ''; }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get('/video.' + key + '/1'); } catch (e) { if (!title) throw e; }

    let author = null;
    if (html) {
      author = parseAuthor(html, key);
      if (!author) host.log('XVIDEOS 詳情頁未解析到作者: ' + key);
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
      try { host.cacheSet('card:' + key, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }

      // 详情页只缓存 master 地址（几百字节），不在这里抓列表：
      // 详情页要秒开，点播放时再抓 master(约 200B) + 变体列表(约 10KB)。
      try {
        const src = sourcesOf(html);
        if (src.hls) {
          host.cacheSet('srcs:' + key, JSON.stringify({ hls: src.hls, durationMs: durationOf(html) }), 5 * 60 * 1000);
        }
      } catch (e) {
        host.log('XVIDEOS 播放地址缓存失敗: ' + e.message);
      }
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
    if (author) {
      drama.author = author.author;
      if (author.authorId) drama.authorId = author.authorId;
      if (author.authorUrl) drama.authorUrl = author.authorUrl;
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
    // 详情必须带一段 slug 或序号；/1 会被站点重定向到规范地址
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
              try {
                host.cacheSet('done:' + key, JSON.stringify({
                  url: prepared.url,
                  playlist: prepared.playlist,
                  durationMs: prepared.durationMs || 0
                }), 2 * 60 * 1000);
              } catch (e) { /* 忽略 */ }
              return prepared;
            }
          }
        }
      }
    } catch (e) { /* 走现场取 */ }

    const html = get('/video.' + key + '/1');
    return prepareMedia(html, pageUrl);
  }
};
