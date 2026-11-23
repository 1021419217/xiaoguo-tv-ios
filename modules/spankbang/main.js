// SpankBang —— 大型成人视频站，挂在 Cloudflare 后面。
//
//   列表  /new_videos/{n}/   /trending_videos/{n}/
//   分类  /s/{tag}/{n}/      搜索 /s/{keyword}/{n}/（空格写 + 号）
//   详情  /{code}/video/     只带 code 会自动跳到带 slug 的地址
//   频道  /{短码}/channel/{名字}/{n}/     演员 /{短码}/pornstar/{名字}/
//   播放  详情页内联多条 master.m3u8（多档合一 + 单档各一条）：
//         https://hls-*.sb-cd.com/hls/…-,240p,480p,720p,.mp4.urlset/master.m3u8?secure=…
//         取「多档合一」那条，再按 RESOLUTION 挑 1080p 封顶的最高档。
//         HLS 明文（无 EXT-X-KEY，分片可 Range），所以能直接交给 App。
//
// 页面里的视频地址带逗号（17053964-,240p,480p,720p,.mp4.urlset），
// 正则里不能用「排除逗号」的字符组，否则一条 master 都匹配不到，会退到
// 缩略图预览的 td.mp4 上——那是几秒钟的预览片，不是正片。
//
// Cloudflare：清单声明 browserFingerprint，App 用浏览器指纹请求；验证过的人机
// 验证凭据由 host.challengeCookie / challengeUA 给出，必须成对使用。
const SITE = 'https://spankbang.com';
const HOST = 'spankbang.com';
const HOST_ALT = 'spankbang.party';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const PLAY_PREFIX = 'spankbang-play://';
const PAGE_LIMIT = 200;

const CATEGORIES = [
  { id: 'new', name: '最新', path: '/new_videos/' },
  { id: 'trending', name: '趋势', path: '/trending_videos/' },
  { id: 'japanese', name: '日本', path: '/s/japanese/' },
  { id: 'asian', name: '亚洲', path: '/s/asian/' },
  { id: 'chinese', name: '中文', path: '/s/chinese/' },
  { id: 'amateur', name: '业余', path: '/s/amateur/' },
  { id: 'hd', name: 'HD', path: '/s/hd/' },
  { id: '4k', name: '4K', path: '/s/4k/' },
  { id: 'vr', name: 'VR', path: '/s/vr/' },
  { id: 'hentai', name: '动漫', path: '/s/hentai/' },
  { id: 'creampie', name: '内射', path: '/s/creampie/' },
  { id: 'uncensored', name: '无码', path: '/s/uncensored/' }
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

// 网址里的 + 是空格，%xx 是 UTF-8
function slugText(slug) {
  let raw = String(slug == null ? '' : slug).replace(/\+/g, ' ');
  try {
    raw = decodeURIComponent(raw);
  } catch (e) { /* 保留原样 */ }
  return clean(raw);
}

// ---- 取页 -------------------------------------------------------------------

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
  return /_cf_chl_opt|cf-chl-|just a moment|attention required|checking your browser|verify you are human|请稍候|請稍候/i.test(head);
}

function fetchPage(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetch({
      url,
      headers: {
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
        'Upgrade-Insecure-Requests': '1',
        Referer: referer || SITE + '/',
        'User-Agent': agent(),
        Cookie: cookies()
      },
      anyStatus: true,
      followRedirects: true,
      timeoutMs: 25000
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    // host 层拦截时抛的是「… HTTP 403，请在 N 秒后重试」这类文案，模块拿不到
    // 状态码，只能按文案识别；统一成「需要人机验证」，App 才会给「去验证」入口。
    if (/HTTP\s*(403|429|503)|blocked|challenge|重试/i.test(message)) {
      throw new Error('SpankBang 需要人机验证，请在站源页里点「去验证」后再试');
    }
    throw new Error('SpankBang 连接失败：' + message);
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

// ---- 列表卡片 ----------------------------------------------------------------
// 页面里有两个 video-list：第一个是顶部推荐（每页都重复同样的 8 条），
// 第二个才是本页列表。只解析最后一个容器，否则翻页会和第一页重复 8 条。

function cardBlocks(html) {
  const scope = String(html || '');
  const at = scope.lastIndexOf('data-testid="video-list"');
  const container = at >= 0 ? scope.slice(at) : scope;
  return container.split('data-testid="video-item"').slice(1);
}

function channelOf(block) {
  const matched = block.match(/<a[^>]+href="(\/[^"]*\/channel\/[^"]*)"[^>]*>([\s\S]{0,200}?)<\/a\s*>/);
  if (!matched) return { name: '', id: '', url: '' };
  const path = matched[1];
  const name = clean(matched[2]);
  const slug = path.replace(/\/+$/, '').split('/').pop() || '';
  return {
    name: name || slugText(slug),
    id: path.replace(/^\/+|\/+$/g, ''),
    url: SITE + path
  };
}

// 分页控件：<li class="next"><a href="…/2/" data-page="2">。
// 只有单页的列表（例如作品很少的频道）整块分页控件都不出现，
// 所以不能靠「本页条数够不够」判断还有没有下一页——那样会让 App 去请求 404。
function hasNextPage(html) {
  return /<li class="next"><a[^>]+href="/.test(String(html || ''));
}

function parseCards(html, page) {
  const items = [];
  const seen = {};
  for (const block of cardBlocks(html)) {
    const link = block.match(/href="(?:https?:\/\/[^"\/]*spankbang\.com)?\/([a-z0-9]+)\/video\/[^"]*"/);
    if (!link) continue;
    const sourceId = link[1];
    if (seen[sourceId]) continue;

    const alt = block.match(/<img[^>]+alt="([^"]*)"/);
    const title = alt ? clean(alt[1]).replace(/\.$/, '').trim() : '';
    if (!title) continue;

    const img = block.match(/<img[^>]+src="(https:\/\/tbi\.sb-cd\.com\/[^"]+)"/) ||
      block.match(/<img[^>]+data-src="(https:\/\/[^"]+)"/);
    const badge = block.match(/data-testid="video-item-resolution"[^>]*>\s*([^<]{1,24})/);
    const length = block.match(/data-testid="video-item-length"[^>]*>\s*([^<]{1,24})/);
    const channel = channelOf(block);

    seen[sourceId] = true;
    const item = {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
      name: title,
      cover: img ? img[1].replace(/&amp;/g, '&').replace(/\/w:300\//, '/w:500/') : '',
      durationText: length ? clean(length[1]) : '',
      badge: badge ? clean(badge[1]) : ''
    };
    if (channel.name) item.author = channel.name;
    if (channel.id) item.authorId = channel.id;
    if (channel.url) item.authorUrl = channel.url;
    items.push(item);
    // 详情页不显示上传者频道，卡片上的这一份是作者信息的唯一来源，先存起来。
    try {
      host.cacheSet('card:' + sourceId, JSON.stringify({
        title: item.title, cover: item.cover, author: item.author || '',
        authorId: item.authorId || '', authorUrl: item.authorUrl || ''
      }), 30 * 60 * 1000);
    } catch (error) { /* 缓存不可用不影响列表 */ }
  }
  return { items, hasMore: hasNextPage(html) };
}

function pageNumber(page) {
  const value = Number(page || 1);
  if (!isFinite(value) || value < 1) return 1;
  return Math.min(Math.floor(value), PAGE_LIMIT);
}

function pagedPath(base, page) {
  const current = pageNumber(page);
  const normalized = base.replace(/\/+$/, '') + '/';
  return current <= 1 ? normalized : normalized + current + '/';
}

function categoryOf(category) {
  const key = trim(category) || 'new';
  for (const entry of CATEGORIES) {
    if (entry.id === key) return entry;
  }
  return null;
}

function catalogPage(page, category) {
  const entry = categoryOf(category) || CATEGORIES[0];
  return parseCards(fetchPage(pagedPath(entry.path, page)), page);
}

// 空格写 + 号（站点自己的链接就是 /s/lil+tay+onlyfans/）
function searchPath(query, page) {
  const words = trim(query).split(/\s+/).filter((word) => word.length > 0);
  if (!words.length) return '';
  const encoded = words.map((word) =>
    encodeURIComponent(word).replace(/%[0-9A-F]{2}/g, (part) => part.toLowerCase())
  );
  return pagedPath('/s/' + encoded.join('+') + '/', page);
}

function search(page, query) {
  const keyword = trim(query);
  if (!keyword || keyword.length > 80) return { items: [], hasMore: false };
  const path = searchPath(keyword, page);
  if (!path) return { items: [], hasMore: false };
  return parseCards(fetchPage(path), page);
}

// 频道页：作者二级页就是 /{短码}/channel/{名字}/{n}/，与列表同构。
// 卡片带回来的 authorId 是「短码/channel/名字」整段路径，这里直接拼回地址。
function author(authorId, authorName, page) {
  const id = trim(authorId);
  const name = trim(authorName);
  let base = '';
  if (id.indexOf('/channel/') >= 0) {
    base = '/' + id.replace(/^\/+|\/+$/g, '') + '/';
  } else if (id.indexOf('/pornstar/') >= 0) {
    base = '/' + id.replace(/^\/+|\/+$/g, '') + '/';
  } else if (id) {
    base = '/channel/' + encodeURIComponent(id) + '/';
  }
  if (!base) {
    if (!name) return { items: [], hasMore: false };
    const fallback = search(page, name);
    return { items: fallback.items.map((item) => {
      if (!item.author) item.author = name;
      return item;
    }), hasMore: fallback.hasMore };
  }
  return parseCards(fetchPage(pagedPath(base, page)), page);
}

// ---- 详情 -------------------------------------------------------------------

// 详情页顶部有一块 data-testid="video-tags"：频道、标签都在里面，
// 一直延伸到 video-toolbar（播放器工具条）之前。页面别处还有一列全局
// 「热门频道 / 热门演员」下拉，那里的链接和当前视频无关，不能从整页抓。
function tagBlock(html) {
  const source = String(html || '');
  const at = source.indexOf('data-testid="video-tags"');
  if (at < 0) return '';
  const end = source.indexOf('data-testid="video-toolbar"', at);
  return source.slice(at, end > at ? end : Math.min(source.length, at + 6000));
}

function detailMeta(html) {
  const meta = {
    title: '',
    cover: '',
    author: '',
    authorId: '',
    authorUrl: '',
    actors: [],
    tags: [],
    onlineDate: ''
  };

  const videoTitle = html.match(/<h1[^>]*data-testid=["']?video-title["']?[^>]*>([\s\S]{0,400}?)<\/h1>/);
  const ogTitle = html.match(/property="og:title"[^>]*content="([^"]+)"/);
  meta.title = clean(videoTitle ? videoTitle[1] : ogTitle ? ogTitle[1] : '')
    .replace(/\s*[-–|:]\s*SpankBang[\s\S]*$/i, '')
    .slice(0, 200);

  const ogImage = html.match(/property="og:image"[^>]*content="([^"]+)"/);
  meta.cover = ogImage ? ogImage[1].replace(/&amp;/g, '&') : '';

  const block = tagBlock(html);
  const channel = block.match(/<a[^>]+href="(\/[^"]*\/channel\/[^"]*)"[^>]*>([\s\S]{0,200}?)<\/a\s*>/);
  if (channel) {
    const path = channel[1];
    const slug = path.replace(/\/+$/, '').split('/').pop() || '';
    meta.author = clean(channel[2]) || slugText(slug);
    meta.authorId = path.replace(/^\/+|\/+$/g, '');
    meta.authorUrl = SITE + path;
  }

  // 演员只从这条视频自己的标签块里取：页面别处还有一列全局「热门演员」下拉，
  // 那里的链接和当前视频无关，从整页抓会把固定几个演员挂到每个视频上。
  const starRe = /<a[^>]+href="\/([^"]*\/pornstar\/([^"\/]+))\/?"[^>]*>([\s\S]{0,120}?)<\/a\s*>/g;
  let star = null;
  while ((star = starRe.exec(block)) !== null) {
    const name = clean(star[3]) || slugText(star[2]);
    if (name && meta.actors.indexOf(name) < 0) meta.actors.push(name.slice(0, 48));
  }

  const tagRe = /<a[^>]+href="\/s\/([^"\/]+)\/"[^>]*>([\s\S]{0,100}?)<\/a\s*>/g;
  let tag = null;
  while ((tag = tagRe.exec(block)) !== null) {
    const name = clean(tag[2]) || slugText(tag[1]);
    if (name && meta.tags.indexOf(name) < 0 && meta.tags.length < 20) {
      meta.tags.push(name.slice(0, 32));
    }
  }

  const date = html.match(/<time[^>]+datetime="(\d{4}-\d{2}-\d{2})/);
  if (date) meta.onlineDate = date[1];

  return meta;
}

// ---- 播放 -------------------------------------------------------------------

// 详情页内联多条 master：选「多档合一」那条（url 里带 2 个以上的 240p, 480p, …）
function masterOf(html) {
  const found = String(html || '').match(/https:\/\/hls-[a-z0-9.\-]+\/hls\/[^\s"'<>]+master\.m3u8[^\s"'<>]*/gi) || [];
  const unique = [];
  for (const url of found) {
    if (unique.indexOf(url) < 0) unique.push(url);
  }
  let best = '';
  let bestCount = 0;
  for (const url of unique) {
    const count = (url.match(/[0-9]{3,4}p,/g) || []).length;
    if (count > bestCount) {
      bestCount = count;
      best = url;
    }
  }
  return best;
}

function bestVariant(text, masterUrl) {
  const lines = String(text || '').split(/\r?\n/);
  let best = null;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].trim();
    if (!line || line.charAt(0) === '#') continue;
    const header = (lines[index - 1] || '').trim();
    const resolution = header.match(/RESOLUTION=(\d+)x(\d+)/);
    const bandwidth = Number((header.match(/BANDWIDTH=(\d+)/) || [])[1] || 0);
    const height = resolution ? Number(resolution[2]) : 0;
    if (height > 1080) continue;
    const url = line.indexOf('http') === 0 ? line : masterUrl.replace(/[^\/]*$/, '') + line;
    const candidate = { url, height, bandwidth };
    if (!best || candidate.height > best.height ||
      (candidate.height === best.height && candidate.bandwidth > best.bandwidth)) {
      best = candidate;
    }
  }
  return best;
}

function prepareMedia(html, pageUrl) {
  const master = masterOf(html);
  if (!master) throw new Error('SpankBang 详情页里没有播放地址（可能被 Cloudflare 简版页拦截）');
  let url = master;
  let height = 0;
  try {
    const variant = bestVariant(fetchPage(master, pageUrl), master);
    if (variant) {
      url = variant.url;
      height = variant.height;
    }
  } catch (error) {
    // 取不到 master 内容时把多档 master 直接交给 App，播放器自己选档
  }
  return host.prepareWebMedia({ url, referer: pageUrl, quality: height || 1080 }, 'SpankBang');
}

function readyKey(code) {
  return 'ready:' + code;
}

module.exports = {
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

  detail(sourceId) {
    const id = trim(sourceId).toLowerCase();
    if (!/^[a-z0-9]{4,12}$/.test(id)) throw new Error('SpankBang 视频 ID 无效');
    const pagePath = '/' + id + '/video/';
    const pageUrl = SITE + pagePath;
    const html = fetchPage(pagePath, pageUrl);
    const meta = detailMeta(html);
    // 详情页不显示上传者频道：从列表卡片的缓存里补作者，深链进来时才可能为空。
    try {
      const cached = host.cacheGet('card:' + id);
      if (cached) {
        const card = JSON.parse(cached) || {};
        if (!meta.author && card.author) meta.author = card.author;
        if (!meta.authorId && card.authorId) meta.authorId = card.authorId;
        if (!meta.authorUrl && card.authorUrl) meta.authorUrl = card.authorUrl;
        if (!meta.cover && card.cover) meta.cover = card.cover;
      }
    } catch (error) { /* 忽略 */ }
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
      totalEpisode: 1
    };
    if (meta.author) drama.author = meta.author;
    if (meta.authorId) drama.authorId = meta.authorId;
    if (meta.authorUrl) drama.authorUrl = meta.authorUrl;
    if (meta.actors.length) drama.actors = meta.actors.slice();
    if (meta.tags.length) drama.tags = meta.tags.slice();
    if (meta.onlineDate) drama.onlineDate = meta.onlineDate;

    // 详情阶段就把播放地址解出来：点播放 0 请求
    try {
      const media = prepareMedia(html, pageUrl);
      host.cacheSet(readyKey(id), JSON.stringify({
        url: media.url,
        playlist: media.playlist,
        referer: media.referer || pageUrl,
        quality: media.quality || 1080,
        durationMs: media.durationMs || 0
      }), 5 * 60 * 1000);
    } catch (error) {
      try {
        host.log('SpankBang 预取失败（播放时会重试）: ' + String((error && error.message) || error));
      } catch (ignored) { /* 忽略 */ }
    }

    return {
      drama,
      chapters: [{
        id: host.chapterId(id, 'video'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        videoUrl: PLAY_PREFIX + id,
        pageUrl,
        referer: pageUrl
      }]
    };
  },

  resolveMedia(task) {
    const chapter = (task && task.chapter) || {};
    let id = '';
    const raw = String(chapter.videoUrl || '');
    if (raw.indexOf(PLAY_PREFIX) === 0) id = raw.slice(PLAY_PREFIX.length);
    if (!id) {
      const parts = String((task && task.dramaId) || '').split(':');
      if (parts.length >= 2) id = parts[1];
    }
    if (!id) throw new Error('SpankBang 无法确定视频 ID');
    const pageUrl = SITE + '/' + id + '/video/';

    try {
      const cached = host.cacheGet(readyKey(id));
      if (cached) {
        const ready = JSON.parse(cached);
        if (ready && ready.url && ready.playlist) {
          return {
            url: ready.url,
            playlist: ready.playlist,
            referer: ready.referer || pageUrl,
            quality: ready.quality || 1080,
            durationMs: ready.durationMs || 0,
            credentials: {
              referer: ready.referer || pageUrl,
              origin: SITE,
              userAgent: agent()
            }
          };
        }
      }
    } catch (error) { /* 走现场取 */ }

    const media = prepareMedia(fetchPage('/' + id + '/video/', pageUrl), pageUrl);
    try {
      host.cacheSet(readyKey(id), JSON.stringify({
        url: media.url,
        playlist: media.playlist,
        referer: media.referer || pageUrl,
        quality: media.quality || 1080,
        durationMs: media.durationMs || 0
      }), 5 * 60 * 1000);
    } catch (error) { /* 缓存不可用不影响播放 */ }
    return media;
  }
};
