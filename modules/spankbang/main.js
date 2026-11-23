// SpankBang —— 大型成人视频站，挂在 Cloudflare 后面。
//
//   列表  /new_videos/{n}/   /trending/{n}/   /most_popular/{n}/
//   分类  /s/{tag}/{n}/      搜索 /s/{keyword}/{n}/
//   详情  /{id}/video          （id 是 5-8 位小写字母数字）
//   播放  详情页里的 stream_data JSON（mp4/hls 多档）或 <source src="…m3u8">
//
// 这个模块的解析全部做成了「多模式兜底」：站点换模板时只要还有一处特征能
// 命中就还能用，命中不到会在日志里打出判空片段，方便按实际页面再收窄。

const SITE = 'https://spankbang.com';
const HOST = 'spankbang.com';
const HOST_ALT = 'spankbang.party';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

const PAGE_LIMIT = 60;

const CATEGORIES = [
  { id: 'new', name: '最新', path: '/new_videos/' },
  { id: 'trending', name: '趋势', path: '/trending/' },
  { id: 'popular', name: '最热', path: '/most_popular/' },
  { id: 'upcoming', name: '即将上架', path: '/upcoming/' },
  { id: 'asian', name: '亚洲', path: '/s/asian/' },
  { id: 'japanese', name: '日本', path: '/s/japanese/' },
  { id: 'chinese', name: '中文', path: '/s/chinese/' },
  { id: 'amateur', name: '业余', path: '/s/amateur/' },
  { id: 'milf', name: '熟女', path: '/s/milf/' },
  { id: 'anal', name: '肛交', path: '/s/anal/' },
  { id: 'bigtits', name: '巨乳', path: '/s/big+tits/' },
  { id: '4k', name: '4K', path: '/s/4k/' },
];

function trim(value) {
  return String(value == null ? '' : value).trim();
}

function decodeHtml(value) {
  let text = String(value == null ? '' : value);
  if (text.indexOf('&') < 0) return text;
  return text
    .replace(/&#(\d+);/g, (all, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (all, code) => String.fromCharCode(parseInt(code, 16)))
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

function clean(value) {
  return decodeHtml(String(value == null ? '' : value).replace(/<[^>]*>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function truncate(text, limit) {
  const value = trim(text);
  return value.length > limit ? value.slice(0, limit) : value;
}

// ---- Cloudflare 过验证 ------------------------------------------------------
// App 内做过站点验证后，host.challengeCookie 给 cf_clearance，
// host.challengeUA 给解验证时 WebView 的真实 UA（两者必须成对，cf_clearance 绑 UA）。

function agent() {
  return host.challengeUA(HOST) || host.challengeUA(HOST_ALT) || UA;
}

function cookies() {
  const learned = host.challengeCookie(HOST) || host.challengeCookie(HOST_ALT);
  const base = 'country=US; lang=en';
  return learned ? base + '; ' + learned : base;
}

function looksLikeChallenge(text) {
  const head = String(text || '').slice(0, 6000);
  return /_cf_chl_opt|cf-chl-|just a moment|attention required|checking your browser|verify you are human|请稍候|請稍候/i.test(
    head,
  );
}

function fetchPage(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetch({
      url,
      headers: {
        Accept:
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
        'Upgrade-Insecure-Requests': '1',
        Referer: referer || SITE + '/',
        'User-Agent': agent(),
        Cookie: cookies(),
      },
      anyStatus: true,
      followRedirects: true,
      timeoutMs: 25000,
    });
  } catch (error) {
    throw new Error(
      'SpankBang 连接失败：' + String((error && error.message) || error),
    );
  }
  const status = response.status || 0;
  const body = response.body || '';
  if (status === 403 || status === 429 || status === 503 || looksLikeChallenge(body)) {
    throw new Error('SpankBang 需要人机验证，请在站源页里点「去验证」后再试');
  }
  if (status < 200 || status >= 300) {
    throw new Error('SpankBang 返回 HTTP ' + status + '（' + path + '）');
  }
  return body;
}

// ---- 列表解析 ---------------------------------------------------------------

// 卡片切分：新模板是 <div class="video-item" data-id="…">，
// 老模板是 <a class="video-item" href="/{id}/video">，两种都认。
function cardBlocks(html) {
  const source = String(html || '');
  const patterns = [
    /<div[^>]+class="[^"]*\bvideo-item\b[^"]*"[^>]*>[\s\S]*?(?=<div[^>]+class="[^"]*\bvideo-item\b|<\/main>|<\/body>)/g,
    /<a[^>]+class="[^"]*\bvideo-item\b[^"]*"[\s\S]*?<\/a>/g,
    /<div[^>]+data-id="[a-z0-9]+"[^>]*>[\s\S]*?<\/img>[^<]*/g,
  ];
  // 三种模板的结果合并去重：真实站点只用其中一种，但混着也能都收进来。
  const merged = [];
  const seen = {};
  for (const pattern of patterns) {
    const found = source.match(pattern) || [];
    for (const block of found) {
      const key = String(block).slice(0, 400);
      if (seen[key]) continue;
      seen[key] = true;
      merged.push(block);
    }
  }
  return merged;
}

function videoIdOf(block) {
  const fromData = block.match(/data-id="([a-z0-9]{4,12})"/i);
  if (fromData) return fromData[1].toLowerCase();
  const fromHref = block.match(/href="(?:https?:\/\/[^\/]+)?\/([a-z0-9]{4,12})\/video\/?/i);
  if (fromHref) return fromHref[1].toLowerCase();
  const fromSlug = block.match(/\/videos?\/([a-z0-9]{4,12})/i);
  return fromSlug ? fromSlug[1].toLowerCase() : '';
}

function cardTitle(block, id) {
  const candidates = [
    /<span[^>]+class="[^"]*video-item-title[^"]*"[^>]*>([\s\S]*?)<\/span>/,
    /<a[^>]+class="[^"]*title[^"]*"[^>]*>([\s\S]*?)<\/a>/,
    /<img[^>]+alt="([^"]{4,})"/,
    /title="([^"]{4,})"/,
  ];
  for (const pattern of candidates) {
    const matched = block.match(pattern);
    const text = matched ? clean(matched[1]) : '';
    if (text && text.toLowerCase() !== 'video') return truncate(text, 120);
  }
  return id;
}

function cardCover(block) {
  const candidates = [
    /<img[^>]+data-src="([^"]+)"/,
    /<img[^>]+data-original="([^"]+)"/,
    /<img[^>]+src="(https?:\/\/[^"]+)"/,
  ];
  for (const pattern of candidates) {
    const matched = block.match(pattern);
    if (matched) return matched[1].replace(/&amp;/g, '&');
  }
  return '';
}

function cardDuration(block) {
  const matched =
    block.match(/class="[^"]*\bduration\b[^"]*"[^>]*>([^<]{2,12})</) ||
    block.match(/>(\d{1,2}:\d{2}(?::\d{2})?)</);
  return matched ? clean(matched[1]) : '';
}

function cardBadge(block) {
  const matched = block.match(/class="[^"]*(?:quality|hd-mark|badge)[^"]*"[^>]*>([^<]{1,8})</);
  return matched ? clean(matched[1]) : '';
}

function cardAuthor(block) {
  const matched =
    block.match(/<a[^>]+href="\/(?:profile|channel|user)\/([A-Za-z0-9_\-%.]+)"[^>]*>([\s\S]{0,120}?)<\/a>/) ||
    block.match(/class="[^"]*username[^"]*"[^>]*>([\s\S]{0,80}?)</);
  if (!matched) return { name: '', id: '' };
  if (matched.length >= 3 && matched[2] !== undefined) {
    return { id: matched[1], name: truncate(clean(matched[2]), 48) };
  }
  return { name: truncate(clean(matched[1]), 48), id: '' };
}

function hasNextPage(html, page) {
  const next = Number(page || 1) + 1;
  return new RegExp(
    'href="[^"]*(?:/' + next + '/|page=' + next + ')[^"]*"',
  ).test(String(html || ''));
}

function pageNumber(page) {
  const value = Number(page || 1);
  if (!Number.isFinite(value) || value < 1) return 1;
  return Math.min(Math.floor(value), PAGE_LIMIT);
}

function listPath(base, page) {
  const current = pageNumber(page);
  return current <= 1 ? base : base.replace(/\/?$/, '/') + current + '/';
}

function parseCards(html, page) {
  const blocks = cardBlocks(html);
  const items = [];
  const seen = {};
  for (const block of blocks) {
    const sourceId = videoIdOf(block);
    if (!sourceId || seen[sourceId]) continue;
    const title = cardTitle(block, sourceId);
    if (!title || title === sourceId) continue;
    seen[sourceId] = true;
    const author = cardAuthor(block);
    const badge = cardBadge(block);
    const item = {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
      name: title,
      cover: cardCover(block),
      durationText: cardDuration(block),
      badge,
      tags: badge ? [badge] : [],
      author: author.name,
      authorId: author.id,
      onlineDate: '',
    };
    if (author.id) item.authorUrl = SITE + '/profile/' + author.id + '/';
    items.push(item);
  }
  return { items, hasMore: items.length > 0 && hasNextPage(html, page) };
}

function catalogPage(page, category) {
  const key = trim(category) || 'new';
  const entry = CATEGORIES.filter((item) => item.id === key)[0];
  if (!entry) {
    const direct = CATEGORIES[0];
    return parseCards(fetchPage(listPath(direct.path, page)), page);
  }
  return parseCards(fetchPage(listPath(entry.path, page)), page);
}

function search(page, query) {
  const keyword = trim(query);
  if (!keyword || keyword.length > 80) return { items: [], hasMore: false };
  const base = '/s/' + encodeURIComponent(keyword.replace(/\s+/g, '+')) + '/';
  return parseCards(fetchPage(listPath(base, page)), page);
}

// 上传者 / 模特的作品页
function author(authorId, authorName, page) {
  const id = trim(authorId);
  const name = truncate(trim(authorName), 64);
  if (!id && !name) return { items: [], hasMore: false, warning: '缺少作者信息' };
  const result = id
    ? parseCards(fetchPage(listPath('/profile/' + encodeURIComponent(id) + '/', page)), page)
    : { items: [], hasMore: false };
  if (result.items.length === 0 && name && pageNumber(page) <= 1) {
    // 频道页取不到时退回名字搜索，避免点进去一片空白。
    const fallback = search(1, name);
    return {
      items: fallback.items.map((item) => {
        if (!item.author) {
          item.author = name;
          if (id) item.authorId = id;
        }
        return item;
      }),
      hasMore: fallback.hasMore,
    };
  }
  return result;
}

// ---- 详情 -------------------------------------------------------------------

function detailMeta(html) {
  const meta = {
    title: '',
    cover: '',
    author: '',
    authorId: '',
    authorUrl: '',
    actors: [],
    maker: '',
    onlineDate: '',
    tags: [],
    durationText: '',
  };

  const ogTitle = html.match(/property="og:title"[^>]*content="([^"]+)"/);
  const h1 = html.match(/<h1[^>]*>([\s\S]{0,300}?)<\/h1>/);
  meta.title = truncate(
    clean(ogTitle ? ogTitle[1] : h1 ? h1[1] : '')
      .replace(/\s*[-–]\s*SpankBang[\s\S]*$/i, ''),
    160,
  );

  const ogImage = html.match(/property="og:image"[^>]*content="([^"]+)"/);
  meta.cover = ogImage ? ogImage[1].replace(/&amp;/g, '&') : '';

  // 上传者：新版 <a href="/profile/xxx">，老版 class="profile"
  const uploader =
    html.match(/<a[^>]+href="\/profile\/([A-Za-z0-9_\-%.]+)\/?"[^>]*>([\s\S]{0,120}?)<\/a>/) ||
    html.match(/class="[^"]*profile[^"]*"[^>]*>[\s\S]{0,200}?<a[^>]+href="\/([A-Za-z0-9_\-%.]+)\/?"[^>]*>([\s\S]{0,100}?)<\/a>/);
  if (uploader) {
    meta.authorId = uploader[1];
    meta.author = truncate(clean(uploader[2]), 48);
    meta.authorUrl = SITE + '/profile/' + uploader[1] + '/';
  }

  // 模特 / 成人星
  const starRe = /<a[^>]+href="\/(?:pornstar|pornstars|stars|model)\/([A-Za-z0-9_\-%.]+)\/?"[^>]*>([\s\S]{0,100}?)<\/a>/g;
  let star = null;
  while ((star = starRe.exec(html)) !== null) {
    const name = truncate(clean(star[2]), 48);
    if (name && meta.actors.indexOf(name) < 0) meta.actors.push(name);
  }

  // 标签
  const tagRe = /<a[^>]+href="\/(?:s|tag|tags)\/([^"\/]+)\/?"[^>]*>([\s\S]{0,60}?)<\/a>/g;
  let tag = null;
  while ((tag = tagRe.exec(html)) !== null) {
    const name = truncate(clean(tag[2]) || clean(tag[1]).replace(/\+/g, ' '), 32);
    if (name && meta.tags.indexOf(name) < 0 && meta.tags.length < 16) {
      meta.tags.push(name);
    }
  }

  // 发布日期
  const dateMatch =
    html.match(/itemprop="(?:datePublished|uploadDate)"[^>]*content="(\d{4}-\d{2}-\d{2})/) ||
    html.match(/"uploadDate"\s*:\s*"(\d{4}-\d{2}-\d{2})/) ||
    html.match(/(?:Added|Published|Uploaded)[^\d]{0,20}(\d{4}-\d{2}-\d{2})/i);
  if (dateMatch) meta.onlineDate = dateMatch[1];

  // 时长
  const duration =
    html.match(/itemprop="duration"[^>]*content="PT(?:(\d+)M)?(?:(\d+)S)?"/) ||
    html.match(/"duration"\s*:\s*"PT(?:(\d+)M)?(?:(\d+)S)?"/);
  if (duration) {
    const minutes = Number(duration[1] || 0);
    const seconds = Number(duration[2] || 0);
    if (minutes || seconds) {
      meta.durationText =
        minutes + ':' + (seconds < 10 ? '0' + seconds : String(seconds));
    }
  }
  return meta;
}

// 播放地址：优先 stream_data 里最高码率的 m3u8，其次 mp4，最后页面任意 m3u8
function streamSources(html) {
  const hls = [];
  const mp4 = [];

  const dataAt = html.indexOf('stream_data');
  if (dataAt >= 0) {
    const chunk = html.slice(dataAt, dataAt + 8000);
    // JSON 里的地址是 https://////… 形式，反斜杠不能当分隔符，正则里要放行。
    const urls = chunk.match(/https?:[\\\/]{2}[^"'\s,}\]]+/g) || [];
    for (const raw of urls) {
      const url = raw.replace(/\\\//g, '/');
      if (/\.m3u8/i.test(url)) hls.push(url);
      else if (/\.mp4/i.test(url)) mp4.push(url);
    }
  }

  const hlsAttrs = html.match(/(?:data-hls|data-m3u8|hls-url)="([^"]+\.m3u8[^"]*)"/gi) || [];
  for (const attr of hlsAttrs) {
    const url = attr.replace(/^[^"]*"/, '').replace(/"$/, '').replace(/\\\//g, '/');
    if (/^https?:/i.test(url)) hls.push(url);
  }

  const generic = html.match(/https?:[\\\/]{2}[^"'\s,}\]]+\.m3u8[^"'\s,}\]]*/gi) || [];
  for (const raw of generic) hls.push(raw.replace(/\\\//g, '/'));

  const mp4Generic = html.match(/https?:[\\\/]{2}[^"'\s,}\]]+\.mp4[^"'\s\,}\]]*/gi) || [];
  for (const raw of mp4Generic) mp4.push(raw.replace(/\\\//g, '/'));

  const unique = (list) => list.filter((url, i) => list.indexOf(url) === i);
  return { hls: unique(hls), mp4: unique(mp4) };
}

function wrapMp4(url, durationMs) {
  const seconds = durationMs > 0 ? Math.max(1, Math.round(durationMs / 1000)) : 3600;
  return {
    url,
    playlist: [
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      '#EXT-X-TARGETDURATION:' + seconds,
      '#EXT-X-PLAYLIST-TYPE:VOD',
      '#EXTINF:' + seconds + ',',
      url,
      '#EXT-X-ENDLIST',
      '',
    ].join('\n'),
    durationMs: durationMs || 0,
  };
}

function resolveMedia(task) {
  const chapter = (task && task.chapter) || {};
  let sourceId = '';
  const fromDrama = String((task && task.dramaId) || '').split(':');
  if (fromDrama.length >= 2) sourceId = fromDrama[1];
  if (!sourceId) {
    const fromChapter = String(chapter.id || '').split(':');
    if (fromChapter.length >= 3) sourceId = fromChapter[1];
  }
  if (!sourceId) throw new Error('SpankBang 无法确定视频 ID');

  const pageUrl = SITE + '/' + sourceId + '/video';
  const html = fetchPage('/' + sourceId + '/video', pageUrl);
  const sources = streamSources(html);
  const meta = detailMeta(html);

  if (sources.hls.length > 0) {
    const url = sources.hls[0];
    const prepared = host.prepareWebMedia(
      { url, referer: pageUrl, quality: 1080 },
      'SpankBang',
    );
    if (prepared && prepared.playlist) return prepared;
  }
  if (sources.mp4.length > 0) {
    const media = wrapMp4(sources.mp4[0], 0);
    media.referer = pageUrl;
    return media;
  }

  let hint = '页面为空，可能被站点拦截';
  if (html) {
    hint = /stream_data|\.m3u8|\.mp4/i.test(html)
      ? '页面有播放信息但没解析出地址，站点可能换了播放器模板'
      : '页面里没有播放信息，可能视频已删除或限制地区';
  }
  try {
    host.log('SpankBang 播放解析失败: ' + sourceId + ' ' + hint);
  } catch (error) {
    /* 忽略 */
  }
  throw new Error('SpankBang 没有找到播放地址：' + hint);
}

function detail(sourceId) {
  const id = trim(sourceId).toLowerCase();
  if (!/^[a-z0-9]{4,12}$/.test(id)) throw new Error('SpankBang 视频 ID 无效');
  const pageUrl = SITE + '/' + id + '/video';
  const html = fetchPage('/' + id + '/video', pageUrl);
  const meta = detailMeta(html);
  const title = meta.title || id;

  const drama = {
    id: host.dramaId(id),
    source: host.source,
    sourceId: id,
    title,
    name: title,
    desc: '',
    intro: '',
    cover: meta.cover,
    totalEpisode: 1,
    episodeCount: 1,
  };
  if (meta.durationText) drama.durationText = meta.durationText;
  if (meta.author) drama.author = meta.author;
  if (meta.authorId) drama.authorId = meta.authorId;
  if (meta.authorUrl) drama.authorUrl = meta.authorUrl;
  if (meta.actors.length) drama.actors = meta.actors.slice();
  if (meta.maker) drama.maker = meta.maker;
  if (meta.onlineDate) drama.onlineDate = meta.onlineDate;
  if (meta.tags.length) drama.tags = meta.tags.slice();

  return {
    drama,
    chapters: [
      {
        id: host.chapterId(id, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: 'spankbang-play://' + id,
        pageUrl,
        referer: pageUrl,
      },
    ],
  };
}

const api = {
  categories() {
    return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
  },

  validCategory(category) {
    const key = trim(category);
    return key === '' || CATEGORIES.some((entry) => entry.id === key);
  },

  catalogPage,

  search,

  author,

  detail,

  resolveMedia,
};

module.exports = api;
