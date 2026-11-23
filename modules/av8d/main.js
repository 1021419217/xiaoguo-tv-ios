// AV8D —— 服务端渲染的 HTML 站，列表用 class="video-img-box" 卡片，
// 详情页带 schema.org VideoObject 的 JSON-LD，其中 contentUrl 就是可直接播放的 m3u8。
// 分片托管在 tiktokcdn 上，扩展名伪装成 .image 且带 PNG 头，由本地代理剥离。

const SITE = 'https://av8d.vip';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const PAGE_TTL = 10 * 60 * 1000;

const CATEGORIES = [
  { id: 'latest', name: '最新', path: '/' },
  { id: 'censored', name: '有碼', path: '/lists/censored' },
  { id: 'uncensored', name: '無碼', path: '/lists/uncensored' },
  { id: 'amateur', name: '素人', path: '/lists/amateur' },
  { id: 'fc2', name: 'FC2', path: '/lists/fc2' },
];

function clean(value) {
  return String(value == null ? '' : value)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function get(path, referer) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  let response = null;
  try {
    response = host.fetch({
      method: 'GET',
      url: url,
      headers: {
        'User-Agent': UA,
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        Referer: referer || SITE + '/',
      },
      anyStatus: true,
      followRedirects: true,
      timeoutMs: 20000,
    });
  } catch (error) {
    throw new Error('AV8D 连接失败：' + String((error && error.message) || error));
  }
  const status = response.status || 0;
  if (status < 200 || status >= 300) {
    throw new Error('AV8D 返回 HTTP ' + status + '（' + path + '）');
  }
  return { text: response.body || '', url: response.url || url };
}

function listPath(category, page) {
  const entry =
    CATEGORIES.filter(function (item) {
      return item.id === category;
    })[0] || CATEGORIES[0];
  if (!page || page <= 1) return entry.path;
  return entry.path + '?page=' + page;
}

// 页面里出现 page={下一頁} 的链接才算还有更多。站点只在分类页输出分页控件，
// 首页没有任何 page= 链接，靠这个能准确判断到底。
function hasNextPage(html, page) {
  return new RegExp('page=' + (Number(page || 1) + 1) + '(?=[^0-9]|$)').test(
    String(html || ''),
  );
}

function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = String(html || '').split('<div class="video-img-box');
  for (let index = 1; index < parts.length; index++) {
    const seg = parts[index].slice(0, 2600);
    const link = /href="https?:\/\/[^"\/]*\/videos\/([^"?#]+)"/.exec(seg);
    if (!link) continue;
    const code = link[1];
    if (code === '' || seen[code]) continue;
    seen[code] = 1;

    let title = '';
    const titled = /<h6 class="title">\s*<a[^>]*>([\s\S]*?)<\/a>/.exec(seg);
    if (titled) title = clean(titled[1]);
    if (title === '') {
      const alt = /<img[^>]*alt="([^"]*)"/.exec(seg);
      title = alt ? clean(alt[1]) : code;
    }

    const cover =
      /<img[^>]*src="([^"]+)"[^>]*data-preview=/.exec(seg) ||
      /<img[^>]*data-preview="([^"]+)"/.exec(seg) ||
      /<img[^>]*src="([^"]+)"/.exec(seg);

    const sub = /<p class="sub-title">([\s\S]*?)<\/p>/.exec(seg);
    const subText = sub ? clean(sub[1]) : '';
    const duration = /(\d{1,2}:\d{2}(?::\d{2})?)/.exec(subText);

    out.push({
      sourceId: code,
      title: title,
      cover: cover ? cover[1] : '',
      duration: duration ? duration[1] : '',
      sub: subText,
    });
  }
  return out;
}

function toDrama(item) {
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: item.title,
    name: item.title,
    desc: item.duration ? '時長 ' + item.duration : '',
    intro: '',
    cover: item.cover,
    totalEpisode: 1,
    episodeCount: 1,
    remark: item.sourceId,
  };
}

function videoObject(html) {
  const blocks = String(html || '').match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g) || [];
  for (const block of blocks) {
    const body = block.replace(/^<script[^>]*>/, '').replace(/<\/script>$/, '');
    let data = null;
    try {
      data = JSON.parse(body);
    } catch (_) {
      continue;
    }
    if (data && data['@type'] === 'VideoObject') return data;
    if (Array.isArray(data)) {
      for (const entry of data) {
        if (entry && entry['@type'] === 'VideoObject') return entry;
      }
    }
  }
  return null;
}

function decodeTag(href) {
  const raw = String(href || '').split('/tags/')[1] || '';
  try {
    return decodeURIComponent(raw);
  } catch (_) {
    return raw;
  }
}

function detail(sourceId) {
  const code = String(sourceId || '').trim();
  if (code === '') throw new Error('AV8D 缺少影片编号');
  const page = get('/videos/' + encodeURIComponent(code));
  try {
    host.cacheSet('page:' + code, page.text, PAGE_TTL);
  } catch (_) {}

  const meta = videoObject(page.text);
  const title = meta && meta.name ? clean(meta.name) : code;
  const cover = meta && meta.thumbnailUrl ? meta.thumbnailUrl : SITE + '/cover/' + code + '.jpg';
  const actors = [];
  if (meta && Array.isArray(meta.actor)) {
    for (const person of meta.actor) {
      const name = clean((person && person.name) || '');
      if (name !== '') actors.push(name);
    }
  }
  const maker = meta && meta.publisher ? clean(meta.publisher.name || '') : '';

  const tags = [];
  const tagHrefs = page.text.match(/href="[^"]*\/tags\/[^"]+"/g) || [];
  for (const href of tagHrefs) {
    const name = decodeTag(href.replace(/^href="/, '').replace(/"$/, ''));
    if (name !== '' && tags.indexOf(name) < 0 && tags.length < 12) tags.push(name);
  }

  const facts = [];
  if (code !== '') facts.push('番號 ' + code);
  if (maker !== '') facts.push('片商 ' + maker);
  if (actors.length > 0) facts.push('演員 ' + actors.join(' / '));

  return {
    drama: {
      id: host.dramaId(code),
      source: host.source,
      sourceId: code,
      title: title,
      name: title,
      desc: facts.join(' · '),
      intro: facts.join(' · '),
      cover: cover,
      tags: tags,
      totalEpisode: 1,
      episodeCount: 1,
      // 站点只给部分演员建了作品页，片商也没有可点页面，作者信息一律留空
      author: '',
      authorId: '',
      authorUrl: '',
      actors: actors,
      serial: code,
    },
    chapters: [
      {
        id: host.chapterId(code, '1'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        pageUrl: SITE + '/videos/' + encodeURIComponent(code),
      },
    ],
  };
}

function sourceIdOf(task) {
  const chapter = task.chapter || {};
  const raw = String(chapter.id || task.dramaId || task.sourceId || '');
  const parts = raw.split(':');
  return (parts.length >= 2 ? parts[1] : raw).trim();
}

function playUrl(html) {
  const meta = videoObject(html);
  const address = meta && meta.contentUrl ? String(meta.contentUrl) : '';
  if (address.indexOf('http') !== 0) {
    throw new Error('詳情頁沒有解析到播放地址');
  }
  return address;
}

function resolveMedia(task) {
  const code = sourceIdOf(task);
  if (code === '') throw new Error('AV8D 缺少影片編號');

  let html = '';
  try {
    html = host.cacheGet('page:' + code) || '';
  } catch (_) {}
  if (html === '') {
    html = get('/videos/' + encodeURIComponent(code)).text;
    try {
      host.cacheSet('page:' + code, html, PAGE_TTL);
    } catch (_) {}
  }

  const url = playUrl(html);
  const referer = SITE + '/videos/' + encodeURIComponent(code);
  const credentials = { origin: SITE, referer: referer, userAgent: UA };
  try {
    return host.prepareWebMedia(
      { url: url, referer: referer, quality: 1080, credentials: credentials },
      'AV8D'
    );
  } catch (_) {
    return { url: url, referer: referer, quality: 1080, credentials: credentials };
  }
}

module.exports = {
  validCategory(category) {
    return (
      !category ||
      CATEGORIES.some(function (entry) {
        return entry.id === category;
      })
    );
  },

  categories() {
    return CATEGORIES.map(function (entry) {
      return { id: entry.id, name: entry.name };
    });
  },

  catalogPage(page, category) {
    const current = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const response = get(listPath(category, current));
    const items = parseCards(response.text).map(toDrama);
    // 只有分类页会给出「下一页」链接（?page=N）；首页（最新）是单页展示，
    // 传 ?page= 也返回同一批内容。原来用「条数 >= 20」判断还有没有更多，
    // 首页一次给 68 条，于是被当成无限列表：滚到底反复请求同一页，
    // 界面就一直转圈不出内容。改成看站点有没有真的给出下一页链接。
    return {
      items: items,
      hasMore: items.length > 0 && hasNextPage(response.text, current),
    };
  },

  search(page, query) {
    return { items: [], hasMore: false };
  },

  detail: detail,

  resolveMedia: resolveMedia,
};
