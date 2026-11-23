// 91吃瓜（www.91cg1.com）：WordPress + Mirages 模板的吃瓜短视频站，和今日看料同一套主题。
// 列表、分类、上传者、搜索都是服务端渲染的 <article> 卡片，分页分别是
// /page/{n}/、/category/{id}/{n}/、/author/{id}/{n}/、/search/{关键词}/{n}/；
// 上传者页与搜索页不带 Referer 会被站点回 502，所有请求都带站内 Referer。
// 详情页视频写在 .dplayer 的 data-config JSON 里，一个帖子可以有多个视频，按顺序当分集。
// 播放地址是带 auth_key 签名的 HLS（AES-128，分片在另一个域名），签名会过期，
// 所以每次播放都重新抓详情页取新地址，抓不到才退回详情里存的那条。

const SITE = 'https://www.91cg1.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const CHANNEL = '91吃瓜';
const PAGE_LIMIT = 300;
const CARD_LIMIT = 40;

const CATEGORIES = [
  { id: 'latest', name: '最新' },
  { id: 'zxcghl', name: '今日吃瓜' },
  { id: 'dydj', name: 'AI短剧' },
  { id: 'stjx', name: 'ST精选' },
  { id: 'mrds', name: '每日大赛' },
  { id: 'rsdg', name: '最高点击' },
  { id: 'lpsd', name: '深夜撸片' },
  { id: 'hjll', name: '海角乱伦' },
  { id: '91th', name: '91探花' },
  { id: 'crdm', name: '成人动漫' },
  { id: 'zdtop', name: '91周榜' },
  { id: 'ydtop', name: '91月榜' },
  { id: 'bcdg', name: '必吃大瓜' },
  { id: 'whhl', name: '网红黑料' },
  { id: 'mxhl', name: '明星黑料' },
  { id: 'qwys', name: '社会奇闻' },
  { id: 'xyjj', name: '校园禁忌' },
  { id: 'fclv', name: '反差靓女' },
  { id: 'tgqg', name: '投稿求瓜' },
  { id: 'gcwh', name: '网黄合集' },
  { id: 'aikj', name: '明星AI' },
  { id: 'sports-live', name: '体育直播' },
  { id: 'zptp', name: '自拍偷拍' },
  { id: 'lqzk', name: '猎奇重口' },
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
  return '';
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
  const text = String(body || '');
  return text.length < 20000 && text.indexOf('location.replace(u.href)') >= 0;
}

function fetchPage(path, options) {
  const settings = options || {};
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetchText({
      url,
      referer: settings.referer || SITE + '/',
      userAgent: UA,
      noCache: settings.noCache === true,
    });
  } catch (error) {
    const message = String((error && error.message) || error);
    if (/403|429|502|503|拦截|封禁/i.test(message)) {
      throw new Error('91吃瓜被站点拦截（' + message + '），请稍后重试');
    }
    throw new Error('91吃瓜连接失败：' + message);
  }
  const body = (response && response.body) || '';
  if (isGatewayPage(body)) throw new Error('91吃瓜该内容被站点设为跳转页，无法直接播放');
  return body;
}

function articleHtml(html) {
  const matched = String(html || '').match(/<article\b[\s\S]*<\/article>/);
  return matched ? matched[0] : String(html || '');
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

function cardCover(block) {
  const banner = block.match(/loadBannerDirect\(\s*'([^']+)'/);
  if (banner) {
    const url = absolute(decodeHtml(banner[1]));
    if (url !== '' && (url.indexOf('biacea.cn/') > 0 || url.indexOf('/upload_') > 0)) return url;
  }
  const image = block.match(/<img[^>]+src="([^"]+)"/);
  if (image) {
    const url = absolute(decodeHtml(image[1]));
    if (url !== '' && url.indexOf('/upload_') > 0) return url;
  }
  return '';
}

function cardDate(block) {
  const meta = block.match(/itemprop="datePublished"[^>]*content="([^"]+)"/);
  return releaseDate(meta ? decodeHtml(meta[1]) : '');
}

function cardAuthor(block) {
  const matched = block.match(/<a[^>]+href="[^"]*\/author\/(\d+)\/?"[^>]*>([\s\S]*?)<\/a>/);
  if (matched) return { id: matched[1], name: truncate(clean(matched[2]), 64) };
  const meta = block.match(/<meta itemprop="name" content="([^"]*)"/);
  const id = block.match(/\/author\/(\d+)\//);
  return {
    id: id ? id[1] : '',
    name: meta ? truncate(decodeHtml(meta[1]), 64) : '',
  };
}

function cardCategory(block) {
  const info = block.match(/<div class="post-card-info">([\s\S]*?)<\/div>/);
  if (!info) return '';
  const pattern = /<span([^>]*)>([\s\S]*?)<\/span>/g;
  let match = null;
  while ((match = pattern.exec(info[1])) !== null) {
    if (match[1].indexOf('itemprop') >= 0) continue;
    const text = clean(match[2]).replace(/[•·]\s*$/, '');
    if (text !== '') return truncate(text, 64);
  }
  return '';
}

function hasNextPage(html) {
  const nav = String(html || '').match(/<[uo]l[^>]*class="[^"]*page-navigator[^"]*"[^>]*>([\s\S]*?)<\/[uo]l>/);
  if (!nav) return false;
  return /class="[^"]*\bnext\b[^"]*"/.test(nav[1]);
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
    const title = cardTitle(block);
    if (title === '') continue;
    const owner = cardAuthor(block);
    const cover = cardCover(block);
    const item = {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId,
      title,
      name: title,
      cover,
      coverUrl: cover,
      author: owner.name || settings.authorName || '',
      authorId: owner.id || settings.authorId || '',
      onlineDate: cardDate(block),
      categoryName: cardCategory(block) || settings.categoryName || '视频',
      channelName: CHANNEL,
      totalEpisode: 1,
      episodeCount: 1,
    };
    if (item.authorId !== '') item.authorUrl = SITE + '/author/' + item.authorId + '/';
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
    const video = payload && payload.video ? payload.video : {};
    const address = trim(video.url);
    if (!/^https?:\/\//i.test(address) || seen[address]) continue;
    seen[address] = true;
    urls.push(address);
  }
  return urls;
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

const BOILERPLATE = /最新地址|永久地址|永久主页|网站无法访问|快速看懂|复制上面|浏览器|邮箱|发邮件/;

function parseIntro(html) {
  const text = String(html || '');
  const start = text.indexOf('<div class="post-content"');
  if (start < 0) return '';
  const player = text.indexOf('class="dplayer"', start);
  const scope = player > start ? text.slice(start, player) : text.slice(start, start + 40000);
  const paragraphs = [];
  const pattern = /<p[^>]*>([\s\S]*?)<\/p>/g;
  let match = null;
  while ((match = pattern.exec(scope)) !== null) {
    const line = clean(match[1]);
    if (line.length < 30 || BOILERPLATE.test(line)) continue;
    paragraphs.push(line);
    if (paragraphs.length >= 3) break;
  }
  return truncate(paragraphs.join(' '), 600);
}

function categories() {
  return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
}

function catalogPage(page, category) {
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  const id = trim(category);
  if (!validCategory(id)) throw new Error('91吃瓜分类无效');
  const key = id === '' ? 'latest' : id;
  if (key === 'latest') {
    return listPage(current > 1 ? '/page/' + current + '/' : '/', { categoryName: '最新' });
  }
  const path = '/category/' + key + '/' + (current > 1 ? current + '/' : '');
  return listPage(path, { categoryName: categoryName(key) });
}

function search(page, query) {
  const keyword = trim(query);
  if (keyword === '' || keyword.length > 100) return { items: [], hasMore: false };
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  return listPage('/search/' + encodeURIComponent(keyword) + '/' + current + '/', { categoryName: '搜索' });
}

function author(authorId, authorName, page) {
  const id = trim(authorId);
  if (!/^\d{1,9}$/.test(id)) return { items: [], hasMore: false };
  if (beyondLastPage(page)) return { items: [], hasMore: false };
  const current = pageNumber(page);
  const path = current > 1 ? '/author/' + id + '/' + current + '/' : '/author/' + id + '/';
  return listPage(path, {
    authorId: id,
    authorName: truncate(trim(authorName), 64) || CHANNEL,
    categoryName: '作品',
  });
}

function parsePost(html, id) {
  const article = articleHtml(html);
  const heading = article.match(/<h1[^>]*class="[^"]*post-title[^"]*"[^>]*>([\s\S]*?)<\/h1>/) || article.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  const title = heading ? truncate(clean(heading[1]), 512) : '';
  if (title === '') throw new Error('91吃瓜详情缺少标题，站点可能已改版');

  let cover = '';
  const image = html.match(/<meta itemprop="image" content="([^"]+)"/);
  if (image) cover = absolute(decodeHtml(image[1]));
  if (cover === '') {
    const poster = article.match(/"pic"\s*:\s*"([^"]+)"/);
    if (poster) cover = absolute(decodeHtml(poster[1]).replace(/\\\//g, '/'));
  }

  const meta = html.match(/<ul class="post-meta">([\s\S]*?)<\/ul>/);
  const metaHtml = meta ? meta[1] : '';
  const owner = metaHtml.match(/<a[^>]+href="[^"]*\/author\/(\d+)\/?"[^>]*>([\s\S]*?)<\/a>/);
  const authorId = owner ? owner[1] : '';
  const authorName = owner ? truncate(clean(owner[2]), 64) : '';
  const authorUrl = authorId === '' ? '' : SITE + '/author/' + authorId + '/';

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
  const intro = parseIntro(html);
  const urls = videoUrls(article);
  if (urls.length === 0) throw new Error('91吃瓜该内容没有可播放视频');

  const pageUrl = SITE + '/archives/' + id + '/';
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

  const description = intro || truncate([names.join(' · '), tags.join(' ')].filter(Boolean).join('｜'), 512) || title;
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

function detail(sourceId) {
  const id = trim(sourceId);
  if (!/^\d{1,9}$/.test(id)) throw new Error('91吃瓜内容 ID 无效');
  return parsePost(fetchPage('/archives/' + id + '/'), id);
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

function freshVideoUrl(sourceId, index) {
  const html = fetchPage('/archives/' + sourceId + '/', { noCache: true });
  const urls = videoUrls(articleHtml(html));
  if (urls.length === 0) return '';
  return urls[index > 0 ? index - 1 : 0] || urls[0];
}

function resolveMedia(task) {
  const chapter = (task && task.chapter) || {};
  const referer = trim(chapter.referer) || SITE + '/';
  const sourceId = sourceIdOf(task && task.dramaId);
  const index = chapterIndexOf(chapter.id);

  let address = '';
  if (sourceId !== '') {
    try {
      address = freshVideoUrl(sourceId, index);
    } catch (error) {
      address = '';
    }
  }
  if (address === '') {
    const stored = trim(chapter.videoUrl);
    address = /^https?:\/\//i.test(stored) ? stored : '';
  }
  if (address === '') throw new Error('91吃瓜该视频没有可用地址，请刷新详情');

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
