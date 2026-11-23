// 今日看料（www.kanliao20.net）：WordPress + Mirages 模板的吃瓜短视频站。
// 列表、分类、搜索、上传者页都是服务端渲染的 <article> 卡片，分页分别是
// /page/{n}/、/category/{id}/{n}/、/search/{关键词}/{n}/、/author/{id}/{n}/。
// 详情页把视频写在 .dplayer 的 data-config JSON 里，一个帖子可以有多个视频，按出现顺序当分集；
// 视频是普通 HLS（.ts 分片、无加密、不需要 referer）。
// 站点把 15 条置顶帖钉在每个列表页顶部，其中多数只回一页跳转外部广告的壳页、标题为空，
// 剩下的是无视频的教程帖，所以整类跳过，不进列表。

const SITE = 'https://www.kanliao20.net';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const CHANNEL = '今日看料';
const PAGE_LIMIT = 500;
const CARD_LIMIT = 40;

const CATEGORIES = [
  { id: 'latest', name: '最新' },
  { id: 'rdgz', name: '热点关注' },
  { id: 'dy', name: '抖音' },
  { id: 'ks', name: '快手' },
  { id: 'douyu', name: '斗鱼' },
  { id: 'hy', name: '虎牙' },
  { id: 'hj', name: '花椒' },
  { id: 'tt', name: '推特' },
  { id: 'wh', name: '网红' },
  { id: 'xb', name: 'X播' },
  { id: 'xsp', name: '小视频' },
  { id: 'asmr', name: 'ASMR' },
];

function trim(value) {
  return String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
}

function decodeHtml(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  return String(text == null ? '' : text).replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (entity, body) => {
    if (body.charAt(0) === '#') {
      const code = body.charAt(1) === 'x' || body.charAt(1) === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    }
    return Object.prototype.hasOwnProperty.call(named, body) ? named[body] : entity;
  });
}

function clean(html) {
  return trim(decodeHtml(String(html || '').replace(/<[^>]*>/g, ' ')));
}

function truncate(text, limit) {
  const value = trim(text);
  const characters = Array.from(value);
  return characters.length <= limit ? value : characters.slice(0, limit).join('') + '...';
}

function releaseDate(value) {
  const match = String(value || '').match(/(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (!match) return '';
  const year = parseInt(match[1], 10);
  const month = parseInt(match[2], 10);
  const day = parseInt(match[3], 10);
  if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) return '';
  const pad = (number) => (number < 10 ? '0' + number : String(number));
  return year + '-' + pad(month) + '-' + pad(day);
}

function absolute(address) {
  const value = trim(address);
  if (value === '') return '';
  if (value.indexOf('//') === 0) return 'https:' + value;
  if (value.indexOf('/') === 0) return SITE + value;
  if (/^https?:\/\//i.test(value)) return value;
  return SITE + '/' + value;
}

function categoryName(id) {
  for (let i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i].name;
  }
  return '';
}

function validCategory(category) {
  const value = trim(category);
  if (value === '') return true;
  return categoryName(value) !== '';
}

function isGatewayPage(body) {
  return String(body || '').length < 20000 && String(body || '').indexOf('location.replace(u.href)') >= 0;
}

function fetchPage(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetchText({ url, referer: SITE + '/', userAgent: UA });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|503|拦截|封禁/i.test(message)) {
      throw new Error('今日看料被站点拦截（' + message + '），请稍后重试');
    }
    throw new Error('今日看料连接失败：' + message);
  }
  const body = (response && response.body) || '';
  if (isGatewayPage(body)) throw new Error('今日看料该内容被站点设为跳转页，无法直接播放');
  return body;
}

function cardBlocks(html) {
  const blocks = [];
  const pattern = /<article\b[\s\S]*?<\/article>/g;
  let match = null;
  while ((match = pattern.exec(String(html || ''))) !== null) {
    blocks.push(match[0]);
  }
  return blocks;
}

function cardTitle(block) {
  const heading = block.match(/<h2[^>]*class="[^"]*post-card-title[^"]*"[^>]*>([\s\S]*?)<\/h2>/);
  if (!heading) return '';
  const body = heading[1].replace(/<div class="wrap">[\s\S]*?<\/div>/g, '');
  return truncate(clean(body), 512);
}

function uploadsUrl(raw) {
  const value = trim(decodeHtml(raw));
  if (value === '') return '';
  const address = value.indexOf('//') === 0 ? 'https:' + value : value;
  if (/^(https?:\/\/)?(www\.)?kanliao20\.net\/usr\/uploads\//i.test(address)) return absolute(address);
  if (address.indexOf('/usr/uploads/') === 0) return SITE + address;
  return '';
}

function cardCover(block) {
  const banner = block.match(/loadBannerDirect\(\s*'([^']+)'/);
  if (banner) {
    const url = uploadsUrl(banner[1]);
    if (url !== '') return url;
  }
  const image = block.match(/<img[^>]+src="([^"]+)"/);
  if (image) return uploadsUrl(image[1]);
  return '';
}

function cardDate(block) {
  const meta = block.match(/itemprop="datePublished"[^>]*content="([^"]+)"/);
  return releaseDate(meta ? decodeHtml(meta[1]) : '');
}

function cardAuthor(block) {
  const span = block.match(/<span[^>]*itemprop="author"[^>]*>([\s\S]*?)<\/span>/);
  if (!span) return '';
  return truncate(clean(span[1]).replace(/[•·]\s*$/, ''), 64);
}

function cardCategory(block) {
  const info = block.match(/<div class="post-card-info">([\s\S]*?)<\/div>/);
  if (!info) return '';
  const pattern = /<span([^>]*)>([\s\S]*?)<\/span>/g;
  let match = null;
  while ((match = pattern.exec(info[1])) !== null) {
    if (match[1].indexOf('itemprop') >= 0) continue;
    const text = clean(match[2]).replace(/[•·]\s*$/, '');
    if (text !== '') return truncate(text, 32);
  }
  return '';
}

function hasNextPage(html) {
  const nav = String(html || '').match(/<ol class="page-navigator">([\s\S]*?)<\/ol>/);
  if (!nav) return false;
  if (/class="[^"]*\bnext\b[^"]*"/.test(nav[1])) return true;
  return /(下一页|Next)/.test(nav[1]);
}

function parseCards(html, options) {
  const settings = options || {};
  const items = [];
  const seen = {};
  const blocks = cardBlocks(html);
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    const link = block.match(/href="([^"]*\/archives\/(\d+)\/?)"/);
    if (!link) continue;
    const sourceId = link[2];
    if (seen[sourceId]) continue;
    const sticky = block.indexOf('class="wraps"') >= 0;
    if (sticky && !settings.includeSticky) continue;
    const title = cardTitle(block);
    if (title === '') continue;
    const cover = cardCover(block);
    const item = {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
      name: title,
      cover,
      coverUrl: cover,
      author: cardAuthor(block) || settings.authorName || '',
      onlineDate: cardDate(block),
      categoryName: cardCategory(block) || settings.categoryName || '视频',
      channelName: CHANNEL,
      totalEpisode: 1,
      episodeCount: 1,
    };
    if (settings.authorId) {
      item.authorId = settings.authorId;
      item.authorUrl = settings.authorUrl || SITE + '/author/' + settings.authorId + '/';
      if (settings.authorName) item.author = settings.authorName;
    }
    seen[sourceId] = true;
    items.push(item);
    if (items.length >= CARD_LIMIT) break;
  }
  return items;
}

function listPage(path, options) {
  const html = fetchPage(path);
  const items = parseCards(html, options);
  return { items, hasMore: items.length > 0 && hasNextPage(html) };
}

function pageNumber(page) {
  return Math.max(1, Math.min(PAGE_LIMIT, Number(page) || 1));
}

function beyondLastPage(page) {
  return Number(page) > PAGE_LIMIT;
}

function videoUrls(html) {
  const urls = [];
  const seen = {};
  const pattern = /data-config=(["'])([\s\S]*?)\1/g;
  let match = null;
  while ((match = pattern.exec(String(html || ''))) !== null) {
    let raw = match[2];
    if (raw.indexOf('&quot;') >= 0) raw = decodeHtml(raw);
    let payload = null;
    try {
      payload = JSON.parse(raw);
    } catch (error) {
      continue;
    }
    const address = payload && payload.video && payload.video.url ? trim(payload.video.url) : '';
    if (!/^https?:\/\//i.test(address) || seen[address]) continue;
    seen[address] = true;
    urls.push(address);
  }
  return urls;
}

function articleHtml(html) {
  const matched = String(html || '').match(/<article\b[\s\S]*<\/article>/);
  return matched ? matched[0] : String(html || '');
}

function parseTags(html) {
  const tags = [];
  const pattern = /<a[^>]+href="[^"]*\/tag\/([^"\/?#]+)\/?"[^>]*>([\s\S]*?)<\/a>/g;
  let match = null;
  while ((match = pattern.exec(String(html || ''))) !== null) {
    let name = clean(match[2]);
    if (name === '') {
      try {
        name = decodeURIComponent(match[1]);
      } catch (error) {
        name = '';
      }
    }
    name = truncate(name, 48);
    if (name !== '' && tags.indexOf(name) < 0) tags.push(name);
    if (tags.length >= 24) break;
  }
  return tags;
}

function categories() {
  return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
}

function catalogPage(page, category) {
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  const id = trim(category);
  if (!validCategory(id)) throw new Error('今日看料分类无效');
  const key = id === '' ? 'latest' : id;
  if (key === 'latest') {
    const path = current > 1 ? '/page/' + current + '/' : '/';
    return listPage(path, { includeSticky: false, categoryName: '最新' });
  }
  const path = '/category/' + key + '/' + (current > 1 ? current + '/' : '');
  return listPage(path, { includeSticky: false, categoryName: categoryName(key) });
}

function search(page, query) {
  const keyword = trim(query);
  if (keyword === '' || keyword.length > 100) return { items: [], hasMore: false };
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  return listPage('/search/' + encodeURIComponent(keyword) + '/' + current + '/', {
    includeSticky: false,
    categoryName: '搜索',
  });
}

function author(authorId, authorName, page) {
  const id = trim(authorId);
  if (!/^\d{1,9}$/.test(id)) return { items: [], hasMore: false };
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  const name = truncate(trim(authorName), 64) || CHANNEL;
  const path = current > 1 ? '/author/' + id + '/' + current + '/' : '/author/' + id + '/';
  return listPage(path, {
    includeSticky: false,
    authorId: id,
    authorName: name,
    authorUrl: SITE + '/author/' + id + '/',
    categoryName: '作品',
  });
}

function detail(sourceId) {
  const id = trim(sourceId);
  if (!/^\d{1,9}$/.test(id)) throw new Error('今日看料内容 ID 无效');
  const pageUrl = SITE + '/archives/' + id + '/';
  const html = fetchPage(pageUrl);
  const article = articleHtml(html);
  const heading = article.match(/<h1[^>]*class="[^"]*post-title[^"]*"[^>]*>([\s\S]*?)<\/h1>/) || article.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  const title = heading ? truncate(clean(heading[1]), 512) : '';
  if (title === '') throw new Error('今日看料详情缺少标题，站点可能已改版');

  let cover = '';
  const image = html.match(/<meta itemprop="image" content="([^"]+)"/);
  if (image) cover = absolute(decodeHtml(image[1]));
  if (cover === '') {
    const inline = html.match(/<div class="post-content"[^>]*>[\s\S]*?<img[^>]+src="([^"]+)"/);
    if (inline) cover = absolute(decodeHtml(inline[1]));
  }

  const meta = html.match(/<ul class="post-meta">([\s\S]*?)<\/ul>/);
  const metaHtml = meta ? meta[1] : '';
  const authorMatch = metaHtml.match(/<a[^>]+href="([^"]*\/author\/(\d+)\/?)"[^>]*>([\s\S]*?)<\/a>/);
  const authorId = authorMatch ? authorMatch[2] : '';
  const authorName = authorMatch ? truncate(clean(authorMatch[3]), 64) : '';
  const authorUrl = authorMatch ? absolute(authorMatch[1]) : (authorId === '' ? '' : SITE + '/author/' + authorId + '/');

  const names = [];
  const categoryPattern = /<a[^>]+href="[^"]*\/category\/([^"\/?#]+)\/?"[^>]*>([\s\S]*?)<\/a>/g;
  let categoryMatch = null;
  while ((categoryMatch = categoryPattern.exec(metaHtml)) !== null) {
    const name = truncate(clean(categoryMatch[2]), 32);
    if (name !== '' && names.indexOf(name) < 0) names.push(name);
  }

  const tags = parseTags(article);
  for (let i = 1; i < names.length; i++) {
    if (tags.indexOf(names[i]) < 0) tags.push(names[i]);
  }

  const date = html.match(/<meta itemprop="datePublished" content="([^"]+)"/);
  const onlineDate = releaseDate(date ? decodeHtml(date[1]) : '');

  const urls = videoUrls(article);
  if (urls.length === 0) throw new Error('今日看料该内容没有可播放视频');
  const chapters = [];
  for (let i = 0; i < urls.length; i++) {
    chapters.push({
      id: host.chapterId(id, 'v' + (i + 1)),
      source: host.source,
      title: urls.length > 1 ? '视频 ' + (i + 1) : '正片',
      currentEpisode: i + 1,
      videoUrl: urls[i],
      pageUrl,
      referer: SITE + '/',
    });
  }

  const description = truncate([names.join(' · '), tags.join(' ')].filter(Boolean).join('｜'), 512) || title;
  const drama = {
    id: host.dramaId(id),
    source: host.source,
    sourceId: id,
    title,
    name: title,
    desc: description,
    intro: description,
    cover,
    coverUrl: cover,
    author: authorName || CHANNEL,
    authorId,
    authorUrl,
    onlineDate,
    tags,
    categoryName: names[0] || '视频',
    channelName: CHANNEL,
    totalEpisode: chapters.length,
    episodeCount: chapters.length,
  };
  return { drama, chapters };
}

function sourceIdOf(dramaId) {
  const value = trim(dramaId);
  const at = value.indexOf(':');
  const id = at >= 0 ? value.slice(at + 1) : value;
  return /^\d{1,9}$/.test(id) ? id : '';
}

function chapterIndexOf(chapterId) {
  const matched = String(chapterId || '').match(/:v(\d{1,4})$/);
  if (!matched) return 0;
  const value = Number(matched[1]);
  return value > 0 && value <= 9999 ? value : 0;
}

function resolveMedia(task) {
  const chapter = (task && task.chapter) || {};
  const referer = trim(chapter.referer) || SITE + '/';
  let address = trim(chapter.videoUrl);
  if (!/^https?:\/\//i.test(address)) address = '';
  if (address === '') {
    const id = sourceIdOf(task && task.dramaId);
    const index = chapterIndexOf(chapter.id);
    if (id !== '') {
      let parsed = null;
      try {
        parsed = detail(id);
      } catch (error) {
        parsed = null;
      }
      if (parsed && parsed.chapters.length > 0) {
        const target = parsed.chapters[index > 0 ? index - 1 : 0] || parsed.chapters[0];
        address = trim(target.videoUrl);
      }
    }
  }
  if (!/^https?:\/\//i.test(address)) throw new Error('今日看料该视频没有可用地址，请刷新详情');
  const credentials = { referer, origin: SITE, userAgent: UA };
  const media = { url: address, referer, credentials };
  try {
    return host.prepareWebMedia(media, CHANNEL);
  } catch (error) {
    return media;
  }
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  author,
  detail,
  resolveMedia,
};
