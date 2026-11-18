// 91 短剧（91crdjai.com）：SSR 页面 + 同源 JSON 接口，没有 edge 桥。
//
// 全部：GET /api/videos?page={n}&size=20          -> data.items + data.pagination
// 搜索：GET /api/search?q={kw}&page={n}&size=20
// 分类：GET /{channel}/page/{n}/                   -> SSR 卡片
// 详情：GET /api/videos/{id}
// 分集：GET /duanju/{id}/1/ 会 301 到真实分集页，页面里 <script id="playInitialData">
//       给出完整 eps 数组与 playBase
// 播放：POST /api/videos/{id}/episodes/{n}/playback，body {}，-> data.streams.main

var SITE = "https://91crdjai.com";
var UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
var CHANNEL = "91短剧";
var PAGE_SIZE = 20;
var HTML_PAGE_SIZE = 22;
var MAX_PAGE = 10000;
var MAX_EPISODES = 2000;

var CATEGORIES = [
  { id: "duanju", name: "短剧" },
  { id: "manju", name: "漫剧" },
  { id: "zhenrenju", name: "真人剧" },
  { id: "shipin", name: "视频" },
];

var RE_ID = /^[1-9][0-9]{0,11}$/;
var RE_CARD = /<a\b([^>]*\bclass="[^"]*\bcard\b[^"]*"[^>]*)>([\s\S]*?)<\/a>/gi;
var RE_CARD_HREF = /href="[^"]*\/(duanju|manju|zhenrenju|shipin)\/(\d+)-[^"]*\/"/i;
var RE_CARD_COVER = /data-src="([^"]+)"/i;
var RE_CARD_TITLE = /<h3[^>]*>([\s\S]*?)<\/h3>/i;
var RE_CARD_FLAG = /<span class="eps-flag">([\s\S]*?)<\/span>/i;
var RE_CARD_SCORE = /<span class="score">([\s\S]*?)<\/span>/i;
var RE_EP_COUNT = /(\d+)\s*集/;
var RE_SCORE = /[0-9]+(?:\.[0-9]+)?/;
var RE_PAGE_LINK = /href="[^"]*\/page\/(\d+)\/"/gi;
var RE_PLAY_DATA = /<script[^>]*id="playInitialData"[^>]*>([\s\S]*?)<\/script>/i;
var RE_EP_GRID = /<div class="ep-grid"[^>]*>([\s\S]*?)<\/div>/gi;
var RE_EP_LINK = /href="([^"]*\/(\d+)\/)"/gi;
var RE_HTML_TAG = /<[^>]+>/g;
var RE_SPACES = /\s+/g;

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
  raw = raw.replace(/\u3000/g, " ").replace(/\u00a0/g, " ");
  return raw.replace(RE_SPACES, " ").replace(/^\s+|\s+$/g, "");
}

function clip(text, limit) {
  var value = String(text === null || text === undefined ? "" : text);
  return value.length > limit ? value.slice(0, limit) : value;
}

function absUrl(raw) {
  var value = String(raw || "").replace(/^\s+|\s+$/g, "");
  value = unescapeHtml(value);
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

function validCategory(category) {
  var value = String(category || "").replace(/^\s+|\s+$/g, "");
  if (value === "") return true;
  for (var index = 0; index < CATEGORIES.length; index++) {
    if (CATEGORIES[index].id === value) return true;
  }
  return false;
}

function categoryName(category) {
  for (var index = 0; index < CATEGORIES.length; index++) {
    if (CATEGORIES[index].id === category) return CATEGORIES[index].name;
  }
  return CHANNEL;
}

function textGet(path) {
  var address = path.indexOf("http") === 0 ? path : SITE + path;
  var response = host.fetchText({ url: address, referer: SITE + "/", userAgent: UA });
  return response && response.body ? response.body : "";
}

function postJson(path) {
  var address = path.indexOf("http") === 0 ? path : SITE + path;
  var response = host.fetch({
    method: "POST",
    url: address,
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/plain, */*",
      Origin: SITE,
      Referer: SITE + "/",
      "User-Agent": UA,
    },
    body: "{}",
    timeoutMs: 25000,
  });
  return response && response.body ? response.body : "";
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
  if (!drama.categoryName) drama.categoryName = CHANNEL;
  return drama;
}

function normalizeTags(raw) {
  var tags = [];
  var seen = {};
  if (!(raw instanceof Array)) return tags;
  for (var index = 0; index < raw.length; index++) {
    var tag = clip(clean(raw[index]), 16);
    if (tag === "" || seen[tag] || tags.length >= 8) continue;
    seen[tag] = true;
    tags.push(tag);
  }
  return tags;
}

function parseItems(data, label) {
  var items = [];
  var seen = {};
  if (!data || !(data.items instanceof Array)) return items;
  for (var index = 0; index < data.items.length; index++) {
    var entry = data.items[index] || {};
    var id = String(entry.id === null || entry.id === undefined ? "" : entry.id).replace(/^\s+|\s+$/g, "");
    var title = clip(clean(entry.title), 512);
    if (!validId(id) || title === "" || seen[id]) continue;
    seen[id] = true;
    var extra = { categoryName: label || CHANNEL };
    var tags = normalizeTags(entry.tags);
    if (tags.length > 0) extra.tags = tags;
    items.push(makeDrama(id, title, absUrl(entry.cover), extra));
  }
  return items;
}

function parseCards(body, label) {
  var items = [];
  var seen = {};
  RE_CARD.lastIndex = 0;
  var match;
  while ((match = RE_CARD.exec(body)) !== null) {
    var href = RE_CARD_HREF.exec(match[1]);
    if (!href) continue;
    var id = href[2];
    if (!validId(id) || seen[id]) continue;
    var titleMatch = RE_CARD_TITLE.exec(match[2]);
    var title = titleMatch ? clip(clean(titleMatch[1]), 512) : "";
    if (title === "") continue;
    seen[id] = true;
    var coverMatch = RE_CARD_COVER.exec(match[2]);
    var extra = { categoryName: label || CHANNEL };
    var flagMatch = RE_CARD_FLAG.exec(match[2]);
    if (flagMatch) {
      var countMatch = RE_EP_COUNT.exec(clean(flagMatch[1]));
      if (countMatch) {
        var count = asNumber(countMatch[1], 0);
        if (count > 0) {
          extra.episodeCount = count;
          extra.totalEpisode = count;
        }
      }
    }
    var scoreMatch = RE_CARD_SCORE.exec(match[2]);
    if (scoreMatch) {
      var score = RE_SCORE.exec(clean(scoreMatch[1]));
      if (score) extra.score = score[0];
    }
    items.push(makeDrama(id, title, coverMatch ? absUrl(coverMatch[1]) : "", extra));
  }
  return items;
}

function lastPage(body) {
  var last = 0;
  RE_PAGE_LINK.lastIndex = 0;
  var match;
  while ((match = RE_PAGE_LINK.exec(body)) !== null) {
    var page = asNumber(match[1], 0);
    if (page > last && page <= MAX_PAGE) last = page;
  }
  return last;
}

function listPath(category, page) {
  if (page > 1) return "/" + category + "/page/" + page + "/";
  return "/" + category + "/";
}

function makeChapter(sourceId, playBase, number) {
  var episode = String(number);
  var base = String(playBase || "").replace(/^\s+|\s+$/g, "").replace(/^\/+|\/+$/g, "");
  if (base === "" || base.indexOf("/") < 0) base = "duanju/" + sourceId;
  return {
    id: host.chapterId(sourceId, episode),
    source: host.source,
    title: "第" + number + "集",
    currentEpisode: number,
    videoUrl: "crdj-play://" + episode,
    pageUrl: SITE + "/" + base + "/" + episode + "/",
    referer: SITE + "/",
  };
}

function sortChapters(chapters) {
  chapters.sort(function (left, right) {
    return left.currentEpisode - right.currentEpisode;
  });
  return chapters;
}

function playChapters(body, sourceId) {
  var match = RE_PLAY_DATA.exec(body);
  if (!match) return null;
  var data = null;
  try {
    data = JSON.parse(match[1].replace(/^\s+|\s+$/g, ""));
  } catch (error) {
    return null;
  }
  if (!data || !(data.eps instanceof Array)) return null;
  var chapters = [];
  var seen = {};
  for (var index = 0; index < data.eps.length; index++) {
    var episode = data.eps[index] || {};
    var number = asNumber(episode.n, 0);
    if (number < 1 || number > MAX_EPISODES) number = index + 1;
    if (seen[number]) continue;
    seen[number] = true;
    var chapter = makeChapter(sourceId, data.playBase, number);
    var title = clip(clean(episode.title), 128);
    if (title !== "" && title.indexOf("第") !== 0) chapter.title = title;
    chapters.push(chapter);
  }
  return { chapters: sortChapters(chapters), data: data };
}

function detailChapters(body, sourceId) {
  var chapters = [];
  var seen = {};
  RE_EP_GRID.lastIndex = 0;
  var grid;
  while ((grid = RE_EP_GRID.exec(body)) !== null) {
    RE_EP_LINK.lastIndex = 0;
    var link;
    while ((link = RE_EP_LINK.exec(grid[1])) !== null) {
      var number = asNumber(link[2], 0);
      if (number < 1 || number > MAX_EPISODES || seen[number]) continue;
      seen[number] = true;
      chapters.push(makeChapter(sourceId, "", number));
    }
  }
  return sortChapters(chapters);
}

function parseEnvelope(body, label) {
  var envelope = null;
  try {
    envelope = JSON.parse(body);
  } catch (error) {
    throw new Error(label + "接口返回格式无效");
  }
  if (!envelope) throw new Error(label + "接口返回格式无效");
  if (envelope.status !== 1 && envelope.status !== 0) {
    throw new Error(label + "接口返回失败：" + (clean(envelope.msg) || "未知错误"));
  }
  return envelope;
}

module.exports = {
  validCategory: validCategory,

  categories: function () {
    return CATEGORIES.slice();
  },

  catalogPage: function (page, category) {
    var index = asNumber(page, 0);
    if (index < 1 || index > MAX_PAGE) throw new Error("91短剧目录页码无效");
    var value = String(category || "").replace(/^\s+|\s+$/g, "");
    if (!validCategory(value)) throw new Error("91短剧内容分类无效");

    if (value === "") {
      var envelope = parseEnvelope(textGet("/api/videos?page=" + index + "&size=" + PAGE_SIZE), "91短剧");
      var data = envelope.data || {};
      var items = parseItems(data, CHANNEL);
      if (items.length === 0) return { items: [], hasMore: false };
      var more = items.length >= PAGE_SIZE;
      var pages = data.pagination ? asNumber(data.pagination.pages, 0) : 0;
      if (pages > 0 && index >= pages) more = false;
      return { items: items, hasMore: more };
    }

    var body = textGet(listPath(value, index));
    var cards = parseCards(body, categoryName(value));
    if (cards.length === 0) return { items: [], hasMore: false };
    var hasMore = cards.length >= HTML_PAGE_SIZE;
    var last = lastPage(body);
    if (last > 0 && index >= last) hasMore = false;
    return { items: cards, hasMore: hasMore };
  },

  search: function (page, query) {
    var index = asNumber(page, 0);
    var keyword = String(query || "").replace(/^\s+|\s+$/g, "");
    if (keyword === "") return { items: [], hasMore: false };
    if (index < 1 || index > MAX_PAGE) throw new Error("91短剧搜索页码无效");
    if (keyword.length > 40) throw new Error("91短剧搜索关键词无效");
    var envelope = parseEnvelope(
      textGet("/api/search?q=" + encodeURIComponent(keyword) + "&page=" + index + "&size=" + PAGE_SIZE),
      "91短剧"
    );
    var data = envelope.data || {};
    var items = parseItems(data, CHANNEL);
    if (items.length === 0) return { items: [], hasMore: false };
    var pages = data.pagination ? asNumber(data.pagination.pages, 0) : 0;
    return { items: items, hasMore: pages > 0 ? index < pages : items.length >= PAGE_SIZE };
  },

  detail: function (sourceId) {
    var id = String(sourceId || "").replace(/^\s+|\s+$/g, "");
    if (!validId(id)) throw new Error("91短剧剧集标识无效");

    var meta = {};
    try {
      var envelope = parseEnvelope(textGet("/api/videos/" + encodeURIComponent(id)), "91短剧");
      if (envelope.data && typeof envelope.data === "object") meta = envelope.data;
    } catch (error) {}

    var play = null;
    var chapters = [];
    try {
      var body = textGet("/duanju/" + encodeURIComponent(id) + "/1/");
      play = playChapters(body, id);
      if (play) chapters = play.chapters;
    } catch (error) {}
    if (chapters.length === 0) {
      try {
        chapters = detailChapters(textGet("/duanju/" + encodeURIComponent(id) + "/"), id);
      } catch (error) {}
    }
    if (chapters.length === 0) chapters = [makeChapter(id, "", 1)];

    var title = clip(clean(meta.title), 512);
    if (title === "" && play && play.data) title = clip(clean(play.data.title), 512);
    if (title === "") throw new Error("91短剧详情缺少剧集名称");

    var cover = absUrl(meta.cover);
    if (cover === "" && play && play.data) cover = absUrl(play.data.poster);
    var description = clean(meta.description);
    if (description === "" && play && play.data) description = clean(play.data.description);

    var label = CHANNEL;
    if (meta.breadcrumb instanceof Array) {
      for (var index = 0; index < meta.breadcrumb.length; index++) {
        var name = clip(clean((meta.breadcrumb[index] || {}).name), 16);
        if (name !== "") {
          label = name;
          break;
        }
      }
    }
    var extra = {
      desc: clip(description, 12000),
      intro: clip(description, 12000),
      episodeCount: chapters.length,
      totalEpisode: chapters.length,
      categoryName: label,
    };
    var tags = normalizeTags(meta.tags);
    if (tags.length > 0) extra.tags = tags;
    return { drama: makeDrama(id, title, cover, extra), chapters: chapters };
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
    if (!validId(sourceId)) throw new Error("91短剧播放信息无效，请刷新详情");
    if (number < 1 || number > MAX_EPISODES) throw new Error("91短剧播放分集信息无效，请刷新详情");

    var envelope = parseEnvelope(
      postJson("/api/videos/" + encodeURIComponent(sourceId) + "/episodes/" + number + "/playback"),
      "91短剧"
    );
    var data = envelope.data || {};
    var streams = data.streams || {};
    var method = String(data.manifest_method || "").replace(/^\s+|\s+$/g, "");
    if (method !== "" && method.toUpperCase() !== "GET") {
      throw new Error("91短剧播放接口返回了不支持的播放方式");
    }
    var pageUrl = String(chapter.pageUrl || "").replace(/^\s+|\s+$/g, "");
    if (pageUrl === "") pageUrl = SITE + "/duanju/" + sourceId + "/" + number + "/";
    var address = absUrl(streams.main || data.src || streams.preview);
    if (!/^https?:\/\//i.test(address)) throw new Error("91短剧该集暂无播放地址");
    var media = host.prepareWebMedia({ url: address, referer: pageUrl }, CHANNEL);
    var hevc = absUrl(streams.hevc);
    if (/^https?:\/\//i.test(hevc) && hevc !== address) {
      media.variants = [{ url: hevc, referer: pageUrl, quality: 1080 }];
    }
    media.referer = pageUrl;
    return media;
  },
};
