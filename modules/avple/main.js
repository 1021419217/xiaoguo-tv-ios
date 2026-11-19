// AVPLE —— Next.js 站点，列表、详情、标签页的数据都在页面里的 __NEXT_DATA__。
// 详情页 instance.play 是相对路径 hls/{token}/playlist.m3u8，要拼到 cdnedge.live
// 的「前缀 + 1」域名上（前端用 u.map(e => e.split(".")[0] + "1.cdnedge.live") 生成）。
// 站点没有独立的模特/上传者页，片商和女优都用 /search?key= 或 /tags/{id}/ 当二级页。

const SITE = 'https://avple.app';
const MIRRORS = ['https://avple.tv'];
const HOST = 'avple.app';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const PAGE_LIMIT = 100;
const MEDIA_PREFIX = '/file/avple-asserts/';
const PLAY_TTL = 30 * 60 * 1000;

const CDN_PREFIXES = [
  'd862cp', 'q2cyl7', 'u89ey', 'zo392', 'wo880', '6m7d', '8bb88', 'fa678',
  'pg2z7', '1xp60', '47b61', 'i3qss', '10j99', 'je40u', 's2jfy', 'l87ul',
  's6s6u', 'rup0u', 'ja34l', 'rr0s1', 'c4m6s', '60frt', 'rd192', '2nm9j',
  'l8uao', 'ie2ow', 'fhq06', 'b3h6s', 'sms9q', 'xre5q', 'tn5un', '8fld9',
  's3fl8', '3krlq', '5sggi', 'xeba3', 'h8ze9', 'ta6us', '2dvqt', '99fnq',
  'x8x5b', 'isg2c',
];

const CATEGORIES = [
  { id: '121', name: '麻豆傳媒' },
  { id: '138', name: '台灣AV' },
  { id: '142', name: '國產AV' },
  { id: '139', name: '最新影片' },
  { id: '136', name: '孟若羽' },
  { id: '122', name: 'SWAG' },
  { id: '132', name: '探花精選' },
  { id: '135', name: 'FC2PPV' },
  { id: '143', name: '自拍流出' },
  { id: '140', name: '熱門影片' },
  { id: '131', name: '國產自拍' },
];

function agent() {
  return host.challengeUA(HOST) || UA;
}

function cookieHeader() {
  return host.challengeCookie(HOST) || '';
}

function decodeHtml(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  return String(text == null ? '' : text).replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (entity, body) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    }
    return Object.prototype.hasOwnProperty.call(named, body) ? named[body] : entity;
  });
}

function clean(html) {
  return decodeHtml(String(html || '').replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function truncate(text, limit) {
  const trimmed = String(text == null ? '' : text).trim();
  const characters = Array.from(trimmed);
  return characters.length <= limit ? trimmed : characters.slice(0, limit).join('') + '...';
}

function fetchPage(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const suffix = url.indexOf(SITE) === 0 ? url.slice(SITE.length) : '';
  const mirrors = [];
  if (suffix !== '') {
    for (const base of MIRRORS) {
      mirrors.push(base + suffix);
    }
  }
  let response = null;
  try {
    response = host.fetchText({
      url,
      referer: SITE + '/',
      userAgent: agent(),
      cookie: cookieHeader(),
      mirrors,
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|503|challenge|验证|限流/i.test(message)) {
      throw new Error('AVPLE 被站点拦截（' + message + '），请稍后重试，或在站源页完成人机验证');
    }
    throw new Error('AVPLE 连接失败：' + message);
  }
  return (response && response.body) || '';
}

function nextData(html) {
  const match = String(html || '').match(/<script[^>]*id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!match) {
    return null;
  }
  try {
    return JSON.parse(match[1]);
  } catch (error) {
    return null;
  }
}

function pageProps(html) {
  const data = nextData(html);
  return data && data.props && data.props.pageProps ? data.props.pageProps : null;
}

function stringList(value) {
  const out = [];
  if (!Array.isArray(value)) {
    return out;
  }
  for (const entry of value) {
    if (typeof entry === 'string' && entry.trim() !== '' && out.indexOf(entry.trim()) < 0) {
      out.push(entry.trim());
    }
  }
  return out;
}

function coverOf(raw) {
  const value = String((raw && (raw.img_normal || raw.img_preview)) || '').trim();
  if (value === '' || value.indexOf('data:') === 0) {
    return '';
  }
  return value.replace(/^http:/, 'https:');
}

function releaseDate(value) {
  const match = String(value || '').match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (!match) {
    return '';
  }
  const year = parseInt(match[1], 10);
  const month = parseInt(match[2], 10);
  const day = parseInt(match[3], 10);
  if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) {
    return '';
  }
  const pad = (number) => (number < 10 ? '0' + number : String(number));
  return year + '-' + pad(month) + '-' + pad(day);
}

// 标签名 → 标签 id，详情页的 /tags/{id}/1/date 链接就是片商/分类的唯一入口。
function tagMap(html) {
  const map = {};
  const pattern = /<a[^>]+href="\/tags\/(\d+)\/1\/date"[^>]*>([\s\S]{0,260}?)<\/a>/g;
  for (const match of String(html || '').matchAll(pattern)) {
    const name = clean(match[2]).replace(/^#+\s*/, '').trim();
    if (name !== '' && !Object.prototype.hasOwnProperty.call(map, name)) {
      map[name] = match[1];
    }
  }
  return map;
}

function toItem(raw) {
  const sourceId = String((raw && raw._id) || '').trim();
  const title = truncate(String((raw && raw.title) || '').trim() || sourceId, 512);
  const tags = stringList(raw && raw.tags);
  const actors = stringList(raw && raw.acters);
  const cover = coverOf(raw);
  const duration = String((raw && raw.timeLengh) || '').trim();
  const item = {
    id: host.dramaId(sourceId),
    source: host.source,
    sourceId,
    title,
    name: title,
    cover,
    coverUrl: cover,
    duration,
    remark: duration,
    onlineDate: releaseDate(raw && raw.release),
    totalEpisode: 1,
    episodeCount: 1,
    channelName: 'AVPLE',
    categoryName: '视频',
  };
  if (tags.length > 0) {
    item.tags = tags;
    item.maker = tags[0];
    item.author = tags[0];
    item.authorUrl = SITE + '/search?key=' + encodeURIComponent(tags[0]);
  }
  if (actors.length > 0) {
    item.actors = actors;
  }
  if (raw && raw.code) {
    item.serial = String(raw.code).trim();
  }
  return item;
}

function fetchList(path) {
  const props = pageProps(fetchPage(path));
  if (!props) {
    throw new Error('AVPLE 列表页结构变化，没有找到数据');
  }
  const raw = Array.isArray(props.data) ? props.data : [];
  const items = [];
  for (const entry of raw) {
    const item = toItem(entry);
    if (item.sourceId !== '') {
      items.push(item);
    }
  }
  const page = Number(props.page || 1);
  const totalPage = Number(props.totalPage || 1);
  return { items, hasMore: page < totalPage && items.length > 0 };
}

function mediaUrl(play) {
  const value = String(play || '').trim();
  if (value === '') {
    return '';
  }
  if (/^https?:\/\//i.test(value)) {
    return value.replace(/^http:/, 'https:');
  }
  const index = Math.floor(Math.random() * CDN_PREFIXES.length);
  return 'https://' + CDN_PREFIXES[index] + '1.cdnedge.live' + MEDIA_PREFIX + value.replace(/^\/+/, '');
}

// play 是固定的 hls/{token}/playlist.m3u8，详情页解析一次就够，播放时不必再抓整页。
function cachePlay(sourceId, play) {
  const value = String(play || '').trim();
  if (value === '') {
    return;
  }
  try {
    host.cacheSet('play:' + sourceId, value, PLAY_TTL);
  } catch (error) {
    /* 缓存不可用时忽略 */
  }
}

function cachedPlay(sourceId) {
  try {
    return String(host.cacheGet('play:' + sourceId) || '').trim();
  } catch (error) {
    return '';
  }
}

function sourceIdOf(task) {
  const prefix = host.source + ':';
  let value = String((task && task.dramaId) || '').trim();
  if (value.indexOf(prefix) === 0) {
    value = value.slice(prefix.length).trim();
  }
  if (value !== '') {
    return value;
  }
  const chapterId = String((task && task.chapter && task.chapter.id) || '');
  const parts = chapterId.split(':');
  return parts.length >= 2 ? parts[1].trim() : '';
}

module.exports = {
  validCategory(category) {
    const id = String(category || '').trim();
    if (id === '') {
      return true;
    }
    return CATEGORIES.some((entry) => entry.id === id);
  },

  categories() {
    return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
  },

  catalogPage(page, category) {
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const id = String(category || '').trim() || '139';
    if (!CATEGORIES.some((entry) => entry.id === id)) {
      throw new Error('AVPLE 分类无效');
    }
    return fetchList('/tags/' + id + '/' + number + '/date');
  },

  search(page, query) {
    const text = String(query || '').trim();
    if (text === '' || text.length > 200) {
      throw new Error('AVPLE 搜索关键词无效');
    }
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    return fetchList('/search?key=' + encodeURIComponent(text) + '&page=' + number);
  },

  // 片商走 /tags/{id}/{page}/date，女优/关键词走 /search?key=。
  author(authorId, authorName, page) {
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const id = String(authorId || '').trim();
    const name = String(authorName || '').trim();
    if (/^\d+$/.test(id)) {
      return fetchList('/tags/' + id + '/' + number + '/date');
    }
    if (name !== '') {
      return fetchList('/search?key=' + encodeURIComponent(name) + '&page=' + number);
    }
    return { items: [], hasMore: false };
  },

  detail(sourceId) {
    const id = String(sourceId || '').trim();
    if (!/^\d+$/.test(id)) {
      throw new Error('AVPLE 视频 ID 无效');
    }
    const pageUrl = SITE + '/video/' + id;
    const html = fetchPage(pageUrl);
    const props = pageProps(html);
    const instance = props && props.instance;
    if (!instance) {
      throw new Error('AVPLE 详情页结构变化，没有找到视频数据');
    }
    const title = truncate(String(instance.title || '').trim() || id, 512);
    cachePlay(id, instance.play);
    const tags = stringList(instance.tags);
    const actors = stringList(instance.acters);
    const duration = String(instance.timeLengh || '').trim();
    const cover = coverOf(instance);
    const map = tagMap(html);
    const maker = tags.length > 0 ? tags[0] : '';
    const makerId = maker !== '' && map[maker] ? map[maker] : '';
    const drama = {
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title,
      name: title,
      desc: title,
      intro: title,
      cover,
      coverUrl: cover,
      channelName: maker || 'AVPLE',
      categoryName: '视频',
      onlineDate: releaseDate(instance.release),
      duration,
      totalEpisode: 1,
      episodeCount: 1,
      tags,
      actors,
      maker,
      serial: String(instance.code || '').trim(),
    };
    if (maker !== '') {
      drama.author = maker;
      if (makerId !== '') {
        drama.authorId = makerId;
        drama.authorUrl = SITE + '/tags/' + makerId + '/1/date';
      } else {
        drama.authorUrl = SITE + '/search?key=' + encodeURIComponent(maker);
      }
    }
    if (!drama.author && actors.length > 0) {
      drama.author = actors[0];
      drama.authorUrl = SITE + '/search?key=' + encodeURIComponent(actors[0]);
    }
    const chapter = {
      id: host.chapterId(id, 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: 'avple-play://' + id,
      pageUrl,
      referer: pageUrl,
    };
    return { drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    const sourceId = sourceIdOf(task);
    if (!/^\d+$/.test(sourceId)) {
      throw new Error('AVPLE 播放分集无效，请刷新详情');
    }
    const pageUrl = SITE + '/video/' + sourceId;
    let play = cachedPlay(sourceId);
    if (play === '') {
      const props = pageProps(fetchPage(pageUrl));
      const instance = props && props.instance;
      play = (instance && instance.play) || '';
      cachePlay(sourceId, play);
    }
    const url = mediaUrl(play);
    if (url === '') {
      throw new Error('AVPLE 页面里没有解析到播放地址');
    }
    const media = {
      url,
      referer: pageUrl,
      quality: 0,
      credentials: {
        referer: pageUrl,
        origin: SITE,
        userAgent: agent(),
        cookie: cookieHeader(),
      },
    };
    try {
      return host.prepareWebMedia(media, 'AVPLE');
    } catch (error) {
      return media;
    }
  },
};
