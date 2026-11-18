// PPP.Porn（精選亞洲素人）站源模組 · 小果影視 模組 API 1
//
//   列表  /new/{n}/                     最新上架（每页 24 条）
//         /categories/{slug}/{n}/        分类
//   搜索  /search/?q={关键词}
//   详情  /v/{slug}/
//   播放  详情页里的 https://hokcap.ppp.porn/stream/{token}/{exp}/{a}/{id}/{id}.m3u8
//         真正的 HLS：104 个 4 秒分片 + AES-128，播放器可以随意拖动
//
// 详情页阶段就把播放列表抓下来交给播放器（App 会直接从内存返回），
// 所以点播放是零请求，起播和拖动都快。
// 模块函数必须同步。

const SITE = 'https://ppp.porn';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  'Referer': SITE + '/'
};

const CATEGORIES = [
  { id: 'new', name: '最新上架' },
  { id: 'c-china', name: '中國' },
  { id: 'c-japan', name: '日本' },
  { id: 'c-taiwan', name: '台灣' },
  { id: 'c-korea', name: '韓國' },
  { id: 'c-hongkong', name: '香港' },
  { id: 'c-se-asia', name: '東南亞' },
  { id: 'c-amateur', name: '素人自拍' },
  { id: 'c-cosplay', name: '角色扮演' },
  { id: 'c-streamer', name: '直播主' },
  { id: 'c-first-person-pov', name: '第一人稱' },
  { id: 'c-china-av', name: '中國AV' },
  { id: 'c-japan-producer', name: '日本片商' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#x([0-9a-f]+);/gi, function (_m, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/&#(\d+);/g, function (_m, d) { return String.fromCharCode(parseInt(d, 10)); })
    .trim();
}

function get(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const res = host.fetch({ method: 'GET', url: url, headers: HEADERS });
  if (res.status === 429) throw new Error('PPP.Porn 限流了，等 1~2 分钟再试');
  if (res.status < 200 || res.status >= 300) throw new Error('PPP.Porn 返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片：<div class="item card-video …">
//         <a href="https://ppp.porn/v/{slug}/">
//           <img class="lazyload" data-src="…/336x189/5.jpg" alt="标题" data-preview="…">
//           <figcaption class="card-video__duration">6:57</figcaption>
//         </a>
//         <h4 class="card-video__title"><a href="…/v/{slug}/">标题</a></h4>
//       </div>
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<div class="item card-video/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    const slug = (seg.match(/\/v\/([a-z0-9]+)\//) || [])[1] || '';
    if (!slug || seen[slug]) continue;
    const img = seg.match(/<img[^>]+(?:data-src|src)="([^"]+)"/);
    const alt = seg.match(/<img[^>]+alt="([^"]*)"/);
    const title = alt ? clean(alt[1]) : '';
    if (!title) continue;
    seen[slug] = 1;
    const dur = seg.match(/card-video__duration[^>]*>([^<]+)</);
    out.push({
      sourceId: slug,
      title: title,
      cover: img ? img[1] : '',
      duration: dur ? clean(dur[1]) : ''
    });
  }
  return out;
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const tail = n > 1 ? n + '/' : '';
  if (category && category.indexOf('c-') === 0) {
    return '/categories/' + category.slice(2) + '/' + tail;
  }
  return '/new/' + tail;
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  return {
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
}

// 片源地址不固定在 ppp.porn：实测分布在
//   hokcap.ppp.porn / hacapw.ppp.porn / ohsnqw.cdnlab.live / oksdos.cdnlab.live
// 所以这里不限定域名，只认 /stream/… .m3u8 这个路径特征。
function m3u8Of(html) {
  const m = html.match(/https:\/\/[^"'\s\\<>]+\/stream\/[^"'\s\\<>]+\.m3u8/);
  return m ? m[0] : '';
}

function playlistDurationMs(text) {
  let total = 0;
  const re = /#EXTINF:([0-9.]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) total += parseFloat(m[1]) || 0;
  return Math.round(total * 1000);
}

function cacheKey(slug) {
  return 'pl:' + slug;
}

module.exports = {
  validCategory(category) {
    return !category || CATEGORIES.some(function (entry) { return entry.id === category; });
  },

  categories() {
    return CATEGORIES;
  },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('沒有分類 ' + category);
    const items = parseCards(get(listPath(category, page))).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const html = get('/search/?q=' + encodeURIComponent(kw) + (n > 1 ? '&page=' + n : ''));
    const items = parseCards(html).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  detail(sourceId) {
    const slug = String(sourceId || '').match(/^[a-z0-9]+$/);
    if (!slug) throw new Error('視頻 ID 無效');
    const key = slug[0];
    const page = SITE + '/v/' + key + '/';
    const html = get('/v/' + key + '/');

    const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
    let title = h1 ? clean(h1[1]) : '';
    if (!title) {
      const og = html.match(/property="og:title"[^>]*content="([^"]*)"/);
      if (og) title = clean(og[1]).replace(/\s*-\s*PPP\.Porn.*$/i, '');
    }
    if (!title) {
      const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
      title = t ? clean(t[1]).replace(/\s*-\s*PPP\.Porn.*$/i, '') : key;
    }
    const ogImg = html.match(/property="og:image"[^>]*content="([^"]*)"/);
    const desc = html.match(/name="description"[^>]*content="([^"]*)"/);

    const drama = {
      id: host.dramaId(key),
      source: host.source,
      sourceId: key,
      title: title,
      name: title,
      desc: desc ? clean(desc[1]).substring(0, 200) : '',
      intro: '',
      cover: ogImg ? ogImg[1] : '',
      totalEpisode: 1
    };

    // 详情页阶段就把播放列表抓下来（真正的 HLS），播放时零请求
    try {
      const m3u8 = m3u8Of(html);
      if (m3u8) {
        const res = host.fetch({ method: 'GET', url: m3u8, headers: { 'User-Agent': UA, 'Referer': page } });
        const text = String(res.body || '');
        if (text.indexOf('#EXTM3U') >= 0) {
          host.cacheSet(cacheKey(key), JSON.stringify({
            url: m3u8,
            playlist: text,
            durationMs: playlistDurationMs(text)
          }), 20 * 60 * 1000);
        }
      }
    } catch (e) {
      host.log('PPP 预取播放列表失败: ' + e.message);
    }

    return {
      drama: drama,
      chapters: [{
        id: host.chapterId(key, 'video'),
        source: host.source,
        title: title || '正片',
        currentEpisode: 1,
        pageUrl: page,
        referer: page
      }]
    };
  },

  resolveMedia(task) {
    let key = '';
    const prefix = host.source + ':';
    if (task && typeof task.dramaId === 'string' && task.dramaId.indexOf(prefix) === 0) {
      key = task.dramaId.slice(prefix.length).trim();
    }
    if (!key && task && task.chapter && task.chapter.id) {
      const parts = String(task.chapter.id).split(':');
      if (parts.length >= 2) key = parts[1];
    }
    if (!key) throw new Error('無法確定視頻 ID');
    const page = SITE + '/v/' + key + '/';

    let bundle = null;
    try {
      const cached = host.cacheGet(cacheKey(key));
      if (cached) bundle = JSON.parse(cached);
    } catch (e) { bundle = null; }

    if (!bundle || !bundle.playlist) {
      // 缓存过期：现场抓一次
      const html = get('/v/' + key + '/');
      const m3u8 = m3u8Of(html);
      if (!m3u8) throw new Error('PPP.Porn 頁面裡沒有找到播放地址');
      const res = host.fetch({ method: 'GET', url: m3u8, headers: { 'User-Agent': UA, 'Referer': page } });
      const text = String(res.body || '');
      if (text.indexOf('#EXTM3U') < 0) throw new Error('PPP.Porn 播放列表無效');
      bundle = { url: m3u8, playlist: text, durationMs: playlistDurationMs(text) };
      try { host.cacheSet(cacheKey(key), JSON.stringify(bundle), 20 * 60 * 1000); } catch (e) { /* 忽略 */ }
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
        userAgent: UA
      }
    };
  }
};
