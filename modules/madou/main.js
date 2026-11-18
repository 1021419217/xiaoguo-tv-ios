// 麻豆社（madou.club）站源模块 · 小果影视 模块 API 1
//
// WordPress 站点：
//   列表  /                        最新（/page/{n}/ 翻页）
//         /likes                   点赞排行（单页 100 条）
//         /category/{slug}/        频道（/category/{slug}/page/{n}/ 翻页）
//   搜索  /?s={关键词}              （/page/{n}/?s={关键词} 翻页）
//   详情  /{slug}.html
//   播放  详情页里只有一个 iframe：https://dash.madou.club/share/{id}
//         那个 share 页里写着：
//             var token = "<JWT>";                 // iat→exp 只有 100 秒
//             var m3u8  = '/videos/{id}/index.m3u8';
//         播放列表必须带 token（不带返回 404）；但**分片和 AES 密钥不需要 token**。
//
// 所以策略是：详情页只缓存 share 地址（不含 token，永久有效），
// 点播放时才去 share 页现取 token + 播放列表；播放列表一旦拿到就能用很久
//（因为分片直连，不带 token 也能取），所以结果缓存 10 分钟。
//
// 模块函数必须同步。

const SITE = 'https://madou.club';
const DASH = 'https://dash.madou.club';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

// 分类 id 不能含 / | \（App 会判非法），所以用英文 slug，真实路径放 path
const CATEGORIES = [
  { id: 'latest', name: '最新', path: '/' },
  { id: 'likes', name: '點讚排行', path: '/likes' },
  { id: 'madou', name: '麻豆傳媒', path: '/category/%e9%ba%bb%e8%b1%86%e4%bc%a0%e5%aa%92/' },
  { id: 'fanwai', name: '麻豆番外', path: '/category/%e9%ba%bb%e8%b1%86%e7%95%aa%e5%a4%96%e7%af%87/' },
  { id: 'huaxu', name: '麻豆花絮', path: '/category/%e9%ba%bb%e8%b1%86%e8%8a%b1%e7%b5%ae/' },
  { id: 'guodong', name: '果凍傳媒', path: '/category/%e6%9e%9c%e5%86%bb%e4%bc%a0%e5%aa%92/' },
  { id: 'mitao', name: '蜜桃影像', path: '/category/%e8%9c%9c%e6%a1%83%e5%bd%b1%e5%83%8f/' },
  { id: 'tianmei', name: '天美傳媒', path: '/category/%e5%a4%a9%e7%be%8e%e4%bc%a0%e5%aa%92/' },
  { id: 'jiu91', name: '91製片廠', path: '/category/91%e5%88%b6%e7%89%87%e5%8e%82/' },
  { id: 'hkdoll', name: 'HongKongDoll', path: '/category/hongkongdoll/' },
  { id: 'psycho', name: 'PsychoPornTW', path: '/category/psychoporntw/' },
  { id: 'huangjia', name: '皇家華人', path: '/category/%e7%9a%87%e5%ae%b6%e5%8d%8e%e4%ba%ba/' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#x([0-9a-f]+);/gi, function (_m, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/&#(\d+);/g, function (_m, d) { return String.fromCharCode(parseInt(d, 10)); })
    .replace(/\s+/g, ' ')
    .trim();
}

function get(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const headers = {};
  for (const k in HEADERS) headers[k] = HEADERS[k];
  headers['Referer'] = referer || (SITE + '/');
  const res = host.fetch({ method: 'GET', url: url, headers: headers, followRedirects: true });
  if (res.status < 200 || res.status >= 300) throw new Error('麻豆社返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片：<article class="excerpt …">
//   <a class="thumbnail" href="https://madou.club/{slug}.html">
//     <img src="…thumb.png" data-src="https://madou.club/covers/2025/10/xxx-240x180.jpg">
//   <h2><a href="…{slug}.html">标题</a></h2>
//   <footer><a class="post-like" data-pid="28819"><span>1263</span></a>
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<article class="excerpt/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i].slice(0, 2500);
    const link = seg.match(/href="https?:\/\/madou\.club\/([^"\/]+\.html)"/);
    if (!link) continue;
    const slug = link[1];
    if (seen[slug]) continue;

    const titleM = seg.match(/<h2[^>]*>\s*<a[^>]*>([\s\S]*?)<\/a>/);
    const title = titleM ? clean(titleM[1]) : '';
    if (!title) continue;

    seen[slug] = 1;
    let cover = '';
    const img = seg.match(/data-src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i) ||
                seg.match(/<img[^>]+src="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i);
    if (img) cover = img[1];
    // 列表缩略图是 -240x180，去掉尺寸段就是原图（实测原图 200）
    cover = cover.replace(/-\d+x\d+(\.(?:jpg|jpeg|png|webp))$/i, '$1');

    const likes = seg.match(/class="post-like"[^>]*>[\s\S]{0,120}?<span>([^<]*)</);
    out.push({
      sourceId: slug,
      title: title,
      cover: cover,
      likes: likes ? clean(likes[1]) : ''
    });
  }
  return out;
}

function toDrama(item) {
  const title = item.title || item.sourceId.replace(/\.html$/, '');
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: item.likes ? '讚 ' + item.likes : '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
}

function listPath(category, page) {
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = !category ? 'latest' : String(category);
  const meta = CATEGORIES.filter(function (c) { return c.id === id; })[0];
  if (!meta) return p > 1 ? '/page/' + p + '/' : '/';
  if (meta.id === 'likes') return meta.path;                                  // 单页
  if (meta.id === 'latest') return p > 1 ? '/page/' + p + '/' : '/';
  return meta.path + (p > 1 ? 'page/' + p + '/' : '');
}

// 详情页里的 iframe → share 地址
function shareOf(html) {
  const m = html.match(/<iframe[^>]+src=["']?([^"'\s>]+)/);
  if (!m) return '';
  let share = m[1];
  if (share.indexOf('//') === 0) share = 'https:' + share;
  if (share.indexOf('http') !== 0) return '';
  return share;
}

// share 页 → token + m3u8 路径
function shareInfo(shareUrl, referer) {
  const page = get(shareUrl, referer || (SITE + '/'));
  const tok = page.match(/var token\s*=\s*"([^"]*)"/);
  const m3 = page.match(/var m3u8\s*=\s*'([^']*)'/) || page.match(/var m3u8\s*=\s*"([^"]*)"/);
  if (!m3) throw new Error('麻豆社播放器裡沒有 m3u8 地址');
  let url = m3[1];
  if (url.indexOf('http') !== 0) url = DASH + url;
  const token = tok ? tok[1] : '';
  if (token && url.indexOf('token=') < 0) {
    url += (url.indexOf('?') >= 0 ? '&' : '?') + 'token=' + token;
  }
  return url;
}

function readyKey(id) { return 'ready:' + id; }

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
    // 点赞排行是单页（100 条），翻页会返回同一批，所以不给下一页
    const singlePage = String(category || '') === 'likes';
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: singlePage ? false : raw.length >= 14 };
  },

  search(page, query) {
    const kw = String(query || '').replace(/\s+/g, ' ').trim();
    if (!kw) return { items: [], hasMore: false };
    const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const path = (p > 1 ? '/page/' + p + '/' : '/') + '?s=' + encodeURIComponent(kw);
    const raw = parseCards(get(path));
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 14 };
  },

  detail(sourceId) {
    const id = String(sourceId || '').trim();
    if (!/^[^\/]+\.html$/.test(id)) throw new Error('視頻 ID 無效');
    const pageUrl = SITE + '/' + id;

    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + id);
      if (c) { const card = JSON.parse(c); title = card.title || ''; cover = card.cover || ''; }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get('/' + id); } catch (e) { if (!title) throw e; }

    if (html) {
      if (!title) {
        const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
        if (h1) title = clean(h1[1]);
      }
      if (!cover) {
        const og = html.match(/property="og:image"[^>]*content="([^"]+)"/);
        if (og && og[1]) cover = og[1];
      }
      // 详情页本身没有 og:image（实测为空），封面在 share 页 DPlayer 的 pic 里。
      // 只有「列表缓存里没有封面」时才多花这一个请求（比如从剧库直接进来）。
      if (!cover) {
        try {
          const share = shareOf(html);
          if (share) {
            const sp = get(share, pageUrl);
            const pic = sp.match(/pic:\s*'([^']+)'/) || sp.match(/pic:\s*"([^"]+)"/);
            if (pic && pic[1]) {
              cover = pic[1].indexOf('http') === 0 ? pic[1] : (DASH + pic[1]);
            }
          }
        } catch (e) { /* 封面取不到就算了，绝不留坏地址 */ }
      }
      try { host.cacheSet('card:' + id, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }

      // 只缓存 share 地址（不含 token，永久有效）；播放列表留到点播放再取
      try {
        const share = shareOf(html);
        if (share) host.cacheSet('share:' + id, share, 30 * 60 * 1000);
      } catch (e) {
        host.log('麻豆社 share 地址緩存失敗: ' + e.message);
      }
    }
    if (!title) title = id.replace(/\.html$/, '');

    return {
      drama: {
        id: host.dramaId(id),
        source: host.source,
        sourceId: id,
        title: title,
        name: title,
        desc: '',
        intro: '',
        cover: cover,
        totalEpisode: 1
      },
      chapters: [{
        id: host.chapterId(id, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'madou-play://' + id,
        pageUrl: pageUrl,
        referer: pageUrl
      }]
    };
  },

  resolveMedia(task) {
    let id = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) id = fromDrama.slice(1).join(':');
    if (!id) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) id = fromChapter.slice(1, -1).join(':');
    }
    if (!id) throw new Error('無法確定視頻 ID');
    const pageUrl = SITE + '/' + id;

    // 10 分钟内重复播放直接复用（播放列表里的分片和 key 都不需要 token，能一直用）
    try {
      const done = host.cacheGet(readyKey(id));
      if (done) {
        const m = JSON.parse(done);
        if (m.url && m.playlist) {
          return {
            url: m.url,
            playlist: m.playlist,
            referer: SITE + '/',
            quality: 1080,
            durationMs: m.durationMs || 0,
            credentials: { referer: SITE + '/', origin: SITE, userAgent: UA }
          };
        }
      }
    } catch (e) { /* 忽略 */ }

    // share 地址：详情页缓存过来的优先，没有再拉详情页
    let share = '';
    try { share = String(host.cacheGet('share:' + id) || ''); } catch (e) { share = ''; }
    if (!share) {
      const html = get('/' + id);
      share = shareOf(html);
    }
    if (!share) throw new Error('麻豆社詳情頁裡沒有播放器');

    // token 只有 100 秒：现取现用；万一刚好过期（播放列表 404）就重试一次
    let playUrl = '';
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const url = shareInfo(share, pageUrl);
        const prepared = host.prepareWebMedia({ url: url, referer: SITE + '/', quality: 1080 }, '麻豆社');
        if (prepared && prepared.playlist) {
          playUrl = url;
          try {
            host.cacheSet(readyKey(id), JSON.stringify({
              url: prepared.url,
              playlist: prepared.playlist,
              durationMs: prepared.durationMs || 0
            }), 10 * 60 * 1000);
          } catch (e) { /* 忽略 */ }
          return prepared;
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw new Error('麻豆社取播放列表失敗' + (lastError ? '：' + lastError.message : ''));
  }
};
