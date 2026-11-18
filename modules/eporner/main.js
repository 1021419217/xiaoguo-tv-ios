// EPORNER 站源模块 · 小果影视 模块 API 1
//
// 列表/搜索走官方 JSON 接口（30 条/页、有准确总页数、没有广告卡）：
//   GET /api/v2/video/search/?query={q}&order={order}&per_page=30&page={p}&thumbsize=big&format=json
// 详情用页面（title / og:image / EP.video.player.hash）：
//   GET /video-{code}/{slug}/
// 播放走接口：
//   GET /xhr/video/{code}?hash={base36 转换后的 hash}&device=generic&domain=…&supportedFormats=hls,mp4&tech=Html5&_={ts}
//   返回 sources.hls（多码率 master）与 sources.mp4（240p→1080p 直链）
//
// 关键点：页面里的 hash 是 32 位十六进制，接口要把它按 4 段各 8 位转 base36 再拼接，
// 直接传会报 "Authorization failed. Try to reload page."
//
// 站点 UI 没有中文（pl/en/fr/es/pt/it/de/nl/tl/ja），但搜索支持中文关键词。
// 模块函数必须同步。

const SITE = 'https://www.eporner.com';
const HOST = 'www.eporner.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

// id 形如 "o:latest"（order=latest, query=all）或 "q:japanese"（query=japanese）
const CATEGORIES = [
  { id: 'o:latest', name: '最新上傳' },
  { id: 'o:top-weekly', name: '本週熱門' },
  { id: 'o:top-monthly', name: '本月熱門' },
  { id: 'o:most-popular', name: '最受歡迎' },
  { id: 'o:top-rated', name: '好評最多' },
  { id: 'q:1080p', name: '高清1080P' },
  { id: 'q:japanese', name: '日本' },
  { id: 'q:asian', name: '亞洲' },
  { id: 'q:chinese', name: '中文' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function get(path, referer, json) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const headers = {};
  for (const k in HEADERS) headers[k] = HEADERS[k];
  if (json) headers['Accept'] = 'application/json';
  headers['Referer'] = referer || SITE + '/';
  const res = host.fetch({ method: 'GET', url: url, headers: headers, followRedirects: true });
  if (res.status < 200 || res.status >= 300) throw new Error('EPORNER 返回 HTTP ' + res.status);
  return res.body || '';
}

function clockText(seconds) {
  const s = Number(seconds || 0);
  if (!s) return '';
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = function (n) { return n < 10 ? '0' + n : String(n); };
  return h > 0 ? h + ':' + pad(m) + ':' + pad(sec) : m + ':' + pad(sec);
}

// 列表接口：{ videos: [ {id,title,length_sec,views,default_thumb:{src},keywords,url} ], total_pages }
function parseApi(body) {
  let json;
  try { json = JSON.parse(body || '{}'); } catch (e) { throw new Error('EPORNER 列表接口返回的不是 JSON'); }
  const videos = Array.isArray(json.videos) ? json.videos : [];
  const items = [];
  for (const v of videos) {
    const id = String(v.id || '');
    const title = clean(v.title || '');
    if (!/^[A-Za-z0-9]+$/.test(id) || !title) continue;
    const thumb = (v.default_thumb && v.default_thumb.src) || (Array.isArray(v.thumbs) && v.thumbs[0] && v.thumbs[0].src) || '';
    items.push({
      sourceId: id,
      title: title,
      cover: String(thumb).replace(/&amp;/g, '&'),
      duration: clockText(v.length_sec),
      views: Number(v.views || 0),
      tags: String(v.keywords || '').split(',').map(clean).filter(Boolean).slice(0, 6)
    });
  }
  return { items: items, pages: Number(json.total_pages || 0) };
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  const bits = [];
  if (item.duration) bits.push('時長 ' + item.duration);
  if (item.views) bits.push(item.views >= 10000 ? Math.round(item.views / 10000) + '萬次觀看' : item.views + '次觀看');
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: bits.join(' · '),
    intro: '',
    cover: item.cover || '',
    tags: item.tags || [],
    totalEpisode: 1
  };
}

function apiPath(query, order, page) {
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  return '/api/v2/video/search/?query=' + encodeURIComponent(query) +
    '&order=' + encodeURIComponent(order) + '&per_page=30&page=' + p + '&thumbsize=big&format=json';
}

// 32 位十六进制 → 4 段各转 base36 再拼接
function hashParam(hash) {
  const h = String(hash || '');
  if (!/^[0-9a-f]{32}$/i.test(h)) return '';
  let out = '';
  for (let i = 0; i < 4; i++) out += parseInt(h.substr(i * 8, 8), 16).toString(36);
  return out;
}

function playback(code, hash, referer) {
  const param = hashParam(hash);
  if (!param) throw new Error('EPORNER 頁面裡沒有播放憑證');
  const query = 'hash=' + param +
    '&device=generic&domain=' + HOST +
    '&fallback=false&embed=false' +
    '&supportedFormats=hls,mp4&tech=Html5' +
    '&_=' + Date.now();
  const res = host.fetch({
    method: 'GET',
    url: SITE + '/xhr/video/' + code + '?' + query,
    headers: { 'User-Agent': UA, 'Referer': referer, 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' }
  });
  if (res.status < 200 || res.status >= 300) throw new Error('EPORNER 接口返回 HTTP ' + res.status);
  let json;
  try { json = JSON.parse(res.body || '{}'); } catch (e) { throw new Error('EPORNER 接口返回的不是 JSON'); }
  if (!json || json.available !== true) {
    throw new Error('EPORNER 這個視頻目前不可用（' + (json && json.message ? json.message : '未知原因') + '）');
  }
  return json;
}

// master 里挑变体：优先 1080p 封顶（4K 码率太高压不住），没有则挑能拿到的最高
function bestVariant(masterText, baseUrl) {
  const lines = String(masterText || '').split(/\r?\n/);
  const variants = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.charAt(0) === '#') continue;
    const prev = (lines[i - 1] || '').trim();
    const bw = Number((prev.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const res = prev.match(/RESOLUTION=(\d+)x(\d+)/);
    const height = res ? Number(res[2]) : 0;
    const abs = line.indexOf('http') === 0 ? line : baseUrl.replace(/[^\/]*$/, '') + line;
    variants.push({ url: abs, bandwidth: bw, height: height });
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

function prepareMedia(json, referer) {
  const sources = (json && json.sources) || {};
  const durationMs = Number(json.duration || 0) * 1000;

  if (sources.hls) {
    const keys = Object.keys(sources.hls);
    const auto = sources.hls.auto || sources.hls[keys[0]];
    const masterUrl = auto && auto.src ? auto.src : '';
    if (masterUrl) {
      try {
        const master = get(masterUrl, referer);
        const variant = bestVariant(master, masterUrl);
        if (variant) return host.prepareWebMedia({ url: variant, referer: referer, quality: 1080 }, 'EPORNER');
      } catch (e) { /* 退回 master 本身 */ }
      return host.prepareWebMedia({ url: masterUrl, referer: referer, quality: 1080 }, 'EPORNER');
    }
  }

  // 没有 HLS：取最高清晰度 MP4，包成单段 HLS（App 的 MP4 直读路径不稳）
  if (sources.mp4) {
    const labels = Object.keys(sources.mp4);
    let pick = '';
    let pickHeight = -1;
    for (const label of labels) {
      const src = sources.mp4[label] && sources.mp4[label].src;
      if (!src) continue;
      const h = Number((label.match(/(\d{3,4})p/) || [])[1] || 0);
      if (h > pickHeight) { pickHeight = h; pick = src; }
    }
    if (pick) {
      const seconds = durationMs > 0 ? Math.max(1, Math.round(durationMs / 1000)) : 3600;
      const playlist = [
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:' + seconds,
        '#EXT-X-MEDIA-SEQUENCE:0',
        '#EXT-X-PLAYLIST-TYPE:VOD',
        '#EXTINF:' + seconds + ',',
        pick,
        '#EXT-X-ENDLIST',
        ''
      ].join('\n');
      return { url: pick, playlist: playlist, durationMs: durationMs, referer: referer };
    }
  }
  throw new Error('EPORNER 沒有返回可用的播放地址');
}

// 从接口返回里取 HLS master 地址
function hlsMaster(json) {
  const sources = (json && json.sources) || {};
  if (!sources.hls) return '';
  const keys = Object.keys(sources.hls);
  const auto = sources.hls.auto || sources.hls[keys[0]];
  return (auto && auto.src) ? auto.src : '';
}

// 详情页缓存了 master：抓 master → 挑 1080p 封顶那一档 → 交给 App
function prepareFromMaster(master, pageUrl) {
  const text = get(master, pageUrl);
  const variant = bestVariant(text, master);
  if (!variant) return host.prepareWebMedia({ url: master, referer: pageUrl, quality: 1080 }, 'EPORNER');
  return host.prepareWebMedia({ url: variant, referer: pageUrl, quality: 1080 }, 'EPORNER');
}

function readyKey(code) { return 'ready:' + code; }

module.exports = {
  validCategory(category) {
    return !category || category === 'new' || CATEGORIES.some(function (e) { return e.id === category; });
  },

  categories() {
    return CATEGORIES;
  },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('沒有分類 ' + category);
    const id = (!category || category === 'new') ? 'o:latest' : String(category);
    const isQuery = id.indexOf('q:') === 0;
    const value = id.slice(2);
    const result = parseApi(get(isQuery ? apiPath(value, 'latest', page) : apiPath('all', value, page), SITE + '/', true));
    for (const it of result.items) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: result.items.map(toDrama), hasMore: result.pages > 0 ? Number(page || 1) < result.pages : result.items.length >= 25 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const result = parseApi(get(apiPath(kw, 'latest', page), SITE + '/', true));
    for (const it of result.items) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: result.items.map(toDrama), hasMore: result.pages > 0 ? Number(page || 1) < result.pages : false };
  },

  detail(sourceId) {
    const code = String(sourceId || '').trim().match(/^[A-Za-z0-9]+$/);
    if (!code) throw new Error('視頻 ID 無效');
    const key = code[0];
    const pageUrl = SITE + '/video-' + key + '/';

    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + key);
      if (c) { const card = JSON.parse(c); title = card.title || ''; cover = card.cover || ''; }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get('/video-' + key + '/'); } catch (e) { if (!title) throw e; }

    if (html) {
      if (!title) {
        const og = html.match(/property="og:title"[^>]+content="([^"]*)"/);
        if (og) title = clean(og[1]).replace(/\s*-\s*EPORNER[\s\S]*$/i, '').trim();
        if (!title) {
          const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
          if (t) title = clean(t[1]).replace(/\s*-\s*EPORNER[\s\S]*$/i, '').trim();
        }
      }
      if (!cover) {
        const og = html.match(/property="og:image"[^>]+content="([^"]+)"/);
        if (og) cover = og[1].replace(/&amp;/g, '&');
      }
      try { host.cacheSet('card:' + key, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }

      // 详情页只缓存 master 地址（几百字节），不在这里抓列表：
      // 详情页要快，点播放时再抓 master + 变体列表两个小请求。
      try {
        const hash = (html.match(/player\.hash\s*=\s*'([0-9a-f]{32})'/) || html.match(/player\.hash\s*=\s*"([0-9a-f]{32})"/) || [])[1] || '';
        if (hash) {
          const json = playback(key, hash, pageUrl);
          const master = hlsMaster(json);
          if (master) {
            // master 只有 2KB 左右，顺手抓下来挑好最高档，播放时就不用再取一次
            let variant = '';
            try {
              variant = bestVariant(get(master, pageUrl), master);
            } catch (e) { /* 挑失败就留空，播放时再处理 */ }
            host.cacheSet('srcs:' + key, JSON.stringify({
              master: master,
              variant: variant,
              durationMs: Number(json.duration || 0) * 1000
            }), 5 * 60 * 1000);
          }
        }
      } catch (e) {
        host.log('EPORNER 播放地址缓存失敗: ' + e.message);
      }
    }
    if (!title) title = key;

    return {
      drama: {
        id: host.dramaId(key),
        source: host.source,
        sourceId: key,
        title: title,
        name: title,
        desc: '',
        intro: '',
        cover: cover,
        totalEpisode: 1
      },
      chapters: [{
        id: host.chapterId(key, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'eporner-play://' + key,
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
            credentials: { referer: m.referer || '', origin: (typeof SITE !== 'undefined' ? SITE : ''), userAgent: UA }
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
    const pageUrl = SITE + '/video-' + key + '/';

    // 详情页已经存好 master 地址，这里只要 master + 变体列表两个小请求
    try {
      const cached = host.cacheGet('srcs:' + key);
      if (cached) {
        const c = JSON.parse(cached);
        // 详情页已挑好变体：直接抓这一档的播放列表（1 个请求）
        if (c.variant) {
          const prepared = host.prepareWebMedia({ url: c.variant, referer: pageUrl, quality: 1080 }, 'EPORNER');
          if (prepared && prepared.playlist) {
            prepared.durationMs = prepared.durationMs || c.durationMs || 0;
            return prepared;
          }
        }
        if (c.master) {
          const prepared = prepareFromMaster(c.master, pageUrl);
          if (prepared && prepared.playlist) {
            prepared.durationMs = prepared.durationMs || c.durationMs || 0;
            return prepared;
          }
        }
      }
    } catch (e) { /* 走现场取 */ }

    const html = get('/video-' + key + '/');
    const hash = (html.match(/player\.hash\s*=\s*'([0-9a-f]{32})'/) || html.match(/player\.hash\s*=\s*"([0-9a-f]{32})"/) || [])[1] || '';
    if (!hash) throw new Error('EPORNER 頁面裡沒有播放憑證');
    const json = playback(key, hash, pageUrl);
    const master = hlsMaster(json);
    if (master) {
      const prepared = prepareFromMaster(master, pageUrl);
      if (prepared && prepared.playlist) {
        prepared.durationMs = prepared.durationMs || Number(json.duration || 0) * 1000;
        return prepared;
      }
    }
    return prepareMedia(json, pageUrl);
  }
};
