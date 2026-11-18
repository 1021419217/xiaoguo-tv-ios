// 91porny（九色）站源模块 · 小果影视 模块 API 1
//
//   列表  /{cate}?page={n}      cate: vod 精品 / video 视频 / videos 蝌蚪 / swag / madou
//   搜索  /search?keywords={kw}&page={n}
//   详情  /vod/view/{code}  或  /video/view/{code}
//   播放  详情页 <video id="video-play" data-src="…index.m3u8?t=&m=">（HLS，无加密，分片小）
//
// 做法与已验证的模块一致：
//   · chapter.videoUrl 用占位符（p91y-play://）
//   · 播放信息在详情页阶段用 host.prepareWebMedia 预处理好并缓存 → 点播放零请求
//   · 拿不到封面时返回空字符串，绝不返回坏地址（否则会把列表封面覆盖成空白）
//
// 模块函数必须同步。

const SITE = 'https://91porny.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

// 注意：站点还有一个「视频」分类（/video），但它 100% 是 /video/viewhd/，
// 属于 VIP 内容，游客只拿到 ~10 秒的预告片（hlsd/js* 路径），点了必然播不出来。
// 所以这里不提供该分类，并在解析时过滤掉 viewhd 条目。
const CATEGORIES = [
  { id: 'vod', name: '精品' },
  { id: 'videos', name: '蝌蚪' },
  { id: 'swag', name: 'SWAG' },
  { id: 'madou', name: '麻豆' }
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
  const res = host.fetch({ method: 'GET', url: url, headers: headers });
  if (res.status === 403) throw new Error('91porny 拦了请求（403）');
  if (res.status < 200 || res.status >= 400) throw new Error('91porny 返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片：<div class="video-elem">
//   <a href="/vod/view/{code}"><div class="img" style="background-image: url('封面')"></div>
//     <small class="layer">时长</small></a>
//   <a class="title …" href="/vod/view/{code}">标题</a>
//   …作者 / 播放量…
// 页面里混着广告卡（外链 alicdn gif），只认 /{vod|video|videos}/view/ 的链接。
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<div class="video-elem[^"]*">/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    // 各分类的详情页路径不一样：/vod/view/、/video/view/、/video/viewhd/、
    // /videos/view/{id}/{slug}/ —— 统一按「种类/动作/后面一串」抓。
    const link = seg.match(/href="\/((?:vod|video|videos)\/(?:view|viewhd)\/[^"#?]+)"/);
    if (!link) continue;
    const code = link[1].replace(/\/+$/, '');
    // viewhd = VIP 预览（只有 ~10 秒预告），直接跳过
    if (code.indexOf('video/viewhd/') === 0) continue;
    if (seen[code]) continue;

    const titleM = seg.match(/<a[^>]*class="title[^"]*"[^>]*>([\s\S]*?)<\/a>/);
    let title = titleM ? clean(titleM[1]) : '';
    if (!title) continue;

    seen[code] = 1;
    // 封面有两种写法：
    //   精品/蝌蚪类：<div class="img" style="background-image: url('https://…png')">
    //   高清类    ：<img class="img" src="//int.ucloud165.xyz/thumb/….jpg">
    let cover = '';
    const bg = seg.match(/background-image:\s*url\('([^']+)'\)/);
    if (bg) cover = bg[1];
    else {
      const img = seg.match(/<img[^>]+class="img"[^>]+src="([^"]+)"/) || seg.match(/<img[^>]+src="([^"]+)"/);
      if (img) cover = img[1];
    }
    cover = String(cover).replace(/&amp;/g, '&');
    if (cover.indexOf('//') === 0) cover = 'https:' + cover;
    const dur = seg.match(/<small class="layer">([^<]*)<\/small>/);
    out.push({
      sourceId: code,
      title: title,
      cover: cover,
      duration: dur ? clean(dur[1]) : ''
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
  const drama = {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: item.duration ? '時長 ' + item.duration : '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
  if (item.author) {
    drama.author = item.author;
    if (item.authorId) drama.authorId = item.authorId;
    if (item.authorUrl) drama.authorUrl = item.authorUrl;
  }
  return drama;
}

function pageOf(key) {
  const k = String(key || '').trim().replace(/^\/+/, '').replace(/\/+$/, '');
  if (!k) throw new Error('缺少视频编号');
  if (/^(?:vod|video|videos)\/(?:view|viewhd)\//.test(k)) return { path: k, url: SITE + '/' + k };
  // 只有编号时默认走精品详情页
  return { path: 'vod/view/' + k, url: SITE + '/vod/view/' + k };
}

// 从详情页取出 m3u8 地址
function mediaOf(html) {
  const tags = html.match(/<video[^>]*>/gi) || [];
  for (const tag of tags) {
    if (tag.indexOf('video-play') < 0 && tag.indexOf('m3u8') < 0) continue;
    const src = (tag.match(/data-src="([^"]+)"/) || [])[1];
    if (src) {
      let url = src.replace(/&amp;/g, '&');
      if (url.indexOf('//') === 0) url = 'https:' + url;
      return url;
    }
  }
  const direct = html.match(/https?:\/\/[^"'\s<>]+\.m3u8[^"'\s<>]*/);
  return direct ? direct[0].replace(/&amp;/g, '&') : '';
}

// 这个站有两种片源：
//   · 精品（/vod）→ 真 HLS（index.m3u8，分片小）
//   · 蝌蚪/SWAG/部分麻豆（/videos、/video/viewhd）→ KVS 的 MP4 直链
// MP4 在 App 里的直读路径不稳（黑屏/连接被重置），所以按已验证的办法
// 包成「单段 HLS」，让播放器走 HLS 分支；时长从页面 video:duration 取。
function mp4DurationMs(html) {
  const m = html.match(/property="video:duration"[^>]*content="(\d+)"/);
  if (m) return Number(m[1]) * 1000;
  const iso = html.match(/"duration"\s*:\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/);
  if (iso) return ((Number(iso[1] || 0) * 3600) + (Number(iso[2] || 0) * 60) + Number(iso[3] || 0)) * 1000;
  return 0;
}

function prepareMedia(html, pageUrl) {
  const url = mediaOf(html);
  if (!url) throw new Error('91porny 詳情頁沒有播放地址');

  if (/\.m3u8(\?|$)/i.test(url)) {
    return host.prepareWebMedia({ url: url, referer: pageUrl, quality: 720 }, '91porny');
  }

  // MP4：包成单段 HLS
  const durationMs = mp4DurationMs(html);
  const seconds = durationMs > 0 ? Math.max(1, Math.round(durationMs / 1000)) : 3600;
  const playlist = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:' + seconds,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    '#EXTINF:' + seconds + ',',
    url,
    '#EXT-X-ENDLIST',
    ''
  ].join('\n');
  return { url: url, playlist: playlist, durationMs: durationMs, referer: pageUrl };
}

function cacheKey(key) {
  return 'ready:' + key;
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
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const cate = (!category || category === 'new') ? 'vod' : category;
    const raw = parseCards(get('/' + cate + '?page=' + n));
    // 缓存标题/封面，打开详情页时不用再下载页面
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const raw = parseCards(get('/search?keywords=' + encodeURIComponent(kw) + '&page=' + n));
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: false };
  },


  // App 点「作者」时调用。这个站没有独立作者主页，用作者名站内搜索，
  // 结果里回填作者字段，方便在二级页继续点。
  author(authorId, authorName, page) {
    const kw = clean(authorName || '') || String(authorId || '').trim();
    if (!kw) return { items: [], hasMore: false, warning: '缺少作者信息' };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    try {
      const raw = parseCards(get('/search?keywords=' + encodeURIComponent(kw) + '&page=' + n));
      const items = raw.map(function (it) {
        it.author = authorName || kw;
        if (authorId) it.authorId = authorId;
        return toDrama(it);
      });
      if (!items.length) return { items: [], hasMore: false, warning: '沒有搜到該作者的作品' };
      return { items: items, hasMore: false };
    } catch (e) {
      return { items: [], hasMore: false, warning: e.message };
    }
  },

  detail(sourceId) {
    const key = String(sourceId || '').trim();
    if (!key) throw new Error('缺少视频编号');
    const page = pageOf(key);

    // 标题/封面优先用列表缓存（详情页秒开）
    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + key);
      if (c) {
        const card = JSON.parse(c);
        title = card.title || '';
        cover = card.cover || '';
      }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get('/' + page.path, SITE + '/'); } catch (e) { html = ''; }

    // 作者只存在于详情页，所以这里总是抓一次；抓失败不影响打开（标题有列表缓存兜底）。
    let author = null;
    if (html) {
      author = parseAuthor(html, key);
      if (!author) host.log('91porny 詳情頁未解析到作者: ' + key);
      if (!title) {
        const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
        if (t) title = clean(t[1]).replace(/\s*[-–|]\s*91(?:porny|视频|自拍|PORNY)[\s\S]*$/i, '').trim();
        if (!title) {
          const og = html.match(/property="og:title"[^>]+content="([^"]*)"/);
          if (og) title = clean(og[1]);
        }
      }
      if (!cover) {
        const poster = html.match(/data-poster="([^"]+)"/);
        if (poster) cover = poster[1].replace(/&amp;/g, '&');
        if (!cover) {
          const og = html.match(/property="og:image:secure_url"[^>]+content="([^"]+)"/) || html.match(/property="og:image"[^>]+content="([^"]+)"/);
          if (og) cover = og[1].replace(/&amp;/g, '&');
        }
      }
      try { host.cacheSet('card:' + key, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    if (!title) title = key;

    // 详情页阶段把播放信息处理好并缓存（走官方 prepareWebMedia）
    try {
      if (!html) { try { html = get('/' + page.path, SITE + '/'); } catch (e) { html = ''; } }
      if (html) {
        const prepared = prepareMedia(html, page.url);
        host.cacheSet(cacheKey(key), JSON.stringify({
          url: prepared.url,
          playlist: prepared.playlist,
          durationMs: prepared.durationMs || 0
        }), 2 * 60 * 1000);
      }
    } catch (e) {
      host.log('91porny 详情页预取失败（播放时会重试）: ' + e.message);
    }

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
        videoUrl: 'p91y-play://' + key,
        pageUrl: page.url,
        referer: page.url
      }]
    };
  },

  resolveMedia(task) {
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) key = fromChapter[1];
    }
    if (!key) throw new Error('無法確定視頻編號');
    const page = pageOf(key);

    // 详情页预取过：零请求
    try {
      const ready = host.cacheGet(cacheKey(key));
      if (ready) {
        const m = JSON.parse(ready);
        if (m.url && m.playlist) {
          return {
            url: m.url,
            playlist: m.playlist,
            referer: page.url,
            quality: 720,
            durationMs: m.durationMs || 0,
            credentials: { referer: page.url, origin: SITE, userAgent: UA }
          };
        }
      }
    } catch (e) { /* 走现场取 */ }

    const html = get('/' + page.path, SITE + '/');
    return prepareMedia(html, page.url);
  }
};
