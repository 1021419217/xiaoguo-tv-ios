// Javrate —— 服务端渲染的 HTML 站。
//   列表  /movie/new、/movie/new/{page}-2-1/、/menu/{uncensored|censored|chinese}
//   卡片  <a class="… movie-card-link" href="/movie/detail/{uuid}.html" title="…">
//   详情  /movie/detail/{uuid}.html 里只有一个 <iframe id="v2-player" src="/player/v2?payload=…">
//   播放  请求该 iframe，页面初始化参数里带 signedUrl（指向 playlist.m3u8），
//         但 token 的 expires 只有约 30 秒，必须现取现用，不能缓存。

const SITE = 'https://www.javrate.com';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const PAGE_TTL = 10 * 60 * 1000;

const CATEGORIES = [
  { id: 'latest', name: '最新', path: '/movie/new', page: '/<n>-2-2/' },
  { id: 'today', name: '今日優選', path: '/movie/new/1-2-1/' },
  { id: 'popular', name: '最多人看', path: '/movie/new/3-2-1/' },
  { id: 'uncensored', name: '無碼', path: '/menu/uncensored', page: '/<n>-2-1/' },
  { id: 'censored', name: '有碼', path: '/menu/censored', page: '/<n>-2-1/' },
  { id: 'chinese', name: '中文字幕', path: '/menu/chinese', page: '/<n>-2-1/' },
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
    throw new Error('Javrate 连接失败：' + String((error && error.message) || error));
  }
  const status = response.status || 0;
  if (status < 200 || status >= 300) {
    throw new Error('Javrate 返回 HTTP ' + status + '（' + path + '）');
  }
  return { text: response.body || '', url: response.url || url };
}

function listPath(category, page) {
  const entry =
    CATEGORIES.filter(function (item) {
      return item.id === category;
    })[0] || CATEGORIES[0];
  if (!page || page <= 1) return entry.path;
  if (!entry.page) return entry.path;
  return entry.path + entry.page.replace('<n>', page);
}

function parseCards(html) {
  const out = [];
  const seen = {};
  const re = /<a[^>]*class="[^"]*movie-card-link[^"]*"[^>]*>/g;
  let matched;
  while ((matched = re.exec(String(html || ''))) !== null) {
    const tag = matched[0];
    const href = /href="([^"]+)"/.exec(tag);
    if (!href) continue;
    const uuid = /\/movie\/detail\/([^"\/]+)\.html/.exec(href[1]);
    if (!uuid) continue;
    const id = uuid[1];
    if (seen[id]) continue;
    seen[id] = 1;

    const tail = html.slice(matched.index, matched.index + 900);
    const image = /<img[^>]*src="([^"]+)"/.exec(tail);
    const titled = /title="([^"]*)"/.exec(tag);
    const code = /data-movie-code="([^"]*)"/.exec(tag);
    const title = decodeEntities(titled ? titled[1] : '') || (code ? code[1] : id);

    out.push({
      sourceId: id,
      title: title,
      cover: image ? image[1] : '',
      code: code ? code[1] : '',
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
    desc: item.code || '',
    intro: '',
    cover: item.cover,
    totalEpisode: 1,
    episodeCount: 1,
    serial: item.code || '',
  };
}

function detailPath(sourceId) {
  return '/movie/detail/' + encodeURIComponent(sourceId) + '.html';
}

function playerUrl(html) {
  const matched =
    /<iframe[^>]*id="v2-player"[^>]*src="([^"]+)"/.exec(html) ||
    /<iframe[^>]*src="([^"]*\/player\/v2[^"]*)"/.exec(html);
  if (!matched) {
    const peek = String(html || '').replace(/\s+/g, ' ').slice(0, 180);
    throw new Error('詳情頁沒有播放器｜' + String(html || '').length + ' 字节｜' + peek);
  }
  const src = matched[1];
  return src.indexOf('http') === 0 ? src : SITE + src;
}

function signedUrlOf(html) {
  const matched = /signedUrl:\s*'([^']+)'/.exec(html) || /"signedUrl"\s*:\s*"([^"]+)"/.exec(html);
  if (!matched) {
    const peek = String(html || '').replace(/\s+/g, ' ').slice(0, 180);
    throw new Error('播放器頁面沒有解析到播放地址｜' + String(html || '').length + ' 字节｜' + peek);
  }
  return String(matched[1]).replace(/\\\//g, '/');
}

function detail(sourceId) {
  const id = String(sourceId || '').trim();
  if (id === '') throw new Error('Javrate 缺少影片 ID');
  const page = get(detailPath(id));
  try {
    host.cacheSet('page:' + id, page.text, PAGE_TTL);
  } catch (_) {}

  const title =
    decodeEntities((/<h1[^>]*>([\s\S]{0,200}?)<\/h1>/.exec(page.text) || [])[1] || '') ||
    decodeEntities((/<meta[^>]*property="og:title"[^>]*content="([^"]*)"/.exec(page.text) || [])[1] || '') ||
    id;
  const cover =
    (/<meta[^>]*property="og:image"[^>]*content="([^"]*)"/.exec(page.text) || [])[1] || '';

  const issuer = /href="\/issuer\/([^"?#\/]+)"/.exec(page.text);
  const maker = issuer ? decodeEntities(issuer[1]) : '';

  const tags = [];
  const tagLinks = page.text.match(/href="\/keywords\/[^"]*"[^>]*>([^<]{1,20})</g) || [];
  for (const entry of tagLinks) {
    const name = decodeEntities((/>([^<]+)</.exec(entry) || [])[1] || '');
    if (name !== '' && tags.indexOf(name) < 0 && tags.length < 12) tags.push(name);
  }

  return {
    drama: {
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title: title,
      name: title,
      desc: '',
      intro: '',
      cover: cover,
      tags: tags,
      totalEpisode: 1,
      episodeCount: 1,
      author: maker,
      authorId: issuer ? issuer[1] : '',
      authorUrl: issuer ? SITE + '/issuer/' + issuer[1] : '',
    },
    chapters: [
      {
        id: host.chapterId(id, '1'),
        source: host.source,
        title: '正片',
        currentEpisode: 1,
        pageUrl: SITE + detailPath(id),
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

// master 里的子列表与分片都是相对路径，且服务端要求 token 出现在每个请求上。
// 这里把子列表和分片全部改写成「绝对地址 + token」的播放列表再交给播放器，
// 否则播放器按相对路径请求会直接 403。
function rewritePlaylist(text, base, query) {
  const lines = String(text || '').split('\n');
  const out = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.charAt(0) === '#') {
      out.push(line);
      continue;
    }
    let address = trimmed.indexOf('http') === 0 ? trimmed : host.resolveUrl(base, trimmed);
    if (query !== '' && address.indexOf('?') < 0) address += '?' + query;
    out.push(address);
  }
  return out.join('\n');
}

function resolveMedia(task) {
  const id = sourceIdOf(task);
  if (id === '') throw new Error('Javrate 缺少影片 ID');

  // signedUrl 的 token 只有约 30 秒有效，这里每次都重新走详情页与播放器页。
  const page = get(detailPath(id));
  const player = get(playerUrl(page.text), SITE + detailPath(id));
  const masterUrl = signedUrlOf(player.text);
  const queryIndex = masterUrl.indexOf('?');
  const query = queryIndex >= 0 ? masterUrl.slice(queryIndex + 1) : '';

  const master = host.fetchText({
    url: masterUrl,
    referer: SITE + '/',
    userAgent: UA,
    timeoutMs: 15000,
  });
  const renditions = String(master.body || '')
    .split('\n')
    .map(function (line) {
      return line.trim();
    })
    .filter(function (line) {
      return line !== '' && line.charAt(0) !== '#';
    });
  if (renditions.length === 0) {
    throw new Error('播放列表是空的（' + String(master.body || '').length + ' 字节）');
  }

  const referer = SITE + '/';
  const credentials = { origin: SITE, referer: referer, userAgent: UA };

  // 每条清晰度都要单独抓子列表并改写：分片必须带 token，播放器不会自己补。
  const medias = [];
  for (const rendition of renditions) {
    const subUrl =
      host.resolveUrl(masterUrl, rendition) + (query === '' ? '' : '?' + query);
    const sub = host.fetchText({
      url: subUrl,
      referer: referer,
      userAgent: UA,
      timeoutMs: 15000,
    });
    const quality = /1080/.test(rendition) ? 1080 : /720/.test(rendition) ? 720 : 0;
    medias.push({
      url: subUrl,
      playlist: rewritePlaylist(sub.body, subUrl, query),
      quality: quality,
    });
  }
  medias.sort(function (left, right) {
    return right.quality - left.quality;
  });

  const primary = medias[0];
  const variants = [];
  for (let index = 1; index < medias.length; index++) {
    variants.push({
      url: medias[index].url,
      playlist: medias[index].playlist,
      quality: medias[index].quality,
      referer: referer,
      credentials: credentials,
    });
  }

  return {
    url: primary.url,
    playlist: primary.playlist,
    referer: referer,
    quality: primary.quality || 1080,
    credentials: credentials,
    variants: variants,
  };
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
    const path = listPath(category, page);
    const response = get(path);
    const items = parseCards(response.text).map(toDrama);
    if (items.length === 0) {
      const peek = String(response.text || '').replace(/\s+/g, ' ').slice(0, 200);
      throw new Error('列表没有解析到内容｜' + response.text.length + ' 字节｜' + peek);
    }
    const entry =
      CATEGORIES.filter(function (item) {
        return item.id === category;
      })[0] || CATEGORIES[0];
    return { items: items, hasMore: Boolean(entry.page) && items.length >= 20 };
  },

  search(page, query) {
    return { items: [], hasMore: false };
  },

  // 片商页 /issuer/<名字>?page=N；个别片商没有收录页，降级成空列表而不是报错
  author(authorId, authorName, page) {
    const key = String(authorId || authorName || '').trim();
    if (key === '') return { items: [], hasMore: false, warning: '缺少片商' };
    const target = (page || 1) <= 1 ? 1 : page;
    let response;
    try {
      response = get('/issuer/' + encodeURIComponent(key) + '?page=' + target + '&sort=5');
    } catch (error) {
      return {
        items: [],
        hasMore: false,
        warning: '該片商沒有作品頁：' + String((error && error.message) || error),
      };
    }
    const items = parseCards(response.text).map(toDrama);
    if (items.length === 0) {
      return { items: [], hasMore: false, warning: '該片商還沒有作品' };
    }
    return { items: items, hasMore: items.length >= 20 };
  },

  detail: detail,

  resolveMedia: resolveMedia,
};
