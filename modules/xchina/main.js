// xChina（小黄书）站源模块 · 小果影视 / 红果鉴 模块 API 1
//
//   首页最新  /videos/new                分页 /videos/new/{n}
//   分类      /video-category/{slug}     分页 /video-category/{slug}/{n}
//             slug: jav / cn / movie / ai / other
//   搜索      /search?q={关键词}&type=video&page={n}
//   详情      /video/{id}
//   播放      #video-player[data-src] → /hls/{id}/master.m3u8
//             master → index.m3u8?n=… → AES-128 key + 绝对分片，交给 App 的播放代理处理
//
// 站点在 Cloudflare 后面，必须带全套浏览器指纹头，否则 403。
// 模块函数必须同步。

const SITE = 'https://xchina.co';
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

const CATEGORIES = [
  { id: 'new', name: '最新' },
  { id: 'cn', name: '国产' },
  { id: 'jav', name: '日本AV' },
  { id: 'movie', name: '电影' },
  { id: 'ai', name: 'AI视频' },
  { id: 'other', name: '其他' }
];

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
  if (res.status === 403) throw new Error('xChina 拦截了请求（Cloudflare 403）');
  if (res.status < 200 || res.status >= 300) throw new Error('xChina 返回 HTTP ' + res.status);
  return res.body || '';
}

// 卡片：<a href="/video/{id}"><span class="ph"><img src="…/cover/{id}.webp" alt="标题">
//        <span class="cover-pill">58:51</span></span><span class="line-clamp-2">标题</span></a>
function parseCards(html) {
  const out = [];
  const seen = {};
  const re = /href="\/video\/([0-9a-f]{10,16})"/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const id = m[1];
    if (seen[id]) continue;
    seen[id] = 1;
    const chunk = html.substring(m.index, m.index + 1400);
    const alt = chunk.match(/<img[^>]+alt="([^"]*)"/);
    let title = alt ? clean(alt[1]) : '';
    if (!title) {
      const text = chunk.match(/line-clamp-2[^>]*>([^<]{2,200})</);
      if (text) title = clean(text[1]);
    }
    if (!title) continue;
    const dur = chunk.match(/tabular-nums">\s*([0-9]{1,3}:[0-9]{2})/);
    out.push({
      sourceId: id,
      title: title,
      cover: COVER + id + '.webp',
      duration: dur ? dur[1] : ''
    });
  }
  return out;
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  if (!category || category === 'new') return n === 1 ? '/videos/new' : '/videos/new/' + n;
  return n === 1 ? '/video-category/' + category : '/video-category/' + category + '/' + n;
}

// ── 作者（演员 / 模特）抓取 ─────────────────────────────
// xChina 详情页有两个来源，都不依赖窗口位置，整页扫即可：
//   ① JSON-LD VideoObject 的 actor：
//      {"@type":"VideoObject",…,"actor":[{"@type":"Person","name":"年年",
//        "url":"https://xchina.co/model/62456cb2ddafa"}]}
//      整页只有这一份，推荐位不会掺进来，是首选。
//   ② 标题下方的作者胶囊：<a href=/model/xxxx class="…rounded-full…">…名字</a>
//      站点输出的是「无引号属性」的压缩 HTML，所以两种写法都要认。
// 目标只是拿到一个名称 + 主页地址，够 App 显示作者胶囊并进入该作者作品页。

// 页面里内嵌的头像都是几十 KB 的 base64，先剔掉，否则任何「取标签内文本」的正则都会被打爆。
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

function xcModelId(url) {
  const m = String(url || '').match(/\/model\/([A-Za-z0-9_-]{3,40})/);
  return m ? m[1] : '';
}

// 名字闸门：按钮、导航、纯数字、时间码都不算作者名
const XC_NAME_BAD = /^(视频|視頻|首页|首頁|分类|分類|标签|標籤|更多|热门|熱門|最新|推荐|推薦|收藏|评论|評論|播放|登录|登錄|注册|註冊|下载|下載|返回|主页|主頁|全部|查看全部|演员|演員|模特|详情|詳情|第.部分)$/;

function xcNameOk(name) {
  const n = String(name == null ? '' : name).replace(/\s+/g, ' ').trim();
  if (!n || n.length > 24) return false;
  if (XC_NAME_BAD.test(n)) return false;
  if (/^[\d\s:：.·-]+$/.test(n)) return false;
  if (/[\/\\]|https?:|www\./.test(n)) return false;
  return true;
}

// ── 详情页结构化数据：直接 JSON.parse ld+json ──
// 旧实现用正则「name 后必须跟 url」，无模特页的演员（只有 name）直接丢失；
// 多演员时还可能把下一个演员的 url 错配过来。JSON.parse 才能拿到 identifier。
function xcLdNodes(html) {
  const out = [];
  const blocks = String(html || '').match(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi) || [];
  for (let i = 0; i < blocks.length; i++) {
    const body = blocks[i].replace(/^[\s\S]*?>/, ' ').replace(/<\/script>$/i, '').trim();
    if (!body) continue;
    try {
      const data = JSON.parse(body);
      const arr = Array.isArray(data) ? data : [data];
      for (let j = 0; j < arr.length; j++) if (arr[j] && arr[j]['@type']) out.push(arr[j]);
    } catch (e) { /* 非纯 JSON 跳过 */ }
  }
  return out;
}

function xcLdVideo(html) {
  const nodes = xcLdNodes(html);
  let video = null, crumbs = null;
  for (let i = 0; i < nodes.length; i++) {
    const t = nodes[i]['@type'];
    if (t === 'VideoObject') video = nodes[i];
    else if (t === 'BreadcrumbList') crumbs = nodes[i];
  }
  return { video: video, crumbs: crumbs };
}

// 演员：name 一定有；url/identifier 只有「有模特页」的才有（如菠萝包这类没有）
function xcJsonAuthors(html) {
  const video = xcLdVideo(html).video;
  const out = [];
  if (!video || !video.actor) return out;
  const raw = Array.isArray(video.actor) ? video.actor : [video.actor];
  for (let i = 0; i < raw.length; i++) {
    const a = raw[i];
    if (!a) continue;
    const name = clean(a.name || '').replace(/\s+/g, ' ').trim();
    if (!xcNameOk(name)) continue;
    const url = a.url ? xcUrl(a.url) : '';
    let id = a.identifier != null ? String(a.identifier) : '';
    if (!id && url) id = xcModelId(url);
    out.push({ author: name, authorId: id, authorUrl: url, url: url });
  }
  return out;
}

// 系列（片商）：面包屑里 /video-series/ 那一项；兜底取倒数第二项（末项是片名）
function xcLdSeries(html) {
  const items = (xcLdVideo(html).crumbs || {}).itemListElement || [];
  let series = '';
  for (let i = 0; i < items.length; i++) {
    if (/\/video-series\//.test(String(items[i].item || ''))) series = items[i].name || series;
  }
  if (!series && items.length >= 2) series = items[items.length - 2].name || '';
  series = clean(series).replace(/\s+/g, ' ').trim();
  if (!xcNameOk(series) || /^(首页|视频|影片|分类|全部)$/.test(series)) return '';
  return series;
}

function xcDomAuthors(html) {
  const out = [];
  const src = xcStripData(html);
  const re = /<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]{0,600}?)<\/a>/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const href = m[1] || m[2] || m[3] || '';
    if (href.indexOf('/model/') < 0) continue;
    const text = clean(m[4].replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
    if (!xcNameOk(text)) continue;
    const url = xcUrl(href);
    out.push({ author: text, authorId: xcModelId(url), authorUrl: url });
  }
  return out;
}

function xcAuthor(html) {
  // ① JSON-LD：整页唯一、最可靠；有 name 就算，不强求有 url（菠萝包这类没有模特页）
  const json = xcJsonAuthors(html);
  if (json.length) return json[0];
  // ② 作者胶囊：按 UID 去重投票，同一个 id 出现 2 次以上才算。
  //    详情页侧栏也可能有 /model/ 链接（推荐），投票能挡掉只出现一次的。
  const dom = xcDomAuthors(html);
  if (!dom.length) return null;
  const tally = {};
  for (const a of dom) {
    const sig = String(a.authorId || a.author).toLowerCase();
    if (!tally[sig]) tally[sig] = { n: 0, info: a };
    tally[sig].n += 1;
  }
  let best = null;
  for (const k in tally) if (!best || tally[k].n > best.n) best = tally[k];
  if (best && best.n >= 2) return best.info;
  // 只有一个 /model/ 链接时也认（页面上没有推荐位）
  const uniq = Object.keys(tally);
  if (uniq.length === 1) return dom[0];
  return null;
}

function xcAuthorDiag(html) {
  const json = xcJsonAuthors(html);
  const dom = xcDomAuthors(html);
  const models = (xcStripData(html).match(/\/model\/[A-Za-z0-9_-]+/g) || []).length;
  const ld = /application\/ld\+json/.test(html);
  const actors = /"actor"\s*:/.test(html);
  const dur = String(html).match(/时长\s*([0-9]{1,3}:[0-9]{2})/);
  return 'ld' + (ld ? '有' : '无') + '/actor' + (actors ? '有' : '无') +
    '/解析' + json.length + '条/胶囊' + dom.length + '条/model链接' + models + '处' +
    '/时长[' + (dur ? dur[1] : '') + ']';
}

// 元数据：详情页信息表用（源给什么列什么）
function xcMeta(html) {
  const meta = {};
  const video = xcLdVideo(html).video || {};
  // 时长：页面「时长 mm:ss」优先，再 JSON-LD duration(ISO8601)
  const dur = String(html).match(/时长\s*([0-9]{1,3}:[0-9]{2})/);
  let durText = dur ? dur[1] : '';
  if (!durText) {
    const iso = String(video.duration || '').match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
    if (iso && (iso[1] || iso[2] || iso[3])) {
      const h = Number(iso[1] || 0), mm = Number(iso[2] || 0), ss = Number(iso[3] || 0);
      durText = (h ? h + ':' : '') + (h && mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
    }
  }
  if (durText) meta['时长'] = durText;

  const up = String(video.uploadDate || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (up) meta['发行'] = up[1] + '-' + up[2] + '-' + up[3];

  const series = xcLdSeries(html);
  if (series) meta['系列'] = series;
  return meta;
}

// 站点部分页面输出「无引号属性」的压缩 HTML（href=/video/6af9ea6c048db），
// parseCards 的 href="…" 在那种页面一条都匹配不到，这里做兼容兜底。
function parseLooseCards(html) {
  const out = [];
  const seen = {};
  const src = xcStripData(html);
  const re = /(?:https?:\/\/xchina\.co)?\/video\/([0-9a-f]{10,16})/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const id = m[1];
    if (seen[id]) continue;
    seen[id] = 1;
    const chunk = src.substring(m.index, m.index + 1600);
    const alt = chunk.match(/alt\s*=\s*(?:"([^"]{2,200})"|([^\s>]{2,200}))/);
    let title = alt ? clean(alt[1] || alt[2]) : '';
    if (!title) {
      const t = chunk.match(/<title[^>]*>([\s\S]{2,200}?)<\/title>/);
      if (t) title = clean(t[1]);
    }
    title = String(title).replace(/\s+/g, ' ').trim();
    if (!title || title.length < 2) continue;
    const dur = chunk.match(/tabular-nums[^>]*>\s*([0-9]{1,3}:[0-9]{2})/);
    out.push({ sourceId: id, title: title, cover: COVER + id + '.webp', duration: dur ? dur[1] : '' });
  }
  return out;
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

// 把 master 和变体列表一起抓下来，并把变体列表文本直接交给播放器。
// App 的 nativeOpen 对 media.Playlist 非空时直接从内存返回，不再回源 —— 这就是「秒播」的关键。
function playlistBundle(id) {
  const masterUrl = SITE + '/hls/' + id + '/master.m3u8';
  const master = get('/hls/' + id + '/master.m3u8', SITE + '/video/' + id);

  // master 里取出最高码率的变体
  let bestUrl = '';
  let bestBandwidth = -1;
  const lines = master.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.charAt(0) === '#') continue;
    const prev = (lines[i - 1] || '').trim();
    const bandwidth = Number((prev.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const absolute = line.indexOf('http') === 0 ? line : masterUrl.replace(/master\.m3u8.*$/, '') + line;
    if (bandwidth > bestBandwidth) {
      bestBandwidth = bandwidth;
      bestUrl = absolute;
    }
  }

  if (!bestUrl) {
    // master 本身就是媒体列表（少见），直接用它
    return { url: masterUrl, playlist: master, durationMs: m3u8DurationMs(master) };
  }

  const variant = get(bestUrl, SITE + '/video/' + id);
  if (variant.indexOf('#EXTM3U') < 0) throw new Error('xChina 播放列表无效');
  return { url: bestUrl, playlist: variant, durationMs: m3u8DurationMs(variant) };
}

function m3u8DurationMs(text) {
  let total = 0;
  const re = /#EXTINF:([0-9.]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) total += parseFloat(m[1]) || 0;
  return Math.round(total * 1000);
}

function cacheKey(id) {
  return 'playlist:' + id;
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
    const html = get('/search?q=' + encodeURIComponent(kw) + '&type=video&page=' + n);
    const items = parseCards(html).map(toDrama);
    return { items: items, hasMore: items.length >= 12 };
  },

  // 作者（模特）全部作品：/model/{slug}，翻页先试 ?page=N，再试 /N
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
      const base = SITE + '/model/' + id;
      const tries = n > 1 ? [base + '?page=' + n, base + '/' + n] : [base];
      for (const url of tries) {
        try {
          const html = get(url);
          let items = pack(parseCards(html), base);
          if (!items.length) items = pack(parseLooseCards(html), base);
          if (items.length) return { items: items, hasMore: items.length >= 12 };
        } catch (e) {
          host.log('xChina作者页失败(' + url.replace(SITE, '') + '): ' + e.message);
        }
      }
    }

    // 兜底：按名字搜索（只在第 1 页，翻页时不做，否则会把搜索结果当成翻页混进来）
    if (name && n <= 1) {
      try {
        const html = get('/search?q=' + encodeURIComponent(name) + '&type=video&page=1');
        let items = pack(parseCards(html), '');
        if (!items.length) items = pack(parseLooseCards(html), '');
        if (items.length) return { items: items, hasMore: items.length >= 12, warning: '按作者名搜索' };
      } catch (e) {
        host.log('xChina作者名搜索失败: ' + e.message);
      }
    }
    return { items: [], hasMore: false };
  },

  detail(sourceId) {
    const id = String(sourceId || '').match(/[0-9a-f]{10,16}/);
    if (!id) throw new Error('缺少视频 ID');
    const key = id[0];
    const page = SITE + '/video/' + key;
    const html = get('/video/' + key);

    const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
    let title = t ? clean(t[1]) : '';
    title = title.replace(/\s*-\s*[^-]*小黄书.*$/i, '').replace(/\s*-\s*xChina.*$/i, '').trim();
    const cover = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
    const desc = html.match(/<meta[^>]+name="description"[^>]+content="([^"]*)"/);

    const drama = {
      id: host.dramaId(key),
      source: host.source,
      sourceId: key,
      title: title || key,
      name: title || key,
      desc: desc ? clean(desc[1]).substring(0, 120) : '',
      intro: '',
      cover: cover ? cover[1] : (COVER + key + '.webp'),
      totalEpisode: 1
    };

    // ── 作者（演员/模特）与信息表 ── 新增，不改动上面任何字段
    try {
      const author = xcAuthor(html);
      if (author) {
        drama.author = author.author;
        if (author.authorId) drama.authorId = author.authorId;
        if (author.authorUrl) drama.authorUrl = author.authorUrl;
      }
      const allAuthors = xcJsonAuthors(html).filter(function (a) { return xcNameOk(a.author); });
      const meta = xcMeta(html);
      for (const mk in meta) drama[mk] = meta[mk];
      // 信息表用的是中文 key（时长/发行/系列），App 只认这些字段名，
      // 不映射过去界面就不显示——之前数据全抓到却看不到，就是这里断的。
      if (meta['时长']) drama.durationText = meta['时长'];
      if (meta['发行']) drama.onlineDate = meta['发行'];
      if (meta['系列']) drama.maker = meta['系列'];
      // 演员数组：只有一个模特时 xcMeta 不会填「演员」，这里统一取全部
      const actorNames = (allAuthors || [])
        .map(function (a) { return a.author; })
        .filter(function (n) { return n; });
      if (actorNames.length) drama.actors = actorNames;
      if (author) {
        host.log('xChina作者 v1.3.0: ' + author.author + (author.authorId ? ' (model ' + author.authorId + ')' : ' (无 model 链接)'));
      } else {
        host.log('xChina作者 v1.3.0: 未取到（' + xcAuthorDiag(html) + '）');
      }
    } catch (e) {
      host.log('xChina作者 v1.3.0: 解析异常 ' + e.message);
    }

    const chapter = {
      id: host.chapterId(key, 'video'),
      source: host.source,
      title: title || '正片',
      currentEpisode: 1,
      pageUrl: page,
      referer: page
    };

    // 在详情页就把播放列表抓好放进缓存（用户这时还在看简介），
    // 点播放时零网络请求，直接开播。
    try {
      host.cacheSet(cacheKey(key), JSON.stringify(playlistBundle(key)), 10 * 60 * 1000);
    } catch (e) {
      host.log('xChina 预取播放列表失败：' + e.message);
    }

    return { drama: drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2 && /^[0-9a-f]{10,16}$/.test(fromDrama[1])) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 2) key = String(fromChapter[1]).trim();
    }
    if (!key) throw new Error('无法确定视频 ID');

    const page = SITE + '/video/' + key;

    // 优先用详情页预取好的列表；缓存过期或缺失时再现场抓
    let bundle = null;
    try {
      const cached = host.cacheGet(cacheKey(key));
      if (cached) bundle = JSON.parse(cached);
    } catch (e) {
      bundle = null;
    }
    if (!bundle || !bundle.url || !bundle.playlist) {
      bundle = playlistBundle(key);
      try {
        host.cacheSet(cacheKey(key), JSON.stringify(bundle), 10 * 60 * 1000);
      } catch (e) { /* 忽略 */ }
    }

    // playlist 非空时 App 直接从内存返回，播放器拿到的就是这份列表
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
