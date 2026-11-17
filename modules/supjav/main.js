// SupJav —— WordPress 列表页 + 每条影片多个 embed 线路。
// 移植自 iDuanJu 的 SupJavProvider（Apache-2.0），按小果影视的模块接口重写。
// 线路优先 EVS → FST → VAS → VOE → TV → ST，LUC 不支持；
// 远端 embed 页需要跳转与反混淆，全部在模块里做完，只把最终地址交给播放器。

const SITE = 'https://supjav.com';
const MIRRORS = ['https://supjav.com', 'https://www.supjav.com'];
let activeBase = SITE;
const BOUNCE = 'https://lk1.supremejav.com/supjav.php?c=';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
// VOE 的嵌入域名是随机词（如 arianathankspecial.com），模块清单的通配
// 只支持固定后缀，覆盖不到，直接跳过省时间。
const SERVER_ORDER = ['EVS', 'FST', 'VAS', 'TV', 'ST'];

const CATEGORIES = [
  { id: 'latest', name: '最近更新', path: '/' },
  { id: 'popular', name: '热门总榜', path: '/popular' },
  { id: 'popular-week', name: '本周热门', path: '/popular?sort=week' },
  { id: 'popular-month', name: '本月热门', path: '/popular?sort=month' },
  { id: 'chinese-subtitles', name: '中文字幕', path: '/category/chinese-subtitles' },
  { id: 'censored', name: '有码', path: '/category/censored-jav' },
  { id: 'uncensored', name: '无码', path: '/category/uncensored-jav' },
  { id: 'amateur', name: '素人', path: '/category/amateur' },
  { id: 'reducing-mosaic', name: '破解', path: '/category/reducing-mosaic' },
  { id: 'english-subtitles', name: '英文字幕', path: '/category/english-subtitles' },
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
const SITE_HOST = 'www.supjav.com';
// 详情页缓存 10 分钟（resolveMedia 复用，省一次请求）
const PAGE_TTL = 10 * 60 * 1000;
// 验证可能在裸域上做的，两个都查
const SITE_HOST_ALT = 'supjav.com';

function agent() {
  const learned =
    host.challengeUA(SITE_HOST) || host.challengeUA(SITE_HOST_ALT);
  return learned || UA;
}

function token() {
  return host.challengeCookie(SITE_HOST) || host.challengeCookie(SITE_HOST_ALT) || '';
}

// 用 host.fetch 而不是 fetchText：需要自己带 Accept / Accept-Language，
// 并且要看真实状态码——Cloudflare 的挑战页是 403 + 一段「Just a moment」，
// 拿到这种页面要明确告诉用户去验证，而不是当成空列表。
function looksLikeChallenge(status, text) {
  if (status === 403 || status === 429 || status === 503) return true;
  const head = String(text || '').slice(0, 6000);
  return /_cf_chl_opt|cf-chl-|just a moment|attention required|checking your browser|verify you are human/i.test(head);
}

function fetchPage(path, referer) {
  const cookie = token();
  const headers = {
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Upgrade-Insecure-Requests': '1',
    Referer: (activeBase || SITE) + '/',
    'User-Agent': agent(),
  };
  if (cookie) headers.Cookie = cookie;

  // 两个域名依次试，优先用上次成功的
  var order = [activeBase || SITE];
  for (var mi = 0; mi < MIRRORS.length; mi++) {
    if (MIRRORS[mi] !== order[0]) order.push(MIRRORS[mi]);
  }
  var response = null;
  var lastBody = '';
  var lastStatus = 0;
  var errors = [];
  for (var oi = 0; oi < order.length; oi++) {
    try {
      var got = host.fetch({
        url: order[oi] + path,
        headers: headers,
        anyStatus: true,
        followRedirects: true,
        timeoutMs: 20000,
      });
      lastStatus = got.status || 0;
      lastBody = got.body || '';
      response = got;
      // 拿到明确状态码就停（403/429/503 也停，交给下面判定挑战页）
      if (lastStatus > 0) {
        activeBase = order[oi];
        break;
      }
    } catch (e) {
      errors.push(order[oi] + ' ≠ ' + String((e && e.message) || e));
      response = null;
    }
  }
  if (!response) {
    // 所有域名都失败：把真实错误抛出去，不要静默返回空文本
    var detailMsg = errors.length ? errors.join(' | ') : '无响应';
    throw new Error('SupJav 连接失败: ' + detailMsg);
  }
  const text = response.body || '';
  const url = response.url || SITE + path;
  const status = response.status || 0;
  if (looksLikeChallenge(status, text)) {
    const error = new Error(
      cookie
        ? '站点仍然要求浏览器验证（通行 cookie 未被接受），请再验证一次'
        : '站点要求浏览器验证，请点「去验证」完成验证后再试'
    );
    error.retryable = true;
    throw error;
  }
  if (status >= 400) {
    const error = new Error('SupJav 返回 HTTP ' + status);
    error.retryable = status >= 500 || status === 408;
    throw error;
  }
  return { text: text, base: originOf(url), url: url, status: status };
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
    // views 在 App 的 Drama 结构体里是 string
    views: views ? String(count(clean(views[1])) || '') : '',
    onlineDate: date ? clean(date[1]) : '',
    remark: code === '' ? '' : code,
  };
}

function parseList(html, page, base) {
  const items = [];
  const seen = {};

  // 首页和热门页的卡片是 <div class="post">，但分类页
  // （/category/xxx）用的是另一套模板，按 class 切会一条都切不出来。
  // 所以标准切法切不到时，退回到「按视频链接位置切」——不依赖任何 class。
  let chunks = html.split('<div class="post">');
  let startIndex = 1;
  if (chunks.length < 2) {
    chunks = [];
    startIndex = 0;
    const linkRe = /<a\s[^>]*href="[^"]*?\d+\.html"[^>]*>/g;
    const positions = [];
    let mm;
    while ((mm = linkRe.exec(html)) !== null) positions.push(mm.index);
    for (let i = 0; i < positions.length; i++) {
      // 封面图通常写在链接前面，往前多取一点
      const from = Math.max(0, positions[i] - 900);
      const to = i + 1 < positions.length ? positions[i + 1] : html.length;
      chunks.push(html.slice(from, to));
    }
  }

  for (let index = startIndex; index < chunks.length; index++) {
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
  const path = pageURL(chosen.path, page);

  try {
    host.log('[supjav] start ' + chosen.path + ' page=' + page);
  } catch (_) {}

  let response;
  try {
    response = fetchPage(path);
  } catch (e) {
    // 请求阶段失败：把路径和真实原因一起抛给 UI
    const reason = String((e && e.message) || e);
    try {
      host.log('[supjav] fetch failed ' + chosen.path + ': ' + reason);
    } catch (_) {}
    throw new Error('分类「' + chosen.name + '」加载失败：' + reason);
  }

  const body = String(response.text || '');
  const result = parseList(body, page, response.base);

  // 拿到页面但解析不出条目：把状态码/长度/片段一起抛出来，方便定位
  if (result.items.length === 0) {
    const head = body.slice(0, 140).replace(/\s+/g, ' ');
    const linkHits = (body.match(/href="[^"]*?\d+\.html"/g) || []).length;
    const hasPostClass = body.indexOf('class="post"') >= 0;
    const msg =
      '分类「' + chosen.name + '」没有解析到内容' +
      '｜HTTP ' + response.status +
      '｜页面 ' + body.length + ' 字节' +
      '｜链接 ' + linkHits + ' 个' +
      '｜post块 ' + (hasPostClass ? '有' : '无') +
      '｜开头：' + head;
    try {
      host.log('[supjav] empty ' + chosen.path + ' ' + msg);
    } catch (_) {}
    throw new Error(msg);
  }

  try {
    host.log('[supjav] ok ' + chosen.path + ' items=' + result.items.length);
  } catch (_) {}

  return { items: result.items, hasMore: result.hasMore };
}

function search(page, query) {
  const text = String(query || '').trim();
  if (text === '') return { items: [], hasMore: false };
  const base = pageURL('/', page);
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
  // 上次成功的线路排最前，避免每次都从失败的线路开始等超时
  let lastGood = '';
  try {
    lastGood = host.loadState('lastServer') || '';
  } catch (_) {}
  // 只认主力线路；历史上记过 ST 之类的一律忽略
  if (lastGood !== 'FST' && lastGood !== 'EVS') lastGood = '';
  if (lastGood !== '') {
    out.sort((left, right) => {
      if (left.name === lastGood) return -1;
      if (right.name === lastGood) return 1;
      return 0;
    });
    return out;
  }
  out.sort((left, right) => {
    const leftRank = SERVER_ORDER.indexOf(left.name);
    const rightRank = SERVER_ORDER.indexOf(right.name);
    return (leftRank < 0 ? 99 : leftRank) - (rightRank < 0 ? 99 : rightRank);
  });
  return out;
}

function detailPath(sourceId) {
  return '/' + sourceId + '.html';
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
  // 缓存详情页：播放时直接复用，不再重复请求
  try {
    host.cacheSet('page:' + id, response.text, PAGE_TTL);
  } catch (_) {}
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

// Dean Edwards Packer 解包：eval(function(p,a,c,k,e,d){...}('...',62,62,'...'.split('|'),0,{}))
// SupJav 的 FST 播放器把整段 JS 打包了，地址藏在解包后的代码里。
function unpackPacker(script) {
  const m = /eval\(function\(p,a,c,k,e,[dr]\)\{[\s\S]*?\}\('([\s\S]*?)',(\d+),(\d+),'([\s\S]*?)'\.split\('\|'\)/i.exec(script);
  if (!m) return '';
  const p = m[1];
  const radix = parseInt(m[2], 10) || 62;
  const count = parseInt(m[3], 10);
  const words = m[4].split('|');
  let out = p;
  for (let i = count - 1; i >= 0; i--) {
    if (!words[i]) continue;
    try {
      out = out.replace(new RegExp('\\b' + i.toString(radix) + '\\b', 'g'), words[i]);
    } catch (_) {}
  }
  return out;
}

function fstSource(html, embed) {
  const scripts = scriptsOf(html);
  scripts.push(html);
  for (const script of scripts) {
    // 先试 packer 解包（FST 的页面是打包过的）
    const unpacked = unpackPacker(script);
    if (unpacked) {
      const direct = /(https?:\/\/[^'"\s\\]+\.m3u8[^'"\s\\]*)/.exec(unpacked);
      if (direct) return direct[1].replace(/\\\//g, '/');
      const boxed = /var\s+links\s*=\s*(\{[\s\S]*?\})/.exec(unpacked);
      if (boxed) {
        const linkMap = parseLooseObject(boxed[1]);
        if (linkMap) {
          for (const name of ['hls4', 'hls3', 'hls2', 'hls1']) {
            if (linkMap[name]) return resolve(embed, linkMap[name]);
          }
        }
      }
    }

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
    timeoutMs: 8000,
  });
  let html = first.body || '';
  let embed = first.url || '';
  // VOE 及其克隆站先返回一段 JS 跳转，换到会轮换的域名上。
  for (let round = 0; round < 2; round++) {
    if (html.indexOf('application/json') >= 0) break;
    const jump = /window\.location\.href\s*=\s*'(https?:\/\/[^']+\/e\/[^']+)'/.exec(html);
    if (!jump) break;
    const next = host.fetchText({ url: jump[1], referer: SITE + '/', userAgent: UA, timeoutMs: 8000 });
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
  if (!address) {
    // 把最长的 <script> 片段带出来——播放地址基本都藏在脚本里
    let scriptText = '';
    const sre = /<script[^>]*>([\s\S]*?)<\/script>/gi;
    let sm;
    while ((sm = sre.exec(html)) !== null) {
      const body = sm[1] || '';
      if (body.length > scriptText.length) scriptText = body;
    }
    const peek = (scriptText || html || '')
      .replace(/\s+/g, ' ')
      .slice(0, 220);
    throw new Error(
      server.name + ' 未找到播放地址｜页面 ' + String(html || '').length +
      ' 字节｜脚本：' + peek
    );
  }
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

// 从详情页 HTML 解析播放地址（VOE 优先，它通常最快）
function resolveFromHtml(html, id) {
  const servers = serversOf(html);
  if (servers.length === 0) throw new Error('页面里没有找到播放线路');

  const failures = [];
  const resolved = [];

  // 最多解析 3 条线路：够切换，又不至于让首次播放等太久
  for (const server of servers) {
    if (resolved.length >= 3) break;
    try {
      const stream = resolveServer(server);
      resolved.push({
        name: server.name,
        url: stream.url,
        referer: stream.referer,
        origin: stream.origin,
      });
    } catch (error) {
      failures.push(server.name + ': ' + String((error && error.message) || error).slice(0, 45));
    }
  }

  if (resolved.length === 0) {
    throw new Error('所有线路都无法播放 → ' + failures.join(' | '));
  }

  // 主力线路：抓播放列表，做到秒开
  const primary = resolved[0];
  const primaryCredentials = {
    origin: primary.origin,
    referer: primary.referer,
    userAgent: UA,
  };
  let media = null;
  try {
    media = host.prepareWebMedia(
      { url: primary.url, referer: primary.referer, quality: 1080, credentials: primaryCredentials },
      'SupJav'
    );
  } catch (_) {
    media = {
      url: primary.url,
      referer: primary.referer,
      quality: 1080,
      credentials: primaryCredentials,
    };
  }

  // 其余线路挂成 variants：不抓播放列表，用户切过去时播放器自己拉，
  // 这样多一条备用线路几乎不增加首播等待。
  const variants = [];
  for (let i = 1; i < resolved.length; i++) {
    const v = resolved[i];
    variants.push({
      url: v.url,
      referer: v.referer,
      quality: 720,
      credentials: { origin: v.origin, referer: v.referer, userAgent: UA },
    });
  }
  if (variants.length > 0) media.variants = variants;

  try { host.saveState('lastServer', primary.name); } catch (_) {}
  return media;
}// 播放地址的短时缓存窗口：embed 播放器签发的地址有时效，
// 5 分钟太长（会拿到过期地址导致播放器报错），90 秒是保守值。
var READY_TTL_MS = 90 * 1000;

function resolveMedia(task) {
  const id = sourceIdOf(task);
  if (id === '') throw new Error('SupJav 缺少影片 ID');

  // ① 90 秒内重复播放：直接用缓存，0 请求
  try {
    const cached = host.cacheGet('ready:' + id);
    if (cached) {
      const m = JSON.parse(cached);
      const age = Date.now() - Number(m.at || 0);
      if (m.url && age >= 0 && age < READY_TTL_MS) {
        return {
          url: m.url,
          playlist: m.playlist || '',
          referer: m.referer || SITE + '/',
          quality: 1080,
          durationMs: Number(m.durationMs || 0),
          credentials: m.credentials || undefined,
          variants: m.variants || undefined,
        };
      }
    }
  } catch (_) {}

  // ② 复用详情页 HTML（10 分钟内不重复抓）
  let html = '';
  try {
    html = host.cacheGet('page:' + id) || '';
  } catch (_) {}
  if (!html) {
    html = fetchPage(detailPath(id)).text;
    try {
      host.cacheSet('page:' + id, html, PAGE_TTL);
    } catch (_) {}
  }

  // ③ 现解析（每次都拿新地址，保证时效）
  const media = resolveFromHtml(html, id);

  // ④ 存 90 秒短缓存，credentials 一并保存（之前漏了 cookie 会导致分片被拒）
  try {
    host.cacheSet(
      'ready:' + id,
      JSON.stringify({
        url: media.url,
        playlist: media.playlist || '',
        referer: media.referer || SITE + '/',
        durationMs: media.durationMs || 0,
        at: Date.now(),
        credentials: media.credentials || null,
        variants: media.variants || null,
      }),
      READY_TTL_MS
    );
  } catch (_) {}

  return media;
}

module.exports = {
  categories,
  validCategory,
  catalogPage,
  search,
  detail,
  resolveMedia,
};
