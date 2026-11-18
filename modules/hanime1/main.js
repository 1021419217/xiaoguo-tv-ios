const siteBaseUrl = "https://hanime1.me";
const sourceName = "Hanime1";
const userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

// 站点在 Cloudflare 的托管验证后面，纯 HTTP 客户端拿不到网页。
// 直连可用时仍然直连；被拦截时改走能执行页面脚本的阅读中转。
const relayBaseUrl = "https://r.jina.ai/";
const bodyLimit = 8 * 1024 * 1024;
const directTimeoutMs = 12000;
const relayTimeoutMs = 45000;
const directModeTtlMs = 10 * 60 * 1000;
const relayModeTtlMs = 30 * 60 * 1000;
const modeCacheKey = "access-mode";

let accessMode = "";

function attr(node, name) {
  return node && node.attrs ? node.attrs[name] || "" : "";
}

function hasClass(node, name) {
  return attr(node, "class").split(/\s+/).includes(name);
}

function select(root, matches) {
  const found = [];
  const pending = root ? [root] : [];
  while (pending.length > 0) {
    const node = pending.pop();
    if (matches(node)) {
      found.push(node);
    }
    const children = node.children || [];
    for (let index = children.length - 1; index >= 0; index--) {
      pending.push(children[index]);
    }
  }
  return found;
}

function text(node) {
  if (!node || node.tag === "script" || node.tag === "style") {
    return "";
  }
  return (node.text || "") + (node.children || []).map(text).join("");
}

function clean(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function httpUrl(raw, base) {
  if (typeof raw !== "string" || raw.trim() === "" || raw.length > 8192) {
    return null;
  }
  try {
    const parsed = host.parseUrl(host.resolveUrl(base || siteBaseUrl + "/", raw.trim()));
    return (parsed.scheme === "https" || parsed.scheme === "http") && parsed.hostname && !parsed.userInfo ? parsed : null;
  } catch (error) {
    return null;
  }
}

function siteUrl(raw, base) {
  const parsed = httpUrl(raw, base);
  return parsed && parsed.scheme === "https" && (!parsed.port || parsed.port === "443") &&
    ["hanime1.me", "www.hanime1.me"].includes(parsed.hostname.toLowerCase()) ? parsed : null;
}

function queryValue(query, name) {
  for (const part of String(query || "").split("&")) {
    const separator = part.indexOf("=");
    try {
      const key = decodeURIComponent((separator < 0 ? part : part.slice(0, separator)).replace(/\+/g, " "));
      if (key === name) {
        return decodeURIComponent((separator < 0 ? "" : part.slice(separator + 1)).replace(/\+/g, " "));
      }
    } catch (error) {
      return "";
    }
  }
  return "";
}

function numericId(value) {
  return typeof value === "string" && /^[1-9][0-9]{0,19}$/.test(value);
}

function videoId(raw) {
  const parsed = siteUrl(raw);
  const id = parsed && parsed.path === "/watch" ? queryValue(parsed.query, "v") : "";
  return numericId(id) ? id : "";
}

function watchUrl(id) {
  if (!numericId(id)) {
    throw new Error("Hanime1 视频 ID 无效");
  }
  return siteBaseUrl + "/watch?v=" + id;
}

function knownGenres() {
  const stored = host.cacheGet("genres");
  if (!stored) {
    return [];
  }
  try {
    const list = JSON.parse(stored);
    return Array.isArray(list) ? list : [];
  } catch (error) {
    return [];
  }
}

function rememberGenres(list) {
  try {
    host.cacheSet("genres", JSON.stringify(list), 86400000);
  } catch (error) {
    /* 缓存失败不影响分类 */
  }
}

function genreName(category) {
  if (typeof category !== "string" || category.length > 800) {
    return "";
  }
  let value = category;
  if (value.startsWith("genre:")) {
    value = value.slice(6);
  } else if (value.startsWith("tag:")) {
    value = value.slice(4);
  }
  for (let round = 0; round < 2 && value.indexOf("%") >= 0; round++) {
    let next = value;
    try {
      next = decodeURIComponent(value);
    } catch (error) {
      break;
    }
    if (next === value) {
      break;
    }
    value = next;
  }
  value = value.trim();
  if (value === "" || value.length > 80 || /[\x00-\x1f\x7f]/.test(value)) {
    return "";
  }
  return value;
}

function validCategory(category) {
  return category === "" || genreName(category) !== "";
}

function isChallenge(response) {
  if (response.blocked === true) {
    return true;
  }
  const body = String(response.body || "");
  return body.indexOf("_cf_chl_opt") >= 0 || /<title>\s*just a moment/i.test(body);
}

function requestText(address, headers, timeout) {
  return host.fetch({
    method: "GET",
    url: address,
    headers: headers,
    timeoutMs: timeout,
    limit: bodyLimit,
    followRedirects: true,
    anyStatus: true,
  });
}

function directHtml(address) {
  const response = requestText(address, { "Accept-Language": "zh-CN,zh;q=0.9", "User-Agent": userAgent }, directTimeoutMs);
  if (response.status !== 200 || isChallenge(response)) {
    return "";
  }
  return String(response.body || "");
}

function relayHtml(address, noCache) {
  const headers = { "x-return-format": "html", "accept": "text/html", "user-agent": userAgent };
  if (noCache === true) {
    headers["x-no-cache"] = "true";
  }
  let response = null;
  let failure = "";
  for (let attempt = 1; attempt <= 2; attempt++) {
    if (attempt > 1) {
      host.sleep(700);
    }
    try {
      response = requestText(relayBaseUrl + address, headers, relayTimeoutMs);
    } catch (error) {
      response = null;
      failure = "Hanime1 中转服务连接失败：" + clean(error && error.message ? error.message : error);
      continue;
    }
    if (response.status === 200) {
      break;
    }
    if (response.status === 429) {
      throw new Error("Hanime1 中转服务请求过多，请稍后重试");
    }
    if (response.status < 500) {
      throw new Error("Hanime1 中转服务返回 HTTP " + response.status);
    }
    failure = "Hanime1 中转服务返回 HTTP " + response.status;
  }
  if (!response || response.status !== 200) {
    throw new Error(failure || "Hanime1 中转服务没有返回网页");
  }
  const html = String(response.body || "");
  if (html.indexOf("<html") < 0) {
    throw new Error("Hanime1 中转服务没有返回网页");
  }
  return html;
}

function cachedMode() {
  if (accessMode) {
    return accessMode;
  }
  const stored = host.cacheGet(modeCacheKey);
  if (stored === "direct" || stored === "relay") {
    accessMode = stored;
  }
  return accessMode;
}

function rememberMode(value, ttl) {
  accessMode = value;
  host.cacheSet(modeCacheKey, value, ttl);
}

function loadHtml(address, noCache) {
  const known = cachedMode();
  if (known !== "relay") {
    let html = "";
    try {
      html = directHtml(address);
    } catch (error) {
      html = "";
    }
    if (html) {
      if (known !== "direct") {
        rememberMode("direct", directModeTtlMs);
      }
      return html;
    }
    host.log("Hanime1 直连被 Cloudflare 拦截，改用中转");
  }
  rememberMode("relay", relayModeTtlMs);
  return relayHtml(address, noCache);
}

function loadPage(address, noCache) {
  return host.parseHtml(loadHtml(address, noCache));
}

function readGenreEntries(root) {
  const found = [];
  const seen = new Set();
  for (const anchor of select(root, (node) => node.tag === "a" &&
    (hasClass(node, "nav-desktop-items") || hasClass(node, "home-genre-tabs")))) {
    const parsed = siteUrl(attr(anchor, "href"));
    const genre = parsed && parsed.path === "/search" ? queryValue(parsed.query, "genre") : "";
    if (genre === "" || seen.has(genre)) {
      continue;
    }
    seen.add(genre);
    found.push({ id: "genre:" + encodeURIComponent(genre), name: genre, href: parsed.href });
  }
  return found;
}

function categories(force) {
  const root = loadPage(siteBaseUrl + "/search", force === true);
  const entries = readGenreEntries(root);
  if (entries.length === 0) {
    throw new Error("Hanime1 未返回可识别的分类，请确认页面结构或访问权限");
  }
  rememberGenres(entries);
  host.log("Hanime1 分类 " + entries.length + " 个");
  return entries.map((entry) => ({ id: entry.id, name: entry.name }));
}

function mappedGenre(genre) {
  const stored = host.cacheGet("genre-map:" + genre);
  if (typeof stored === "string" && stored !== "") {
    return stored;
  }
  try {
    const raw = host.loadState("genre-map");
    if (raw) {
      const map = JSON.parse(raw);
      if (map && typeof map === "object" && typeof map[genre] === "string" && map[genre] !== "") {
        host.cacheSet("genre-map:" + genre, map[genre], 86400000);
        return map[genre];
      }
    }
  } catch (error) {
    /* 读取失败时按原分类处理 */
  }
  return genre;
}

function rememberGenreMap(genre, mapped) {
  host.cacheSet("genre-map:" + genre, mapped, 86400000);
  try {
    const raw = host.loadState("genre-map");
    const map = raw ? JSON.parse(raw) : {};
    if (map && typeof map === "object") {
      map[genre] = mapped;
      host.saveState("genre-map", JSON.stringify(map));
    }
  } catch (error) {
    /* 保存失败不影响本次分类 */
  }
}

function genreCandidates(genre) {
  const known = knownGenres();
  const names = [];
  for (let index = 0; index < known.length; index++) {
    const name = known[index].name;
    if (!name || name === genre) {
      continue;
    }
    if (genre.indexOf(name) === 0 || name.indexOf(genre) === 0) {
      names.push(name);
    }
  }
  names.sort((left, right) => right.length - left.length);
  return names.slice(0, 2);
}

function genreHref(genre) {
  const known = knownGenres();
  for (let index = 0; index < known.length; index++) {
    if (known[index].name === genre && known[index].href) {
      return known[index].href;
    }
  }
  try {
    const entries = readGenreEntries(loadPage(siteBaseUrl + "/search", false));
    rememberGenres(entries);
    for (let index = 0; index < entries.length; index++) {
      if (entries[index].name === genre) {
        return entries[index].href;
      }
    }
  } catch (error) {
    /* 取站点链接失败时保持原地址 */
  }
  return "";
}

function drama(id, title, cover, intro) {
  return {
    id: host.dramaId(id), source: host.source, sourceId: id,
    title, name: title, cover, coverUrl: cover, intro: intro || "", desc: intro || "",
    channelName: sourceName, totalEpisode: 1, episodeCount: 1,
  };
}

function coverUrl(raw) {
  const parsed = httpUrl(raw);
  return parsed ? parsed.href : "";
}

function searchAddress(params, page) {
  const query = Object.assign({}, params, { page: String(page) });
  return siteBaseUrl + "/search?" + Object.keys(query)
    .map((key) => encodeURIComponent(key) + "=" + encodeURIComponent(query[key])).join("&");
}

function withPage(href, page) {
  const parsed = siteUrl(href);
  if (!parsed) {
    return "";
  }
  const query = parsed.query ? parsed.query + "&" : "";
  return siteBaseUrl + parsed.path + "?" + query + "page=" + encodeURIComponent(String(page));
}

function listing(page, params) {
  return parseListing(page, searchAddress(params, page), params, false);
}

function parseListing(page, address, params, noCache) {
  if (!Number.isInteger(page) || page < 1 || page > 100000) {
    throw new Error("Hanime1 页码无效");
  }
  const root = loadPage(address, noCache === true);
  const scope = select(root, (node) => attr(node, "id") === "home-rows-wrapper" && hasClass(node, "search-rows-wrapper"))[0];
  if (!scope) {
    throw new Error("Hanime1 未返回搜索列表，请确认页面结构或访问权限");
  }
  const items = [];
  const seen = new Set();
  const cards = select(scope, (node) => hasClass(node, "video-item-container") ||
    (node.tag === "a" && (node.children || []).some((child) => hasClass(child, "home-rows-videos-div") && hasClass(child, "search-videos"))));
  for (const card of cards) {
    const portrait = card.tag === "a";
    const anchor = portrait ? card : select(card, (node) => node.tag === "a" && hasClass(node, "video-link") && videoId(attr(node, "href")) !== "")[0];
    const id = videoId(attr(anchor, "href"));
    if (id === "" || seen.has(id)) {
      continue;
    }
    const titleNode = select(anchor, (node) => hasClass(node, portrait ? "home-rows-videos-title" : "title"))[0];
    const title = clean(text(titleNode)) || clean(attr(card, "title"));
    if (!title) {
      throw new Error("Hanime1 视频卡片缺少标题，请确认页面结构");
    }
    const image = select(anchor, (node) => node.tag === "img" && (portrait || hasClass(node, "main-thumb")))[0];
    const cover = coverUrl(attr(image, "data-src")) || coverUrl(attr(image, "data-original")) || coverUrl(attr(image, "src"));
    seen.add(id);
    items.push(drama(id, title, cover));
  }
  let hasMore = false;
  for (const anchor of select(root, (node) => node.tag === "a" && hasClass(node, "page-link"))) {
    const parsed = siteUrl(attr(anchor, "href"), address);
    if (!parsed || parsed.path !== "/search" ||
      queryValue(parsed.query, "query") !== (params.query || "") ||
      queryValue(parsed.query, "genre") !== (params.genre || "")) {
      continue;
    }
    const next = queryValue(parsed.query, "page");
    if (/^[1-9][0-9]{0,5}$/.test(next) && Number(next) > page) {
      hasMore = true;
    }
  }
  if (items.length === 0 && (hasMore || select(scope, (node) => node.tag === "a" && videoId(attr(node, "href")) !== "").length > 0)) {
    throw new Error("Hanime1 列表中存在视频或下一页，但未解析到有效卡片");
  }
  return { items, hasMore };
}

function catalogPage(page, category) {
  const label = category === "" ? "全部" : category;
  host.log("Hanime1 取分类 " + label + " 第 " + page + " 页");
  try {
    if (!validCategory(category)) {
      throw new Error("Hanime1 分类无效");
    }
    const requested = category === "" ? "" : genreName(category);
    const genre = requested === "" ? "" : mappedGenre(requested);
    const params = genre === "" ? {} : { genre };
    const primary = searchAddress(params, page);
    let result = parseListing(page, primary, params, false);
    if (result.items.length === 0 && page === 1) {
      host.log("Hanime1 分类 " + label + " 首次取到 0 条，跳过中转缓存重试");
      const fresh = parseListing(page, primary, params, true);
      if (fresh.items.length > 0) {
        result = fresh;
      }
    }
    if (result.items.length === 0 && requested !== "" && page === 1) {
      const candidates = genreCandidates(requested);
      for (let index = 0; index < candidates.length; index++) {
        host.log("Hanime1 分类 " + label + " 无内容，改用相近分类 " + candidates[index]);
        const candidate = { genre: candidates[index] };
        const attempt = parseListing(page, searchAddress(candidate, page), candidate, false);
        if (attempt.items.length > 0) {
          rememberGenreMap(requested, candidates[index]);
          result = attempt;
          break;
        }
      }
    }
    if (result.items.length === 0 && genre !== "" && page === 1) {
      const href = genreHref(genre);
      const address = href ? withPage(href, page) : "";
      if (address && address !== primary) {
        host.log("Hanime1 分类 " + label + " 无内容，改用站点链接重试");
        const retry = parseListing(page, address, params, false);
        if (retry.items.length > 0) {
          result = retry;
        }
      }
    }
    if (result.items.length === 0) {
      result.warning = "Hanime1 分类「" + (requested || "全部") + "」取到 0 条（" +
        (cachedMode() === "relay" ? "中转" : "直连") + "）：" + primary;
    }
    host.log("Hanime1 分类 " + label + " 第 " + page + " 页：" + result.items.length + " 条");
    return result;
  } catch (error) {
    host.log("Hanime1 分类 " + label + " 失败：" + clean(error && error.message ? error.message : error));
    throw error;
  }
}

function search(page, query) {
  const keyword = clean(query);
  if (!keyword) {
    return { items: [], hasMore: false };
  }
  if (keyword.length > 200 || /[\x00-\x1f\x7f]/.test(keyword)) {
    throw new Error("Hanime1 搜索词无效");
  }
  return listing(page, { query: keyword });
}

function detailPage(id) {
  const root = loadPage(watchUrl(id), true);
  const metadata = {};
  for (const node of select(root, (entry) => entry.tag === "meta")) {
    const key = attr(node, "property") || attr(node, "name");
    if (key.startsWith("og:")) {
      metadata[key] = attr(node, "content");
    }
  }
  if (videoId(metadata["og:url"]) !== id) {
    throw new Error("Hanime1 详情与请求的视频 ID 不一致");
  }
  const player = select(root, (node) => node.tag === "video" && attr(node, "id") === "player")[0];
  const titleNode = select(root, (node) => attr(node, "id") === "shareBtn-title")[0];
  const title = clean(text(titleNode)) || clean(metadata["og:title"]);
  if (!player || !title) {
    throw new Error("Hanime1 详情缺少播放器或标题，请在站点确认访问权限");
  }
  return { player, metadata, title };
}

function detail(sourceId) {
  const page = detailPage(sourceId);
  const cover = coverUrl(page.metadata["og:image"]) || coverUrl(attr(page.player, "poster"));
  return {
    drama: drama(sourceId, page.title, cover, clean(page.metadata["og:description"])),
    chapters: [{
      id: host.chapterId(sourceId, "1"), source: host.source, title: "正片", currentEpisode: 1,
      videoUrl: watchUrl(sourceId), referer: siteBaseUrl + "/",
    }],
  };
}

function resolveMedia(task) {
  const prefix = host.source + ":";
  const id = typeof task.dramaId === "string" && task.dramaId.startsWith(prefix) ? task.dramaId.slice(prefix.length) : "";
  if (!numericId(id) || !task.chapter || videoId(task.chapter.videoUrl) !== id) {
    throw new Error("Hanime1 播放任务与视频 ID 不一致，请重新获取详情");
  }
  const page = detailPage(id);
  const seconds = Number(page.metadata["og:video:duration"]);
  const durationMs = Number.isFinite(seconds) && seconds > 0 && seconds <= 86400 ? Math.round(seconds * 1000) : 0;
  const variants = [];
  const seen = new Set();
  for (const source of select(page.player, (node) => node.tag === "source")) {
    const parsed = httpUrl(attr(source, "src"));
    if (!parsed || parsed.scheme !== "https" || parsed.hostname.toLowerCase() !== "vdownload.hembed.com" ||
      (parsed.port && parsed.port !== "443") || attr(source, "type").toLowerCase() !== "video/mp4" || !/\.mp4$/i.test(parsed.path) || seen.has(parsed.href)) {
      continue;
    }
    const size = attr(source, "size");
    const quality = /^[1-9][0-9]{1,3}$/.test(size) ? Number(size) : 0;
    seen.add(parsed.href);
    variants.push({ url: parsed.href, referer: watchUrl(id), quality, durationMs });
  }
  if (variants.length === 0) {
    throw new Error("Hanime1 未返回支持的 MP4 地址，请确认访问权限或媒体域名是否变化");
  }
  variants.sort((left, right) => right.quality - left.quality);
  return Object.assign({}, variants[0], { variants });
}

module.exports = { validCategory, categories, catalogPage, search, detail, resolveMedia };
