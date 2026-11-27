// MyJav cn.myjav.tv 站源模块 · 小果影视 模块 API 1
//
//   最新      /videos?x=updated          分页 &page={n}
//   分类      /videos?t={tag}            标签维度（巨乳/素人/人妻…）
//   搜索      /videos?k={词}             注意是 k，不是 q/keyword（实测那些参数无效）
//   详情      /video/{code}              code 形如 ABW-339 / 10musume-112026_01
//   演员      /actor?id={id}             详情页演员链接
//   播放      /hls/{hash}/master.m3u8    与 xChina 同套 HLS，AES-128
//
// 与 xChina / 视色 同一套程序：封面 CDN（r2.xchina.download）、HLS 结构一致，
// 但路由与字段位置不同（信息在 <span class="detail-label"> 的详情表里，无 JSON-LD）。
// 列表/详情 curl 带完整浏览器指纹即可 200。
// 模块函数必须同步。

const SITE = 'https://cn.myjav.tv';
const COVER = 'https://r2.xchina.download/cover/';

const BROWSER_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  'sec-ch-ua': '"Chromium";v="131", "Not_A Brand";v="24"',
  'sec-ch-ua-mobile': '?0',
  'sec-ch-ua-platform': '"Windows"',
  'Sec-Fetch-Dest': 'document',
  'Sec-Fetch-Mode': 'navigate',
  'Sec-Fetch-Site': 'none',
  'Sec-Fetch-User': '?1',
  'Upgrade-Insecure-Requests': '1'
};

// 分类 = 最新 + 站点真实标签（/tags 页核对过）。path 已含查询串。
const CATEGORIES = [
  { id: 'new',     name: '最新',   path: '/videos?x=updated' },
  { id: 'bigtits', name: '巨乳',   path: '/videos?t=Big+Tits' },
  { id: 'amateur', name: '素人',   path: '/videos?t=Amateur' },
  { id: 'married', name: '人妻',   path: '/videos?t=Married+Woman' },
  { id: 'beauty',  name: '美少女', path: '/videos?t=Beautiful+Girl' },
  { id: 'mature',  name: '熟女',   path: '/videos?t=Mature+Woman' },
  { id: 'uniform', name: '制服',   path: '/videos?t=Uniform' },
  { id: 'maid',    name: '女仆',   path: '/videos?t=Maid' },
  { id: 'best',    name: '精选',   path: '/videos?t=Best' }
];

function categoryPath(id) {
  for (let i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i].path;
  }
  return CATEGORIES[0].path;
}

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&hellip;/g, '…')
    .replace(/\s+/g, ' ')
    .trim();
}

function get(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const res = host.fetch({ method: 'GET', url: url, headers: BROWSER_HEADERS });
  if (res.status === 403) throw new Error('MyJav 拦截了请求（Cloudflare 403）');
  if (res.status < 200 || res.status >= 300) throw new Error('MyJav 返回 HTTP ' + res.status);
  return res.body || '';
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const base = categoryPath(category);
  return n === 1 ? base : base + '&page=' + n;
}

// ── 列表卡片 ────────────────────────────────────────────────
// <div class="video-card"><a href="/video/SDNM-569">
//   <div class="video-cover" style="background-image:url('…/cover/xxx.webp')">
//     <span class="video-vol-tag">SDNM-569</span>
//     <span class="video-duration">02:37:25</span></div>
//   <div class="video-info"><h3 class="video-title">标题</h3>…
function parseCards(html) {
  const out = [];
  const seen = {};
  const src = String(html || '');
  const re = /<a\b[^>]*href="\/video\/([^"\/?#]+)"[^>]*>([\s\S]{0,2600}?)<\/a>/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const code = m[1];
    if (!code || seen[code]) continue;
    seen[code] = 1;
    const chunk = m[2];
    const bg = chunk.match(/background-image:\s*url\(['"]?([^'")]+)/);
    const dur = chunk.match(/video-duration">\s*([0-9]{1,3}:[0-9]{2}(?::[0-9]{2})?)/);
    const ti = chunk.match(/video-title">([\s\S]{1,200}?)<\/h3>/);
    const vol = chunk.match(/video-vol-tag">([^<]{1,40})/);
    let title = ti ? clean(ti[1]) : '';
    if (!title && vol) title = clean(vol[1]);
    out.push({
      sourceId: code,
      title: title || code,
      cover: bg ? bg[1] : '',
      duration: dur ? dur[1] : '',
      vol: vol ? clean(vol[1]) : ''
    });
  }
  return out;
}

function toDrama(item) {
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: item.title,
    name: item.title,
    durationText: item.duration || '',
    desc: '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
}

// ── 详情表 ──────────────────────────────────────────────────
// <span class="detail-label">时长:</span><span class="detail-value">02:19:42</span>
// <span class="detail-label">片商:</span><span class="detail-value"><a …>PRESTIGE,プレステージ</a>
function detailValue(html, label) {
  const re = new RegExp(
    '<span class="detail-label">\\s*' + label + '\\s*[:：]?\\s*</span>\\s*' +
    '<span class="detail-value[^"]*">([\\s\\S]{0,600}?)</span>',
    'i'
  );
  const m = String(html || '').match(re);
  return m ? m[1] : '';
}

// 演员名去掉括号里的日文/罗马音：凉森玲梦 (涼森れむ Suzumori Remu) → 凉森玲梦
function actorName(raw) {
  const full = clean(raw);
  const bare = full.replace(/[（(][^）)]*[）)]/g, '').trim();
  return (bare || full).slice(0, 24);
}

function parseActors(html) {
  const out = [];
  const seen = {};
  const re = /<a\b[^>]*href="\/actor\?id=([A-Za-z0-9]+)"[^>]*>([\s\S]{0,160}?)<\/a>/g;
  let m;
  while ((m = re.exec(String(html || ''))) !== null) {
    const id = m[1];
    if (!id || seen[id]) continue;
    seen[id] = 1;
    const name = actorName(m[2]);
    if (!name) continue;
    out.push({ author: name, authorId: id, authorUrl: SITE + '/actor?id=' + id });
  }
  return out;
}

// ── 播放列表 ────────────────────────────────────────────────
function m3u8DurationMs(text) {
  let total = 0;
  const re = /#EXTINF:([0-9.]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) total += parseFloat(m[1]) || 0;
  return Math.round(total * 1000);
}

function hlsHash(html) {
  const m = String(html || '').match(/\/hls\/([0-9a-f]{10,16})\/master\.m3u8/);
  return m ? m[1] : '';
}

function playlistBundle(code) {
  const page = SITE + '/video/' + code;
  const html = get('/video/' + code);
  const hash = hlsHash(html);
  if (!hash) throw new Error('MyJav 未返回播放地址');
  const masterUrl = SITE + '/hls/' + hash + '/master.m3u8';
  const master = get(masterUrl);
  let bestUrl = '';
  let bestBandwidth = -1;
  const lines = master.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.charAt(0) === '#') continue;
    const prev = (lines[i - 1] || '').trim();
    const bandwidth = Number((prev.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const absolute = line.indexOf('http') === 0
      ? line
      : masterUrl.replace(/master\.m3u8.*$/, '') + line;
    if (bandwidth > bestBandwidth) { bestBandwidth = bandwidth; bestUrl = absolute; }
  }
  if (!bestUrl) return { url: masterUrl, playlist: master, durationMs: m3u8DurationMs(master) };
  const variant = get(bestUrl);
  if (variant.indexOf('#EXTM3U') < 0) throw new Error('MyJav 播放列表无效');
  return { url: bestUrl, playlist: variant, durationMs: m3u8DurationMs(variant) };
}

function cacheKey(code) { return 'playlist:' + code; }

module.exports = {
  validCategory(category) {
    return !category || CATEGORIES.some(function (e) { return e.id === category; });
  },

  categories() { return CATEGORIES; },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('没有分类 ' + category);
    const items = parseCards(get(listPath(category, page))).map(toDrama);
    return { items: items, hasMore: items.length >= 10 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const q = '/videos?k=' + encodeURIComponent(kw) + (n > 1 ? '&page=' + n : '');
    const items = parseCards(get(q)).map(toDrama);
    return { items: items, hasMore: items.length >= 10 };
  },

  author(authorId, authorName, page) {
    const id = String(authorId == null ? '' : authorId).replace(/[^A-Za-z0-9]/g, '');
    const name = clean(authorName || '');
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    if (!id) return { items: [], hasMore: false };
    const url = '/actor?id=' + id + (n > 1 ? '&page=' + n : '');
    const items = parseCards(get(url)).map(function (it) {
      const d = toDrama(it);
      d.author = name || id;
      d.authorId = id;
      d.authorUrl = SITE + '/actor?id=' + id;
      return d;
    });
    return { items: items, hasMore: items.length >= 10 };
  },

  detail(sourceId) {
    const code = String(sourceId == null ? '' : sourceId).trim();
    if (!code) throw new Error('缺少视频编号');
    const page = SITE + '/video/' + code;
    const html = get('/video/' + code);

    const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
    let title = t ? clean(t[1]) : '';
    // 页面 title 形如「ABW-339 - 标题」或「ABW-339 - 标题 - MyJav」；去掉番号前缀
    title = title.replace(/^[A-Za-z0-9_.-]+\s*-\s*/, '').replace(/\s*-\s*MyJav.*$/i, '').trim();
    const cover = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
    const desc = html.match(/<meta[^>]+name="description"[^>]+content="([^"]*)"/);

    const drama = {
      id: host.dramaId(code),
      source: host.source,
      sourceId: code,
      title: title || code,
      name: title || code,
      desc: desc ? clean(desc[1]).substring(0, 120) : '',
      intro: '',
      cover: cover ? cover[1] : '',
      totalEpisode: 1
    };

    try {
      const actors = parseActors(html);
      if (actors.length) {
        drama.author = actors[0].author;
        drama.authorId = actors[0].authorId;
        drama.authorUrl = actors[0].authorUrl;
        drama.actors = actors.map(function (a) { return a.author; });
      }
      const durRaw = clean(detailValue(html, '时长'));
      const dur = durRaw.match(/[0-9]{1,3}:[0-9]{2}(?::[0-9]{2})?/);
      if (dur) drama.durationText = dur[0];
      const date = clean(detailValue(html, '发布日') || detailValue(html, '发布')).match(/\d{4}-\d{2}-\d{2}/);
      if (date) drama.onlineDate = date[0];
      const maker = clean(detailValue(html, '片商'));
      if (maker) drama.maker = maker;
      const series = clean(detailValue(html, '系列'));
      if (series) drama.series = series;
      const label = clean(detailValue(html, '类别'));
      if (label) drama.category = label;
    } catch (e) {
      host.log('MyJav 详情解析异常: ' + e.message);
    }

    const chapter = {
      id: host.chapterId(code, 'video'),
      source: host.source,
      title: title || '正片',
      currentEpisode: 1,
      pageUrl: page,
      referer: page
    };

    try {
      host.cacheSet(cacheKey(code), JSON.stringify(playlistBundle(code)), 10 * 60 * 1000);
    } catch (e) {
      host.log('MyJav 预取播放列表失败: ' + e.message);
    }
    return { drama: drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    let code = '';
    const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
    if (fromChapter.length >= 2) code = fromChapter[1];
    if (!code) {
      const fromDrama = String((task && task.dramaId) || '').split(':');
      if (fromDrama.length >= 2) code = fromDrama[1];
    }
    code = String(code || '').trim();
    if (!code) throw new Error('无法确定视频编号');

    let bundle = null;
    try {
      const cached = host.cacheGet(cacheKey(code));
      if (cached) bundle = JSON.parse(cached);
    } catch (e) { bundle = null; }
    if (!bundle || !bundle.url || !bundle.playlist) {
      bundle = playlistBundle(code);
      try { host.cacheSet(cacheKey(code), JSON.stringify(bundle), 10 * 60 * 1000); } catch (e) {}
    }
    return host.prepareWebMedia({
      url: bundle.url,
      playlist: bundle.playlist,
      durationMs: bundle.durationMs,
      referer: SITE + '/video/' + code
    });
  }
};
