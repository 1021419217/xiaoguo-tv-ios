// 视色 shise.me 站源模块 · 小果影视 模块 API 1
//
//   首页最新  /videos.html → 分页 /videos/{n}.html
//   分类      /categories.html 列出的 7 个主系列，真实路径见 CATEGORIES.path
//             分页是路径式 /xxx/{n}.html（不是 ?page=N，那个会被忽略）
//   搜索      /search.html?keyword={词}（结果服务端渲染，分页同路径式）
//   详情      /video/id-{hash}.html
//   作者      /videos/model-{id}.html → 分页 /videos/model-{id}/{n}.html
//   播放      /hls/{hash}/master.m3u8 → 变体列表 → AES-128，交给 App 播放代理
//
// 与 xchina.co 同一套程序（封面/CDN/HLS 完全一致），但路由规则不同：
// 本站所有路径带 .html 后缀、详情 ID 带 id- 前缀、作者页是 /videos/model-xxx.html。
// 详情/列表/搜索 curl 带完整指纹即可 200，不需要过 Cloudflare 挑战。
// 模块函数必须同步。

const SITE = 'https://shise.me';
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

// 与站点 /categories.html 一致：7 个主系列 + 最新。
// path 是 /categories.html 里父级 series-xxx 重定向后的真实可用路径。
// 分页统一为 path + '/' + n + '.html'；首屏是 path + '.html'。
const CATEGORIES = [
  { id: 'new',     name: '最新',     path: '/videos' },
  { id: 'cn',      name: '中文AV',   path: '/videos/cat-cn' },
  { id: 'jav',     name: '日本AV',   path: '/videos/cat-jav' },
  { id: 'model',   name: '模特私拍', path: '/videos/xs-62' },
  { id: 'amateur', name: '业余拍摄', path: '/videos/cat-cn' },
  { id: 'movie',   name: '情色电影', path: '/videos/cat-movie' },
  { id: 'other',   name: '其他影片', path: '/videos/cat-other' },
  { id: 'ai',      name: 'AI视频',   path: '/videos/cat-ai' }
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
    .trim();
}

function get(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const headers = {};
  for (const k in BROWSER_HEADERS) headers[k] = BROWSER_HEADERS[k];
  if (referer) headers['Referer'] = referer;
  const res = host.fetch({ method: 'GET', url: url, headers: headers });
  if (res.status === 403) throw new Error('视色拦截了请求（403）');
  if (res.status < 200 || res.status >= 300) throw new Error('视色返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片：<a href="/video/id-{hash}.html" title="标题">
//         <div role="img" style="background-image:url('.../cover/{hash}.webp')"></div>
//       <div class="tags">…<i class="far fa-clock"></i>54:14
function parseCards(html) {
  const out = [];
  const seen = {};
  const re = /href="\/video\/id-([0-9a-f]{10,16})\.html"/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const id = m[1];
    if (seen[id]) continue;
    seen[id] = 1;
    const chunk = html.substring(Math.max(0, m.index - 60), m.index + 1500);
    const titleAttr = chunk.match(/title="([^"]{2,300})"/);
    let title = titleAttr ? clean(titleAttr[1]) : '';
    if (!title) {
      const t = chunk.match(/class="title"[^>]*>\s*<a[^>]*>([^<]{2,300})</);
      if (t) title = clean(t[1]);
    }
    if (!title) continue;
    const img = chunk.match(/cover\/([0-9a-f]{10,16})([a-z_-]*)\.webp/);
    const dur = chunk.match(/fa-clock[\s\S]{0,40}?([0-9]{1,3}:[0-9]{2})/);
    out.push({
      sourceId: id,
      title: title,
      cover: COVER + (img ? img[1] + img[2] : id) + '.webp',
      duration: dur ? dur[1] : ''
    });
  }
  return out;
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const base = categoryPath(category);
  // 首屏 /videos.html、/videos/cat-cn.html；翻页 /videos/2.html、/videos/cat-cn/2.html
  return n === 1 ? base + '.html' : base + '/' + n + '.html';
}

// ── 作者 / 演员 ─────────────────────────────────────────────
// 详情页 JSON-LD 的 actor 只有 name 没有 url；作者主页链接在侧栏
// /videos/model-{id}.html 里。JSON-LD 取名字，DOM 取 id + url。
function xcStripData(html) {
  return String(html || '').replace(/data:image\/[a-z+]+;base64,[A-Za-z0-9+/=\s]+/gi, 'B64');
}

function xcUrl(href) {
  const h = String(href || '').trim().replace(/^["']|["']$/g, '');
  if (!h) return '';
  if (h.indexOf('http') === 0) return h;
  if (h.charAt(0) === '/') return SITE + h;
  return SITE + '/' + h;
}

function modelId(url) {
  const m = String(url || '').match(/\/videos\/model-([A-Za-z0-9_-]{3,40})/);
  return m ? m[1] : '';
}

const NAME_BAD = /^(视频|視頻|首页|首頁|分类|分類|标签|標籤|更多|热门|熱門|最新|推荐|推薦|收藏|评论|評論|播放|登录|登錄|注册|註冊|下载|下載|返回|主页|主頁|全部|查看全部|演员|演員|模特|详情|詳情)$/;

function nameOk(name) {
  const n = String(name == null ? '' : name).replace(/\s+/g, ' ').trim();
  if (!n || n.length > 24) return false;
  if (NAME_BAD.test(n)) return false;
  if (/^[\d\s:：.·-]+$/.test(n)) return false;
  if (/[\/\\]|https?:|www\./.test(n)) return false;
  return true;
}

// JSON-LD actor[]：本站只有 name，可能多个
function jsonActors(html) {
  const out = [];
  const blocks = String(html || '').match(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi) || [];
  for (const block of blocks) {
    const body = block.replace(/^[\s\S]*?>/, '').replace(/<\/script>$/i, '');
    const arr = /"actor"\s*:\s*\[([\s\S]{0,2000}?)\]/g;
    let am;
    while ((am = arr.exec(body)) !== null) {
      const seg = am[1];
      const names = /"name"\s*:\s*"([^"]{1,60})"/g;
      let nm;
      while ((nm = names.exec(seg)) !== null) {
        const u = seg.substring(nm.index).match(/"url"\s*:\s*"([^"]{1,220})"/);
        out.push({ author: nm[1], url: u ? u[1] : '' });
      }
    }
    const one = /"actor"\s*:\s*\{([\s\S]{0,600}?)\}/g;
    let om;
    while ((om = one.exec(body)) !== null) {
      const n = om[1].match(/"name"\s*:\s*"([^"]{1,60})"/);
      const u = om[1].match(/"url"\s*:\s*"([^"]{1,220})"/);
      if (n) out.push({ author: n[1], url: u ? u[1] : '' });
    }
  }
  return out.filter(function (a) { return nameOk(a.author); });
}

// 侧栏 /videos/model-{id}.html 胶囊：给 JSON-LD 的名字补 id + url
function domModels(html) {
  const out = [];
  const src = xcStripData(html);
  const re = /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]{0,400}?)<\/a>/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const href = m[1] || m[2] || m[3] || '';
    if (href.indexOf('/videos/model-') < 0) continue;
    const text = clean(m[4].replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
    if (!nameOk(text)) continue;
    const url = xcUrl(href);
    out.push({ author: text, authorId: modelId(url), authorUrl: url });
  }
  return out;
}

function resolveAuthor(html) {
  const actors = jsonActors(html);
  const models = domModels(html);
  // 先按名字把 model 链接配给 JSON-LD actor
  let primary = null;
  if (actors.length) {
    primary = { author: clean(actors[0].author).replace(/\s+/g, ' ').trim() };
    for (const mo of models) {
      if (mo.author === primary.author) {
        primary.authorId = mo.authorId;
        primary.authorUrl = mo.authorUrl;
        break;
      }
    }
  }
  if (!primary && models.length) {
    const tally = {};
    for (const a of models) {
      const sig = String(a.authorId || a.author).toLowerCase();
      if (!tally[sig]) tally[sig] = { n: 0, info: a };
      tally[sig].n += 1;
    }
    let best = null;
    for (const k in tally) if (!best || tally[k].n > best.n) best = tally[k];
    if (best && best.n >= 1) primary = best.info;
  }
  return { primary: primary, actors: actors, models: models };
}

// 详情信息表：时长 / 发行 / 系列（App 只认固定字段名）
function meta(html, authors) {
  const m = {};
  const ld = String(html || '').match(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/i);
  const body = ld ? ld[1] : '';
  const ogdur = String(html).match(/og:duration"[^>]*content="(\d+)"/);
  let durText = '';
  const iso = body.match(/"duration"\s*:\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/);
  if (iso) {
    const h = Number(iso[1] || 0), mm = Number(iso[2] || 0), ss = Number(iso[3] || 0);
    durText = (h ? h + ':' : '') + (h && mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
  } else if (ogdur) {
    const total = Number(ogdur[1]);
    const hh = Math.floor(total / 3600), mm = Math.floor(total % 3600 / 60), ss = total % 60;
    durText = (hh ? hh + ':' : '') + (hh && mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
  }
  if (durText) m['时长'] = durText;
  const up = body.match(/"uploadDate"\s*:\s*"(\d{4})-(\d{2})-(\d{2})/);
  if (up) m['发行'] = up[1] + '-' + up[2] + '-' + up[3];
  const crumbs = String(html).match(/\{"@type":"ListItem","position":\d+,"name":"([^"]{1,40})","item":"[^"]*\/videos\/xs-[^"]*"\}/g) || [];
  if (crumbs.length) {
    const nm = crumbs[crumbs.length - 1].match(/"name":"([^"]{1,40})"/);
    if (nm) m['系列'] = nm[1];
  }
  if (authors && authors.length > 1) m['演员'] = authors.map(function (a) { return a.author; }).join('、');
  return m;
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    durationText: item.duration || '',
    desc: '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
}

function m3u8DurationMs(text) {
  let total = 0;
  const re = /#EXTINF:([0-9.]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) total += parseFloat(m[1]) || 0;
  return Math.round(total * 1000);
}

function playlistBundle(id) {
  const masterUrl = SITE + '/hls/' + id + '/master.m3u8';
  const master = get('/hls/' + id + '/master.m3u8', SITE + '/video/id-' + id + '.html');
  let bestUrl = '';
  let bestBandwidth = -1;
  const lines = master.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.charAt(0) === '#') continue;
    const prev = (lines[i - 1] || '').trim();
    const bandwidth = Number((prev.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const absolute = line.indexOf('http') === 0 ? line : masterUrl.replace(/master\.m3u8.*$/, '') + line;
    if (bandwidth > bestBandwidth) { bestBandwidth = bandwidth; bestUrl = absolute; }
  }
  if (!bestUrl) return { url: masterUrl, playlist: master, durationMs: m3u8DurationMs(master) };
  const variant = get(bestUrl, SITE + '/video/id-' + id + '.html');
  if (variant.indexOf('#EXTM3U') < 0) throw new Error('视色播放列表无效');
  return { url: bestUrl, playlist: variant, durationMs: m3u8DurationMs(variant) };
}

function cacheKey(id) { return 'playlist:' + id; }

module.exports = {
  validCategory(category) {
    return !category || CATEGORIES.some(function (e) { return e.id === category; });
  },

  categories() { return CATEGORIES; },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('没有分类 ' + category);
    const items = parseCards(get(listPath(category, page))).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const q = n > 1 ? '&page=' + n : '';
    const html = get('/search.html?keyword=' + encodeURIComponent(kw) + q);
    const items = parseCards(html).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  author(authorId, authorName, page) {
    const id = String(authorId == null ? '' : authorId).replace(/[^A-Za-z0-9_\-]/g, '');
    const name = clean(authorName || '').replace(/\s+/g, ' ').trim();
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const seen = {};
    function pack(list, url) {
      const out = [];
      for (const it of list) {
        if (!it || !it.sourceId || seen[it.sourceId]) continue;
        seen[it.sourceId] = 1;
        const d = toDrama(it);
        if (name || id) {
          d.author = name || id;
          if (id) d.authorId = id;
          if (url) d.authorUrl = url;
        }
        out.push(d);
      }
      return out;
    }
    if (id) {
      const base = SITE + '/videos/model-' + id + '.html';
      const tries = n > 1 ? [base + '?page=' + n, base.replace('.html', '/' + n + '.html')] : [base];
      for (const url of tries) {
        try {
          const html = get(url);
          const items = pack(parseCards(html), base);
          if (items.length) return { items: items, hasMore: items.length >= 12 };
        } catch (e) {
          host.log('视色作者页失败(' + url.replace(SITE, '') + '): ' + e.message);
        }
      }
    }
    if (name && n <= 1) {
      try {
        const html = get('/search.html?keyword=' + encodeURIComponent(name));
        const items = pack(parseCards(html), '');
        if (items.length) return { items: items, hasMore: items.length >= 12, warning: '按作者名搜索' };
      } catch (e) {
        host.log('视色作者名搜索失败: ' + e.message);
      }
    }
    return { items: [], hasMore: false };
  },

  detail(sourceId) {
    const mm = String(sourceId || '').match(/([0-9a-f]{10,16})/);
    if (!mm) throw new Error('缺少视频 ID');
    const id = mm[1];
    const page = SITE + '/video/id-' + id + '.html';
    const html = get('/video/id-' + id + '.html');

    const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
    let title = t ? clean(t[1]) : '';
    title = title.replace(/\s*-\s*[^-]*视色\s*$/i, '').replace(/\s*-\s*shise\s*$/i, '').trim();
    const cover = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
    const desc = html.match(/<meta[^>]+name="description"[^>]+content="([^"]*)"/);

    const drama = {
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title: title || id,
      name: title || id,
      desc: desc ? clean(desc[1]).substring(0, 120) : '',
      intro: '',
      cover: cover ? cover[1] : (COVER + id + '.webp'),
      totalEpisode: 1
    };

    try {
      const info = resolveAuthor(html);
      if (info.primary) {
        drama.author = info.primary.author;
        if (info.primary.authorId) drama.authorId = info.primary.authorId;
        if (info.primary.authorUrl) drama.authorUrl = info.primary.authorUrl;
      }
      const actorNames = info.actors.map(function (a) { return a.author; });
      const metaData = meta(html, actorNames);
      for (const mk in metaData) drama[mk] = metaData[mk];
      if (metaData['时长']) drama.durationText = metaData['时长'];
      if (metaData['发行']) drama.onlineDate = metaData['发行'];
      if (metaData['系列']) drama.maker = metaData['系列'];
      if (actorNames.length) drama.actors = actorNames;
    } catch (e) {
      host.log('视色元数据解析异常: ' + e.message);
    }

    const chapter = {
      id: host.chapterId(id, 'video'),
      source: host.source,
      title: title || '正片',
      currentEpisode: 1,
      pageUrl: page,
      referer: page
    };

    try {
      host.cacheSet(cacheKey(id), JSON.stringify(playlistBundle(id)), 10 * 60 * 1000);
    } catch (e) {
      host.log('视色预取播放列表失败: ' + e.message);
    }
    return { drama: drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    let id = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2 && /^[0-9a-f]{10,16}$/.test(fromDrama[1])) id = fromDrama[1];
    if (!id) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 2) id = String(fromChapter[1]).trim();
    }
    if (!id) throw new Error('无法确定视频 ID');
    const page = SITE + '/video/id-' + id + '.html';

    let bundle = null;
    try {
      const cached = host.cacheGet(cacheKey(id));
      if (cached) bundle = JSON.parse(cached);
    } catch (e) { bundle = null; }
    if (!bundle || !bundle.url || !bundle.playlist) {
      bundle = playlistBundle(id);
      try { host.cacheSet(cacheKey(id), JSON.stringify(bundle), 10 * 60 * 1000); } catch (e) {}
    }
    return {
      url: bundle.url,
      playlist: bundle.playlist,
      referer: page,
      quality: 720,
      durationMs: bundle.durationMs || 0,
      credentials: {
        referer: page,
        origin: SITE,
        userAgent: BROWSER_HEADERS['User-Agent']
      }
    };
  }
};
