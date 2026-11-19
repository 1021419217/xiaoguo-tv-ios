// 肉視頻（rou.video）—— SolidStart 站。详情页的播放地址藏在 hydration 数据里：
// ev:{d:"base64",k:52}，解出来是 {videoUrl:"/api/hls/{id}"}。
// 站点把 m3u8 和分片都包在 PNG 的 roUd chunk 里，m3u8 还是 deflate 压缩的，
// 由宿主 fetchPlaylist / 分片代理解包（宿主侧能力）。

const SITE = 'https://rou.video';
const HOST = 'rou.video';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const PAGE_LIMIT = 1500;

const CATEGORIES = [
  { id: '', name: '最新' },
  { id: '國產AV', name: '國產AV' },
  { id: '探花', name: '探花' },
  { id: '自拍流出', name: '自拍流出' },
  { id: 'OnlyFans', name: 'OnlyFans' },
  { id: '日本', name: '日本' },
  { id: 'AI短劇', name: 'AI短劇' },
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
  let response = null;
  try {
    response = host.fetchText({
      url,
      referer: SITE + '/home',
      userAgent: agent(),
      cookie: cookieHeader(),
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|503|challenge|验证/i.test(message)) {
      throw new Error('肉視頻 被站点拦截（' + message + '），请稍后重试');
    }
    throw new Error('肉視頻 连接失败：' + message);
  }
  return (response && response.body) || '';
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

function durationOf(value) {
  const match = String(value || '').match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/i);
  if (!match) {
    return String(value || '');
  }
  const hours = parseInt(match[1] || '0', 10);
  const minutes = parseInt(match[2] || '0', 10);
  const seconds = parseInt(match[3] || '0', 10);
  if (hours > 0) {
    return hours + ':' + (minutes < 10 ? '0' + minutes : minutes) + ':' + (seconds < 10 ? '0' + seconds : seconds);
  }
  return minutes + ':' + (seconds < 10 ? '0' + seconds : seconds);
}

function parseCards(html) {
  const items = [];
  const seen = {};
  const blocks = String(html || '').split('<a href="/v/');
  for (let index = 1; index < blocks.length; index++) {
    const block = blocks[index].slice(0, 1800);
    const idMatch = block.match(/^([a-z0-9]{20,})"/);
    if (!idMatch) {
      continue;
    }
    const sourceId = idMatch[1];
    if (seen[sourceId]) {
      continue;
    }
    seen[sourceId] = true;
    const image = block.match(/<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"/);
    const cover = image ? decodeHtml(image[1]).replace(/^http:/, 'https:') : '';
    let title = image ? decodeHtml(image[2]).trim() : '';
    const heading = block.match(/<h3[^>]*>([\s\S]{0,300}?)<\/h3>/);
    if (heading) {
      const text = clean(heading[1]);
      if (text !== '') {
        title = text;
      }
    }
    if (title === '') {
      title = sourceId;
    }
    const spans = [];
    for (const span of block.matchAll(/<span[^>]*>([\s\S]{0,60}?)<\/span>/g)) {
      const text = clean(span[1]);
      if (text !== '') {
        spans.push(text);
      }
    }
    const duration = spans.find((text) => /\d+\s*(小時|小时|分|秒)/.test(text)) || '';
    const resolution = spans.find((text) => /^\d{3,4}P$/.test(text)) || '';
    const serial = spans.find((text) => /^[A-Z]{2,8}-?\d{2,6}$/.test(text)) || '';
    items.push({
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title: truncate(title, 512),
      name: truncate(title, 512),
      cover,
      coverUrl: cover,
      duration,
      remark: duration || resolution,
      totalEpisode: 1,
      episodeCount: 1,
      channelName: '肉視頻',
      categoryName: '视频',
      serial,
    });
    if (items.length >= 60) {
      break;
    }
  }
  return items;
}

function hasMore(html, page) {
  let max = 0;
  for (const match of String(html || '').matchAll(/[?&]page=(\d+)/g)) {
    max = Math.max(max, parseInt(match[1], 10));
  }
  return max > page;
}

function fetchList(path, page) {
  const url = path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page;
  const html = fetchPage(url);
  const items = parseCards(html);
  return { items, hasMore: hasMore(html, page) && items.length > 0 };
}

// ev:{d:"base64",k:52} → JSON.parse(atob(d) 每字符减 k)
function decodeEv(d, k) {
  let bytes = null;
  try {
    bytes = host.base64Decode(d);
  } catch (error) {
    return null;
  }
  const shifted = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index++) {
    shifted[index] = (bytes[index] - k + 256) % 256;
  }
  try {
    return JSON.parse(host.utf8Decode(shifted));
  } catch (error) {
    return null;
  }
}

function playInfo(html) {
  const match = String(html || '').match(/ev:\$R\[\d+\]=\{d:"([A-Za-z0-9+/=]+)",k:(\d+)\}/);
  if (!match) {
    return null;
  }
  return decodeEv(match[1], parseInt(match[2], 10));
}

function videoObject(html) {
  const blocks = String(html || '').match(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/g) || [];
  for (const block of blocks) {
    const body = block.replace(/^<script[^>]*>/, '').replace(/<\/script>$/, '');
    let data = null;
    try {
      data = JSON.parse(body);
    } catch (error) {
      continue;
    }
    if (data && data['@type'] === 'VideoObject') {
      return data;
    }
  }
  return null;
}

function seriesIdOf(url) {
  const match = String(url || '').match(/\/s\/([a-z0-9]{20,})/);
  return match ? match[1] : '';
}

module.exports = {
  validCategory(category) {
    const id = String(category || '').trim();
    return CATEGORIES.some((entry) => entry.id === id);
  },

  categories() {
    return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
  },

  catalogPage(page, category) {
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const id = String(category || '').trim();
    if (!CATEGORIES.some((entry) => entry.id === id)) {
      throw new Error('肉視頻 分类无效');
    }
    if (id === '') {
      return fetchList('/v?order=createdAt', number);
    }
    return fetchList('/t/' + encodeURIComponent(id), number);
  },

  search(page, query) {
    const text = String(query || '').trim();
    if (text === '' || text.length > 100) {
      throw new Error('肉視頻 搜索关键词无效');
    }
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    return fetchList('/search?q=' + encodeURIComponent(text), number);
  },

  author(authorId, authorName, page) {
    const id = String(authorId || '').trim();
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    if (!/^[a-z0-9]{20,}$/.test(id)) {
      return { items: [], hasMore: false };
    }
    return fetchList('/s/' + id, number);
  },

  detail(sourceId) {
    const slug = String(sourceId || '').trim();
    if (!/^[a-z0-9]{20,}$/.test(slug)) {
      throw new Error('肉視頻 视频 ID 无效');
    }
    const pageUrl = SITE + '/v/' + slug;
    const html = fetchPage(pageUrl);
    const meta = videoObject(html);
    if (!meta) {
      throw new Error('肉視頻 详情页结构变化，没有找到视频数据');
    }
    const title = truncate(String(meta.name || '').trim() || slug, 512);
    const covers = Array.isArray(meta.thumbnailUrl) ? meta.thumbnailUrl : [];
    const cover = covers.length > 0 ? decodeHtml(covers[0]).replace(/^http:/, 'https:') : '';
    const tags = Array.isArray(meta.genre) ? meta.genre.filter((text) => typeof text === 'string' && text.trim() !== '') : [];
    const drama = {
      id: host.dramaId(slug),
      source: host.source,
      sourceId: slug,
      title,
      name: title,
      desc: truncate(String(meta.description || title), 12000),
      intro: truncate(String(meta.description || title), 12000),
      cover,
      coverUrl: cover,
      channelName: '肉視頻',
      categoryName: '视频',
      onlineDate: releaseDate(meta.uploadDate),
      duration: durationOf(meta.duration),
      totalEpisode: 1,
      episodeCount: 1,
      tags,
    };
    const series = meta.partOfSeries;
    if (series && series.name) {
      drama.author = String(series.name).trim();
      const seriesId = seriesIdOf(series.url);
      if (seriesId !== '') {
        drama.authorId = seriesId;
        drama.authorUrl = SITE + '/s/' + seriesId;
      }
    }
    const chapter = {
      id: host.chapterId(slug, 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: 'rou-play://' + slug,
      pageUrl,
      referer: pageUrl,
    };
    return { drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    const prefix = host.source + ':';
    let slug = String((task && task.dramaId) || '').trim();
    if (slug.indexOf(prefix) === 0) {
      slug = slug.slice(prefix.length).trim();
    }
    if (!/^[a-z0-9]{20,}$/.test(slug)) {
      throw new Error('肉視頻 播放分集无效，请刷新详情');
    }
    const pageUrl = SITE + '/v/' + slug;
    const html = fetchPage(pageUrl);
    const info = playInfo(html);
    const videoUrl = info && info.videoUrl;
    if (!videoUrl) {
      throw new Error('肉視頻 页面里没有解析到播放地址');
    }
    const address = videoUrl.indexOf('http') === 0 ? videoUrl : SITE + videoUrl;
    let playlist = '';
    try {
      playlist = host.fetchPlaylist({ url: address, referer: pageUrl }).playlist;
    } catch (error) {
      throw new Error('肉視頻 获取播放清单失败：' + String((error && error.message) || error));
    }
    const media = {
      url: address,
      referer: pageUrl,
      playlist,
      quality: 0,
      credentials: {
        referer: pageUrl,
        origin: SITE,
        userAgent: agent(),
        cookie: cookieHeader(),
      },
    };
    try {
      return host.prepareWebMedia(media, '肉視頻');
    } catch (error) {
      return media;
    }
  },
};
