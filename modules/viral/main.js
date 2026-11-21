// viralxxxporn.com（病毒式 XXX / OnlyFans 泄露）站源模块 · 小果影视 模块 API 1
//
//   列表  /zh/                      首页
//         /zh/latest-updates/{n}/   最新
//         /zh/categories/{slug}/{n}/
//   搜索  /zh/search/{关键词}/        （一次返回全部，不分页）
//   详情  /zh/video/{id}/{slug}/
//
// 详情页 flashvars 直接给 MP4：
//     video_alt_url  → 720p
//     video_alt_url2 → 1080p
//     video_url      → 480p
// 地址会 302 跳到 sextape.viralxxxporn.com，跟随之后 Range 正常（实测 206 video/mp4）。
// 游客可播，不需要登录。
// 模块函数必须同步。

const SITE = 'https://viralxxxporn.com';
const LOC = '/zh';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  'Referer': SITE + LOC + '/'
};

const CATEGORIES = [
  { id: 'latest', name: '最新' },
  { id: 'c-anal', name: '肛门' },
  { id: 'c-closeup', name: '特写' },
  { id: 'c-solo', name: '单人' },
  { id: 'c-ppv', name: 'PPV' },
  { id: 'c-lingerie', name: '内衣' },
  { id: 'c-tease', name: '挑逗' },
  { id: 'c-topless', name: '无上装' },
  { id: 'c-cute', name: '可爱' }
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
  if (res.status === 429) throw new Error('ViralXXX 限流了，等 1~2 分钟再试');
  if (res.status < 200 || res.status >= 300) throw new Error('ViralXXX 返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片（首页用 .vx-card，列表页用 .vx-th item，但都有 a.vx-media + img.vx-img）：
//   <a class="vx-media" href="https://viralxxxporn.com/zh/video/553583/slug/" title="…">
//     <img class="vx-img" src="https://imgcdn.viralxxxporn.com/…/800x450/2.jpg" alt="…">
function shrinkCover(url) {
  return String(url || '').replace('/800x450/', '/320x180/');
}

function parseCards(html) {
  const out = [];
  const seen = {};
  const re = /href="https:\/\/viralxxxporn\.com\/zh\/video\/(\d+)\/([^"\/]+)\/"/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const id = 'video/' + m[1] + '/' + m[2];
    if (seen[id]) continue;
    seen[id] = 1;
    const chunk = html.substring(m.index, m.index + 1200);
    const img = chunk.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    const alt = chunk.match(/<img[^>]+alt="([^"]*)"/i) || chunk.match(/title="([^"]*)"/i);
    out.push({
      sourceId: id,
      title: alt ? clean(alt[1]) : m[2].replace(/-/g, ' '),
      cover: img ? shrinkCover(img[1]) : '',
      duration: ''
    });
  }
  return out;
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const tail = n > 1 ? n + '/' : '';
  if (category && category.indexOf('c-') === 0) return LOC + '/categories/' + category.slice(2) + '/' + tail;
  return LOC + '/latest-updates/' + tail;
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  return {
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
}

function detailKey(sourceId) {
  const m = String(sourceId || '').match(/^video\/(\d+)\/([^\/]+)$/);
  if (!m) throw new Error('视频 ID 无效');
  return { id: m[1], slug: m[2], path: LOC + '/video/' + m[1] + '/' + m[2] + '/' };
}

// flashvars 里的三档清晰度；720p 优先（起播快），1080p / 480p 作为备选
function pickStreams(html) {
  const out = [];
  function take(name, re) {
    const m = html.match(re);
    if (m && m[1] && /^https?:/.test(m[1])) {
      const u = m[1].replace(/&amp;/g, '&');
      if (!out.some(function (x) { return x.url === u; })) out.push({ name: name, url: u });
    }
  }
  take('720p', /video_alt_url:\s*'([^']+)'/);
  take('1080p', /video_alt_url2:\s*'([^']+)'/);
  take('480p', /video_url:\s*'([^']+)'/);
  return out;
}

module.exports = {
  validCategory(category) {
    return !category || CATEGORIES.some(function (entry) { return entry.id === category; });
  },

  categories() {
    return CATEGORIES;
  },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('没有分类 ' + category);
    const items = parseCards(get(listPath(category, page))).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    if (n > 1) return { items: [], hasMore: false };  // 站点搜索一次返回全部
    const items = parseCards(get(LOC + '/search/' + encodeURIComponent(kw) + '/')).map(toDrama);
    return { items: items, hasMore: false };
  },

  detail(sourceId) {
    const info = detailKey(sourceId);
    const html = get(info.path);

    const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
    let title = h1 ? clean(h1[1]) : '';
    if (!title) {
      const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
      title = t ? clean(t[1]).replace(/^免费观看/, '').replace(/！$/, '') : info.slug;
    }
    const og = html.match(/property="og:image"[^>]*content="([^"]+)"/);
    const desc = html.match(/name="description"[^>]*content="([^"]*)"/);

    const drama = toDrama({ sourceId: sourceId, title: title, cover: og ? shrinkCover(og[1]) : '' });
    drama.desc = desc ? clean(desc[1]).substring(0, 200) : '';

    // 详情页已经打开了：顺手把时长和文件大小缓存好，播放时就不用再请求。
    try {
      host.cacheSet('streams:' + info.id, JSON.stringify(pickStreams(html)), 30 * 60 * 1000);

      let ms = 0;
      const dur = html.match(/property="video:duration"[^>]*content="(\d+)"/);
      if (dur) ms = Number(dur[1] || 0) * 1000;
      if (!ms) {
        const iso = html.match(/"duration"\s*:\s*"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/);
        if (iso) ms = ((Number(iso[1] || 0) * 3600) + (Number(iso[2] || 0) * 60) + Number(iso[3] || 0)) * 1000;
      }
      if (ms > 0) host.cacheSet('duration:' + info.id, String(ms), 30 * 60 * 1000);

      // 记录这个视频有哪些清晰度（flashvars 里有 video_alt_url2 = 有 1080p）
      const names = pickStreams(html).map(function (s) { return s.name; });
      host.cacheSet('tiers:' + info.id, names.join(','), 30 * 60 * 1000);
      const tier = '_720p';

      // 取文件总大小（用 Range: bytes=0-0，只回 1 字节，比 HEAD 稳）
      const m = info.id;
      const band = String(Math.floor(Number(m) / 1000) * 1000);
      const probeUrl = 'https://sextape.viralxxxporn.com/contents/videos/' + band + '/' + m + '/' + m + tier + '.mp4';
      const res = host.fetch({ method: 'GET', url: probeUrl, headers: { 'User-Agent': UA, 'Range': 'bytes=0-0' } });
      const h = res.headers || {};
      const range = (h['content-range'] || h['Content-Range'] || [''])[0] || '';
      let len = Number((range.match(/\/(\d+)\s*$/) || [])[1] || 0);
      if (!len) len = Number((h['content-length'] || h['Content-Length'] || ['0'])[0] || 0);
      if (len > 1) host.cacheSet('size:' + info.id, String(len), 30 * 60 * 1000);
    } catch (e) { /* 忽略：拿不到就退回整段播放 */ }

    const page = SITE + info.path;
    return {
      drama: drama,
      chapters: [{
        id: host.chapterId(sourceId, 'video'),
        source: host.source,
        title: title || '正片',
        currentEpisode: 1,
        pageUrl: page,
        referer: page
      }]
    };
  },

  resolveMedia(task) {
    // DramaID 形如 "viral:video/<id>/<slug>"；Chapter.ID 形如 "viral:video/<id>/<slug>:video"
    let sourceId = '';
    const prefix = host.source + ':';
    if (task && typeof task.dramaId === 'string' && task.dramaId.indexOf(prefix) === 0) {
      sourceId = task.dramaId.slice(prefix.length);
    }
    if (!sourceId && task && task.chapter && task.chapter.id) {
      const parts = String(task.chapter.id).split(':');
      if (parts.length >= 2) sourceId = parts.slice(1, parts.length - 1).join(':');
    }
    const info = detailKey(sourceId);
    const page = SITE + info.path;

    // CDN 路径由视频 id 决定、不需要 token（实测 200/206 + ftypisom）
    const vid = info.id;
    const band = String(Math.floor(Number(vid) / 1000) * 1000);

    // 清晰度固定 720p。
    // 三档实测：1080p=1920x1080/6.8Mbps(34.7MB)、720p=1280x720/3.3Mbps(17.1MB)、480p=854x480。
    // 1080p 体积是 720p 的两倍，整段缓冲要慢一倍，实测体验反而更差，所以用 720p。
    const tier = '_720p';
    const quality = 720;
    const mp4 = 'https://sextape.viralxxxporn.com/contents/videos/' + band + '/' + vid + '/' + vid + tier + '.mp4';

    // 时长和文件大小在详情页阶段就缓存好；播放时零请求
    let durationMs = 0;
    let totalSize = 0;
    try {
      const d = host.cacheGet('duration:' + vid);
      if (d) durationMs = Number(d) || 0;
      const s = host.cacheGet('size:' + vid);
      if (s) totalSize = Number(s) || 0;
    } catch (e) { durationMs = 0; totalSize = 0; }

    const seconds = durationMs > 0 ? Math.max(1, Math.round(durationMs / 1000)) : 0;

    // 不包 HLS，直接给 MP4。
    // HLS 的分片是原子的：拖到 80% 就得把分片从头下到 80% 才能播（17 MB → 十几秒转圈）。
    // 普通 MP4 走 HTTP Range，拖到哪取哪，seek 是瞬间的。
    // 注意：这依赖 App 的 MP4 直读路径可用（之前出过本地代理挂死的问题，重启 App 即恢复）。
    return {
      url: mp4,
      referer: page,
      quality: quality,
      durationMs: durationMs,
      credentials: {
        referer: page,
        origin: SITE,
        userAgent: UA
      }
    };
  }
};
