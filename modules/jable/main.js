// Jable —— 服务端渲染的 KVS 模板站，详情页里直接给出 hlsUrl。
// 移植自 iDuanJu 的 JableProvider（Apache-2.0），按小果影视的模块接口重写：
// 不做异步、只依赖 host.fetchText / host.base64Decode 这类宿主能力。

const SITE = 'https://jable.tv';
const MIRRORS = ['https://jable.tv', 'https://fs1.app'];
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const LANG = 'kt_rt_lang=zh';

const CATEGORIES = [
  { id: 'latest', name: '最近更新', path: '/latest-updates/' },
  { id: 'new', name: '新片上架', path: '/new-release/' },
  { id: 'hot-today', name: '今日热门', path: '/hot/?sort_by=video_viewed_today' },
  { id: 'hot-week', name: '本周热门', path: '/hot/?sort_by=video_viewed_week' },
  { id: 'hot-month', name: '本月热门', path: '/hot/?sort_by=video_viewed_month' },
  { id: 'hot', name: '热门总榜', path: '/hot/' },
  { id: 'zh-sub', name: '中文字幕', path: '/categories/chinese-subtitle/' },
  { id: 'uncensored', name: '无码', path: '/categories/uncensored/' },
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

function fetchPage(path, referer) {
  const response = host.fetchText({
    url: SITE + path,
    referer: referer || SITE + '/',
    userAgent: UA,
    cookie: LANG,
    mirrors: MIRRORS.map((mirror) => mirror + path),
  });
  return { text: response.body || '', base: originOf(response.url) };
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
  const raw = String(text || '')
    .replace(/,/g, '')
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

// 列表页模板不止一种（最近更新 / 热门 / 分类页各用一套），不能只凭
// `video-img-box` 这个 class 切块，否则换一个分类就整页取不到东西。
// 这里以「详情链接」为锚点切块：每个 /videos/xxx/ 链接到下一个链接之间
// 就是一张卡片的 HTML，标题、封面、时长都在这段里找。
function anchorChunks(html) {
  const hits = [];
  const pattern = /<a[^>]+href="[^"]*\/videos\/([^\/"?#]+)\/?"/g;
  let matched = pattern.exec(html);
  while (matched) {
    hits.push({ id: matched[1], start: matched.index });
    matched = pattern.exec(html);
  }
  const out = [];
  const seen = {};
  for (let index = 0; index < hits.length; index++) {
    const hit = hits[index];
    if (seen[hit.id]) continue;
    seen[hit.id] = true;
    const until = index + 1 < hits.length ? hits[index + 1].start : html.length;
    out.push({ id: hit.id, html: html.slice(hit.start, Math.min(until, hit.start + 6000)) });
  }
  return out;
}

// 兼容老模板：仍然按 video-img-box 切一遍，作为锚点法取不到时的兜底。
function classChunks(html) {
  const parts = html.split('<div class="video-img-box');
  const out = [];
  for (let index = 1; index < parts.length; index++) {
    const chunk = parts[index].slice(0, 4000);
    const link = /href="[^"]*\/videos\/([^\/"?#]+)\/?"/.exec(chunk);
    if (link) out.push({ id: link[1], html: chunk });
  }
  return out;
}

function usableCover(url) {
  const value = String(url || '').trim();
  if (value === '') return false;
  // 懒加载占位图 / 1px 透明图 / base64 占位都不能当封面。
  if (/^data:/i.test(value)) return false;
  if (/blank|spacer|placeholder|transparent|1x1|lazy\.(gif|png|svg)/i.test(value)) return false;
  return /\.(jpe?g|png|webp|avif|gif)(\?|#|$)/i.test(value) || /\/(contents|uploads|media)\//i.test(value);
}

const COVER_ATTRS = [
  'data-src',
  'data-original',
  'data-lazy-src',
  'data-lazysrc',
  'data-echo',
  'data-bg',
  'data-background',
  'data-thumb',
  'data-poster',
  'data-image',
  'data-cover',
  'src',
];

function coverOf(chunk) {
  for (const attr of COVER_ATTRS) {
    const pattern = new RegExp(attr + '\\s*=\\s*["\']([^"\']+)["\']', 'i');
    const matched = pattern.exec(chunk);
    if (matched && usableCover(matched[1])) return matched[1];
  }
  // 有些模板把封面写成背景图。
  const styled = /background(?:-image)?\s*:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)/i.exec(chunk);
  if (styled && usableCover(styled[1])) return styled[1];
  // 响应式图片：srcset 里取第一张。
  const srcset = /srcset\s*=\s*["']([^"']+)["']/i.exec(chunk);
  if (srcset) {
    const first = srcset[1].split(',')[0].trim().split(/\s+/)[0];
    if (usableCover(first)) return first;
  }
  // 最后的兜底：块里出现的第一个站内图片地址。
  const anywhere = /(https?:\/\/[^"'\s)]+\.(?:jpe?g|png|webp))[^"'\s)]*/i.exec(chunk);
  if (anywhere && usableCover(anywhere[0])) return anywhere[0];
  return '';
}

function titleOf(chunk, chunkId) {
  const heading = /<h6[^>]*>([\s\S]*?)<\/h6>/.exec(chunk);
  if (heading) {
    const text = clean(heading[1]);
    if (text !== '') return text;
  }
  const anchorTitle = /<a[^>]*title="([^"]+)"/.exec(chunk);
  if (anchorTitle && clean(anchorTitle[1]) !== '') return clean(anchorTitle[1]);
  const alt = /<img[^>]*alt="([^"]*)"/.exec(chunk);
  if (alt && clean(alt[1]) !== '') return clean(alt[1]);
  return String(chunkId || '').toUpperCase();
}

function dramaOf(chunk, chunkId, base) {
  const sourceId = chunkId;
  const title = titleOf(chunk, chunkId);
  const cover = coverOf(chunk);
  const label = /<span class="label">([^<]+)<\/span>/.exec(chunk);
  const views = /icon-eye[\s\S]{0,60}?<\/svg>\s*([0-9.,KMBkmb]+)/.exec(chunk);
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
    duration: label ? clock(clean(label[1])) : 0,
    views: views ? count(clean(views[1])) : 0,
  };
}

function parseList(html, page, base) {
  const items = [];
  const seen = {};
  let chunks = anchorChunks(html);
  if (chunks.length === 0) chunks = classChunks(html);
  for (const chunk of chunks) {
    if (seen[chunk.id]) continue;
    seen[chunk.id] = true;
    const drama = dramaOf(chunk.html, chunk.id, base);
    if (drama.title === '' && drama.cover === '') continue;
    items.push(drama);
  }
  let maxFrom = 0;
  const matched = html.match(/from(?:_videos)?[:=]0*(\d+)/g) || [];
  for (const entry of matched) {
    const value = parseInt(entry.replace(/[^0-9]/g, ''), 10);
    if (!isNaN(value) && value > maxFrom) maxFrom = value;
  }
  return { items: items, hasMore: items.length > 0 && maxFrom > page };
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
  return {
    url: address,
    referer: referer,
    credentials: {
      origin: response.base,
      referer: referer,
      userAgent: UA,
      cookie: LANG,
    },
  };
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  detail,
  resolveMedia,
};
