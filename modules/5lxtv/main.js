// 5L —— 服务端渲染的 HTML 站，列表用 <a href="/videos/{slug}" class="group block"> 卡片。
// 详情页把播放地址藏起来：不写 m3u8，只留 slug、t、n 三个变量，点播放才请求
// /api/play/{slug}?t=&n= 拿到 m3u8。分片是绝对地址的 .jpg 伪装 TS，AES-128 加密，
// 密钥走 /api/hlskey/{slug}?t=&n=，这两层都由宿主媒体代理处理。

const SITE = 'https://5lxtv.com';
const HOST = '5lxtv.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const PAGE_LIMIT = 200;

const CATEGORIES = [
  { id: 'latest', name: '最新' },
  { id: 'ai-drama', name: '短劇' },
  { id: 'decensored', name: '無碼破解' },
  { id: 'censored', name: '有碼A片' },
  { id: 'chinese', name: '中文字幕' },
  { id: 'selfie', name: '偷拍盜攝' },
  { id: 'cuckold', name: '綠帽NTR' },
  { id: 'exclusive', name: '國產AV' },
];

function agent() {
  return host.challengeUA(HOST) || UA;
}

function cookieHeader() {
  return host.challengeCookie(HOST) || '';
}

function decodeHtml(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };
  return String(text == null ? '' : text).replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z#0-9]+);/g, (entity, body) => {
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
      referer: SITE + '/',
      userAgent: agent(),
      cookie: cookieHeader(),
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|503|challenge|验证/i.test(message)) {
      throw new Error('5L 被站点拦截（' + message + '），请稍后重试');
    }
    throw new Error('5L 连接失败：' + message);
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

function codeOf(title) {
  const match = String(title || '').match(/^([A-Za-z]{2,10}-\d{2,6})\b/);
  return match ? match[1].toUpperCase() : '';
}

function tagsOf(html) {
  const tags = [];
  const pattern = /<a[^>]+href="\/tags\/([^"?#]+)"[^>]*>/g;
  for (const match of String(html || '').matchAll(pattern)) {
    let name = match[1];
    try {
      name = decodeURIComponent(name);
    } catch (error) {
      /* 保留原值 */
    }
    name = name.trim();
    if (name !== '' && tags.indexOf(name) < 0 && Array.from(name).length <= 48) {
      tags.push(name);
    }
    if (tags.length >= 20) {
      break;
    }
  }
  return tags;
}

function actorsOf(html) {
  const actors = [];
  const pattern = /<a[^>]+href="\/actors\/(\d+)\/([^"?#]+)"[^>]*>([\s\S]{0,400}?)<\/a>/g;
  for (const match of String(html || '').matchAll(pattern)) {
    let name = '';
    const span = match[3].match(/<span[^>]*>([\s\S]{0,80}?)<\/span>/);
    if (span) {
      name = clean(span[1]);
    }
    if (name === '') {
      try {
        name = decodeURIComponent(match[2]).trim();
      } catch (error) {
        name = match[2].trim();
      }
    }
    if (name !== '' && actors.length < 20) {
      actors.push({ id: match[1], name, url: SITE + '/actors/' + match[1] + '/' + match[2] });
    }
  }
  return actors;
}

function parseCards(html) {
  const items = [];
  const seen = {};
  const pattern = /<a\b[^>]*href="\/videos\/([^"?#]+)"[^>]*>([\s\S]{0,2400}?)<\/a>/g;
  for (const match of String(html || '').matchAll(pattern)) {
    const slug = match[1].trim();
    if (slug === '' || seen[slug]) {
      continue;
    }
    seen[slug] = true;
    const block = match[2];
    const image = block.match(/<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"/);
    const cover = image ? decodeHtml(image[1]).replace(/^http:/, 'https:') : '';
    let title = image ? decodeHtml(image[2]).trim() : '';
    const titleDiv = block.match(/<div class="[^"]*line-clamp-2[^"]*"[^>]*>([\s\S]{0,300}?)<\/div>/);
    if (titleDiv) {
      const text = clean(titleDiv[1]);
      if (text !== '') {
        title = text;
      }
    }
    if (title === '') {
      title = slug;
    }
    const spans = [];
    for (const span of block.matchAll(/<span[^>]*>([\s\S]{0,40}?)<\/span>/g)) {
      spans.push(clean(span[1]));
    }
    const duration = spans.find((text) => /^\d{1,2}:\d{2}(:\d{2})?$/.test(text)) || '';
    const views = spans.find((text) => text.indexOf('▶') === 0) || '';
    const dateDiv = block.match(/<div class="[^"]*text-\[11px\][^"]*"[^>]*>([\s\S]{0,40}?)<\/div>/);
    const item = {
      id: host.dramaId(slug),
      source: host.source,
      sourceId: slug,
      title: truncate(title, 512),
      name: truncate(title, 512),
      cover,
      coverUrl: cover,
      duration,
      remark: duration || views,
      onlineDate: releaseDate(dateDiv ? clean(dateDiv[1]) : ''),
      totalEpisode: 1,
      episodeCount: 1,
      channelName: '5L',
      categoryName: '视频',
      serial: codeOf(title),
    };
    items.push(item);
    if (items.length >= 60) {
      break;
    }
  }
  return items;
}

function hasMore(html, page) {
  const numbers = [];
  for (const match of String(html || '').matchAll(/[?&]page=(\d+)/g)) {
    numbers.push(parseInt(match[1], 10));
  }
  if (numbers.length === 0) {
    return false;
  }
  return Math.max.apply(null, numbers) > page;
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
    const id = String(category || '').trim() || 'latest';
    if (!CATEGORIES.some((entry) => entry.id === id)) {
      throw new Error('5L 分类无效');
    }
    return fetchList('/' + id, number);
  },

  search(page, query) {
    const text = String(query || '').trim();
    if (text === '' || text.length > 200) {
      throw new Error('5L 搜索关键词无效');
    }
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    return fetchList('/search?q=' + encodeURIComponent(text), number);
  },

  author(authorId, authorName, page) {
    const number = Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
    const id = String(authorId || '').trim();
    const name = String(authorName || '').trim();
    if (/^\d+$/.test(id) && name !== '') {
      return fetchList('/actors/' + id + '/' + encodeURIComponent(name), number);
    }
    if (name !== '') {
      return fetchList('/search?q=' + encodeURIComponent(name), number);
    }
    return { items: [], hasMore: false };
  },

  detail(sourceId) {
    const slug = String(sourceId || '').trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{1,120}$/.test(slug)) {
      throw new Error('5L 视频 ID 无效');
    }
    const pageUrl = SITE + '/videos/' + slug;
    const html = fetchPage(pageUrl);
    const heading = html.match(/<h1[^>]*>([\s\S]{0,300}?)<\/h1>/);
    const title = truncate(heading ? clean(heading[1]) : slug, 512);
    const poster = html.match(/poster="([^"]+)"/);
    const cover = poster ? decodeHtml(poster[1]).replace(/^http:/, 'https:') : '';
    const durationMatch = html.match(/時長：\s*([\d:]{4,12})/);
    const releaseMatch = html.match(/發布：\s*(\d{4}-\d{2}-\d{2})/);
    const actors = actorsOf(html);
    const tags = tagsOf(html);
    const first = actors.length > 0 ? actors[0] : null;
    const drama = {
      id: host.dramaId(slug),
      source: host.source,
      sourceId: slug,
      title,
      name: title,
      desc: title,
      intro: title,
      cover,
      coverUrl: cover,
      channelName: '5L',
      categoryName: '视频',
      onlineDate: releaseDate(releaseMatch ? releaseMatch[1] : ''),
      duration: durationMatch ? durationMatch[1] : '',
      totalEpisode: 1,
      episodeCount: 1,
      tags,
      serial: codeOf(title),
    };
    if (actors.length > 0) {
      drama.actors = actors.map((entry) => entry.name);
      if (first) {
        drama.author = first.name;
        drama.authorId = first.id;
        drama.authorUrl = first.url;
      }
    }
    const chapter = {
      id: host.chapterId(slug, 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: '5l-play://' + slug,
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
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{1,120}$/.test(slug)) {
      throw new Error('5L 播放分集无效，请刷新详情');
    }
    const pageUrl = SITE + '/videos/' + slug;
    const html = fetchPage(pageUrl);
    const stamp = html.match(/var\s+t\s*=\s*(\d{6,})/);
    const nonce = html.match(/var\s+n\s*=\s*"([A-Za-z0-9]+)"/);
    const name = html.match(/var\s+slug\s*=\s*"([^"]+)"/);
    if (!stamp || !nonce) {
      throw new Error('5L 详情页没有播放参数，可能已改版');
    }
    const realSlug = name ? name[1] : slug;
    const apiUrl = SITE + '/api/play/' + encodeURIComponent(realSlug) + '?t=' + stamp[1] + '&n=' + encodeURIComponent(nonce[1]);
    let playlist = '';
    try {
      playlist = host.fetchText({ url: apiUrl, referer: pageUrl, userAgent: agent(), cookie: cookieHeader() }).body;
    } catch (error) {
      throw new Error('5L 获取播放清单失败：' + String((error && error.message) || error));
    }
    if (playlist.indexOf('#EXTM3U') < 0) {
      throw new Error('5L 播放清单无效');
    }
    const media = {
      url: apiUrl,
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
      return host.prepareWebMedia(media, '5L');
    } catch (error) {
      return media;
    }
  },
};
