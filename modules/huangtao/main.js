// 黄桃（aihuangdou.com）：SSR 列表页 + 同源 JSON 接口，所有 /api/* 走站点 edge 桥。
//
// 列表：/ai-duanju/、/tag/{slug}/，翻页走路径 /{path}/{n}/，每页 22 部，页脚「第 X/Y 页」。
// 搜索：edge GET /api/search?q=&page=&size=20 -> data.items + data.pagination.pages
// 详情：edge GET /api/videos/{id}；分集直连 /videos/{id}/episodes（不带 /api 前缀，也不走 edge）
// 播放：edge POST /api/videos/{id}/episodes/{n}/playback，body {} -> data.streams.main
//
// edge 桥：POST /api/edge/request，信封 {method, path, body(base64), content_type}。

var SITE = "https://aihuangdou.com";
var UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
var CHANNEL = "黄桃";
var DEFAULT_CHANNEL = "ai-duanju";
var SEARCH_PAGE_SIZE = 20;
var MAX_PAGE = 500;
var MAX_EPISODES = 2000;

var CHANNELS = [
  { id: "c:ai-duanju", name: "AI 短剧" },
  { id: "c:ai-manju", name: "AI 漫剧" },
  { id: "c:ai-mogai", name: "AI 魔改" },
  { id: "c:ai-meinv", name: "AI 美女" },
];

var RE_CARD = /<article class="drama-card"[^>]*>([\s\S]*?)<\/article>/gi;
var RE_CARD_ID = /href="\/drama\/(\d+)\/"/i;
var RE_CARD_NAME = /data-track-item-name="([^"]*)"/i;
var RE_CARD_ALT = /<img[^>]+alt="《([^》]*)》封面"/i;
var RE_CARD_COVER = /data-src="([^"]+)"/i;
var RE_CARD_SCORE = /<em class="card-score">([\s\S]*?)<\/em>/i;
var RE_CARD_FLAG = /<span class="eps-flag">([\s\S]*?)<\/span>/i;
var RE_CARD_TITLE = /<h3[^>]*>([\s\S]*?)<\/h3>/i;
var RE_CARD_DESC = /<p class="card-desc">([\s\S]*?)<\/p>/i;
var RE_CARD_META = /<\/h3><\/a>\s*<p>([\s\S]*?)<\/p>/i;
var RE_PAGE_TOTAL = /第\s*\d+\s*\/\s*(\d+)\s*页/;
var RE_PLAY_DATA = /<script id="ninePlayData" type="application\/json">([\s\S]*?)<\/script>/i;
var RE_HTML_TAG = /<[^>]+>/g;
var RE_ID = /^[1-9][0-9]{0,15}$/;
var RE_SLUG = /^[a-z0-9][a-z0-9\-]{0,63}$/;
var RE_HEAT = /[0-9]+(?:\.[0-9]+)?\s*[wW万]?/;

function unescapeHtml(text) {
  return String(text)
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, function (_, code) {
      return String.fromCharCode(parseInt(code, 10));
    });
}

function clean(text) {
  if (text === null || text === undefined) return "";
  var raw = unescapeHtml(String(text).replace(RE_HTML_TAG, " "));
  raw = raw.replace(/\u3000/g, " ");
  return raw.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
}

function clip(text, limit) {
  var value = String(text === null || text === undefined ? "" : text);
  return value.length > limit ? value.slice(0, limit) : value;
}

function absUrl(raw) {
  var value = String(raw || "").replace(/^\s+|\s+$/g, "");
  if (value === "") return "";
  if (value.indexOf("//") === 0) return "https:" + value;
  if (/^https?:\/\//i.test(value)) return value;
  if (value.charAt(0) === "/") return SITE + value;
  return SITE + "/" + value;
}

function asNumber(value, fallback) {
  var parsed = parseInt(String(value), 10);
  return isNaN(parsed) ? fallback : parsed;
}

function validId(id) {
  return RE_ID.test(String(id || "").replace(/^\s+|\s+$/g, ""));
}

function categoryParts(category) {
  var value = String(category || "").replace(/^\s+|\s+$/g, "");
  if (value === "") return { kind: "default", value: "" };
  if (value.indexOf("c:") === 0) {
    for (var index = 0; index < CHANNELS.length; index++) {
      if (CHANNELS[index].id === value) return { kind: "channel", value: value.slice(2) };
    }
    return null;
  }
  if (value.indexOf("t:") === 0) {
    var slug = value.slice(2);
    if (RE_SLUG.test(slug)) return { kind: "tag", value: slug };
    return null;
  }
  return null;
}

function validCategory(category) {
  return categoryParts(category) !== null;
}

function listPath(category, page) {
  var parts = categoryParts(category) || { kind: "default", value: "" };
  var base = "/" + DEFAULT_CHANNEL + "/";
  if (parts.kind === "channel") base = "/" + parts.value + "/";
  else if (parts.kind === "tag") base = "/tag/" + parts.value + "/";
  if (page > 1) return base + page + "/";
  return base;
}

function textGet(path) {
  var address = path.indexOf("http") === 0 ? path : SITE + path;
  var response = host.fetchText({ url: address, referer: SITE + "/", userAgent: UA });
  return response && response.body ? response.body : "";
}

function edge(method, path, payload) {
  var target = path.charAt(0) === "/" ? path : "/" + path;
  var envelope = { method: method, path: target, body: "", content_type: "" };
  if (payload !== null && payload !== undefined) {
    envelope.body = host.base64Encode(JSON.stringify(payload));
    envelope.content_type = "application/json";
  }
  var response = host.fetch({
    method: "POST",
    url: SITE + "/api/edge/request",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/plain, */*",
      Origin: SITE,
      Referer: SITE + "/",
      "User-Agent": UA,
    },
    body: JSON.stringify(envelope),
    timeoutMs: 30000,
  });
  var reply = null;
  try {
    reply = JSON.parse(response && response.body ? response.body : "");
  } catch (error) {
    throw new Error("黄桃接口返回格式无效");
  }
  if (!reply) throw new Error("黄桃接口返回格式无效");
  if (reply.status !== 1) throw new Error("黄桃接口返回失败：" + (clean(reply.msg) || "未知错误"));
  return reply.data;
}

function heatOf(meta) {
  var value = String(meta || "").replace(/^\s+|\s+$/g, "");
  if (value === "") return "";
  var index = value.indexOf("热度");
  if (index < 0) return "";
  var segment = value.slice(0, index);
  var cut = segment.lastIndexOf("·");
  if (cut >= 0) segment = segment.slice(cut + 1);
  var match = RE_HEAT.exec(segment);
  return match ? String(match[0]).replace(/^\s+|\s+$/g, "") : "";
}

function makeDrama(sourceId, title, cover, extra) {
  var drama = {
    id: host.dramaId(sourceId),
    source: host.source,
    sourceId: sourceId,
    title: title,
    name: title,
    channelName: CHANNEL,
  };
  if (cover) {
    drama.cover = cover;
    drama.coverUrl = cover;
  }
  if (extra) {
    for (var key in extra) {
      if (Object.prototype.hasOwnProperty.call(extra, key) && extra[key] !== "" && extra[key] !== null) {
        drama[key] = extra[key];
      }
    }
  }
  if (!drama.categoryName) drama.categoryName = "AI 短剧";
  return drama;
}

function parseCards(body) {
  var items = [];
  var seen = {};
  RE_CARD.lastIndex = 0;
  var match;
  while ((match = RE_CARD.exec(body)) !== null) {
    var chunk = match[1];
    var idMatch = RE_CARD_ID.exec(chunk);
    if (!idMatch || !validId(idMatch[1]) || seen[idMatch[1]]) continue;
    var sourceId = idMatch[1];
    var title = "";
    var nameMatch = RE_CARD_NAME.exec(chunk);
    if (nameMatch) title = clean(nameMatch[1]);
    if (title === "") {
      var titleMatch = RE_CARD_TITLE.exec(chunk);
      if (titleMatch) title = clean(titleMatch[1]);
    }
    if (title === "") {
      var altMatch = RE_CARD_ALT.exec(chunk);
      if (altMatch) title = clean(altMatch[1]);
    }
    if (title === "") continue;
    seen[sourceId] = true;
    var coverMatch = RE_CARD_COVER.exec(chunk);
    var remark = "";
    var flagMatch = RE_CARD_FLAG.exec(chunk);
    if (flagMatch) remark = clip(clean(flagMatch[1]), 64);
    var score = "";
    var scoreMatch = RE_CARD_SCORE.exec(chunk);
    if (scoreMatch) score = clip(clean(scoreMatch[1]).replace(/\s+分/g, "分"), 16);
    var meta = "";
    var metaMatch = RE_CARD_META.exec(chunk);
    if (metaMatch) meta = clean(metaMatch[1]);
    var description = "";
    var descMatch = RE_CARD_DESC.exec(chunk);
    if (descMatch) description = clip(clean(descMatch[1]), 4000);
    var categoryName = "AI 短剧";
    if (meta !== "") {
      var segments = meta.split("·");
      for (var index = segments.length - 1; index >= 0; index--) {
        var segment = String(segments[index]).replace(/^\s+|\s+$/g, "");
        if (segment === "" || segment.indexOf("热度") >= 0 || segment.indexOf("AI") === 0) continue;
        categoryName = clip(segment, 24);
        break;
      }
    }
    items.push(
      makeDrama(sourceId, clip(title, 512), coverMatch ? absUrl(coverMatch[1]) : "", {
        desc: description,
        intro: description,
        categoryName: categoryName,
        remark: remark,
        score: score,
        heat: heatOf(meta),
      })
    );
    if (items.length >= 200) break;
  }
  return items;
}

function totalPages(body) {
  var match = RE_PAGE_TOTAL.exec(body);
  if (!match) return 0;
  var total = asNumber(match[1], 0);
  return total >= 0 && total <= MAX_PAGE ? total : 0;
}

function chapterOf(sourceId, number) {
  var episode = String(number);
  return {
    id: host.chapterId(sourceId, episode),
    source: host.source,
    title: "第" + number + "集",
    currentEpisode: number,
    videoUrl: "huangtao-play://" + episode,
    pageUrl: SITE + "/video/" + sourceId + "/" + episode + "/",
    referer: SITE + "/",
  };
}

function buildChapters(eps, total, sourceId) {
  var chapters = [];
  for (var index = 0; index < eps.length; index++) {
    var episode = eps[index] || {};
    var number = asNumber(episode.n, 0);
    if (number < 1 || number > MAX_EPISODES) number = index + 1;
    var title = clip(clean(episode.title || episode.fact || episode.heading), 128);
    var chapter = chapterOf(sourceId, number);
    if (title !== "") chapter.title = title;
    chapters.push(chapter);
  }
  if (chapters.length === 0 && total > 0 && total <= MAX_EPISODES) {
    for (var number = 1; number <= total; number++) chapters.push(chapterOf(sourceId, number));
  }
  chapters.sort(function (left, right) {
    return left.currentEpisode - right.currentEpisode;
  });
  return chapters;
}

function pageEpisodes(sourceId) {
  var body = textGet("/video/" + encodeURIComponent(sourceId) + "/");
  var match = RE_PLAY_DATA.exec(body);
  if (!match) return null;
  var data = null;
  try {
    data = JSON.parse(unescapeHtml(match[1]));
  } catch (error) {
    return null;
  }
  if (!data || !(data.eps instanceof Array) || data.eps.length === 0) return null;
  var chapters = buildChapters(data.eps, asNumber(data.epTotal, 0), sourceId);
  if (chapters.length === 0) return null;
  return { total: Math.max(asNumber(data.epTotal, 0), chapters.length), chapters: chapters };
}

function fetchEpisodes(sourceId) {
  var total = 0;
  var eps = [];
  try {
    var body = textGet("/videos/" + encodeURIComponent(sourceId) + "/episodes");
    var envelope = JSON.parse(body);
    if (envelope && envelope.data) {
      total = asNumber(envelope.data.epTotal, 0);
      if (envelope.data.eps instanceof Array) eps = envelope.data.eps;
    }
  } catch (error) {}
  var chapters = buildChapters(eps, total, sourceId);
  if (chapters.length === 0) {
    var fallback = pageEpisodes(sourceId);
    if (fallback) return fallback;
    return null;
  }
  return { total: Math.max(total, chapters.length), chapters: chapters };
}

module.exports = {
  validCategory: validCategory,

  categories: function () {
    var data = edge("GET", "/api/tags", null);
    var categories = CHANNELS.slice();
    var tags = 0;
    var groups = data && data.categories instanceof Array ? data.categories : [];
    for (var index = 0; index < groups.length; index++) {
      var group = groups[index] || {};
      var entries = group.tags instanceof Array ? group.tags : [];
      for (var inner = 0; inner < entries.length; inner++) {
        var tag = entries[inner] || {};
        var slug = String(tag.slug || "").replace(/^\s+|\s+$/g, "");
        if (!RE_SLUG.test(slug)) continue;
        var name = String(tag.name || "").replace(/^\s+|\s+$/g, "");
        var groupName = String(group.name || "").replace(/^\s+|\s+$/g, "");
        if (groupName !== "" && name !== "") name = groupName + " · " + name;
        if (name === "") name = slug;
        categories.push({ id: "t:" + slug, name: clip(name, 24) });
        tags++;
        if (categories.length >= 96) break;
      }
      if (categories.length >= 96) break;
    }
    if (tags === 0 && groups.length === 0) throw new Error("黄桃暂未返回内容分类");
    return categories;
  },

  catalogPage: function (page, category) {
    var index = asNumber(page, 0);
    if (index < 1 || index > MAX_PAGE) throw new Error("黄桃目录页码无效");
    if (!validCategory(category)) throw new Error("黄桃内容分类无效");
    var body = textGet(listPath(category, index));
    var items = parseCards(body);
    if (items.length === 0) return { items: [], hasMore: false };
    var pages = totalPages(body);
    if (pages > 0) return { items: items, hasMore: index < pages };
    return { items: items, hasMore: items.length >= 20 };
  },

  search: function (page, query) {
    var index = asNumber(page, 0);
    var keyword = String(query || "").replace(/^\s+|\s+$/g, "");
    if (keyword === "") return { items: [], hasMore: false };
    if (index < 1 || index > MAX_PAGE) throw new Error("黄桃搜索页码无效");
    if (keyword.length > 64) throw new Error("黄桃搜索关键词无效");
    var data = edge(
      "GET",
      "/api/search?q=" + encodeURIComponent(keyword) + "&page=" + index + "&size=" + SEARCH_PAGE_SIZE,
      null
    );
    var rows = data && data.items instanceof Array ? data.items : [];
    var items = [];
    var seen = {};
    for (var row = 0; row < rows.length; row++) {
      var entry = rows[row] || {};
      var sourceId = String(entry.id !== undefined && entry.id !== null ? entry.id : entry.video_id || "")
        .replace(/^\s+|\s+$/g, "");
      if (!validId(sourceId) || seen[sourceId]) continue;
      var title = clip(clean(entry.title || entry.name), 512);
      if (title === "") continue;
      seen[sourceId] = true;
      var description = clip(clean(entry.description || entry.intro), 4000);
      var onlineDate = "";
      var created = String(entry.created_at || "").replace(/^\s+|\s+$/g, "");
      if (created.length >= 10) onlineDate = created.slice(0, 10);
      var tags = entry.tags instanceof Array ? entry.tags : [];
      var extra = {
        desc: description,
        intro: description,
        categoryName: "AI 短剧",
        heat: String(entry.hot === undefined || entry.hot === null ? "" : entry.hot),
        views: String(entry.play_count === undefined || entry.play_count === null ? "" : entry.play_count),
        onlineDate: onlineDate,
      };
      if (tags.length > 0) extra.tags = tags;
      items.push(makeDrama(sourceId, title, absUrl(entry.cover || entry.poster), extra));
    }
    var pages = data && data.pagination ? asNumber(data.pagination.pages, 0) : 0;
    return { items: items, hasMore: pages > 0 ? index < pages : false };
  },

  detail: function (sourceId) {
    var id = String(sourceId || "").replace(/^\s+|\s+$/g, "");
    if (!validId(id)) throw new Error("黄桃剧集标识无效");
    var row = edge("GET", "/api/videos/" + encodeURIComponent(id), null) || {};
    var returned = String(row.id === undefined || row.id === null ? "" : row.id).replace(/^\s+|\s+$/g, "");
    if (returned !== "" && returned !== id) throw new Error("黄桃详情与请求剧集不符");

    var title = clip(clean(row.title || row.name), 512);
    if (title === "") throw new Error("黄桃详情缺少剧集名称");
    var description = clip(clean(row.description || row.intro), 12000);
    var cover = absUrl(row.cover || row.poster);
    var label = "AI 短剧";
    if (row.breadcrumb instanceof Array && row.breadcrumb.length > 0) {
      var crumb = clip(clean((row.breadcrumb[0] || {}).name), 32);
      if (crumb !== "") label = crumb;
    }

    var episodes = fetchEpisodes(id);
    if (!episodes) throw new Error("黄桃该剧暂无可播放分集");

    var extra = {
      desc: description,
      intro: description,
      categoryName: label,
      episodeCount: episodes.total,
      totalEpisode: episodes.total,
      remark: "全 " + episodes.total + " 集",
    };
    var tags = row.tags instanceof Array ? row.tags : [];
    if (tags.length > 0) extra.tags = tags;
    var created = String(row.created_at || "").replace(/^\s+|\s+$/g, "");
    if (created.length >= 10) extra.onlineDate = created.slice(0, 10);
    if (row.counts && typeof row.counts === "object") {
      if (row.counts.hot !== undefined && row.counts.hot !== null) extra.heat = String(row.counts.hot);
      var views = row.counts.play !== undefined && row.counts.play !== null ? row.counts.play : row.counts.view;
      if (views === undefined || views === null) views = row.counts.hot;
      if (views !== undefined && views !== null) extra.views = String(views);
    }
    return { drama: makeDrama(id, title, cover, extra), chapters: episodes.chapters };
  },

  resolveMedia: function (task) {
    var chapter = task && task.chapter ? task.chapter : {};
    var dramaId = String((task && task.dramaId) || host.source + ":");
    var prefix = host.source + ":";
    var rest = dramaId.indexOf(prefix) === 0 ? dramaId.slice(prefix.length) : "";
    var sourceId = rest;
    var number = 0;
    var separator = rest.indexOf(":");
    if (separator > 0) {
      sourceId = rest.slice(0, separator);
      number = asNumber(rest.slice(separator + 1), 0);
    } else if (chapter.id) {
      var chapterId = String(chapter.id);
      var cut = chapterId.lastIndexOf(":");
      if (cut > 0) number = asNumber(chapterId.slice(cut + 1), 0);
    }
    if (!validId(sourceId)) throw new Error("黄桃播放信息无效，请刷新详情");
    if (number < 1 || number > MAX_EPISODES) throw new Error("黄桃播放分集信息无效，请刷新详情");

    var data =
      edge(
        "POST",
        "/api/videos/" + encodeURIComponent(sourceId) + "/episodes/" + number + "/playback",
        {}
      ) || {};
    var method = String(data.manifest_method || "").replace(/^\s+|\s+$/g, "");
    if (method !== "" && method.toUpperCase() !== "GET") throw new Error("黄桃播放接口返回了不支持的播放方式");
    var streams = data.streams || {};
    var pageUrl = SITE + "/video/" + sourceId + "/" + number + "/";
    var address = absUrl(streams.main || data.src);
    if (!/^https?:\/\//i.test(address)) throw new Error("黄桃该集暂无播放地址");
    var media = host.prepareWebMedia({ url: address, referer: pageUrl }, CHANNEL);
    var hevc = absUrl(streams.hevc);
    if (/^https?:\/\//i.test(hevc) && hevc !== address) {
      media.variants = [{ url: hevc, referer: pageUrl, quality: 1080 }];
    }
    media.referer = pageUrl;
    return media;
  },
};
