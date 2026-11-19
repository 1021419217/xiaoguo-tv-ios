const BASE = 'https://cn.xgroovy.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
const REFERER = BASE + '/';
const VIDEO_RE = /\/videos\/(\d+)\/([a-z0-9][a-z0-9-]*)\/?/i;
const CATEGORY_RE = /\/categories\/([a-z0-9][a-z0-9-]*)\/?/i;
const FALLBACK_CATEGORIES = [
  ['big-tits', '巨乳'], ['big-ass', '大屁股'], ['blowjob', '口交'],
  ['amateur', '业余'], ['teens', '青少年 (18+)'], ['big-cock', '大屌'],
  ['cumshot', '射精'], ['milf', '辣妈'], ['interracial', '跨种族'],
  ['pov', 'POV (第一视角)'], ['small-tits', '贫乳'], ['anal', '爆菊'],
  ['latina', '拉丁裔美女'], ['family', '继家庭幻想'], ['threesome', '3P 三人行'],
  ['bbc', 'BBC (大黑屌)'], ['ebony', '黑人'], ['public', '公共场合'],
  ['asian', '亚洲人'], ['bbw', 'BBW (大号美女)'], ['petite', '娇小'],
  ['cheating', '出轨'], ['cuckold', '绿帽侠'], ['creampie', '体内射精']
];

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
  if (query) return BASE + '/search/' + encodeURIComponent(query) + '/' + (page > 1 ? page + '/' : '');
  if (category) return BASE + '/tags/' + category + '/' + (page > 1 ? page + '/' : '');
  return BASE + '/new/' + (page > 1 ? page + '/' : '');
}

function parseCards(html) {
  const items = [];
  const seen = {};
  const blocks = String(html || '').split(/<div[^>]*class="[^"]*\bitem\b[^"]*"/i).slice(1);
  for (const block of blocks) {
    const href = (block.match(/<a[^>]+href="([^"]*\/videos\/[^"]+)"/i) || [])[1] || '';
    const video = href.match(VIDEO_RE);
    if (!video) continue;
    const sourceId = video[1] + '/' + video[2];
    if (seen[sourceId]) continue;
    seen[sourceId] = true;
    const image = block.match(/<img[^>]*>/i);
    const cover = image
      ? absolute(attr(image[0], 'data-jpg') || attr(image[0], 'src'))
      : '';
    const titleMatch = block.match(/<strong[^>]*class="[^"]*title[^"]*"[^>]*>([\s\S]*?)<\/strong>/i);
    const title = clean(titleMatch ? titleMatch[1] : attr(image ? image[0] : '', 'alt'));
    const duration = clean((block.match(/<div[^>]*class="[^"]*duration[^"]*"[^>]*>([\s\S]*?)<\/div>/i) || [])[1]);
    items.push({
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
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
  return /class="next"/i.test(html) ||
    new RegExp('[?&]page=' + (page + 1) + '(?:[&#"]|$)', 'i').test(html);
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
  return BASE + '/videos/' + String(sourceId || '').replace(/^\/+/, '') + '/';
}

module.exports = {
  validCategory(category) {
    category = String(category || '').trim();
    return category === '' || (!category.includes('/') && !category.includes('\\') && category.length <= 128);
  },

  categories() {
    let html = '';
    try {
      html = fetchText(BASE + '/categories/');
    } catch (error) {
      return FALLBACK_CATEGORIES.map(([id, name]) => ({ id, name }));
    }
    const result = [];
    const seen = {};
    for (const match of html.matchAll(/<a[^>]+href="([^"]*\/categories\/([a-z0-9][a-z0-9-]*)\/)"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const id = match[2];
      if (seen[id]) continue;
      const name = clean(match[3]);
      if (!name) continue;
      seen[id] = true;
      result.push({ id, name });
    }
    if (result.length < 2) {
      return FALLBACK_CATEGORIES.map(([id, name]) => ({ id, name }));
    }
    return result;
  },

  catalogPage(page, category) {
    if (page < 1 || page > 100000) throw new Error('XGroovy 页码无效');
    const html = fetchText(pageUrl(page, category, ''));
    const items = parseCards(html);
    if (items.length === 0 && page === 1) throw new Error('XGroovy 没有返回视频列表');
    return { items, hasMore: hasNext(html, page) };
  },

  search(page, query) {
    query = String(query || '').trim();
    if (!query || query.length > 200) throw new Error('XGroovy 搜索关键词无效');
    if (page < 1 || page > 100000) throw new Error('XGroovy 页码无效');
    const html = fetchText(pageUrl(page, '', query));
    return { items: parseCards(html), hasMore: hasNext(html, page) };
  },

  detail(sourceId) {
    sourceId = String(sourceId || '').trim();
    if (!/^\d+\/[a-z0-9-]+$/i.test(sourceId)) throw new Error('XGroovy 视频 ID 无效');
    const url = videoPage(sourceId);
    const html = fetchText(url);
    const meta = (name) => {
      const match = html.match(new RegExp('<meta[^>]+(?:property|name)="' + name + '"[^>]+content="([^"]*)"', 'i'));
      return match ? decode(match[1]) : '';
    };
    const heading = (html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || [])[1];
    const title = clean(heading) || meta('og:title');
    if (!title) throw new Error('XGroovy 详情缺少标题');
    const cover = absolute(meta('og:image'));
    const intro = meta('og:description') || meta('description');
    const relatedIndex = html.search(/<div[^>]*class="[^"]*related-videos/i);
    const detail = relatedIndex > 0 ? html.slice(0, relatedIndex) : html;
    const channel = detail.match(/href="https?:\/\/[^"]*\/channels\/([a-z0-9][a-z0-9-]*)\/"[^>]*>([\s\S]*?)<\/a>/i);
    const actors = [];
    const actorLinks = [];
    for (const match of detail.matchAll(/href="https?:\/\/[^"]*\/pornstars\/([a-z0-9][a-z0-9-]*)\/"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const name = clean(match[2]).replace(/\s+\d+$/, '');
      if (name && !actors.includes(name)) {
        actors.push(name);
        actorLinks.push({ name, id: match[1] });
      }
    }
    const tags = [];
    for (const match of detail.matchAll(/href="https?:\/\/[^"]*\/tags\/([a-z0-9][a-z0-9-]*)\/"[^>]*>([\s\S]*?)<\/a>/gi)) {
      const name = clean(match[2]);
      if (name && !tags.includes(name)) tags.push(name);
    }
    const publisher = channel ? clean(channel[2]) : '';
    const firstActor = actorLinks[0];
    const author = publisher || (firstActor ? firstActor.name : '');
    const authorId = channel ? channel[1] : (firstActor ? firstActor.id : '');
    const authorUrl = channel
      ? BASE + '/channels/' + channel[1] + '/'
      : firstActor
        ? BASE + '/pornstars/' + firstActor.id + '/'
        : '';
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
      channelName: publisher || author || 'XGroovy',
      categoryName: '视频',
      totalEpisode: 1,
      episodeCount: 1,
      tags,
      actors,
      maker: publisher,
      author,
      authorId,
      authorUrl
    };
    const chapter = {
      id: host.chapterId(sourceId, 'main'),
      source: host.source,
      title: '正片',
      currentEpisode: 1,
      videoUrl: 'xgroovy-play://' + sourceId,
      pageUrl: url,
      referer: url
    };
    return { drama, chapters: [chapter] };
  },

  resolveMedia(task) {
    const sourceId = sourceIdOf(task);
    if (!/^\d+\/[a-z0-9-]+$/i.test(sourceId)) throw new Error('XGroovy 播放分集无效，请刷新详情');
    const url = videoPage(sourceId);
    const html = fetchText(url);
    const sources = [];
    for (const match of html.matchAll(/<source[^>]*>/gi)) {
      const tag = match[0];
      const src = absolute(attr(tag, 'src'));
      if (!src) continue;
      const quality = Number((attr(tag, 'title').match(/\d+/) || [0])[0]) || 0;
      const hd = attr(tag, 'data-fluid-hd') !== '';
      sources.push({ src, quality, hd });
    }
    sources.sort((left, right) => (right.quality || 0) - (left.quality || 0));
    if (sources.length === 0) throw new Error('XGroovy 详情页没有播放地址');
    const main = sources[0];
    const media = host.prepareWebMedia({
      url: main.src,
      referer: url,
      quality: main.quality || 720,
      credentials: {
        referer: url,
        origin: BASE,
        userAgent: UA
      }
    }, 'XGroovy');
    if (sources.length > 1) {
      media.variants = sources.slice(1).map((source) => ({
        url: source.src,
        referer: url,
        quality: source.quality,
        credentials: {
          referer: url,
          origin: BASE,
          userAgent: UA
        }
      }));
    }
    return media;
  }
};
