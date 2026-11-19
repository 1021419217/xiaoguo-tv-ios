// KanAV —— 苹果CMS（MacCMS）站。详情页路由是空的，改成用播放页当详情源：
// player_aaaa 里带 vod_name / vod_actor，页面里有封面图。
// 播放地址是 MacCMS 的 encrypt=2：base64 解出 %XX 串，再 unescape 才是 m3u8。
// 站点没有演员页，author 用演员名走搜索页。

const SITE = 'https://kanav.ad';
const HOST = 'kanav.ad';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const PAGE_LIMIT = 300;

const CATEGORIES = [
  { id: '1', name: '中文字幕' },
  { id: '2', name: '日韩有码' },
  { id: '3', name: '日韩无码' },
  { id: '4', name: '国产AV' },
  { id: '30', name: '自拍泄密' },
  { id: '31', name: '探花约炮' },
  { id: '32', name: '主播录制' },
  { id: '25', name: '里番' },
  { id: '26', name: '泡面番' },
  { id: '27', name: 'Motion Anime' },
  { id: '28', name: '3D动画' },
  { id: '29', name: '同人作品' },
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

function percentDecode(text) {
  try {
    return decodeURIComponent(text);
  } catch (error) {
    return String(text).replace(/%([0-9A-Fa-f]{2})/g, (match, hex) => String.fromCharCode(parseInt(hex, 16)));
  }
}

function fetchPage(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetchText({
      url,
      referer: SITE + '/',
      userAgent: agent(),
      cookie: cookieHeader(),
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|503|challenge|验证/i.test(message)) {
      throw new Error('KanAV 被站点拦截（' + message + '），请稍后重试');
    }
    throw new Error('KanAV 连接失败：' + message);
  }
  return (response && response.body) || '';
}

function releaseDate(value) {
  const match = String(value || '').match(/(\d{4})\s*\/\s*(\d{1,2})\s*\/\s*(\d{1,2})/);
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

function codeOf(title) {
  const match = String(title || '').match(/\b([A-Z]{2,10}-\d{2,6})\b/);
  return match ? match[1].toUpperCase() : '';
}

function playPath(sourceId) {
  const parts = String(sourceId || '').trim().split('/');
  const id = (parts[0] || '').trim();
  if (!/^\d+$/.test(id)) {
    throw new Error('KanAV 视频 ID 无效');
  }
  const sid = /^\d+$/.test(parts[1] || '') ? parts[1] : '1';
  const nid = /^\d+$/.test(parts[2] || '') ? parts[2] : '1';
  return '/index.php/vod/play/id/' + id + '/sid/' + sid + '/nid/' + nid + '.html';
}

function playerData(html) {
  const match = String(html || '').match(/var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*<\/script>/);
  if (!match) {
    return null;
  }
  try {
    return JSON.parse(match[1]);
  } catch (error) {
    return null;
  }
}

function decodePlayUrl(raw) {
  const text = String(raw || '').trim();
  if (text === '') {
    return '';
  }
  if (/^https?:\/\//i.test(text)) {
    return text.replace(/^http:/, 'https:');
  }
  let decoded = '';
  try {
    decoded = host.utf8Decode(host.base64Decode(text));
  } catch (error) {
    return '';
  }
  return percentDecode(decoded).replace(/^http:/, 'https:');
}

function actorsOf(value) {
  const out = [];
  for (const part of String(value || '').split(/[,，、/|]+/)) {
    const name = part.trim();
    if (name !== '' && out.indexOf(name) < 0 && out.length < 20) {
      out.push(name);
    }
  }
  return out;
}

function parseCards(html) {
  const items = [];
  const seen = {};
  const blocks = String(html || '').split('<div class="col-md-3');
  for (let index = 1; index < blocks.length; index++) {
    const block = blocks[index].slice(0, 2600);
    const link = block.match(/href="(\/index\.php\/vod\/play\/id\/(\d+)\/sid\/(\d+)\/nid\/(\d+)\.html)"/);
    if (!link) {
      continue;
    }
    const sourceId = link[2] + '/' + link[3] + '/' + link[4];
    if (seen[sourceId]) {
      continue;
    }
    seen[sourceId] = true;
    const image = block.match(/<img[^>]+(?:data-original|src)="([^"]+)"[^>]*alt="([^"]*)"/);
    const cover = image ? decodeHtml(image[1]).replace(/^http:/, 'https:') : '';
    let title = image ? decodeHtml(image[2]).trim() : '';
    const titled = block.match(/<a\s+title="([^"]{1,300})"[^>]*href="\/index\.php\/vod\/play/);
    if (titled && clean(titled[1]) !== '') {
      title = clean(titled[1]);
    }
    if (title === '') {
      title = sourceId;
    }
    const views = block.match(/<span class="model-view-left">([\s\S]{0,40}?)<\/span>/);
    const duration = block.match(/<span class="model-view">([\s\S]{0,40}?)<\/span>/);
    const dateMatch = block.match(/(\d{4})\s*\/\s*(\d{1,2})\s*\/\s*(\d{1,2})/);
    const onlineDate = dateMatch
      ? dateMatch[1] + '-' + (dateMatch[2].length < 2 ? '0' + dateMatch[2] : dateMatch[2]) + '-' + (dateMatch[3].length < 2 ? '0' + dateMatch[3] : dateMatch[3])
      : '';
    items.push({
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title: truncate(title, 512),
      name: truncate(title, 512),
      cover,
      coverUrl: cover,
      duration: duration ? clean(duration[1]) : '',
      remark: duration ? clean(duration[1]) : views ? clean(views[1]) : '',
      onlineDate,
      totalEpisode: 1,
      episodeCount: 1,
      channelName: 'KanAV',
      categoryName: '视频',
      serial: codeOf(title),
    });
    if (items.length >= 60) {
      break;
    }
  }
  return items;
}

function hasMore(html, page) {
  let max = 0;
  for (const match of String(html || '').matchAll(/page[/=](\d+)/g)) {
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

module.exports = {
  validCategory(category) {
    const id = String(category || '').trim();
    return id === '' || CATEGORIES.some((entry) => entry.id === id);
  },

  categories() {
    return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
  },

  catalogPage(page, category) {
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const id = String(category || '').trim() || '1';
    if (!CATEGORIES.some((entry) => entry.id === id)) {
      throw new Error('KanAV 分类无效');
    }
    const path = '/index.php/vod/type/id/' + id + (number > 1 ? '/page/' + number : '') + '.html';
    const html = fetchPage(path);
    const items = parseCards(html);
    return { items, hasMore: hasMore(html, number) && items.length > 0 };
  },

  search(page, query) {
    const text = String(query || '').trim();
    if (text === '' || text.length > 200) {
      throw new Error('KanAV 搜索关键词无效');
    }
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const html = fetchPage('/index.php/vod/search.html?wd=' + encodeURIComponent(text) + '&page=' + number);
    const items = parseCards(html);
    return { items, hasMore: hasMore(html, number) && items.length > 0 };
  },

  // 站点没有演员页，演员名走搜索。
  author(authorId, authorName, page) {
    const name = String(authorName || '').trim();
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    if (name === '') {
      return { items: [], hasMore: false };
    }
    const html = fetchPage('/index.php/vod/search.html?wd=' + encodeURIComponent(name) + '&page=' + number);
    const items = parseCards(html);
    return { items, hasMore: hasMore(html, number) && items.length > 0 };
  },

  detail(sourceId) {
    const path = playPath(sourceId);
    const pageUrl = SITE + path;
    const html = fetchPage(path);
    const data = playerData(html);
    if (!data) {
      throw new Error('KanAV 播放页结构变化，没有找到 player_aaaa');
    }
    const vod = data.vod_data || {};
    const pageTitle = (html.match(/<title[^>]*>([\s\S]{0,200}?)<\/title>/) || [])[1];
    const title = truncate(String(vod.vod_name || '').trim() || clean(pageTitle), 512);
    const coverMatch = html.match(/<img[^>]+class="[^"]*countext-img[^"]*"[^>]+src="([^"]+)"/);
    const cover = coverMatch ? decodeHtml(coverMatch[1]).replace(/^http:/, 'https:') : '';
    const actors = actorsOf(vod.vod_actor);
    const drama = {
      id: host.dramaId(String(sourceId || '').trim()),
      source: host.source,
      sourceId: String(sourceId || '').trim(),
      title,
      name: title,
      desc: title,
      intro: title,
      cover,
      coverUrl: cover,
      channelName: 'KanAV',
      categoryName: '视频',
      totalEpisode: 1,
      episodeCount: 1,
      serial: codeOf(title),
    };
    if (actors.length > 0) {
      drama.actors = actors;
      drama.author = actors[0];
      drama.authorUrl = SITE + '/index.php/vod/search.html?wd=' + encodeURIComponent(actors[0]);
    }
    if (vod.vod_class) {
      drama.tags = String(vod.vod_class).split(/[,，、/|]+/).map((text) => text.trim()).filter((text) => text !== '');
    }
    const chapter = {
      id: host.chapterId(String(sourceId || '').trim(), 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: 'kanav-play://' + String(sourceId || '').trim(),
      pageUrl,
      referer: pageUrl,
    };
    return { drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    const prefix = host.source + ':';
    let sourceId = String((task && task.dramaId) || '').trim();
    if (sourceId.indexOf(prefix) === 0) {
      sourceId = sourceId.slice(prefix.length).trim();
    }
    const path = playPath(sourceId);
    const pageUrl = SITE + path;
    const html = fetchPage(path);
    const data = playerData(html);
    const url = decodePlayUrl(data && data.url);
    if (url === '') {
      throw new Error('KanAV 播放地址解析失败');
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
      return host.prepareWebMedia(media, 'KanAV');
    } catch (error) {
      return media;
    }
  },
};
