// SupJav —— WordPress 列表页 + 每条影片多个 embed 线路。
// 移植自 iDuanJu 的 SupJavProvider（Apache-2.0），按小果影视的模块接口重写。
// 线路优先 EVS → FST → VAS → VOE → TV → ST，LUC 不支持；
// 远端 embed 页需要跳转与反混淆，全部在模块里做完，只把最终地址交给播放器。

const SITE = 'https://supjav.com';
const BOUNCE = 'https://lk1.supremejav.com/supjav.php?c=';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const SERVER_ORDER = ['EVS', 'FST', 'VAS', 'VOE', 'TV', 'ST'];

const CATEGORIES = [
  { id: 'latest', name: '最近更新', path: '/zh/' },
  { id: 'popular', name: '热门总榜', path: '/zh/popular' },
  { id: 'popular-week', name: '本周热门', path: '/zh/popular?sort=week' },
  { id: 'popular-month', name: '本月热门', path: '/zh/popular?sort=month' },
  { id: 'chinese-subtitles', name: '中文字幕', path: '/zh/category/chinese-subtitles' },
  { id: 'censored', name: '有码', path: '/zh/category/censored-jav' },
  { id: 'uncensored', name: '无码', path: '/zh/category/uncensored-jav' },
  { id: 'amateur', name: '素人', path: '/zh/category/amateur' },
  { id: 'reducing-mosaic', name: '破解', path: '/zh/category/reducing-mosaic' },
  { id: 'english-subtitles', name: '英文字幕', path: '/zh/category/english-subtitles' },
];

function categories() {
  return CATEGORIES.map((entry) => ({ id: entry.id, name: entry.name }));
}

function validCategory(category) {
  return category === '' || CATEGORIES.some((entry) => entry.id === category);
}

function originOf(address) {
  const matched = /^(https?:\/\/[^\/]+)/.exec(address || '');
  return matched ? matched[1] : SITE;
}

// SupJav 由 Cloudflare 托管，纯 HTTP 会拿到 403「Just a moment」。
// App 里做过站点验证后，host.challengeCookie 会给出 cf_clearance，
// host.challengeUA 给出解验证时 WebView 的真实 UA——cf_clearance 绑 UA，
// 所以必须成对使用，不能用写死的 UA。
const SITE_HOST = 'supjav.com';

function agent() {
  const learned = host.challengeUA(SITE_HOST);
  return learned || UA;
}

function token() {
  return host.challengeCookie(SITE_HOST);
}

function fetchPage(path, referer) {
  const response = host.fetchText({
    url: SITE + path,
    referer: referer || SITE + '/',
    userAgent: agent(),
    cookie: token(),
  });
  return { text: response.body || '', base: originOf(response.url), url: response.url || SITE + path };
}

function pageURL(path, page) {
  if (page <= 1) return path;
  const parts = path.split('?');
  let head = parts[0];
  if (head.charAt(head.length - 1) !== '/') head += '/';
  head += 'page/' + page + '/';
  return parts.length > 1 ? head + '?' + parts[1] : head;
}

function resolve(base, address) {
  if (!address) return '';
  if (/^https?:\/\//.test(address)) return address;
  try {
    return host.resolveUrl(base, address);
  } catch (_) {
    return address;
  }
}

function clean(text) {
  return (text || '')
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

function count(text) {
  const raw = String(text || '')
    .replace(/,/g, '')
    .trim()
    .toUpperCase();
  const matched = /^([0-9.]+)\s*([KMB]?)/.exec(raw);
  if (!matched) return 0;
  const value = parseFloat(matched[1]);
  const unit = matched[2];
  const scale = unit === 'B' ? 1e9 : unit === 'M' ? 1e6 : unit === 'K' ? 1e3 : 1;
  return Math.round(value * scale);
}

function codeOf(title) {
  const matched = /([A-Za-z]{2,6})-?(\d{2,6})/.exec(title || '');
  return matched ? matched[1].toUpperCase() + '-' + matched[2] : '';
}

function padBase64(text) {
  const rest = text.length % 4;
  return rest === 0 ? text : text + '===='.slice(rest);
}

function encodeAlnum(text) {
  let out = '';
  for (let index = 0; index < text.length; index++) {
    const ch = text.charAt(index);
    if (/[A-Za-z0-9]/.test(ch)) {
      out += ch;
    } else {
      const code = text.charCodeAt(index);
      out += '%' + (code < 16 ? '0' : '') + code.toString(16).toUpperCase();
    }
  }
  return out;
}

function scriptsOf(html) {
  const out = [];
  const matched = html.match(/<script[^>]*>([\s\S]*?)<\/script>/g) || [];
  for (const block of matched) {
    out.push(block.replace(/^<script[^>]*>/, '').replace(/<\/script>$/, ''));
  }
  return out;
}

function parseLooseObject(text) {
  try {
    const value = JSON.parse(text);
    if (value && typeof value === 'object') return value;
  } catch (_) {
    // 页面里的对象字面量不一定带引号，退回正则提取。
  }
  const out = {};
  const matched =
    text.match(/([A-Za-z_$][\w$]*)\s*:\s*['"]([^'"]*)['"]/g) || [];
  for (const entry of matched) {
    const pair = /([A-Za-z_$][\w$]*)\s*:\s*['"]([^'"]*)['"]/.exec(entry);
    if (pair) out[pair[1]] = pair[2];
  }
  return Object.keys(out).length > 0 ? out : null;
}

// ---------------------------------------------------------------- 列表 / 详情

function dramaOf(card, base) {
  const link = /<a\s[^>]*href="([^"]+?(\d+)\.html)"[^>]*>/.exec(card);
  if (!link) return null;
  const sourceId = link[2];
  let title = '';
  const titled = /<a\s[^>]*href="[^"]+\.html"[^>]*title="([^"]*)"/.exec(card);
  if (titled) title = clean(titled[1]);
  if (title === '') {
    const heading = /<h3[^>]*>\s*<a[^>]*>([\s\S]*?)<\/a>/.exec(card);
    title = heading ? clean(heading[1]) : sourceId;
  }
  const cover =
    /<img[^>]*?data-original="([^"]+)"/.exec(card) ||
    /<img[^>]*?data-src="([^"]+)"/.exec(card) ||
    /<img[^>]*?\ssrc="(https?:[^"]+)"/.exec(card);
  const views = /([0-9,]+)\s*Views/.exec(card);
  const date = /class="meta">\s*(\d{4}\/\d{1,2}\/\d{1,2})/.exec(card);
  const code = codeOf(title);
  return {
    id: host.dramaId(sourceId),
    source: host.source,
    sourceId: sourceId,
    title: title,
    name: title,
    desc: '',
    intro: '',
    cover: cover ? resolve(base, cover[1]) : '',
    tags: [],
    totalEpisode: 1,
    episodeCount: 1,
    views: views ? count(clean(views[1])) : 0,
    onlineDate: date ? clean(date[1]) : '',
    remark: code === '' ? '' : code,
  };
}

function parseList(html, page, base) {
  const items = [];
  const seen = {};
  const chunks = html.split('<div class="post">');
  for (let index = 1; index < chunks.length; index++) {
    const drama = dramaOf(chunks[index].slice(0, 4000), base);
    if (drama === null || seen[drama.sourceId]) continue;
    seen[drama.sourceId] = true;
    items.push(drama);
  }
  const more =
    html.indexOf('/page/' + (page + 1)) >= 0 || html.indexOf('class="next') >= 0;
  return {
    items: items,
    hasMore: items.length > 0 && (more || (page === 1 && items.length >= 20)),
  };
}

function catalogPage(page, category) {
  const chosen = CATEGORIES.filter((entry) => entry.id === category)[0] || CATEGORIES[0];
  const response = fetchPage(pageURL(chosen.path, page));
  const result = parseList(response.text, page, response.base);
  return { items: result.items, hasMore: result.hasMore };
}

function search(page, query) {
  const text = String(query || '').trim();
  if (text === '') return { items: [], hasMore: false };
  const base = pageURL('/zh/', page);
  const path = base + '?s=' + encodeURIComponent(text);
  const response = fetchPage(path);
  const result = parseList(response.text, page, response.base);
  return { items: result.items, hasMore: result.hasMore };
}

function serversOf(html) {
  const out = [];
  const seen = {};
  // 属性顺序不固定（data-link 可能在 class 前后），先取出整个 <a> 再分别提取。
  const matched = html.match(/<a[^>]*class="[^"]*btn-server[^"]*"[^>]*>[\s\S]*?<\/a>/g) || [];
  for (const block of matched) {
    const link = /data-link="([^"]+)"/.exec(block);
    if (!link) continue;
    const name = clean(block.replace(/^<a[^>]*>/, '')).toUpperCase();
    if (name === '' || name === 'LUC' || seen[name]) continue;
    seen[name] = true;
    out.push({ name: name, link: link[1] });
  }
  out.sort((left, right) => {
    const leftRank = SERVER_ORDER.indexOf(left.name);
    const rightRank = SERVER_ORDER.indexOf(right.name);
    return (leftRank < 0 ? 99 : leftRank) - (rightRank < 0 ? 99 : rightRank);
  });
  return out;
}

function detailPath(sourceId) {
  return '/zh/' + sourceId + '.html';
}

function parseDetail(html, sourceId, base) {
  const heading = /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(html);
  const title = heading ? clean(heading[1]) : sourceId;
  const cover =
    /class="post-meta[^"]*">\s*<img[^>]*?src="([^"]+)"/.exec(html) ||
    /<meta[^>]*property="og:image"[^>]*content="([^"]+)"/.exec(html);
  const cats = /<div class="cats">([\s\S]*?)<\/div>/.exec(html);
  const catLinks = cats ? cats[1].match(/<a[^>]*>([^<]+)<\/a>/g) || [] : [];
  const tags = [];
  for (const entry of catLinks) {
    const name = clean(entry);
    if (name !== '' && tags.indexOf(name) < 0 && tags.length < 16) tags.push(name);
  }
  const tagsBlock = /<div class="tags">([\s\S]*?)<\/div>/.exec(html);
  if (tagsBlock) {
    const extra = tagsBlock[1].match(/<a[^>]*>([^<]+)<\/a>/g) || [];
    for (const entry of extra) {
      const name = clean(entry);
      if (name !== '' && tags.indexOf(name) < 0 && tags.length < 16) tags.push(name);
    }
  }
  const maker = /Maker\s*:\s*<\/span>\s*<a[^>]*>([^<]+)<\/a>/.exec(html);
  const castBlock = /Cast\s*:\s*<\/span>([\s\S]*?)<\/p>/.exec(html);
  const actors = [];
  if (castBlock) {
    const people = castBlock[1].match(/<a[^>]*>([^<]+)<\/a>/g) || [];
    for (const entry of people) {
      const name = clean(entry);
      if (name !== '') actors.push(name);
    }
  }
  const servers = serversOf(html);
  const code = codeOf(title);
  const facts = [];
  if (code !== '') facts.push('番号 ' + code);
  if (servers.length > 0) facts.push('线路 ' + servers.map((entry) => entry.name).join(' / '));
  return {
    drama: {
      id: host.dramaId(sourceId),
      source: host.source,
      sourceId: sourceId,
      title: title,
      name: title,
      desc: facts.join(' · '),
      intro: facts.join(' · '),
      cover: cover ? resolve(base, cover[1]) : '',
      tags: tags,
      totalEpisode: 1,
      episodeCount: 1,
      author: maker ? clean(maker[1]) : '',
    },
    actors: actors,
  };
}

function detail(sourceId) {
  const id = String(sourceId || '').trim();
  if (id === '') throw new Error('SupJav 缺少影片 ID');
  const response = fetchPage(detailPath(id));
  const parsed = parseDetail(response.text, id, response.base);
  return {
    drama: parsed.drama,
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

// ---------------------------------------------------------------- 线路解析

function rot13(text) {
  return text.replace(/[a-zA-Z]/g, (ch) => {
    const code = ch.charCodeAt(0);
    if (code >= 65 && code <= 90) {
      return String.fromCharCode(((code - 65 + 13) % 26) + 65);
    }
    return String.fromCharCode(((code - 97 + 13) % 26) + 97);
  });
}

function voeSource(html) {
  const matched = /<script type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  if (!matched) return null;
  let list;
  try {
    list = JSON.parse(matched[1]);
  } catch (_) {
    return null;
  }
  if (!list || list.length === 0) return null;
  let encoded = rot13(String(list[0]));
  const noise = ['@$', '^^', '~@', '%?', '*~', '!!', '#&'];
  for (const token of noise) encoded = encoded.split(token).join('_');
  encoded = encoded.split('_').join('');
  const first = host.base64Decode(padBase64(encoded));
  if (!first || first.length === 0) return null;
  // 逐字节 -3 再整体反转，最后再解一次 base64。
  const reversed = new Uint8Array(first.length);
  for (let index = 0; index < first.length; index++) {
    reversed[index] = (first[first.length - 1 - index] + 253) & 255;
  }
  let json;
  try {
    json = JSON.parse(host.utf8Decode(host.base64Encode(reversed)));
  } catch (_) {
    return null;
  }
  return json.source || json.direct_access_url || null;
}

function fstSource(html, embed) {
  const scripts = scriptsOf(html);
  scripts.push(html);
  for (const script of scripts) {
    const matched = /var\s+links\s*=\s*(\{[\s\S]*?\})/.exec(script);
    if (!matched) continue;
    const links = parseLooseObject(matched[1]);
    if (!links) continue;
    const order = [];
    const file = /file\s*:\s*((?:links\.\w+\s*\|\|\s*)*links\.\w+)/.exec(script);
    if (file) {
      const names = file[1].match(/links\.(\w+)/g) || [];
      for (const name of names) order.push(name.replace('links.', ''));
    }
    for (const name of order.concat(['hls4', 'hls3', 'hls2'])) {
      if (links[name]) return resolve(embed, links[name]);
    }
  }
  return null;
}

function tvSource(html) {
  const matched = /urlPlay\s*=\s*['"]([^'"]+\.m3u8[^'"]*)['"]/.exec(html);
  return matched ? matched[1] : null;
}

function streamtapeSource(html) {
  const ids = ['robotlink', 'botlink', 'ideoolink'];
  for (const id of ids) {
    const pattern = new RegExp(
      "getElementById\\('" +
        id +
        "'\\)\\.innerHTML\\s*=\\s*['\"]([^'\"]*)['\"]\\s*\\+\\s*(?:''\\s*\\+\\s*)?\\(['\"]([^'\"]*)['\"]\\)((?:\\.substring\\(\\d+\\))*)",
      'g',
    );
    const matched = pattern.exec(html);
    if (!matched) continue;
    let tail = matched[2];
    const cuts = matched[3].match(/substring\((\d+)\)/g) || [];
    for (const cut of cuts) {
      const steps = parseInt(cut.replace(/[^0-9]/g, ''), 10);
      if (!isNaN(steps)) tail = tail.slice(steps);
    }
    let address = matched[1] + tail;
    while (address.charAt(0) === '/') address = address.slice(1);
    if (address.indexOf('get_video') >= 0) return 'https://' + address;
  }
  return null;
}

function vasSource(embed, origin) {
  const fileName = embed.split('#')[0].split('?')[0].split('/');
  const code = fileName[fileName.length - 1];
  if (!code) return null;
  const response = host.fetch({
    method: 'POST',
    url: origin + '/api/stream',
    headers: {
      'Content-Type': 'application/json',
      Referer: embed,
      Origin: origin,
      'User-Agent': UA,
    },
    body: JSON.stringify({ filecode: code, device: 'web', codecs: [] }),
    followRedirects: true,
    anyStatus: true,
    timeoutMs: 20000,
  });
  if (response.status < 200 || response.status >= 300) return null;
  let json;
  try {
    json = JSON.parse(response.body || '');
  } catch (_) {
    return null;
  }
  const address = json.streaming_url || json.url || '';
  return /^https?:/.test(address) ? address : null;
}

function genericSource(html) {
  const scripts = scriptsOf(html);
  scripts.push(html);
  for (const script of scripts) {
    const matched = /(https?:\/\/[^'"\s]+\.m3u8[^'"\s]*)/.exec(script);
    if (matched) return matched[1];
  }
  return null;
}

function resolveServer(server) {
  const reversed = server.link.split('').reverse().join('');
  const first = host.fetchText({
    url: BOUNCE + encodeAlnum(reversed),
    referer: SITE + '/',
    userAgent: UA,
  });
  let html = first.body || '';
  let embed = first.url || '';
  // VOE 及其克隆站先返回一段 JS 跳转，换到会轮换的域名上。
  for (let round = 0; round < 2; round++) {
    if (html.indexOf('application/json') >= 0) break;
    const jump = /window\.location\.href\s*=\s*'(https?:\/\/[^']+\/e\/[^']+)'/.exec(html);
    if (!jump) break;
    const next = host.fetchText({ url: jump[1], referer: SITE + '/', userAgent: UA });
    html = next.body || '';
    embed = next.url || jump[1];
  }
  if (embed === '' || embed.indexOf('supremejav') >= 0) {
    throw new Error('跳转失败');
  }
  const origin = originOf(embed);
  let address = null;
  if (server.name === 'VOE') {
    address = voeSource(html);
  } else if (server.name === 'FST') {
    address = fstSource(html, embed);
  } else if (server.name === 'VAS') {
    address = vasSource(embed, origin);
  } else if (server.name === 'TV') {
    address = tvSource(html);
  } else if (server.name === 'ST') {
    address = streamtapeSource(html);
  }
  if (!address) address = genericSource(html);
  if (!address) throw new Error(server.name + ' 未找到播放地址');
  return {
    url: address,
    referer: embed,
    origin: origin,
  };
}

function sourceIdOf(task) {
  const chapter = task.chapter || {};
  const raw = String(chapter.id || task.dramaId || task.sourceId || '');
  const parts = raw.split(':');
  return (parts.length >= 2 ? parts[1] : raw).trim();
}

function resolveMedia(task) {
  const id = sourceIdOf(task);
  if (id === '') throw new Error('SupJav 缺少影片 ID');
  const response = fetchPage(detailPath(id));
  const servers = serversOf(response.text);
  if (servers.length === 0) throw new Error('SupJav 页面里没有找到播放线路');
  const errors = [];
  for (const server of servers) {
    try {
      const stream = resolveServer(server);
      return {
        url: stream.url,
        referer: stream.referer,
        credentials: {
          origin: stream.origin,
          referer: stream.referer,
          userAgent: UA,
        },
      };
    } catch (error) {
      errors.push(server.name + ': ' + (error && error.message ? error.message : '解析失败'));
    }
  }
  throw new Error('SupJav 所有线路解析失败（' + errors.join('；') + '）');
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  detail,
  resolveMedia,
};
