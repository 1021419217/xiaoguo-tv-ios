// Jable —— 服务端渲染的 KVS 模板站，详情页里直接给出 hlsUrl。
// 移植自 iDuanJu 的 JableProvider（Apache-2.0），按小果影视的模块接口重写：
// 不做异步、只依赖 host.fetchText / host.base64Decode 这类宿主能力。

const SITE = 'https://jable.tv';
const MIRRORS = ['https://jable.tv', 'https://fs1.app'];
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const LANG = 'kt_rt_lang=zh';
const SITE_HOST = 'jable.tv';
const SITE_HOST_ALT = 'fs1.app';

// 只保留站点上确实存在的入口：以前写的 /categories/uncensored/ 是 404，
// 点进去必然报错，已换成站点导航里真实存在的页面。
const CATEGORIES = [
  { id: 'latest', name: '最近更新', path: '/latest-updates/' },
  { id: 'new', name: '新片上架', path: '/new-release/' },
  { id: 'hot-today', name: '今日热门', path: '/hot/?sort_by=video_viewed_today' },
  { id: 'hot-week', name: '本周热门', path: '/hot/?sort_by=video_viewed_week' },
  { id: 'hot', name: '热门总榜', path: '/hot/' },
  { id: 'zh-sub', name: '中文字幕', path: '/categories/chinese-subtitle/' },
];

function categories() {
  return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
}

function validCategory(category) {
  return category === '' || CATEGORIES.some((entry) => entry.id === category);
}

function originOf(address) {
  const matched = /^(https?:\/\/[^\/]+)/.exec(address || '');
  return matched ? matched[1] : SITE;
}

// Jable 也挂在 Cloudflare 后面：纯 HTTP 会拿到 403「Just a moment」。
// App 里做过站点验证后，host.challengeCookie 给出 cf_clearance，
// host.challengeUA 给出解验证时 WebView 的真实 UA（cf_clearance 绑 UA，
// 必须成对使用）。以前这里只带一句写死的语言 cookie，验证完了也照样 403，
// 而且 fetchText 把 403 变成一句普通错误，首页连「去验证」都不给。
function agent() {
  const learned =
    host.challengeUA(SITE_HOST) || host.challengeUA(SITE_HOST_ALT);
  return learned || UA;
}

function cookieHeader() {
  const learned =
    host.challengeCookie(SITE_HOST) || host.challengeCookie(SITE_HOST_ALT);
  return learned ? LANG + '; ' + learned : LANG;
}

function looksLikeChallenge(status, text) {
  if (status === 403 || status === 429 || status === 503) return true;
  const head = String(text || '').slice(0, 6000);
  return /_cf_chl_opt|cf-chl-|just a moment|attention required|checking your browser|verify you are human|请稍候|請稍候/i.test(
    head
  );
}

function request(base, path, referer) {
  const response = host.fetch({
    url: base + path,
    headers: {
      Accept:
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Upgrade-Insecure-Requests': '1',
      Referer: referer || SITE + '/',
      'User-Agent': agent(),
      Cookie: cookieHeader(),
    },
    anyStatus: true,
    followRedirects: true,
    timeoutMs: 25000,
  });
  return {
    status: response.status || 0,
    text: response.body || '',
    base: base,
  };
}

function fetchPage(path, referer) {
  let status = 0;
  let text = '';
  let failed = false;
  for (const base of MIRRORS) {
    try {
      const response = request(base, path, referer);
      if (!looksLikeChallenge(response.status, response.text) && response.status < 400) {
        return { text: response.text, base: originOf(response.base) };
      }
      status = response.status;
      text = response.text;
      failed = true;
    } catch (_) {
      failed = true;
    }
  }
  if (!failed) throw new Error('Jable 无法连接，请检查网络');
  if (looksLikeChallenge(status, text)) {
    const error = new Error(
      cookieHeader() !== LANG
        ? '站点仍然要求浏览器验证（通行 cookie 未被接受），请再验证一次'
        : 'Jable 要求浏览器验证，请点「去验证」完成验证后再试'
    );
    error.retryable = true;
    throw error;
  }
  const error = new Error('Jable 返回 HTTP ' + status);
  error.retryable = status >= 500 || status === 408;
  throw error;
}

function pageURL(base, page) {
  if (page <= 1) return base;
  return base + (base.indexOf('?') >= 0 ? '&' : '?') + 'from=' + page;
}

function resolve(base, address) {
  if (!address) return '';
  if (/^https?:\/\//.test(address)) return address;
  try {
    return host.resolveUrl(base, address);
  } catch (_) {
    return address;
  }
}

function clean(text) {
  return (text || '')
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

function clock(text) {
  const parts = String(text || '').trim().split(':');
  let seconds = 0;
  for (const part of parts) {
    const value = parseInt(part, 10);
    if (isNaN(value)) return 0;
    seconds = seconds * 60 + value;
  }
  return parts.length > 1 ? seconds : 0;
}

function count(text) {
  // 观看数会用空格做千分位（`2 436`），先去掉千分位再解析。
  const raw = String(text || '')
    .replace(/[,\s]/g, '')
    .trim()
    .toUpperCase();
  const matched = /^([0-9.]+)\s*([KMB]?)/.exec(raw);
  if (!matched) return 0;
  const value = parseFloat(matched[1]);
  const unit = matched[2];
  const scale = unit === 'B' ? 1e9 : unit === 'M' ? 1e6 : unit === 'K' ? 1e3 : 1;
  return Math.round(value * scale);
}

function codeOf(title) {
  const matched = /([A-Za-z]{2,6})-?(\d{2,6})/.exec(title || '');
  return matched ? matched[1].toUpperCase() + '-' + matched[2] : '';
}

// —— HTML 解析 ——
// Jable 的页面会被站点的优化插件压成「无引号属性」形式：
//   <a href=https://jable.tv/videos/mfyd-215/>
//   <div class=img-box><img class=lazyloaded src="data:..." data-src=https://... 1.jpg>
// 只认 href="..." 的写法会一条都匹配不到，整页空列表。
// 所以属性一律用下面这个兼容三种写法的解析器取值。

function attrOf(tag, name) {
  const pattern = new RegExp(
    '(?:^|[\\s"\'])(' + name + ')\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
    'i'
  );
  const matched = pattern.exec(tag);
  if (!matched) return '';
  if (matched[2] !== undefined) return matched[2];
  if (matched[3] !== undefined) return matched[3];
  return matched[4] || '';
}

function classOf(tag) {
  return attrOf(tag, 'class');
}

// 懒加载占位的 base64 图有几十 KB，切块前先整段清掉，否则一张卡的
// HTML 会被占位图撑爆、真正的 data-src 落到切块范围之外。
function stripDataURIs(html) {
  return String(html || '')
    .replace(/([\w:-]+)\s*=\s*"data:[^"]*"/gi, '$1=""')
    .replace(/([\w:-]+)\s*=\s*'data:[^']*'/gi, "$1=''")
    .replace(/([\w:-]+)\s*=\s*data:[^\s>]+/gi, '$1=""');
}

function videoIdOf(href) {
  const matched = /\/videos\/([A-Za-z0-9_-]+)\/?/.exec(href || '');
  return matched ? matched[1] : '';
}

function videoAnchors(html) {
  const out = [];
  const pattern = /<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
  let matched = pattern.exec(html);
  while (matched) {
    const href = matched[1] || matched[2] || matched[3] || '';
    const id = videoIdOf(href);
    if (id !== '') out.push({ id: id, start: matched.index, href: href });
    matched = pattern.exec(html);
  }
  return out;
}

// 优先按卡片容器切块（封面、标题、时长都在同一个 video-img-box 里），
// 这样同一部片子的封面链接和标题链接不会被切成两段。
function boxChunks(html) {
  const out = [];
  const pattern = /<div\b[^>]*>/gi;
  const starts = [];
  let matched = pattern.exec(html);
  while (matched) {
    const cls = classOf(matched[0]);
    if (/(^|\s)video-img-box(\s|$)/.test(cls)) {
      starts.push({ start: matched.index, tag: matched[0] });
    }
    matched = pattern.exec(html);
  }
  for (let index = 0; index < starts.length; index++) {
    const from = starts[index].start;
    const to = index + 1 < starts.length ? starts[index + 1].start : html.length;
    out.push(html.slice(from, Math.min(to, from + 12000)));
  }
  return out;
}

// 兜底：按「详情链接首次出现」切块。同一张卡里标题也链到同一部片子，
// 所以必须以「第一次出现」为界，否则会把 h6 标题切到下一块去。
function anchorChunks(html) {
  const anchors = videoAnchors(html);
  const first = {};
  const order = [];
  for (const anchor of anchors) {
    if (first[anchor.id] === undefined) {
      first[anchor.id] = anchor.start;
      order.push(anchor.id);
    }
  }
  const out = [];
  for (let index = 0; index < order.length; index++) {
    const from = first[order[index]];
    const to = index + 1 < order.length ? first[order[index + 1]] : html.length;
    out.push(html.slice(from, Math.min(to, from + 12000)));
  }
  return out;
}

function usableCover(url) {
  const value = String(url || '').trim();
  if (value === '') return false;
  if (/^data:/i.test(value)) return false;
  // 懒加载占位图 / 1px 透明图 / 纯色块都不能当封面。
  if (/blank|spacer|placeholder|transparent|1x1|lazy\.(gif|png|svg)/i.test(value)) return false;
  if (/\.svg(\?|#|$)/i.test(value)) return false;
  return (
    /\.(jpe?g|png|webp|avif|gif)(\?|#|$)/i.test(value) ||
    /\/(contents|uploads|media|screenshots)\//i.test(value)
  );
}

const COVER_ATTRS = [
  'data-src',
  'data-original',
  'data-lazy-src',
  'data-lazysrc',
  'data-echo',
  'data-thumb',
  'data-poster',
  'data-image',
  'data-cover',
  'src',
];

function coverOf(chunk) {
  const images = chunk.match(/<img\b[^>]*>/gi) || [];
  for (const tag of images) {
    for (const attr of COVER_ATTRS) {
      const value = attrOf(tag, attr);
      if (usableCover(value)) return value;
    }
    // 响应式图片：srcset 里取第一张。
    const srcset = attrOf(tag, 'srcset') || attrOf(tag, 'data-srcset');
    if (srcset) {
      const first = srcset.split(',')[0].trim().split(/\s+/)[0];
      if (usableCover(first)) return first;
    }
  }
  // 有些模板把封面写成背景图。
  const styled = /background(?:-image)?\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)/i.exec(chunk);
  if (styled && usableCover(styled[1])) return styled[1];
  const anywhere = /(https?:\/\/[^"'\s>)+]+\.(?:jpe?g|png|webp))/i.exec(chunk);
  if (anywhere && usableCover(anywhere[1])) return anywhere[1];
  return '';
}

function titleOf(chunk, chunkId) {
  const heading = /<h6\b[^>]*>([\s\S]*?)<\/h6>/i.exec(chunk);
  if (heading) {
    const text = clean(heading[1]);
    if (text !== '') return text;
  }
  const anchorTitle = /<a\b[^>]*\btitle\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/i.exec(chunk);
  if (anchorTitle) {
    const text = clean(anchorTitle[1] || anchorTitle[2] || anchorTitle[3] || '');
    if (text !== '') return text;
  }
  const alt = /<img\b[^>]*\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(chunk);
  if (alt) {
    const text = clean(alt[1] || alt[2] || alt[3] || '');
    if (text !== '') return text;
  }
  return String(chunkId || '').toUpperCase();
}

function durationOf(chunk) {
  const spans = chunk.match(/<span\b[^>]*>[\s\S]*?<\/span>/gi) || [];
  for (const tag of spans) {
    if (/\blabel\b/i.test(classOf(tag))) {
      const value = clock(clean(tag));
      if (value > 0) return value;
    }
  }
  const loose = /<span\b[^>]*\blabel\b[^>]*>\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\s*<\/span>/i.exec(chunk);
  return loose ? clock(loose[1]) : 0;
}

function viewsOf(chunk) {
  // 观看数紧跟在眼睛图标后面（`</svg>2 436`），后面还有心形图标的点赞数，
  // 所以只吃到下一个标签为止，别把点赞数也算进来。
  const matched = /icon-eye[\s\S]{0,200}?<\/svg>\s*([0-9][0-9.,\s]*[KMB]?)/i.exec(chunk);
  return matched ? count(clean(matched[1])) : 0;
}

function dramaOf(chunk, chunkId, base) {
  const sourceId = chunkId;
  const title = titleOf(chunk, chunkId);
  const cover = coverOf(chunk);
  return {
    id: host.dramaId(sourceId),
    source: host.source,
    sourceId: sourceId,
    title: title,
    name: title,
    desc: '',
    intro: '',
    cover: cover ? resolve(base, cover) : '',
    tags: [],
    totalEpisode: 1,
    episodeCount: 1,
    duration: durationOf(chunk),
    // views 在 App 的 Drama 结构体里是 string，传数字会报
    // json: cannot unmarshal number into ... jsDramaPage.items.views of type string
    views: viewsOf(chunk) > 0 ? String(viewsOf(chunk)) : '',
  };
}

function parseList(html, page, base) {
  const text = stripDataURIs(html);
  const chunks = [];
  const seen = {};
  // 先按卡片容器切；容器认不出来时退回按详情链接切。
  let blocks = boxChunks(text);
  if (blocks.length === 0) blocks = anchorChunks(text);
  for (const block of blocks) {
    const anchor = /<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(block);
    if (!anchor) continue;
    const id = videoIdOf(anchor[1] || anchor[2] || anchor[3] || '');
    if (id === '' || seen[id]) continue;
    seen[id] = true;
    const drama = dramaOf(block, id, base);
    if (drama.title === '' && drama.cover === '') continue;
    chunks.push(drama);
  }
  let maxFrom = 0;
  const matched = text.match(/from(?:_videos)?[:=]0*(\d+)/g) || [];
  for (const entry of matched) {
    const value = parseInt(entry.replace(/[^0-9]/g, ''), 10);
    if (!isNaN(value) && value > maxFrom) maxFrom = value;
  }
  return { items: chunks, hasMore: chunks.length > 0 && maxFrom > page };
}

function catalogPage(page, category) {
  const chosen = CATEGORIES.filter((entry) => entry.id === category)[0] || CATEGORIES[0];
  const path = pageURL(chosen.path, page);
  const response = fetchPage(path);
  const result = parseList(response.text, page, response.base);
  return { items: result.items, hasMore: result.hasMore };
}

function search(page, query) {
  const text = String(query || '').trim();
  if (text === '') return { items: [], hasMore: false };
  const path = pageURL('/search/?q=' + encodeURIComponent(text), page);
  const response = fetchPage(path);
  const result = parseList(response.text, page, response.base);
  return { items: result.items, hasMore: result.hasMore };
}

function detailPath(sourceId) {
  return '/videos/' + sourceId + '/';
}

function parseDetail(html, sourceId, base) {
  const heading = /<h4>([\s\S]*?)<\/h4>/.exec(html);
  const title = heading ? clean(heading[1]) : sourceId.toUpperCase();
  const tagMatches = html.match(/<a class="tag[^"]*" href="[^"]*\/tags\/[^"]*">([^<]+)<\/a>/g) || [];
  const tags = [];
  for (const entry of tagMatches) {
    const name = clean(entry.replace(/^.*?>/, ''));
    if (name !== '' && tags.indexOf(name) < 0 && tags.length < 16) tags.push(name);
  }
  const modelBlock = /<div class="models">([\s\S]*?)<\/div>/.exec(html);
  const actors = [];
  if (modelBlock) {
    const models = modelBlock[1].match(/title="([^"]+)"/g) || [];
    for (const entry of models) {
      const name = clean(entry.replace(/^title="/, '').replace(/"$/, ''));
      if (name !== '') actors.push(name);
    }
  }
  const date = /上市於\s*([0-9-]+)/.exec(html);
  const views = /icon-eye[\s\S]{0,80}?<\/svg>\s*<span[^>]*>([^<]+)<\/span>/.exec(html);
  const cover =
    /<meta[^>]*property="og:image"[^>]*content="([^"]+)"/.exec(html) ||
    /<meta[^>]*content="([^"]+)"[^>]*property="og:image"/.exec(html) ||
    /<img[^>]*?data-src="([^"]+)"/.exec(html) ||
    /<img[^>]*?\ssrc="(https?:[^"]+)"/.exec(html);
  const code = codeOf(title);
  const facts = [];
  if (code !== '') facts.push('番号 ' + code);
  if (date) facts.push('发行 ' + clean(date[1]));
  if (views) {
    const value = count(clean(views[1]));
    if (value > 0) facts.push(value + ' 次观看');
  }
  return {
    drama: {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId: sourceId,
      title: title,
      name: title,
      desc: facts.join(' · '),
      intro: facts.join(' · '),
      cover: cover ? resolve(base, cover[1]) : '',
      tags: tags,
      totalEpisode: 1,
      episodeCount: 1,
      author: actors.length > 0 ? actors.join(' / ') : '',
    },
    tags: tags,
    actors: actors,
  };
}

function detail(sourceId) {
  const id = String(sourceId || '').trim();
  if (id === '') throw new Error('Jable 缺少影片 ID');
  const response = fetchPage(detailPath(id));
  if (!/hlsUrl\s*=\s*['"]/.test(response.text) && /<title>.*(Just a moment|请稍候)/i.test(response.text)) {
    const error = new Error('Jable 需要人机验证，请稍后重试');
    error.retryable = true;
    throw error;
  }
  const parsed = parseDetail(response.text, id, response.base);
  return {
    drama: parsed.drama,
    chapters: [
      {
        id: host.chapterId(id, '1'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        pageUrl: response.base + detailPath(id),
      },
    ],
  };
}

// 剧集 ID 形如 `jable:abc123`，分集 ID 形如 `jable:abc123:1`。
function sourceIdOf(task) {
  const chapter = task.chapter || {};
  const raw = String(chapter.id || task.dramaId || task.sourceId || '');
  const parts = raw.split(':');
  return (parts.length >= 2 ? parts[1] : raw).trim();
}

function resolveMedia(task) {
  const id = sourceIdOf(task);
  if (id === '') throw new Error('Jable 缺少影片 ID');
  const response = fetchPage(detailPath(id));
  const matched = /hlsUrl\s*=\s*['"]([^'"]+\.m3u8[^'"]*)['"]/.exec(response.text);
  if (!matched) {
    throw new Error('Jable 页面里没有找到播放地址，可能需要人机验证');
  }
  const address = resolve(response.base, matched[1]);
  const referer = response.base + '/';
  const credentials = {
    origin: response.base,
    referer: referer,
    userAgent: agent(),
    cookie: cookieHeader(),
  };
  // 预取播放列表（m3u8 在 CDN 上，不受 Cloudflare 保护），播放时 0 请求
  try {
    return host.prepareWebMedia(
      { url: address, referer: referer, quality: 1080, credentials: credentials },
      'Jable'
    );
  } catch (_) {
    return { url: address, referer: referer, credentials: credentials };
  }
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  detail,
  resolveMedia,
};
