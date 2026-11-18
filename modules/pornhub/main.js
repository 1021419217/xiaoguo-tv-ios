// Pornhub 站源模块 · 小果影视 模块 API 1
//
//   列表  /video?o=ht          热门
//         /video?o=mr          最新
//         /video?o=mv&t=w      本周最多观看
//         /video?o=tr&t=m      本月好评
//         翻页加 &page=N
//   搜索  /video/search?search={关键词}&page={N}
//   详情  /view_video.php?viewkey={key}
//   播放  详情页里的 mediaDefinitions（JSON 数组，要用括号配对解析，正则会被嵌套的 [] 截断）
//         里面 format=="hls" 的条目按 height 从高到低，取 1080p 封顶那一档
//
// 注意：不要带年龄验证 Cookie（platform=pc; age_verified=1）。
// 实测「iPhone UA + 该 Cookie」会被 302 跳到 cn.pornhub.com，而 App 的站源请求
// 不允许跨域重定向（provider_host.go），会直接报「接口重定向地址异常」。
// 不带 Cookie 时页面内容完全一样，媒体也不需要 Cookie。
//
// 站点自带中文界面（Accept-Language: zh-CN 时标题和分类都是中文）。
// 模块函数必须同步。

const SITE = 'https://www.pornhub.com';
// 与 App 内置的 UserAgent 保持一致（它决定了 Pornhub 是否按地区跳转）
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';

const HEADERS = {
  'User-Agent': UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
};

const CATEGORIES = [
  { id: 'hot', name: '熱門' },
  { id: 'new', name: '最新' },
  { id: 'week', name: '本週最多' },
  { id: 'rated', name: '本月好評' }
];

// 标题过滤：用户上传站，挡掉明显涉及未成年/非自愿的字样（与仓库主做法一致）
const BLOCKED = [
  'underage', 'under age', 'minor ', 'minors', 'preteen', 'pre-teen', 'child', 'kid ', 'kids', 'loli', 'shota',
  'schoolgirl', 'school girl', 'jailbait', 'rape', 'raped', 'forced', 'non-consensual', 'nonconsensual', 'non consent',
  'drugged', 'unconscious', 'sleeping', 'passed out', 'hidden cam', 'hidden camera', 'spy cam', 'upskirt',
  '未成年', '幼女', '萝莉', '蘿莉', '中学生', '中學生', '小学生', '小學生', '强姦', '强奸', '強姦', '强暴', '迷奸', '迷姦', '偷拍', '下药', '下藥'
];

function allowed(title) {
  const t = ' ' + String(title || '').toLowerCase() + ' ';
  for (const w of BLOCKED) if (t.indexOf(w) >= 0) return false;
  return true;
}

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#124;/g, '|')
    .replace(/\s+/g, ' ')
    .trim();
}

// Pornhub 会按地区把 www 跳到 cn / de 等子域。App 的站源请求不允许跨域重定向
//（provider_host.go：重定向目标 origin 变了就报「接口重定向地址异常」），
// 所以这里先探一次真实域名并记住，后续直连；同时请求本身打开 followRedirects 兜底。
let siteCache = null;

function headerValue(headers, name) {
  if (!headers) return '';
  const key = Object.keys(headers).filter(function (k) { return k.toLowerCase() === name; })[0];
  if (!key) return '';
  const v = headers[key];
  return Array.isArray(v) ? String(v[0] || '') : String(v || '');
}

function resolveSite() {
  if (siteCache && Date.now() - siteCache.at < 30 * 60 * 1000) return siteCache.host;
  let hostName = 'www.pornhub.com';
  try {
    const probe = host.fetch({
      method: 'HEAD',
      url: 'https://www.pornhub.com/',
      headers: HEADERS,
      followRedirects: false,
      anyStatus: true,
      limit: 2048
    });
    const loc = headerValue(probe.headers, 'location');
    const m = loc.match(/^https?:\/\/([^\/?#]+)/i);
    if (m && /pornhub\.com$/i.test(m[1])) hostName = m[1];
  } catch (e) { /* 用默认域名 */ }
  siteCache = { host: hostName, at: Date.now() };
  return hostName;
}

function siteRoot() {
  return 'https://' + resolveSite();
}

function fetchOnce(path, referer) {
  const root = siteRoot();
  const url = path.indexOf('http') === 0 ? path : root + path;
  const headers = {};
  for (const k in HEADERS) headers[k] = HEADERS[k];
  headers['Referer'] = referer || (root + '/');
  return host.fetch({ method: 'GET', url: url, headers: headers, followRedirects: true });
}

function get(path, referer) {
  let res = fetchOnce(path, referer);
  if (res.status < 200 || res.status >= 300) {
    // 学到的域名（例如 cn.）万一不通，退回默认域名再试一次
    siteCache = null;
    res = fetchOnce(path, referer);
  }
  if (res.status < 200 || res.status >= 300) throw new Error('Pornhub 返回 HTTP ' + res.status);
  return res.body || '';
}

// 括号配对的数组提取（字符串内的 ] 不算）
function balancedArray(text, marker) {
  const at = text.indexOf(marker);
  if (at < 0) return null;
  const start = text.indexOf('[', at);
  if (start < 0) return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text.charAt(i);
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '[') depth++;
    else if (c === ']') { depth--; if (depth === 0) return text.slice(start, i + 1); }
  }
  return null;
}

// 卡片：<li … data-video-vkey="{key}" …>
//         <a href="/view_video.php?viewkey=…" title="标题" …>
//           <img … videoThumb … data-image/src="缩略图">
//         <span class="time">12:34</span>
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/data-video-vkey="/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i].slice(0, 6000);
    const key = (seg.match(/^([a-z0-9]+)"/) || [])[1] || '';
    if (!key || seen[key]) continue;

    let title = '';
    const tAttr = seg.match(/<a[^>]+href="\/view_video\.php\?viewkey=[a-z0-9]+"[^>]+title="([^"]+)"/);
    if (tAttr) title = clean(tAttr[1]);
    if (!title) {
      const alt = seg.match(/<img[^>]+\salt="([^"]+)"/);
      if (alt) title = clean(alt[1]);
    }
    if (!title || !allowed(title)) continue;

    seen[key] = 1;
    let cover = '';
    const imgTag = seg.match(/<img[^>]*videoThumb[^>]*>/) || seg.match(/<img[^>]+>/);
    if (imgTag) {
      const tag = imgTag[0];
      for (const attr of ['data-image', 'data-mediumthumb', 'src', 'data-src', 'data-thumb_url']) {
        const m = tag.match(new RegExp('\\s' + attr + '="(https://[^"]+)"'));
        if (m && m[1].indexOf('blank.gif') < 0) { cover = m[1]; break; }
      }
    }
    const dur = seg.match(/<span class="time">([0-9:]+)<\/span>/) || seg.match(/<var class="duration">([0-9:]+)<\/var>/);
    const views = seg.match(/<div class="views">([^<]+)<\/div>/) || seg.match(/<span class="views"><var>([^<]+)<\/var>/);

    out.push({
      sourceId: key,
      title: title,
      cover: cover,
      duration: dur ? dur[1] : '',
      views: views ? clean(views[1]) : ''
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
  if (item.duration) bits.push(item.duration);
  if (item.views) {
    // 站点给的观看数已经带「次观看」，别再拼一次
    const views = String(item.views).replace(/\s+/g, ' ').trim();
    bits.push(/次观看|次觀看/.test(views) ? views : views + '次觀看');
  }
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
  if (item.author) {
    drama.author = item.author;
    if (item.authorId) drama.authorId = item.authorId;
    if (item.authorUrl) drama.authorUrl = item.authorUrl;
  }
  return drama;
}

function listPath(category, page) {
  const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
  const id = !category ? 'hot' : String(category);
  let base = '/video?o=ht';
  if (id === 'new') base = '/video?o=mr';
  else if (id === 'week') base = '/video?o=mv&t=w';
  else if (id === 'rated') base = '/video?o=tr&t=m';
  return base + (p > 1 ? '&page=' + p : '');
}

// 从 mediaDefinitions 里挑 HLS，按 height 从高到低
function hlsSources(html) {
  const raw = balancedArray(html, '"mediaDefinitions"');
  if (!raw) return [];
  let arr;
  try { arr = JSON.parse(raw); } catch (e) { return []; }
  if (!Array.isArray(arr)) return [];
  const list = [];
  for (const d of arr) {
    if (!d || d.format !== 'hls') continue;
    const url = String(d.videoUrl || '');
    if (url.indexOf('https://') !== 0) continue;
    const height = Number(d.height || 0) || (parseInt(String(d.quality || ''), 10) || 0);
    list.push({ url: url, height: height });
  }
  list.sort(function (a, b) { return b.height - a.height; });
  return list;
}

// master 里挑变体：优先 1080p 封顶
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

function prepareMedia(html, pageUrl) {
  const list = hlsSources(html);
  if (!list.length) throw new Error('Pornhub 頁面裡沒有 HLS 播放源（可能需要年齡驗證或地區受限）');
  const viaList = prepareFromList(list, pageUrl);
  if (viaList) return viaList;

  // 从最高画质往下逐档试（偶发单档失败就降一档，保证起播）
  const errors = [];
  for (const src of list) {
    try {
      const master = get(src.url, pageUrl);
      const variant = bestVariant(master, src.url);
      if (!variant) { errors.push(src.height + 'p:master 無變體'); continue; }
      const prepared = host.prepareWebMedia({ url: variant, referer: pageUrl, quality: src.height || 1080 }, 'Pornhub');
      if (prepared && prepared.playlist) return prepared;
      errors.push(src.height + 'p:列表為空');
    } catch (e) {
      errors.push(src.height + 'p:' + String(e.message || e).slice(0, 40));
    }
  }
  throw new Error('Pornhub 播放源取不到（' + errors.join(' / ') + '）');
}

// 从地址清单里逐档尝试。
// 关键：Pornhub 每个档位（1080P_4000K_…/master.m3u8）本身就是「只有一个变体」的 master，
// 所以不用先抓 master 再挑变体（那样多一次跨洋往返），直接把这一档交给 App 即可。
function prepareFromList(list, pageUrl) {
  const errors = [];
  for (const src of list) {
    try {
      const prepared = host.prepareWebMedia({ url: src.url, referer: pageUrl, quality: src.height || 1080 }, 'Pornhub');
      if (prepared && prepared.playlist) return prepared;
      errors.push(src.height + 'p:列表為空');
    } catch (e) {
      errors.push(src.height + 'p:' + String(e.message || e).slice(0, 40));
    }
  }
  if (errors.length) throw new Error('Pornhub 播放源取不到（' + errors.join(' / ') + '）');
  return null;
}

function readyKey(key) { return 'ready:' + key; }

function clockText(seconds) {
  const s = Math.max(0, Math.round(Number(seconds) || 0));
  if (!s) return '';
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = function (n) { return n < 10 ? '0' + n : String(n); };
  return h > 0 ? h + ':' + pad(m) + ':' + pad(sec) : m + ':' + pad(sec);
}

function detailOf(html, key) {
  const titleM = html.match(/property="og:title"[^>]+content="([^"]*)"/);
  const coverM = html.match(/property="og:image"[^>]+content="([^"]+)"/);
  const durM = html.match(/"video_duration"\s*:\s*"?(\d+)/);
  // 详情页 mediaDefinitions 里有真实档位，取最高的一档作为展示分辨率
  let height = 0;
  for (const src of hlsSources(html)) if (src.height > height) height = src.height;
  return {
    title: titleM ? clean(titleM[1]) : '',
    cover: coverM ? coverM[1].replace(/&amp;/g, '&') : '',
    durationMs: durM ? Number(durM[1]) * 1000 : 0,
    height: height
  };
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
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const p = Number(page || 1) < 1 ? 1 : Number(page || 1);
    let body = '';
    try {
      body = get('/video/search?search=' + encodeURIComponent(kw) + (p > 1 ? '&page=' + p : ''));
    } catch (e) {
      body = '';
    }
    const raw = parseCards(body);
    for (const it of raw) {
      try { host.cacheSet('card:' + it.sourceId, JSON.stringify({ title: it.title, cover: it.cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }
    }
    return { items: raw.map(toDrama), hasMore: raw.length >= 15 };
  },


  // App 点「作者」时调用：模特的视频列表页逐个试，拿不到就按名字搜索。
  author(authorId, authorName, page) {
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const id = String(authorId == null ? '' : authorId).trim().replace(/^\/+|\/+$/g, '');
    const name = clean(authorName || '');
    if (!id && !name) return { items: [], hasMore: false, warning: '缺少作者信息' };

    const candidates = [];
    if (id) {
      if (n > 1) {
        candidates.push('/model/' + id + '/videos?page=' + n);
        candidates.push('/pornstar/' + id + '/videos?page=' + n);
      } else {
        candidates.push('/model/' + id + '/videos');
        candidates.push('/model/' + id);
        candidates.push('/pornstar/' + id + '/videos');
        candidates.push('/pornstar/' + id);
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
          return toDrama(it);
        });
        const hasNext = new RegExp('page=' + (n + 1) + '(?=[^0-9]|$)').test(html);
        return { items: items, hasMore: hasNext || items.length >= 20 };
      } catch (e) {
        host.log('Pornhub 作者頁失敗(' + path + '): ' + e.message);
      }
    }

    if (name && n <= 1) {
      try {
        const raw = parseCards(get('/video/search?search=' + encodeURIComponent(name)));
        if (raw.length) {
          const items = raw.map(function (it) {
            it.author = name;
            if (id) it.authorId = id;
            return toDrama(it);
          });
          return { items: items, hasMore: false };
        }
      } catch (e) { /* 走空结果 */ }
    }

    return { items: [], hasMore: false, warning: '沒有取到該作者的作品' };
  },

  detail(sourceId) {
    const key = String(sourceId || '').trim().match(/^[a-z0-9]+$/);
    if (!key) throw new Error('視頻 ID 無效');
    const code = key[0];
    const pagePath = '/view_video.php?viewkey=' + code;
    const pageUrl = siteRoot() + pagePath;

    let title = '';
    let cover = '';
    try {
      const c = host.cacheGet('card:' + code);
      if (c) { const card = JSON.parse(c); title = card.title || ''; cover = card.cover || ''; }
    } catch (e) { /* 忽略 */ }

    let html = '';
    try { html = get(pagePath); } catch (e) { if (!title) throw e; }

    let durationMs = 0;
    let desc = '';
    let author = null;
    if (html) {
      author = parseAuthor(html, code);
      if (!author) host.log('Pornhub 詳情頁未解析到作者: ' + code);
      const info = detailOf(html, code);
      if (!title) title = info.title;
      if (!cover) cover = info.cover;
      durationMs = info.durationMs;
      const bits = [];
      if (info.height) bits.push(info.height + 'p');
      const clock = clockText(Math.round(durationMs / 1000));
      if (clock) bits.push(clock);
      desc = bits.join(' · ');
      try { host.cacheSet('card:' + code, JSON.stringify({ title: title, cover: cover }), 30 * 60 * 1000); } catch (e) { /* 忽略 */ }

      // 详情页只缓存「播放地址清单」（几百字节），不在这里抓列表：
      // 详情页要快（官方模块那种手感），点播放时再用这份清单抓 master(约 200B) + 列表(约 8KB)。
      try {
        const list = hlsSources(html);
        if (list.length) {
          host.cacheSet('srcs:' + code, JSON.stringify(list.map(function (x) { return { url: x.url, height: x.height }; })), 5 * 60 * 1000);
        }
      } catch (e) {
        host.log('Pornhub 播放地址缓存失敗: ' + e.message);
      }
    }
    if (!title) title = code;

    const drama = {
      id: host.dramaId(code),
      source: host.source,
      sourceId: code,
      title: title,
      name: title,
      desc: desc,
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
        id: host.chapterId(code, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'pornhub-play://' + code,
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
    const pageUrl = siteRoot() + '/view_video.php?viewkey=' + key;

    // 详情页已经存好了 HLS 地址清单，这里直接用它：只需 master + 列表两个小请求
    try {
      const cached = host.cacheGet('srcs:' + key);
      if (cached) {
        const list = JSON.parse(cached);
        const prepared = prepareFromList(list, pageUrl);
        if (prepared && prepared.playlist) return prepared;
      }
    } catch (e) { /* 走现场取 */ }

    const html = get('/view_video.php?viewkey=' + key);
    const prepared = prepareMedia(html, pageUrl);
    const info = detailOf(html, key);
    prepared.durationMs = prepared.durationMs || info.durationMs;
    return prepared;
  }
};
