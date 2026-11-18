// 91porna 站源模块 · 小果影视 模块 API 1
//
//   列表  /comic/index/video?category={id}&page={n}
//   搜索  /comic/index/search?keyword={kw}
//   详情  /comic/index/avdetail?video_key={key}   ← 页面里有 data-video="<mediaId>"
//   播放  POST /api/videos/{mediaId}/playback → data.streams.main（带 auth_key 的 m3u8）
//
// 与常见写法的区别：详情页阶段就把「接口 + 播放列表」抓完并缓存，
// 点播放时 App 直接从内存拿列表，零请求。
// 这个站的 m3u8 有 600 个分片、约 109 KB，播放时才去拿会明显卡顿。
//
// 站点只提供一路清晰度（streams.main；hevc 为空），没有更高档可选。
// 模块函数必须同步。

const SITE = 'https://91porna.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

const CATEGORIES = [
  { id: 'new_update', name: '最近更新' },
  { id: 'now_hot', name: '当前最热' },
  { id: 'now_month_hot', name: '本月最热' },
  { id: 'original', name: '91原创' },
  { id: 'hd', name: '高清' },
  { id: 'ten_minutes', name: '10分钟以上' },
  { id: 'twenty_minutes', name: '20分钟以上' },
  { id: 'now_month_collect', name: '本月收藏' },
  { id: 'now_month_comment', name: '本月讨论' },
  { id: 'max_collect', name: '收藏最多' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function req(o) {
  const headers = {};
  for (const k in HEADERS) headers[k] = HEADERS[k];
  if (o.referer) headers['Referer'] = o.referer;
  if (o.method === 'POST') headers['Content-Type'] = 'application/json';
  const res = host.fetch({ method: o.method || 'GET', url: o.url, headers: headers, body: o.body });
  if (res.status === 403) throw new Error('91porna 拦了请求（403）');
  if (res.status < 200 || res.status >= 300) throw new Error('91porna 返回 HTTP ' + res.status);
  return res.body || '';
}

function getText(path, referer) {
  return req({ url: path.indexOf('http') === 0 ? path : SITE + path, referer: referer || SITE + '/' });
}

// 卡片：<div class="video-item"> … <a href="/comic/index/avdetail?video_key=KEY">
//         <img data-src="封面" alt="标题"> … <div class="line-clamp-2 …">标题</div>
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<div class="video-item">/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    // 新分类用 avdetail，老分类用 detail，两种都要认
    const key = (seg.match(/(?:avdetail|detail)\?video_key=([0-9A-Za-z_\-]+)/) || [])[1] || '';
    if (!key || seen[key]) continue;
    const img = seg.match(/data-src="([^"]+)"/) || seg.match(/<img[^>]+src="(http[^"]+)"/);
    const alt = seg.match(/<img[^>]+alt="([^"]*)"/);
    let title = alt ? clean(alt[1]) : '';
    if (!title) {
      const t = seg.match(/class="line-clamp-2[^"]*"[^>]*>([\s\S]*?)<\/div>/);
      if (t) title = clean(t[1]);
    }
    if (!title) continue;
    seen[key] = 1;
    out.push({
      sourceId: key,
      title: title,
      cover: img ? img[1].replace(/&amp;/g, '&') : '',
      duration: ''
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

function detailPath(key) {
  return '/comic/index/avdetail?video_key=' + encodeURIComponent(key);
}

function cacheKey(key) {
  return 'pb:' + key;
}

function playlistDurationMs(text) {
  let total = 0;
  const re = /#EXTINF:([0-9.]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) total += parseFloat(m[1]) || 0;
  return Math.round(total * 1000);
}

// 走一遍「接口 + 播放列表」，结果缓存起来
// 已知 mediaId 时可以跳过详情页（省掉那个 400 KB 的 HTML）。
// 老格式的长视频：video_key 本身就是 mediaId（纯数字），所以能直接走这条快路。
function fetchPlayback(key, knownMedia, knownPageUrl, knownHtml) {
  let fetchedHtml = '';
  let media = knownMedia || '';
  let pageUrl = knownPageUrl || '';

  // 详情页 HTML 已经抓过就直接复用，别重复请求（详情页 HTML 有 400 KB）。
  if (!media && knownHtml) {
    const id = (knownHtml.match(/data-video="(\d+)"/) || [])[1] || '';
    if (id) {
      media = id;
      fetchedHtml = knownHtml;
      try { host.cacheSet('media:' + key, id, 60 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
  }

  if (!media) {
    // 站里有两套详情页：新分类用 /comic/index/avdetail，老分类用 /comic/index/detail。
    // 两套页面都有 data-video="<mediaId>"，都可以走同一个播放接口。
    const paths = ['/comic/index/avdetail?video_key=', '/comic/index/detail?video_key='];
    for (const p of paths) {
      try {
        const candidate = getText(p + encodeURIComponent(key));
        const id = (candidate.match(/data-video="(\d+)"/) || [])[1] || '';
        if (id) {
          media = id;
          fetchedHtml = candidate;
          pageUrl = SITE + p + encodeURIComponent(key);
          try { host.cacheSet('media:' + key, id, 60 * 60 * 1000); } catch (e) { /* 忽略 */ }
          break;
        }
      } catch (e) { /* 试下一种 */ }
    }
  }
  if (!media) throw new Error('91porna 详情页里没有播放数据（可能已下架）');
  if (!pageUrl) pageUrl = SITE + '/comic/index/detail?video_key=' + encodeURIComponent(key);

  const raw = req({ method: 'POST', url: SITE + '/api/videos/' + media + '/playback', referer: pageUrl, body: '{}' });
  let json;
  try { json = JSON.parse(raw); } catch (e) { throw new Error('91porna 播放接口返回的不是 JSON'); }
  const streams = (json && json.data && json.data.streams) || {};
  const url = streams.main || streams.preview || streams.hevc || '';
  if (!url) throw new Error('91porna 播放接口没有给出地址');

  // 直接把播放列表抓下来（这个列表很大，播放时再抓会明显卡顿）
  const playlist = String(getText(url, pageUrl));
  if (playlist.indexOf('#EXTM3U') < 0) throw new Error('91porna 播放列表无效');

  const bundle = { url: url, playlist: playlist, durationMs: playlistDurationMs(playlist), media: media };
  try { host.cacheSet(cacheKey(key), JSON.stringify(bundle), 5 * 60 * 1000); } catch (e) { /* 忽略 */ }
  return { bundle: bundle, html: fetchedHtml, pageUrl: pageUrl };
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
    const cate = (!category || category === 'new') ? 'new_update' : category;
    const raw = parseCards(getText('/comic/index/video?category=' + cate + '&page=' + n));
    // 把标题/封面缓存起来：打开详情页时就不用再下载 400 KB 的 HTML
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    const items = raw.map(toDrama);
    return { items: items, hasMore: items.length >= 10 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const raw = parseCards(getText('/comic/index/search?keyword=' + encodeURIComponent(kw)));
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: false };
  },

  // App 点「作者」时调用。91porna 没有稳定的作者主页，用作者名站内搜索，
  // 结果里回填作者字段，方便在二级页继续点。
  author(authorId, authorName, page) {
    const kw = clean(authorName || '') || String(authorId || '').trim();
    if (!kw) return { items: [], hasMore: false, warning: '缺少作者信息' };
    try {
      const raw = parseCards(getText('/comic/index/search?keyword=' + encodeURIComponent(kw)));
      const items = raw.map(function (it) {
        it.author = authorName || kw;
        if (authorId) it.authorId = authorId;
        return toDrama(it);
      });
      if (!items.length) return { items: [], hasMore: false, warning: '没有搜到该作者的作品' };
      return { items: items, hasMore: false };
    } catch (e) {
      return { items: [], hasMore: false, warning: e.message };
    }
  },

  detail(sourceId) {
    const key = String(sourceId || '').trim();
    if (!key) throw new Error('缺少 video_key');

    const isNumeric = /^\d+$/.test(key);
    const pageUrl = isNumeric
      ? SITE + '/comic/index/detail?video_key=' + encodeURIComponent(key)
      : SITE + '/comic/index/avdetail?video_key=' + encodeURIComponent(key);

    // 优先用列表页缓存下来的标题/封面 —— 这时不需要任何网络请求，详情页秒开
    let title = '';
    let cover = '';
    let desc = '';
    try {
      const c = host.cacheGet('card:' + key);
      if (c) {
        const card = JSON.parse(c);
        title = card.title || '';
        cover = card.cover || '';
      }
    } catch (e) { /* 忽略 */ }

    // 详情页 HTML 每次都要抓：标题、简介、作者都在里面。
    // 下面取播放列表时会把这份 HTML 直接传进去复用，所以不会多出请求。
    // 抓失败不影响打开，只是没有作者入口（标题用列表页缓存兜住）。
    let html = '';
    for (const p of ['/comic/index/avdetail?video_key=', '/comic/index/detail?video_key=']) {
      try {
        const candidate = getText(p + encodeURIComponent(key));
        // 三种特征任一命中就算详情页（模板改版时 data-video 可能不在，用长度兜底）
        if (candidate.indexOf('data-video="') >= 0 || candidate.indexOf('og:title') >= 0 || candidate.length > 200) { html = candidate; break; }
      } catch (e) { /* 试下一种 */ }
    }
    let author = null;
    if (html) {
      author = parseAuthor(html, key);
      if (!title) {
        const og = html.match(/property="og:title"[^>]+content="([^"]*)"/);
        if (og) title = clean(og[1]);
        if (!title) {
          const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
          if (t) title = clean(t[1]);
        }
        title = title.replace(/\s*-\s*91視頻[\s\S]*$/, '').replace(/\s*-\s*91视频[\s\S]*$/, '').replace(/\s*-\s*91porna[\s\S]*$/, '').trim();
      }
      // 注意：详情页的 og:image 在 expose.eisees.com 上，返回 200 但 0 字节，是坏地址。
      // 如果把它交给 App，会被 MergeNativeDrama 合并进剧库并持久化，
      // 导致列表封面变空白（要刷新分类才恢复）。所以这里不取 og:image：
      // 拿不到列表缓存的封面就留空，App 会保留原来的封面。
      if (!desc) desc = (html.match(/property="og:description"[^>]+content="([^"]*)"/) || [])[1] || '';
      try { host.cacheSet('card:' + key, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    if (!title) title = key;
    if (!author) host.log('91porna 详情页未解析到作者: ' + key);


    // 详情页阶段就用官方路径（prepareWebMedia）把播放列表处理好并缓存，
    // 播放时零请求；同时保留 chapter.videoUrl 占位符（MissAV 方案）。
    try {
      let media = /^\d+$/.test(key) ? key : '';
      if (!media) {
        const m = host.cacheGet('media:' + key);
        if (m) media = String(m);
      }
      if (!media) {
        const got = fetchPlayback(key, '', pageUrl, html);
        media = got.bundle ? got.bundle.media : '';
      }
      if (media) {
        const raw = req({ method: 'POST', url: SITE + '/api/videos/' + media + '/playback', referer: pageUrl, body: '{}' });
        const json = JSON.parse(raw);
        const streams = (json && json.data && json.data.streams) || {};
        const url = streams.main || streams.preview || streams.hevc || '';
        if (url) {
          const prepared = host.prepareWebMedia({ url: url, referer: pageUrl, quality: 720 }, '91porna');
          host.cacheSet('media-ready:' + key, JSON.stringify({
            url: prepared.url,
            playlist: prepared.playlist,
            durationMs: prepared.durationMs || 0
          }), 2 * 60 * 1000);
        }
      }
    } catch (e) {
      host.log('91porna 详情页预取失败（播放时会重试）: ' + e.message);
    }
    const drama = {
      id: host.dramaId(key),
      source: host.source,
      sourceId: key,
      title: title,
      name: title,
      desc: clean(desc).substring(0, 200),
      intro: '',
      cover: String(cover).replace(/&amp;/g, '&'),
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
        videoUrl: 'p91a-play://' + key,
        pageUrl: pageUrl,
        referer: pageUrl
      }]
    };
  },

  resolveMedia(task) {
    // 完全照 MissAV 的写法：现取播放地址，交给 host.prepareWebMedia 处理。
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) key = fromChapter[1];
    }
    if (!key) throw new Error('無法確定 video_key');

    const isNumeric = /^\d+$/.test(key);
    const pageUrl = isNumeric
      ? SITE + '/comic/index/detail?video_key=' + encodeURIComponent(key)
      : SITE + '/comic/index/avdetail?video_key=' + encodeURIComponent(key);

    // mediaId：数字 key 就是它本身；否则从缓存或详情页拿
    let media = '';
    if (isNumeric) media = key;
    else {
      try { const m = host.cacheGet('media:' + key); if (m) media = String(m); } catch (e) { /* 忽略 */ }
    }
    if (!media) {
      const got = fetchPlayback(key, '', pageUrl);
      media = got.bundle ? got.bundle.media : '';
    }
    if (!media) throw new Error('91porna 找不到 mediaId');

    // 详情页已经用 prepareWebMedia 处理过，直接返回（零请求）
    try {
      const ready = host.cacheGet('media-ready:' + key);
      if (ready) {
        const m = JSON.parse(ready);
        if (m.url && m.playlist) {
          return {
            url: m.url,
            playlist: m.playlist,
            referer: pageUrl,
            quality: 720,
            durationMs: m.durationMs || 0,
            credentials: { referer: pageUrl, origin: SITE, userAgent: UA }
          };
        }
      }
    } catch (e) { /* 走现场取 */ }

    // 缓存没有：现取一次（同样走官方 prepareWebMedia）
    const raw = req({ method: 'POST', url: SITE + '/api/videos/' + media + '/playback', referer: pageUrl, body: '{}' });
    let json;
    try { json = JSON.parse(raw); } catch (e) { throw new Error('91porna 播放接口返回的不是 JSON'); }
    const streams = (json && json.data && json.data.streams) || {};
    const url = streams.main || streams.preview || streams.hevc || '';
    if (!url) throw new Error('91porna 播放接口没有给出地址');

    // 交给 App 自己抓列表、自己重写（与 MissAV 完全一致的路径）
    return host.prepareWebMedia({ url: url, referer: pageUrl, quality: 720 }, '91porna');
  }
};