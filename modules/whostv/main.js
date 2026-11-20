// whos.tv（bad.news 的新站）—— 服务端渲染，直接 HTTP 可访问，不需要站点验证。
//   列表  /videos、/videos/page-{n}（每页 12 条），排行榜 /ranking/video
//   卡片  <a href="/videos/{code}"> … <div data-cover-src="{hex}"> … <h3>标题</h3>
//   封面  data-cover-src 是「hex(明文逐字节 XOR 密钥) + 2 位十六进制密钥」
//   详情  /videos/{code}，og:title / og:image，播放地址在 <source src="…m3u8">
//   bad.news 已并入 whos.tv，两者内容一致。

const SITE = 'https://whos.tv';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const PAGE_TTL = 10 * 60 * 1000;

const CATEGORIES = [
  { id: 'latest', name: '最新', path: '/videos', page: '/page-<n>' },
  { id: 'ranking', name: '排行榜', path: '/ranking/video', page: '/page-<n>' },
];

function decodeEntities(value) {
  return String(value == null ? '' : value)
    .replace(/&#x([0-9a-fA-F]+);/g, function (_m, hex) {
      return String.fromCharCode(parseInt(hex, 16));
    })
    .replace(/&#(\d+);/g, function (_m, dec) {
      return String.fromCharCode(parseInt(dec, 10));
    })
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// lazy-cover.js 的 coolDecrypt：末两位是密钥，其余按字节异或。
function decodeCover(value) {
  const hex = String(value || '');
  if (hex.length < 6 || hex.length % 2 !== 0) return '';
  const key = parseInt(hex.slice(-2), 16);
  if (isNaN(key)) return '';
  const body = hex.slice(0, -2);
  let out = '';
  for (let index = 0; index < body.length; index += 2) {
    out += String.fromCharCode(parseInt(body.substr(index, 2), 16) ^ key);
  }
  return out.replace(/\u0000+$/, '');
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
    throw new Error('whos.tv 连接失败：' + String((error && error.message) || error));
  }
  const status = response.status || 0;
  if (status < 200 || status >= 300) {
    throw new Error('whos.tv 返回 HTTP ' + status + '（' + path + '）');
  }
  return { text: response.body || '', url: response.url || url };
}

function listPath(category, page) {
  const entry =
    CATEGORIES.filter(function (item) {
      return item.id === category;
    })[0] || CATEGORIES[0];
  if (!page || page <= 1) return entry.path;
  return entry.path + entry.page.replace('<n>', page);
}

function parseCards(html) {
  const text = String(html || '');
  const out = [];
  const seen = {};
  const re = /<a[^>]*href="\/videos\/([^"?#\/]+)"[^>]*>/g;
  let matched;
  while ((matched = re.exec(text)) !== null) {
    const code = matched[1];
    if (seen[code]) continue;
    const tail = text.slice(matched.index, matched.index + 1500);
    const cover = /data-cover-src="([0-9a-fA-F]+)"/.exec(tail);
    if (!cover) continue;
    seen[code] = 1;

    const heading = /<h3[^>]*>([\s\S]{0,200}?)<\/h3>/.exec(tail);
    const bold = /<p[^>]*class="[^"]*font-bold[^"]*"[^>]*>([\s\S]{0,200}?)<\/p>/.exec(tail);
    const alt = /alt="([^"]{0,200})"/.exec(tail);
    const candidates = [
      heading ? decodeEntities(heading[1]) : '',
      bold ? decodeEntities(bold[1]) : '',
      alt ? decodeEntities(alt[1]) : '',
    ];
    let title = '';
    for (const candidate of candidates) {
      if (candidate === '') continue;
      // 排行榜的 alt 只有番号，当作最后兜底
      if (candidate.toUpperCase() === code.toUpperCase() && title === '') {
        title = candidate;
        continue;
      }
      if (candidate.length > title.length) title = candidate;
    }
    if (title === '') title = code;

    out.push({
      sourceId: code,
      title: title,
      cover: decodeCover(cover[1]),
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
    desc: item.sourceId.toUpperCase(),
    intro: '',
    cover: item.cover,
    totalEpisode: 1,
    episodeCount: 1,
    serial: item.sourceId.toUpperCase(),
  };
}

function detailPath(sourceId) {
  return '/videos/' + encodeURIComponent(String(sourceId || '').trim());
}

function detail(sourceId) {
  const code = String(sourceId || '').trim();
  if (code === '') throw new Error('whos.tv 缺少影片编号');
  const page = get(detailPath(code));
  try {
    host.cacheSet('page:' + code, page.text, PAGE_TTL);
  } catch (_) {}

  const raw = decodeEntities(
    (/<meta[^>]*property="og:title"[^>]*content="([^"]*)"/.exec(page.text) || [])[1] || ''
  );
  // og:title 形如 "hez-936 标题"，去掉前缀编号
  const title = raw.replace(/^[a-zA-Z0-9_-]+\s+/, '').trim() || raw || code;
  const cover =
    (/<meta[^>]*property="og:image"[^>]*content="([^"]*)"/.exec(page.text) || [])[1] || '';

  return {
    drama: {
      id: host.dramaId(code),
      source: host.source,
      sourceId: code,
      title: title,
      name: title,
      desc: code.toUpperCase(),
      intro: '',
      cover: cover,
      totalEpisode: 1,
      episodeCount: 1,
      serial: code.toUpperCase(),
    },
    chapters: [
      {
        id: host.chapterId(code, '1'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        pageUrl: SITE + detailPath(code),
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

function mediaOf(html) {
  const matched =
    /<source[^>]*src="([^"]+)"/.exec(html) ||
    /data-src="([^"]+\.m3u8[^"]*)"/.exec(html) ||
    /"(https?:\/\/[^"]+\.m3u8[^"]*)"/.exec(html);
  if (!matched) {
    const peek = String(html || '').replace(/\s+/g, ' ').slice(0, 200);
    throw new Error('詳情頁沒有解析到播放地址｜' + String(html || '').length + ' 字节｜' + peek);
  }
  return matched[1].replace(/\\\//g, '/');
}

function resolveMedia(task) {
  const code = sourceIdOf(task);
  if (code === '') throw new Error('whos.tv 缺少影片编号');

  let html = '';
  try {
    html = host.cacheGet('page:' + code) || '';
  } catch (_) {}
  if (html === '') {
    html = get(detailPath(code)).text;
    try {
      host.cacheSet('page:' + code, html, PAGE_TTL);
    } catch (_) {}
  }

  const url = mediaOf(html);
  const referer = SITE + '/';
  const credentials = { origin: SITE, referer: referer, userAgent: UA };
  try {
    return host.prepareWebMedia(
      { url: url, referer: referer, quality: 1080, credentials: credentials },
      'whos.tv'
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
    const response = get(listPath(category, page));
    const items = parseCards(response.text).map(toDrama);
    if (items.length === 0) {
      const peek = String(response.text || '').replace(/\s+/g, ' ').slice(0, 200);
      throw new Error(
        '列表没有解析到内容｜' + response.text.length + ' 字节｜' + peek
      );
    }
    return { items: items, hasMore: items.length >= 10 };
  },

  search(page, query) {
    const keyword = String(query || '').trim();
    if (keyword === '') return { items: [], hasMore: false };
    const current = page && page > 1 ? page : 1;
    // 站点的真实搜索入口是首页表单 action="/result"?search=，参数名 search。
    // 用 /videos?keyword= 会被忽略，返回默认列表（表现为永远同样十几条）。
    const search = '?search=' + encodeURIComponent(keyword);
    const paths =
      current === 1
        ? ['/result' + search]
        : ['/result/page-' + current + search, '/result' + search + '&page=' + current];
    for (const path of paths) {
      const response = get(path);
      const items = parseCards(response.text).map(toDrama);
      if (items.length > 0) {
        return { items: items, hasMore: items.length >= 10 };
      }
    }
    return { items: [], hasMore: false };
  },

  detail: detail,

  resolveMedia: resolveMedia,
};
