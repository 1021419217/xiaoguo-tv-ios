// 黄色仓库（hsck）站源模块 · 小果影视 模块 API 1
//
// MacCMS 模板站：
//   首页  /                          最新
//   分类  /vodtype/{n}.html          翻页 ?page=N（每页 40 条）
//         1 日韩AV / 2 国产系列 / 3 欧美 / 4 成人动漫
//   搜索  /vodsearch/-------------.html?wd={关键词}
//   详情  /v{分类}/{id}-1-1.html
//
// 播放链路（站点自带的「手势校验」防采集）：
//   详情页里定义 AID / ASID / ANID / AK
//   → POST /static/count.php  body: id,sid,nid,tk,g,x,y,dt,sw,sh,tz,t
//   → {"ok":true,"u":"<base64>"} → 解码得到 index.m3u8
//   注意：必须带 g=1 和合理的 x/y/dt，否则返回 {"ok":false,"err":"gesture"}
//
// 模块函数必须同步。

// 主域名会换（111 → 222 …）。旧域名收到任何路径的请求都会 301 到「根路径」，
// 把 /vodsearch/…?wd=、/vodtype/…、/v5/… 整段丢掉 —— 于是搜索不管输什么
// 都返回首页那批视频，分类和详情也一样。所以这里放域名池，谁能用就用谁。
let SITE = 'https://222.ajmck.cc';
const MIRRORS = [
  'https://222.ajmck.cc',
  'https://333.9983hsck.cc',
  'https://444.9930hsck.cc',
  'https://hsccck.cc',
  'https://111.ajlck.cc',
  'https://222.9981hsck.cc',
  'https://222.ajjck.cc',
  'https://111.ajjck.cc'
];
let mirrorIndex = 0;
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

// 分类 id 不能含 / | \，用英文 slug，真实路径放 path
const CATEGORIES = [
  { id: 'latest', name: '最新', path: '/' },
  { id: 'jav', name: '日韓AV', path: '/vodtype/1.html' },
  { id: 'guochan', name: '國產系列', path: '/vodtype/2.html' },
  { id: 'west', name: '歐美', path: '/vodtype/3.html' },
  { id: 'anime', name: '成人動漫', path: '/vodtype/4.html' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// 首页标题是固定的「黄色仓库-hsck.tv」，其它页面的标题都会带内容后缀。
// 请求的不是根路径、却拿到这个标题，就说明被 301 甩回首页了 —— 结果不能用。
function looksLikeHome(body, path) {
  if (!path || path === '/' || path === '') return false;
  const t = String(body || '').match(/<title[^>]*>([\s\S]{0,160}?)<\/title>/i);
  if (!t) return false;
  const title = t[1].replace(/\s+/g, '');
  return /^黄色仓库[-_—]?hsck\.tv$/i.test(title) || /^hsck\.tv[-_—]?黄色仓库$/i.test(title);
}

function get(path, referer) {
  const absolute = path.indexOf('http') === 0;
  const order = [];
  for (let i = 0; i < MIRRORS.length; i++) order.push((mirrorIndex + i) % MIRRORS.length);
  let lastError = null;
  for (const idx of order) {
    const base = MIRRORS[idx];
    const url = absolute ? path : base + path;
    const headers = {};
    for (const k in HEADERS) headers[k] = HEADERS[k];
    headers['Referer'] = referer || (base + '/');
    let res = null;
    try {
      res = host.fetch({ method: 'GET', url: url, headers: headers, followRedirects: true });
    } catch (e) {
      lastError = e;
      continue;
    }
    if (!res || res.status < 200 || res.status >= 300) {
      lastError = new Error('黄色仓库返回 HTTP ' + (res ? res.status : '?'));
      continue;
    }
    const body = res.body || '';
    // 被甩回首页：换下一个域名重试，不能把首页当成搜索结果返回
    if (looksLikeHome(body, path)) {
      lastError = new Error('黄色仓库被重定向到首页（' + base + '）');
      continue;
    }
    mirrorIndex = idx;
    SITE = base;
    return body;
  }
  throw lastError || new Error('黄色仓库请求失败');
}

// 卡片：<li><div class="stui-vodlist__box">
//   <a class="stui-vodlist__thumb lazyload" href="/v5/290447-1-1.html" title="标题"
//      data-original="https://…/vod.jpg">
//     <span class="pic-text text-right">2:02:58</span></a>
//   <h4 class="title"><a href="…">标题</a></h4>
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<div class="stui-vodlist__box">/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i].slice(0, 1800);
    const link = seg.match(/href="(\/v\d+\/\d+-\d+-\d+\.html)"/);
    if (!link) continue;
    const path = link[1];
    if (seen[path]) continue;

    let title = '';
    const tAttr = seg.match(/<a[^>]+class="stui-vodlist__thumb[^"]*"[^>]+title="([^"]+)"/) ||
                  seg.match(/<h4 class="title"><a[^>]+title="([^"]+)"/) ||
                  seg.match(/<h4 class="title"><a[^>]*>([\s\S]*?)<\/a>/);
    if (tAttr) title = clean(tAttr[1]);
    if (!title) continue;

    seen[path] = 1;
    const cov = seg.match(/data-original="(https?:\/\/[^"]+)"/) ||
                seg.match(/data-src="(https?:\/\/[^"]+)"/) ||
                seg.match(/<img[^>]+src="(https?:\/\/[^"]+)"/);
    const dur = seg.match(/<span class="pic-text[^"]*">([^<]*)<\/span>/);
    out.push({
      sourceId: path,
      title: title,
      cover: cov ? cov[1] : '',
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

function listPath(category, page) {
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = !category ? 'latest' : String(category);
  const meta = CATEGORIES.filter(function (c) { return c.id === id; })[0];
  const base = meta ? meta.path : '/';
  if (base === '/') return p > 1 ? '/index.php/vod/show/id/1/page/' + p + '.html' : '/';
  return base + (p > 1 ? '?page=' + p : '');
}

// 详情页里提取 AID / ASID / ANID / AK
function credOf(html) {
  const id = (html.match(/AID\s*=\s*'?(\d+)'?/) || [])[1] || '';
  const sid = (html.match(/ASID\s*=\s*'?(\d+)'?/) || [])[1] || '1';
  const nid = (html.match(/ANID\s*=\s*'?(\d+)'?/) || [])[1] || '1';
  const tk = (html.match(/AK\s*=\s*'([^']+)'/) || html.match(/AK\s*=\s*"([^"]+)"/) || [])[1] || '';
  return { id: id, sid: sid, nid: nid, tk: tk };
}

function countKey(path) { return 'cred:' + path; }
function readyKey(path) { return 'ready:' + path; }

// POST /static/count.php 取播放地址（base64）
function playUrl(cred, referer) {
  const body = {
    id: cred.id, sid: cred.sid, nid: cred.nid, tk: cred.tk, g: '1',
    x: '512', y: '400', dt: '1200',
    sw: '1920', sh: '1080', tz: '-480', t: String(Date.now())
  };
  const encoded = Object.keys(body).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(body[k]);
  }).join('&');
  const res = host.fetch({
    method: 'POST',
    url: SITE + '/static/count.php',
    headers: {
      'User-Agent': UA,
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest',
      'Referer': referer,
      'Origin': SITE
    },
    body: encoded
  });
  if (res.status !== 200) throw new Error('取播放地址失敗 HTTP ' + res.status);
  let json;
  try { json = JSON.parse(res.body || '{}'); } catch (e) { throw new Error('播放接口返回的不是 JSON'); }
  if (!json || json.ok !== true || !json.u) {
    throw new Error('播放接口拒絕（' + ((json && json.err) || '未知') + '）');
  }
  const decoded = host.utf8Decode(host.base64Decode(json.u));
  if (!decoded || decoded.indexOf('http') !== 0) throw new Error('播放地址解碼失敗');
  return decoded;
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
    return { items: raw.map(toDrama), hasMore: raw.length >= 20 };
  },

  search(page, query) {
    const kw = String(query || '').replace(/\s+/g, ' ').trim();
    if (!kw) return { items: [], hasMore: false };
    const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const path = '/vodsearch/-------------' + (p > 1 ? p : '1') + '---.html?wd=' + encodeURIComponent(kw);
    const raw = parseCards(get(path));
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 20 };
  },


  // App 点「作者」时调用。这类站的「作者」多是主演/演员，没有作者主页，
  // 直接用名字站内搜索，结果里回填作者，方便继续点。
  author(authorId, authorName, page) {
    const kw = clean(authorName || '') || String(authorId || '').trim();
    if (!kw) return { items: [], hasMore: false, warning: '缺少作者信息' };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const path = '/vodsearch/-------------' + n + '---.html?wd=' + encodeURIComponent(kw);
    try {
      const raw = parseCards(get(path));
      const items = raw.map(function (it) {
        it.author = authorName || kw;
        if (authorId) it.authorId = authorId;
        return toDrama(it);
      });
      if (!items.length) return { items: [], hasMore: false, warning: '沒有搜到該作者的作品' };
      return { items: items, hasMore: raw.length >= 20 };
    } catch (e) {
      return { items: [], hasMore: false, warning: e.message };
    }
  },

  detail(sourceId) {
    const path = String(sourceId || '').trim();
    if (!/^\/v\d+\/\d+-\d+-\d+\.html$/.test(path)) throw new Error('視頻地址無效');
    const pageUrl = SITE + path;

    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + path);
      if (c) { const card = JSON.parse(c); title = card.title || ''; cover = card.cover || ''; }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get(path); } catch (e) { if (!title) throw e; }

    let author = null;
    if (html) {
      author = parseAuthor(html, path);
      if (!author) host.log('黄色仓库 詳情頁未解析到作者: ' + path);
      if (!title) {
        const h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
        if (h1) title = clean(h1[1]);
        if (!title) {
          const og = html.match(/property="og:title"[^>]+content="([^"]*)"/);
          if (og) title = clean(og[1]);
        }
        // 这个站详情页没有 h1 / og:title，标题在 <title> 里（形如「标题 - 黄色仓库...」）
        if (!title) {
          const tt = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
          if (tt) title = clean(tt[1]);
        }
        title = title.replace(/\s*[-–|]\s*黄色仓库[\s\S]*$/i, '').replace(/\s*-\s*$/, '').trim();
      }
      if (!cover) {
        const og = html.match(/property="og:image"[^>]+content="([^"]+)"/) ||
                   html.match(/data-original="(https?:\/\/[^"]+vod\.jpg)"/);
        if (og) cover = og[1];
      }
      try { host.cacheSet('card:' + path, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }

      // 播放凭证只在详情页出现：缓存起来，点播放时直接用
      try {
        const cred = credOf(html);
        if (cred.id && cred.tk) {
          host.cacheSet(countKey(path), JSON.stringify(cred), 30 * 60 * 1000);
        }
      } catch (e) {
        host.log('黄色仓库凭证缓存失敗: ' + e.message);
      }
    }
    if (!title) title = path;

    const drama = {
      id: host.dramaId(path),
      source: host.source,
      sourceId: path,
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
        id: host.chapterId(path, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'hsck-play://' + path,
        pageUrl: pageUrl,
        referer: pageUrl
      }]
    };
  },

  resolveMedia(task) {
    let path = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2) path = fromDrama.slice(1).join(':');
    if (!path) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 3) path = fromChapter.slice(1, -1).join(':');
    }
    if (!path) throw new Error('無法確定視頻地址');
    const pageUrl = SITE + path;

    // 5 分钟内重复播放直接复用
    try {
      const done = host.cacheGet(readyKey(path));
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

    // 凭证：详情页缓存的优先，没有再拉详情页
    let cred = null;
    try {
      const c = host.cacheGet(countKey(path));
      if (c) cred = JSON.parse(c);
    } catch (e) { cred = null; }
    if (!cred || !cred.id || !cred.tk) cred = credOf(get(path));
    if (!cred.id || !cred.tk) throw new Error('黃色倉庫詳情頁裡沒有播放憑證');

    const url = playUrl(cred, pageUrl);
    const prepared = host.prepareWebMedia({ url: url, referer: SITE + '/', quality: 1080 }, '黄色仓库');
    try {
      host.cacheSet(readyKey(path), JSON.stringify({
        url: prepared.url,
        playlist: prepared.playlist,
        durationMs: prepared.durationMs || 0
      }), 5 * 60 * 1000);
    } catch (e) { /* 忽略 */ }
    return prepared;
  }
};
