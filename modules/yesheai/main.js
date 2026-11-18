// 夜社（yesheai.com）：苹果 CMS 风格，没有加密接口。
//
// 列表：/filter/{type}.html，翻页 /filter/{type}/page/{n}.html，每页 30 条。
// 搜索：/vod/search/wd/{关键词}.html，翻页加 /page/{n}.html。
// 详情：/detail/{id}.html，分集是 data-episode + href="/play/{id}/1/{n}.html"。
// 播放：/play/{id}/1/{n}.html 里内联 var player_aaaa = {...}，
//       encrypt 为 0 时 url 就是 m3u8 直链，1 是 base64，2 是 base64 后再整体倒序。

var SITE = "https://yesheai.com";
var UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
var CHANNEL = "夜社";
var PAGE_SIZE = 30;
var MAX_PAGE = 10000;
var DEFAULT_TYPE = "6";

var FALLBACK_CATEGORIES = [
  { id: "6", name: "短剧" },
  { id: "1", name: "成人短剧" },
  { id: "3", name: "国产短剧" },
  { id: "4", name: "海外短剧" },
  { id: "7", name: "动漫" },
  { id: "16", name: "AI 漫剧" },
  { id: "20", name: "网剧" },
  { id: "21", name: "电影" },
  { id: "12", name: "综艺" },
];

var RE_ANCHOR = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
var RE_CARD_COVER = /<img[^>]+src="([^"]+)"/i;
var RE_CARD_TYPE = /<div\s+class="type">([\s\S]*?)<\/div>/i;
var RE_CARD_INTRO = /<div\s+class="module-poster-item-intro">([\s\S]*?)<\/div>/i;
var RE_CARD_NAME = /class="module-poster-item-title"[^>]*>([\s\S]*?)</i;
var RE_EP_TEXT = /(\d+)\s*集/;
var RE_DETAIL_H1 = /class="ys-web-detail__info"[\s\S]*?<h1[^>]*>([\s\S]*?)<\/h1>/i;
var RE_DETAIL_PIC = /class="ys-web-detail__poster"[\s\S]*?<img[^>]+src="([^"]+)"/i;
var RE_DETAIL_CATE = /class="ys-web-detail__meta ys-web-detail__cate">([\s\S]*?)<\/div>/i;
var RE_DETAIL_DESC = /<p\s+class="ys-web-detail__desc"[^>]*>([\s\S]*?)<\/p>/i;
var RE_EPISODE = /data-episode="(\d+)"[^>]*href="\/play\/(\d+)\/1\/(\d+)\.html"/gi;
var RE_EPISODE_ALT = /href="\/play\/(\d+)\/1\/(\d+)\.html"[^>]*data-episode="(\d+)"/gi;
var RE_PLAYER = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;?\s*<\/script>/i;
var RE_HTML_TAG = /<[^>]+>/g;
var RE_SPACES = /\s+/g;
var RE_ID = /^[1-9][0-9]{0,11}$/;
var RE_TYPE = /^[1-9][0-9]{0,5}$/;
var RE_NAV_TYPE = /<a\b[^>]*href="\/type\/(\d+)\.html"[^>]*>([\s\S]*?)<\/a>/gi;
var RE_CATE_TAG = /#([^<#]{1,16})/g;
var RE_ATTR = /\b([a-zA-Z:-]+)="([^"]*)"/g;

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

function attrOf(fragment, name) {
  var pattern = new RegExp('\\b' + name + '="([^"]*)"', "i");
  var match = pattern.exec(fragment);
  return match ? match[1] : "";
}

function absUrl(raw) {
  var value = String(raw || "").replace(/^\s+|\s+$/g, "");
  if (value === "") return "";
  if (value.indexOf("//") === 0) return "https:" + value;
  if (/^https?:\/\//i.test(value)) return value;
  if (value.charAt(0) === "/") return SITE + value;
  return SITE + "/" + value;
}

function textGet(path) {
  var address = path.indexOf("http") === 0 ? path : SITE + path;
  var response = host.fetchText({ url: address, referer: SITE + "/", userAgent: UA });
  return response && response.body ? response.body : "";
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
  return value === "" || RE_TYPE.test(value);
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

function listPath(category, page) {
  var type = String(category || "").replace(/^\s+|\s+$/g, "");
  if (!validCategory(type) || type === "") type = DEFAULT_TYPE;
  if (page > 1) return "/filter/" + type + "/page/" + page + ".html";
  return "/filter/" + type + ".html";
}

function searchPath(query, page) {
  var keyword = encodeURIComponent(String(query || "").replace(/^\s+|\s+$/g, ""));
  if (page > 1) return "/vod/search/wd/" + keyword + "/page/" + page + ".html";
  return "/vod/search/wd/" + keyword + ".html";
}

function parseCards(body) {
  var items = [];
  var seen = {};
  RE_ANCHOR.lastIndex = 0;
  var match;
  while ((match = RE_ANCHOR.exec(body)) !== null) {
    var attrs = match[1];
    var chunk = match[2];
    if (attrs.indexOf("module-poster-item") < 0) continue;
    var href = attrOf(attrs, "href");
    if (href.indexOf("/detail/") !== 0 || href.slice(-5) !== ".html") continue;
    var sourceId = href.slice(8, href.length - 5);
    if (!validId(sourceId) || seen[sourceId]) continue;
    var title = clean(attrOf(attrs, "title"));
    if (title === "") {
      var nameMatch = RE_CARD_NAME.exec(chunk);
      if (nameMatch) title = clean(nameMatch[1]);
    }
    if (title === "") {
      var coverMatch = RE_CARD_COVER.exec(chunk);
      if (coverMatch) title = clean(attrOf(coverMatch[0], "alt"));
    }
    if (title === "") continue;
    seen[sourceId] = true;
    var cover = "";
    var imageMatch = RE_CARD_COVER.exec(chunk);
    if (imageMatch) cover = absUrl(imageMatch[1]);
    var categoryName = "";
    var typeMatch = RE_CARD_TYPE.exec(chunk);
    if (typeMatch) categoryName = clip(clean(typeMatch[1]), 24);
    var remark = "";
    var epMatch = RE_EP_TEXT.exec(chunk);
    if (epMatch) remark = "更新至" + epMatch[1] + "集";
    if (remark === "") {
      var introMatch = RE_CARD_INTRO.exec(chunk);
      if (introMatch) remark = clip(clean(introMatch[1]), 60);
    }
    items.push(
      makeDrama(sourceId, clip(title, 512), cover, {
        categoryName: categoryName || CHANNEL,
        remark: remark,
      })
    );
    if (items.length >= 240) break;
  }
  return items;
}

function buildChapters(body, sourceId) {
  var chapters = [];
  var seen = {};
  var add = function (dramaId, episode) {
    var number = asNumber(episode, 0);
    if (number < 1 || number > MAX_PAGE || seen[number]) return;
    if (String(dramaId) !== String(sourceId)) return;
    seen[number] = true;
    chapters.push({
      id: host.chapterId(sourceId, String(episode)),
      source: host.source,
      title: "第" + number + "集",
      currentEpisode: number,
      videoUrl: "yesheai-play://" + episode,
      pageUrl: SITE + "/play/" + sourceId + "/1/" + episode + ".html",
      referer: SITE + "/",
    });
  };
  RE_EPISODE.lastIndex = 0;
  var match;
  while ((match = RE_EPISODE.exec(body)) !== null) add(match[2], match[3]);
  RE_EPISODE_ALT.lastIndex = 0;
  while ((match = RE_EPISODE_ALT.exec(body)) !== null) add(match[1], match[2]);
  chapters.sort(function (left, right) {
    return left.currentEpisode - right.currentEpisode;
  });
  return chapters;
}

function decodeBase64Text(raw) {
  try {
    return host.utf8Decode(host.base64Decode(raw));
  } catch (error) {
    return "";
  }
}

function decodePlayerUrl(raw, encrypt) {
  var value = String(raw || "").replace(/^\s+|\s+$/g, "");
  value = unescapeHtml(value);
  if (value === "" || encrypt === 0) return value;
  if (encrypt === 2) {
    var characters = value.split("");
    value = characters.reverse().join("");
  }
  var decoded = decodeBase64Text(value);
  if (decoded === "") return value;
  decoded = decoded.replace(/^\s+|\s+$/g, "");
  try {
    decoded = decodeURIComponent(decoded.replace(/\+/g, " "));
  } catch (error) {}
  return decoded;
}

module.exports = {
  validCategory: validCategory,

  categories: function () {
    var body = "";
    try {
      body = textGet("/");
    } catch (error) {
      return FALLBACK_CATEGORIES.slice();
    }
    var categories = [];
    var seen = {};
    RE_NAV_TYPE.lastIndex = 0;
    var match;
    while ((match = RE_NAV_TYPE.exec(body)) !== null) {
      var id = match[1];
      var name = clip(clean(match[2]), 16);
      if (!validCategory(id) || name === "" || seen[id]) continue;
      if (name.length > 12 || name.indexOf("更多") >= 0) continue;
      seen[id] = true;
      categories.push({ id: id, name: name });
    }
    if (categories.length === 0) return FALLBACK_CATEGORIES.slice();
    return categories;
  },

  catalogPage: function (page, category) {
    var index = asNumber(page, 0);
    if (index < 1 || index > MAX_PAGE) throw new Error("夜社目录页码无效");
    if (!validCategory(category)) throw new Error("夜社内容分类无效");
    var body = textGet(listPath(category, index));
    var items = parseCards(body);
    if (items.length === 0) return { items: [], hasMore: false };
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  search: function (page, query) {
    var index = asNumber(page, 0);
    var keyword = String(query || "").replace(/^\s+|\s+$/g, "");
    if (keyword === "") return { items: [], hasMore: false };
    if (index < 1 || index > MAX_PAGE) throw new Error("夜社搜索页码无效");
    if (keyword.length > 40) throw new Error("夜社搜索关键词无效");
    var body = textGet(searchPath(keyword, index));
    var items = parseCards(body);
    if (items.length === 0) return { items: [], hasMore: false };
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  detail: function (sourceId) {
    var id = String(sourceId || "").replace(/^\s+|\s+$/g, "");
    if (!validId(id)) throw new Error("夜社剧集标识无效");
    var body = textGet("/detail/" + id + ".html");
    var chapters = buildChapters(body, id);
    if (chapters.length === 0) throw new Error("夜社该剧暂无可播放分集");

    var title = "";
    var h1Match = RE_DETAIL_H1.exec(body);
    if (h1Match) title = clip(clean(h1Match[1]), 512);
    if (title === "") throw new Error("夜社详情缺少剧集名称");

    var cover = "";
    var picMatch = RE_DETAIL_PIC.exec(body);
    if (picMatch) cover = absUrl(picMatch[1]);

    var description = "";
    var descMatch = RE_DETAIL_DESC.exec(body);
    if (descMatch) description = clean(descMatch[1]);

    var tags = [];
    var seenTags = {};
    var categoryName = "";
    var cateMatch = RE_DETAIL_CATE.exec(body);
    if (cateMatch) {
      var cateText = clean(cateMatch[1]);
      RE_CATE_TAG.lastIndex = 0;
      var tagMatch;
      while ((tagMatch = RE_CATE_TAG.exec(cateText)) !== null) {
        var tag = clip(String(tagMatch[1]).replace(/^\s+|\s+$/g, ""), 16);
        if (tag === "" || seenTags[tag] || tags.length >= 8) continue;
        seenTags[tag] = true;
        tags.push(tag);
        if (categoryName === "") categoryName = tag;
      }
    }

    var extra = {
      desc: clip(description, 12000),
      intro: clip(description, 12000),
      episodeCount: chapters.length,
      totalEpisode: chapters.length,
      remark: "全" + chapters.length + "集",
      categoryName: categoryName || CHANNEL,
    };
    if (tags.length > 0) extra.tags = tags;
    return { drama: makeDrama(id, title, cover, extra), chapters: chapters };
  },

  resolveMedia: function (task) {
    var chapter = task && task.chapter ? task.chapter : {};
    var dramaId = String((task && task.dramaId) || host.source + ":");
    var prefix = host.source + ":";
    var rest = dramaId.indexOf(prefix) === 0 ? dramaId.slice(prefix.length) : "";
    var sourceId = rest;
    var episode = 0;
    var separator = rest.indexOf(":");
    if (separator > 0) {
      sourceId = rest.slice(0, separator);
      episode = asNumber(rest.slice(separator + 1), 0);
    } else if (chapter.id) {
      var chapterId = String(chapter.id);
      var cut = chapterId.lastIndexOf(":");
      if (cut > 0) episode = asNumber(chapterId.slice(cut + 1), 0);
    }
    if (!validId(sourceId)) throw new Error("夜社播放信息无效，请刷新详情");
    if (episode < 1 || episode > MAX_PAGE) throw new Error("夜社播放分集信息无效，请刷新详情");

    var pageUrl = SITE + "/play/" + sourceId + "/1/" + episode + ".html";
    var body = textGet(pageUrl);
    var match = RE_PLAYER.exec(body);
    if (!match) throw new Error("夜社该集暂无可播放地址，可能需要在站点开通会员");
    var player = null;
    try {
      player = JSON.parse(match[1]);
    } catch (error) {
      throw new Error("夜社播放信息解析失败，请刷新后重试");
    }
    var encrypt = asNumber(player.encrypt, 0);
    var address = decodePlayerUrl(player.url, encrypt);
    if (address === "" || address === "null") address = decodePlayerUrl(player.url_next, encrypt);
    address = absUrl(address);
    if (!/^https?:\/\//i.test(address)) {
      throw new Error("夜社该集暂无可播放地址，可能需要在站点开通会员");
    }
    var media = host.prepareWebMedia({ url: address, referer: pageUrl }, CHANNEL);
    media.referer = pageUrl;
    return media;
  },
};
