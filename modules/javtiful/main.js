const BASE = 'https://javtiful.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
const REFERER = BASE + '/zh/main';
const VIDEO_RE = /\/zh\/video\/(\d+)\/([a-z0-9][a-z0-9-]*)/i;
const CATEGORY_RE = /\/zh\/category\/([^"'?#]+)/i;
const TICKET_RE = /"playback"\s*:\s*\{[\s\S]{0,400}?"endpoint"\s*:\s*"([^"]+)"[\s\S]{0,400}?"ticket"\s*:\s*"([^"]+)"/i;

function decode(text) {
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
  return decode(String(html || '').replace(/<[^>]*>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function attr(tag, name) {
  const match = String(tag || '').match(new RegExp(name + '\\s*=\\s*["\']([^"\']*)["\']', 'i'));
  return match ? decode(match[1]) : '';
}

function absolute(value) {
  value = decode(String(value || '').trim());
  if (value === '') return '';
  if (value.indexOf('//') === 0) return 'https:' + value;
  if (/^https?:\/\//i.test(value)) return value.replace(/^http:/i, 'https:');
  if (value[0] === '/') return BASE + value;
  return BASE + '/' + value.replace(/^\.\//, '');
}

function fetchText(url, referer) {
  return host.fetchText({
    url: absolute(url),
    referer: referer || REFERER,
    userAgent: UA
  }).body;
}

function pageUrl(page, category, query) {
  const suffix = page > 1 ? '&page=' + page : '';
  if (query) return BASE + '/zh/search?q=' + encodeURIComponent(query) + suffix;
  if (category) return BASE + '/zh/category/' + category + (page > 1 ? '?page=' + page : '');
  return BASE + '/zh/videos' + (page > 1 ? '?page=' + page : '');
}

function parseCards(html) {
  const items = [];
  const seen = {};
  const blocks = String(html || '').match(/<article[^>]*class="[^"]*video-card[^"]*"[\s\S]*?<\/article>/gi) || [];
  for (const block of blocks) {
    const link = (block.match(/href="(\/zh\/video\/[^"]+)"/i) || [])[1] || '';
    const video = link.match(VIDEO_RE);
    if (!video) continue;
    const sourceId = video[1] + '/' + video[2];
    if (seen[sourceId]) continue;
    seen[sourceId] = true;
    const titleAnchor = block.match(/<a[^>]*class="[^"]*video-card__title[^"]*"[^>]*>([\s\S]*?)<\/a>/i);
    const title = attr(block.match(/<a[^>]*class="[^"]*video-card__title[^"]*"[^>]*>/i)?.[0] || '', 'title') ||
      clean(titleAnchor ? titleAnchor[1] : '') ||
      clean(block);
    const image = block.match(/<img[^>]*>/i);
    const cover = image
      ? absolute(attr(image[0], 'data-front-lazy-src') || attr(image[0], 'data-src') || attr(image[0], 'src'))
      : '';
    const details = clean((block.match(/video-card__details[^>]*>([\s\S]*?)<\/span>/i) || [])[1]);
    const duration = (details.match(/\d{1,2}:\d{2}:\d{2}/) || [])[0] || '';
    items.push({
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title: title,
      name: title,
      cover,
      coverUrl: cover,
      duration,
      totalEpisode: 1,
      episodeCount: 1,
      categoryName: '视频'
    });
  }
  return items;
}

function hasNext(html, page) {
  if (/rel="next"/i.test(html) || /class="[^"]*pagination[^"]*"[\s\S]{0,2000}?page=/.test(html)) {
    return new RegExp('[?&]page=' + (page + 1) + '(?:[&#"]|$)').test(html);
  }
  return false;
}

function sourceIdOf(task) {
  let value = String(task && task.dramaId || '');
  const prefix = host.source + ':';
  if (value.indexOf(prefix) === 0) value = value.slice(prefix.length);
  if (!value && task && task.chapter) {
    const chapter = String(task.chapter.id || '');
    if (chapter.indexOf(prefix) === 0) value = chapter.slice(prefix.length).split(':')[0];
  }
  return value.trim();
}

function videoPage(sourceId) {
  const value = String(sourceId || '').replace(/^\/+/, '');
  return /^https?:/i.test(value)
    ? value
    : /^zh\//i.test(value)
      ? BASE + '/' + value
      : BASE + '/zh/video/' + value;
}

module.exports = {
  validCategory(category) {
    category = String(category || '').trim();
    return category === '' || (!category.includes('/') && !category.includes('\\') && category.length <= 128);
  },

  categories() {
    const html = fetchText(BASE + '/zh/categories');
    const result = [];
    const seen = {};
    for (const match of html.matchAll(/<a[^>]*class="[^"]*category-card[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const path = match[1].match(CATEGORY_RE);
      if (!path) continue;
      const id = path[1];
      if (seen[id]) continue;
      seen[id] = true;
      const caption = match[2].match(/category-card__name[^>]*>([\s\S]*?)<\/span>/i);
      const name = clean(caption ? caption[1] : match[2]);
      if (name) result.push({ id, name });
    }
    return result;
  },

  catalogPage(page, category) {
    if (page < 1 || page > 10000) throw new Error('Javtiful 页码无效');
    const html = fetchText(pageUrl(page, category, ''));
    const items = parseCards(html);
    if (items.length === 0 && page === 1) throw new Error('Javtiful 没有返回视频列表，请检查分类或站点状态');
    return { items, hasMore: hasNext(html, page) };
  },

  search(page, query) {
    query = String(query || '').trim();
    if (!query || query.length > 200) throw new Error('Javtiful 搜索关键词无效');
    if (page < 1 || page > 10000) throw new Error('Javtiful 页码无效');
    const html = fetchText(pageUrl(page, '', query));
    return { items: parseCards(html), hasMore: hasNext(html, page) };
  },

  detail(sourceId) {
    sourceId = String(sourceId || '').trim();
    if (!/^\d+\/[a-z0-9-]+$/i.test(sourceId)) throw new Error('Javtiful 视频 ID 无效');
    const url = videoPage(sourceId);
    const html = fetchText(url);
    const meta = (name) => {
      const match = html.match(new RegExp('<meta[^>]+(?:property|name)="' + name + '"[^>]+content="([^"]*)"', 'i'));
      return match ? decode(match[1]) : '';
    };
    const heading = (html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || [])[1];
    const title = clean(heading) || meta('og:title').replace(/\s*\|\s*Javtiful\s*$/i, '');
    if (!title) throw new Error('Javtiful 详情缺少标题');
    const cover = absolute(meta('og:image') || meta('twitter:image'));
    const intro = meta('og:description') || meta('description');
    const actors = [];
    for (const match of html.matchAll(/<a[^>]*href="\/zh\/actress\/([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const name = clean(match[2]);
      if (name && !actors.includes(name)) actors.push(name);
    }
    const channel = html.match(/<strong>频道<\/strong>[\s\S]{0,600}?<a[^>]*href="\/zh\/channel\/([^"]+)"[^>]*>([\s\S]*?)<\/a>/i);
    const publisher = channel ? clean(channel[2]) : '';
    const tags = [];
    for (const match of html.matchAll(/<a[^>]*href="\/zh\/search\?q=([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const name = clean(match[2]);
      if (name && !tags.includes(name)) tags.push(name);
    }
    const drama = {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
      name: title,
      desc: intro,
      intro,
      cover,
      coverUrl: cover,
      channelName: publisher || 'Javtiful',
      categoryName: '视频',
      totalEpisode: 1,
      episodeCount: 1,
      tags,
      actors,
      maker: publisher,
      author: publisher,
      authorId: channel ? channel[1] : '',
      authorUrl: channel ? BASE + '/zh/channel/' + channel[1] : ''
    };
    const chapter = {
      id: host.chapterId(sourceId, 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: 'javtiful-play://' + sourceId,
      pageUrl: url,
      referer: url
    };
    return { drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    const sourceId = sourceIdOf(task);
    if (!/^\d+\/[a-z0-9-]+$/i.test(sourceId)) throw new Error('Javtiful 播放分集无效，请刷新详情');
    const url = videoPage(sourceId);
    const html = fetchText(url);
    const config = html.match(TICKET_RE);
    if (!config) throw new Error('Javtiful 详情页没有播放 ticket，请重启应用后再试');
    const endpoint = config[1];
    const ticket = config[2];
    const response = host.fetch({
      method: 'POST',
      url: absolute(endpoint),
      referer: url,
      userAgent: UA,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
        'Accept': 'application/json, text/plain, */*',
        'Origin': BASE,
        'Referer': url
      },
      body: 'ticket=' + encodeURIComponent(ticket)
    });
    if (!response || response.status < 200 || response.status >= 300) {
      throw new Error('Javtiful 播放接口返回 HTTP ' + (response ? response.status : '?'));
    }
    let data;
    try {
      data = JSON.parse(response.body || '{}');
    } catch (error) {
      throw new Error('Javtiful 播放接口返回无效 JSON');
    }
    if (!data.success || !Array.isArray(data.sources) || data.sources.length === 0) {
      throw new Error('Javtiful 没有返回可播放线路');
    }
    const source = data.sources.find((item) => item && typeof item.src === 'string' && item.src.trim());
    if (!source) throw new Error('Javtiful 播放线路为空');
    const mediaUrl = absolute(source.src);
    return host.prepareWebMedia({
      url: mediaUrl,
      referer: url,
      quality: Number(source.size || 720),
      credentials: {
        referer: url,
        origin: BASE,
        userAgent: UA
      }
    }, 'Javtiful');
  }
};
