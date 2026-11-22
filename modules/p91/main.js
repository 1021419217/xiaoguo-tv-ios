// 91porn（91视频）站源模块 · 小果影视 / 红果鉴 模块 API 1
//
// 站点结构（纯 PHP，服务端渲染）：
//   首页最新  /v.php?next=watch
//   分类列表  /v.php?category=<code>&page=N     （24 条/页）
//   搜索      /search_result.php?search_id=<关键词>&search_type=search_videos
//             第 2 页起要换成站点回发的数字 search_id 令牌，不能用原始关键词
//   详情      /view_video.php?viewkey=<20 位 hex>
//   播放地址  详情页里是 document.write(strencode2("...")) 编码的，另有 <source> 明文备用
//
// 模块限制：exports 里的函数必须同步（不能 async），host.fetch 也是同步的。

const SITE = 'https://www.91porn.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const CATEGORIES = [
  { id: 'watch', name: '首页最新' },
  { id: 'hd', name: '高清' },
  { id: 'rf', name: '最近加精' },
  { id: 'ori', name: '91原创' },
  { id: 'hot', name: '当前最热' },
  { id: 'top', name: '本月最热' },
  { id: 'tf', name: '本月收藏' },
  { id: 'mf', name: '收藏最多' },
  { id: 'long', name: '10分钟以上' },
  { id: 'longer', name: '20分钟以上' },
  { id: 'md', name: '本月讨论' }
];

function clean(s) {
  return String(s == null ? '' : s)
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#x([0-9a-f]+);/gi, function (_m, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/&#(\d+);/g, function (_m, d) { return String.fromCharCode(parseInt(d, 10)); })
    .trim();
}

function get(path) {
  const url = path.indexOf('http') === 0 ? path : SITE + path;
  const res = host.fetch({
    method: 'GET',
    url: url,
    timeoutMs: 20000,
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': SITE + '/'
    }
  });
  if (res.status < 200 || res.status >= 300) {
    throw new Error('91porn 返回 HTTP ' + res.status + '（' + path + '）');
  }
  return res.body || '';
}

// 列表页每张卡是一个 <a href="...viewkey=KEY..."> 块，里面依次是
//   <div id="playvthumb_<视频id>"><img src=".../thumb/<视频id>.jpg"> <span class="duration">…
//   <span class="video-title …">标题</span>
// 注意：同一个 viewkey 在页面里会出现多次（关系推荐、data-* 等），
// 按 viewkey 切区间会把别的卡的图配给这张卡的 key（实测 6 张里错 3 张），
// 所以必须按 <a>…</a> 整块解析，并按缩略图 id 去重。
// 列表页每张卡是一个 <div class="col-xs-12 col-sm-4 …"> 容器，容器里才是
//   <a href="…viewkey=KEY…"> + <div id="playvthumb_<视频id>"> + <img …/thumb/<视频id>.jpg> + 标题
// 注意：页面里 viewkey 出现次数远多于卡片数（推荐位/重复链接），
// 按 viewkey 或按 <a> 切都会把相邻卡片的封面配错（实测 6 张错 3 张），
// 唯一稳定的做法是**按卡片容器切**，容器内的 key ↔ 视频 id 才是对的。
function parseCards(html) {
  const out = [];
  const seen = {};
  const parts = html.split(/<div class="col-xs-12[^"]*">/);
  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i];
    const key = (seg.match(/viewkey=([0-9a-f]{12,32})/) || [])[1] || '';
    const vid = (seg.match(/playvthumb_(\d+)/) || [])[1] || '';
    // 2026-11 站点改版：标题从 <span class="video-title"> 挪到 <i class="vci">，
    // 两个选择器都保留，旧页面回退也能解析。
    const t = seg.match(/class="vci"[^>]*>([\s\S]*?)<\/i>/) ||
      seg.match(/class="video-title[^"]*"[^>]*>([\s\S]*?)<\/span>/) ||
      seg.match(/<bdi[^>]*>([\s\S]*?)<\/bdi>/) ||
      seg.match(/<div[^>]*class="(?![^"]*(?:duration|thumb-overlay|hd-text-icon))[^"]*"[^>]*>\s*([^<>]{4,200})\s*<\/div>\s*<\/a>/);
    const title = t ? clean(t[1]) : '';
    if (!key || !title) continue;
    const dedupe = vid || key;
    if (seen[dedupe]) continue;
    seen[dedupe] = 1;

    const img = seg.match(/<img[^>]+src="([^"]+)"/);
    const dur = seg.match(/class="duration"[^>]*>([^<]+)</);
    out.push({
      sourceId: key,
      title: title,
      cover: img ? img[1] : '',
      duration: dur ? clean(dur[1]) : ''
    });
  }
  return out;
}

function listPath(category, page) {
  const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
  let path;
  if (!category || category === 'watch') path = '/v.php?next=watch';
  else path = '/v.php?category=' + encodeURIComponent(category);
  if (n > 1) path += (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + n;
  return path;
}

function detailMeta(html) {
  const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/);
  let title = t ? clean(t[1]) : '';
  title = title.replace(/\s*-\s*91porn\s*$/i, '').trim();
  const poster = html.match(/<video[^>]*poster="([^"]+)"/);
  const dur = html.match(/<span class="duration">([^<]+)<\/span>/);
  return { title: title, poster: poster ? poster[1] : '', duration: dur ? clean(dur[1]) : '' };
}

// 详情页里可能有多条源：明文 <source>、被注释包住的备用源、以及 strencode2 编码的那条。
function decodeSources(html) {
  const urls = [];
  function push(u) {
    if (u && u.indexOf('http') === 0 && urls.indexOf(u) < 0) urls.push(u);
  }
  const reEnc = /strencode2\(\s*"([^"]+)"\s*\)/g;
  let m;
  while ((m = reEnc.exec(html)) !== null) {
    let t = m[1];
    try { t = decodeURIComponent(t); } catch (e) { /* 保持原样 */ }
    const s = t.match(/src\s*=\s*['"]([^'"]+)['"]/);
    if (s) push(s[1]);
  }
  const reSrc = /<source[^>]+src="([^"]+\.(?:mp4|m3u8)[^"]*)"/g;
  while ((m = reSrc.exec(html)) !== null) push(m[1]);
  return urls;
}

// ── 发布者（作者 / 上传者）────────────────────────────────────
// 只加抓取，原有解析逻辑一行不动。
// 取法从强到弱依次尝试，命中即返回：
//   ⓪ 带作者类名的容器（class="user-info" / "author" / "uploader" / "publisher" …）里的作者链接
//      —— pornhub 上验证最有效的一层，91 的页面同样有这类容器
//   ①「作者 / 上传者 / Uploaded by」标签之后紧跟的作者链接
//   ② 标签之后只有纯文本名字（没有 UID，只能显示、不能跳转）
//   ③ 信息区里作者链接去重后只剩一个 UID
//   ④ 信息区里同一作者出现 2 次以上（投票）
//   ⑤ <meta name="author"> / JSON-LD 的 author.name
// 全部落空返回 null：宁可没有作者，也不能把侧栏推荐位当成作者。
// 另外加了一道保护：连续 3 个不同视频解析出同一个人 → 判定为推荐位，直接丢弃。

// 信息区：标题附近开始，遇到「相关推荐 / 评论」就结束。
// 详情页的推荐位、侧栏、猜你喜欢都在这个范围之外。
function authorScan(html) {
  if (!html) return '';
  html = String(html)
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ');
  // 91 的信息表容器有稳定标识（id=videodetails / videodetails-yakov）。
  // 不能优先按 video-title 定位：页面后段的推荐位卡片也带这个类名，
  // 一 search 就落到 48 万字符之后，42 万处的作者区块会被整块切掉。
  const box = String(html).search(/id=["']?videodetails|videodetails-yakov|id=["']?video-details|视频信息/i);
  let start = 0;
  if (box > 0) {
    start = box;
  } else {
    const t = html.search(/<h1[\s>]|id="viewvideo-title"|class="[^"]*(?:video-title|videoTitle)[^"]*"/i);
    if (t > 0) start = Math.max(0, t - 1200);
  }
  let win = String(html).slice(start, start + 9000);
  const cut = win.search(/相关视频|相關視頻|猜你喜欢|猜你喜歡|推荐视频|推薦視頻|相關推薦|相关推荐|related-videos|id="related"|class="[^"]{0,40}related[^"]{0,40}"|热门视频|熱門視頻|评论区|評論區|留言列表|全部留言|class="[^"]{0,40}comments?[^"]{0,40}"|id="comments?"/i);
  if (cut > 0) win = win.slice(0, cut);
  return win;
}

const AUTHOR_LABEL_RE = /(?:作者|上传者|投稿人|發布者|发布者|原作者|UP主|Uploaded\s*by|Added\s*by|Owner|Uploader)/gi;
const AUTHOR_HREF_PART = '(?:(?:uvideos|uprofile|user_followed|compose)\\.php\\?[^"]*(?:UID|receiver)=[A-Za-z0-9_-]+|[?&](?:UID|receiver)=[A-Za-z0-9_-]+)';
const AUTHOR_A_RE = new RegExp('<a[^>]+href="([^"]*' + AUTHOR_HREF_PART + '[^"]*)"[^>]*>([\\s\\S]{0,120}?)<\\/a>', 'i');

function authorAbsUrl(href) {
  const h = String(href == null ? '' : href).replace(/&amp;/g, '&').trim();
  if (!h) return '';
  if (h.indexOf('//') === 0) return 'https:' + h;
  if (h.indexOf('http') === 0) return h;
  return SITE + (h.charAt(0) === '/' ? h : '/' + h);
}

// 91 的 UID 早就不是纯数字了：现在是 43 位 base64url 串
// （例：kBBKslfHMfbdEHWuSL6NpZLJbRcwu4vhjWHzR3aH5Seu6w）。
// 只认 \d 会让页面上每一条作者链接都解析失败，这是「几乎看不到作者」的根因。
function authorUidOf(href) {
  const m = String(href || '').replace(/&amp;/g, '&').match(/[?&](?:UID|uid|receiver)=([A-Za-z0-9_\-]{6,80})/);
  return m ? m[1] : '';
}

// 真实页面写的是「作者: jiuyaoni ( 发送消息 ) 点此关注」，
// 直接取标签后面的文本会把括号、按钮字一起带进来，再被长度闸门挡掉。
function authorNameClean(raw) {
  let n = String(raw == null ? '' : raw).replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
  n = n.replace(/^(?:作者|上传者|投稿人|發布者|发布者|原作者|UP主|Uploaded\s*by|Added\s*by|Owner|Uploader)\s*[：:]?\s*/i, '').trim();
  n = n.split(/[（(\[【|｜]/)[0].trim();
  n = n.replace(/(发送消息|發送消息|发消息|点此关注|點此關注|关注|私信|举报|舉報|收起|展开|複製|复制).*$/, '').trim();
  n = n.replace(/[：:，,。;；、\-–—]+$/, '').trim();
  return n;
}

// 名字闸门：页面导航、按钮、栏目名都会被当成「作者名」，
// 典型的就是把「视频」「首页」这种词显示成创作者。这里统一挡掉。
const AUTHOR_NAME_BAD = /^(视频|視頻|首页|首頁|分类|分類|标签|標籤|更多|热门|熱門|最新|推荐|推薦|收藏|评论|評論|播放|登录|登錄|注册|註冊|原创|原創|全部|返回|主页|主頁|用户|用戶|会员|會員|设置|設置|搜索|分享|下载|下載|举报|舉報|关注|關注|私信|详情|詳情|查看|观看|觀看|更多视频|查看全部|免费|免費|高清|无码|無碼)$/;

function authorNameOk(name) {
  const n = String(name == null ? '' : name).replace(/\s+/g, ' ').trim();
  if (!n) return false;
  if (n.length < 2 || n.length > 32) return false;
  if (AUTHOR_NAME_BAD.test(n)) return false;
  if (/^(视频|視頻|首页|首頁|分类|分類|标签|標籤)/.test(n)) return false;
  if (/[\/\\]|https?:|www\./.test(n)) return false;
  // 页面把样式内联在 <style> 里，随机 class 让正则可能抓到 CSS 片段
  if (/[{}<>]|::|attr\s*\(|content\s*:|!important|@media|var\(--/i.test(n)) return false;
  if (/^(?:content|attr|before|after|important|display|none)$/i.test(n)) return false;
  // 纯符号（***、···、---）不是名字：站点把隐藏作者显示成 ***，交由 UID 兜底
  if (/^[*·•\-\s]+$/.test(n)) return false;
  // HTML/JS 残留：引号、脚本关键字、属性名（-b2452) attr / iI6yev7g" / vascript:void）
  if (/["']|\battr\b|javascript|void|\bstyle\s*=|\bclass\s*=/.test(n)) return false;
  return true;
}

// 导航/功能链接不是作者主页
const AUTHOR_HREF_BAD = /(?:\/v\.php|\/view_video|\/index\.php|\/search_result|\/login|\/logout|\/register|\/faq|\/contact|\/dmca|\/advertise|\/upload|\/tags?\b|\/category|\/comment)/i;

// 所有作者链接（保留重复，重复次数就是投票数）
function authorLinkList(html) {
  const out = [];
  if (!html) return out;
  const re = new RegExp('<a[^>]+href="([^"]*' + AUTHOR_HREF_PART + '[^"]*)"[^>]*>([\\s\\S]{0,120}?)<\\/a>', 'gi');
  let m;
  while ((m = re.exec(html)) !== null) {
    const id = authorUidOf(m[1]);
    if (!id) continue;
    out.push({
      author: clean(m[2]).replace(/\s+/g, ' ').trim(),
      authorId: id,
      authorUrl: authorAbsUrl(m[1])
    });
  }
  return out;
}

// ⓪ 作者类名容器：先定位类名，再在容器内挑第一个「名字合法、不是导航链接」的链接。
// 容器里的第一个链接常常是头像/分类入口（文本就是「视频」），所以不能直接取第一个。
function labeledAuthor(region) {
  if (!region) return null;
  const boxRe = /class="((?:[^"]*\s)?(?:author|uploader|creator|publisher|user-info|user-name|username|up-info|video-user)[^"]*)"/i;
  const bm = region.match(boxRe);
  if (!bm) return null;
  const cls = bm[1].toLowerCase();
  if (/nav|menu|header|footer|sidebar|aside|tab|pager|toolbar|breadcrumb/.test(cls)) return null;
  const head = region.slice(bm.index, bm.index + 240);
  if (/logout|signin|sign_in|\/login|register|signup/i.test(head)) return null;
  let tail = region.slice(bm.index + bm[0].length, bm.index + bm[0].length + 600);
  const close = tail.search(/<\/div>/i);
  if (close > 0) tail = tail.slice(0, close);
  const re = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,120}?)<\/a>/gi;
  let m;
  while ((m = re.exec(tail)) !== null) {
    if (AUTHOR_HREF_BAD.test(m[1])) continue;
    if (/(logout|login|register|signup|member\.php)/i.test(m[1])) continue;
    const name = clean(m[2]).replace(/\s+/g, ' ').trim();
    if (!authorNameOk(name)) continue;
    return { author: name, authorId: authorUidOf(m[1]), authorUrl: authorAbsUrl(m[1]) };
  }
  return null;
}

// 投票：返回票数最多的候选
function voteAuthor(list) {
  const buckets = {};
  for (const a of list) {
    const key = String(a.authorId || a.author).toLowerCase();
    if (!key) continue;
    if (!buckets[key]) buckets[key] = { info: a, n: 0 };
    buckets[key].n += 1;
  }
  let best = null, total = 0;
  for (const key in buckets) {
    total += buckets[key].n;
    if (!best || buckets[key].n > best.n) best = buckets[key];
  }
  return { best: best, total: total };
}

// 连续 3 个不同视频投给同一个人 → 这就是站方固定的推荐位，丢弃。
function authorLooksBroken(key, info) {
  if (!info || !key) return false;
  const sig = String(info.authorId || info.author).toLowerCase();
  let hist = [];
  try { hist = JSON.parse(String(host.loadState('author-hist') || '[]')); } catch (e) { hist = []; }
  if (!hist || typeof hist.length !== 'number') hist = [];
  const distinct = {};
  for (const h of hist) if (h && h.a === sig && h.k) distinct[h.k] = 1;
  if (!distinct[key] && Object.keys(distinct).length >= 3) {
    try { host.log('91作者疑似固定推荐位，已丢弃: ' + sig); } catch (e) { /* 忽略 */ }
    return true;
  }
  hist.unshift({ k: key, a: sig });
  if (hist.length > 12) hist = hist.slice(0, 12);
  try { host.saveState('author-hist', JSON.stringify(hist)); } catch (e) { /* 忽略 */ }
  return false;
}


// 页面可能把中文写成 &#20316;&#32773; 这样的实体，"作者"两个字就匹配不到。
// 只解数字实体和 &nbsp;，不动 &lt; &gt;，否则会把 HTML 结构改坏。
function decodeEntities(raw) {
  return String(raw == null ? '' : raw)
    .replace(/&#x([0-9a-fA-F]+);/g, function (_, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/&#(\d+);/g, function (_, d) { return String.fromCharCode(parseInt(d, 10)); })
    .replace(/&nbsp;/gi, ' ');
}

// 「发送消息」按钮的 compose.php?receiver=UID 只属于本视频作者：
// 推荐位卡片、评论区都不会有它。比"作者"这两个字可靠得多，也不怕模板改版。
function composeAuthor(html) {
  const s = String(html || '');
  const re = /compose\.php\?[^"']*receiver=([A-Za-z0-9_\-]{6,80})/gi;
  let m, uid = '', at = -1;
  while ((m = re.exec(s)) !== null) {
    if (!uid) { uid = m[1]; at = m.index; }
    else if (m[1] !== uid) return null; // 出现多个不同的人，宁可不认
  }
  if (!uid || at < 0) return null;

  // ① 同一 UID 的作者主页链接，文本就是作者名
  const near = s.slice(Math.max(0, at - 900), at + 900);
  const same = authorLinkList(near).filter(function (l) { return l.authorId === uid; });
  for (const l of same) {
    const name = authorNameClean(l.author);
    if (authorNameOk(name)) return { author: name, authorId: uid, authorUrl: l.authorUrl };
  }
  // ② 名字不是链接：取「发送消息」前面最后一段完整标签文本。
  //    注意不能整体去标签——compose 前面往往停在 href="/ 这种半截标签上。
  const before = s.slice(Math.max(0, at - 600), at);
  const chunks = before.split('>');
  for (let i = chunks.length - 1; i >= 0; i--) {
    const raw = chunks[i].split('<')[0].replace(/&nbsp;/g, ' ').trim();
    const name = authorNameClean(raw);
    if (authorNameOk(name)) {
      return { author: name, authorId: uid, authorUrl: SITE + '/uvideos.php?UID=' + uid };
    }
  }
  // 名字被字体加密（data-* + 自定义字体），服务端拿不到明文：用「用户+UID前6位」
  // 占位，保住「点作者看作品」的能力。
  return { author: authorDisplayName('', uid), authorId: uid, authorUrl: SITE + '/uprofile.php?UID=' + uid };
}

// 极短诊断，塞进简介里让人一眼看到（App 的模块日志要靠新版才显示）
function authorDiagShort(html) {
  const win = authorScan(html) || '';
  const labels = String(win).match(AUTHOR_LABEL_RE) || [];
  const links = authorLinkList(win);
  const mail = (String(html || '').match(/compose\.php\?[^"']*receiver=/gi) || []).length;
  return '标' + labels.length + '/链' + links.length + '/信' + mail;
}

function authorDisplayName(name, uid) {
  const text = String(name == null ? '' : name).trim();
  if (text && !/^[*\u00b7\u2022\s]+$/.test(text)) return text;
  return uid ? '用户' + String(uid).slice(0, 6) : '';
}

// 站点把作者名拆成 data-a / data-b 两段，用 CSS attr() 拼接显示，
// 元素里没有文本节点，只能读属性再拼。
function splitAuthorName(html) {
  const box = /class="title\s+vun"[^>]*>/.exec(html);
  if (!box) return null;
  const a = /data-a="([^"]*)"/.exec(box[0]);
  const b = /data-b="([^"]*)"/.exec(box[0]);
  if (!a && !b) return null;
  const name = decodeEntities((a ? a[1] : '') + (b ? b[1] : '')).trim();
  const before = html.slice(Math.max(0, box.index - 300), box.index);
  const href = /uprofile\.php\?UID=([A-Za-z0-9_-]+)/.exec(before) ||
    /uvideos\.php\?UID=([A-Za-z0-9_-]+)/.exec(before);
  return { name: name, uid: href ? href[1] : '' };
}

function authorOf(html, key) {
  html = decodeEntities(html);
  const split = splitAuthorName(html);
  if (split && authorNameOk(split.name)) {
    return {
      author: split.name,
      authorId: split.uid,
      authorUrl: split.uid ? SITE + '/uprofile.php?UID=' + split.uid : '',
    };
  }
  const win = authorScan(html);
  if (!win) return null;
  let m;

  // ⓪ 作者类名容器（最贴近本视频，pornhub 上最有效的一层）
  const labeled = labeledAuthor(win);
  if (labeled) return labeled;

  // ⓪b 私信锚点：本视频专属，优先级高于一切文字标签
  const mailed = composeAuthor(html);
  if (mailed && !authorLooksBroken(key, mailed)) return mailed;

  // ① 标签锚定：标签本身是强证据，后面紧跟作者链接时出现一次就认。
  AUTHOR_LABEL_RE.lastIndex = 0;
  let lb;
  while ((lb = AUTHOR_LABEL_RE.exec(win)) !== null) {
    // 标签必须独立成词：「投票作者」「原作者声明」里夹着的「作者」不算标签
    const prev = lb.index > 0 ? win.charAt(lb.index - 1) : '';
    if (/[\u4e00-\u9fa5A-Za-z]/.test(prev)) continue;
    const seg = win.slice(lb.index, lb.index + 320);
    const a = seg.match(AUTHOR_A_RE);
    if (a) {
      const between = seg.slice(lb[0].length, seg.indexOf(a[0]));
      if (!/(作者|上传者|投稿人|UP主|Uploaded\s*by|Owner|Uploader)/i.test(between)) {
        const id = authorUidOf(a[1]);
        const name = authorNameClean(clean(a[2]));
        if (id && authorNameOk(name)) return { author: name, authorId: id, authorUrl: authorAbsUrl(a[1]) };
      }
    }
    // ② 标签后面是纯文本：只认「标签: 名字」，排除统计类文字。
    m = seg.match(/^(?:[\s\S]{0,20}?)[：:]\s*([^<\n\r]{1,60})/);
    if (m) {
      const name = authorNameClean(clean(m[1]));
      if (authorNameOk(name) && !/^[\d\s:：.\/]+$/.test(name) &&
          !/(次|播放|收藏|评论|时间|上传于|浏览)/.test(name)) {
        // 名字旁边一般就是作者主页 / 私信链接（compose.php?receiver=），
        // 能取到 UID 就一起带上；取不到才留空，交由 App 按名字搜索兜底。
        const nearAll = authorLinkList(seg);
        const near = nearAll.filter(function (l) {
          return l.author && (l.author.indexOf(name) >= 0 || name.indexOf(l.author) >= 0);
        })[0] || nearAll[0];
        return {
          author: name,
          authorId: near ? near.authorId : '',
          authorUrl: near ? near.authorUrl : '',
        };
      }
    }
  }

  // ③ 信息区里只出现过一个作者 UID
  const links = authorLinkList(win);
  const ids = {};
  for (const l of links) ids[l.authorId] = 1;
  const uniq = Object.keys(ids);
  if (uniq.length === 1) {
    const first = links[0];
    const name = authorNameOk(first.author) ? first.author : '';
    return {
      author: authorDisplayName(name, first.authorId),
      authorId: first.authorId,
      authorUrl: first.authorUrl,
    };
  }

  // ④ 信息区投票：同一个作者出现 2 次以上才算
  const voted = voteAuthor(links);
  if (voted.best && voted.best.n >= 2 && authorNameOk(voted.best.info.author)) {
    if (authorLooksBroken(key, voted.best.info)) return null;
    return voted.best.info;
  }

  // ⑤ 页面脚本里内联的用户信息（"uid":123 … "username":"xxx"），比 DOM 文本可靠
  let uid = '', uname = '';
  let mm = html.match(/"(?:uid|user_id|userId|userid)"\s*:\s*"?([A-Za-z0-9_\-]{1,80})"?[\s\S]{0,300}?"(?:username|user_name|nickname|uname)"\s*:\s*"([^"]{1,40})"/i);
  if (mm) { uid = mm[1]; uname = mm[2]; }
  if (!uname) {
    mm = html.match(/"(?:username|user_name|nickname|uname)"\s*:\s*"([^"]{1,40})"[\s\S]{0,300}?"(?:uid|user_id|userId|userid)"\s*:\s*"?([A-Za-z0-9_\-]{1,80})"?/i);
    if (mm) { uname = mm[1]; uid = mm[2]; }
  }
  if (uname) {
    const nm = clean(uname).replace(/\s+/g, ' ').trim();
    if (authorNameOk(nm)) {
      return { author: nm, authorId: uid || '', authorUrl: uid ? SITE + '/uvideos.php?UID=' + uid : '' };
    }
  }

  // ⑥ 结构化数据（先信息区、再整页）
  for (const src of [win, html]) {
    const meta = String(src || '').match(/<meta[^>]+name=["']author["'][^>]+content=["']([^"']+)["']/i);
    if (meta) {
      const name = clean(meta[1]).replace(/\s+/g, ' ').trim();
      if (name) return { author: name, authorId: '', authorUrl: '' };
    }
    const lds = String(src || '').match(/"author"\s*:\s*\{[^{}]{0,200}?"name"\s*:\s*"([^"]+)"/gi) || [];
    if (lds.length === 1) {
      const nm = lds[0].match(/"name"\s*:\s*"([^"]+)"/i);
      if (nm) {
        const name = clean(nm[1]).replace(/\s+/g, ' ').trim();
        if (name) return { author: name, authorId: '', authorUrl: '' };
      }
    }
  }

  // ⑦ 全页的作者类名容器（信息区截取不准时的补救）
  return labeledAuthor(html);
}

// 取不到作者时打一条诊断：标签几处、作者链接几条、UID 几个、href 形态。
// 有这条日志就能判断是「页面没有作者」还是「规则没覆盖到这种模板」。
function authorDiag(html) {
  const win = authorScan(html);
  const labels = String(win || '').match(AUTHOR_LABEL_RE) || [];
  const links = authorLinkList(String(win || ''));
  const ids = {};
  for (const l of links) ids[l.authorId] = 1;
  const hrefs = String(html || '').match(/href="[^"]*UID=[^"]*"/gi) || [];
  const shapes = [];
  for (const h of hrefs) {
    const m = h.match(/uid=[A-Za-z0-9_\-]+/i);
    if (m && shapes.indexOf(m[0].replace(/\d+/g, '*')) < 0) shapes.push(m[0].replace(/\d+/g, '*'));
  }
  const boxes = [];
  const bre = /class="([^"]*(?:author|upload|creator|user|member|up-info)[^"]*)"/gi;
  let bm;
  while ((bm = bre.exec(String(html || ''))) !== null) {
    const c = bm[1].trim();
    if (c && c.length < 50 && boxes.indexOf(c) < 0) boxes.push(c);
    if (boxes.length >= 4) break;
  }
  const cands = links.slice(0, 3).map(function (l) { return (l.author || '?') + '@' + (l.authorId || '-'); }).join(',');
  return '信息区' + win.length + '字符/标签' + labels.length + '处/作者链接' + links.length +
    '条/UID' + Object.keys(ids).length + '个/候选[' + cands + ']/容器名[' + boxes.join('|') +
    ']/全页href形态[' + shapes.slice(0, 2).join(' ') + ']';
}

// 作者页的卡片结构可能和列表页不同。这里做宽松兜底：按 <a ...viewkey=KEY...> 切块取标题，
// 只在标准解析出 0 条时启用。
function parseLooseCards(html) {
  const out = [];
  const seen = {};
  const re = /<a[^>]+href="([^"]*viewkey=([0-9a-f]{12,32})[^"]*)"[^>]*>([\s\S]{0,600}?)<\/a>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const key = m[2];
    if (seen[key]) continue;
    const inner = m[3];
    let title = '';
    const t = inner.match(/title="([^"]{2,120})"/);
    if (t) title = clean(t[1]);
    if (!title) {
      const span = inner.match(/class="[^"]*title[^"]*"[^>]*>([\s\S]{0,120}?)</);
      if (span) title = clean(span[1]);
    }
    title = title.replace(/\s+/g, ' ').trim();
    if (!title) continue;
    const img = inner.match(/<img[^>]+(?:src|data-src)="([^"]+)"/);
    const dur = inner.match(/class="duration"[^>]*>([^<]+)</);
    seen[key] = 1;
    out.push({ sourceId: key, title: title, cover: img ? img[1] : '', duration: dur ? clean(dur[1]) : '' });
  }
  return out;
}

function toDrama(item) {
  const title = item.title || item.sourceId;
  return {
    id: host.dramaId(item.sourceId),
    source: host.source,
    sourceId: item.sourceId,
    title: title,
    name: title,
    desc: item.duration ? '时长 ' + item.duration : '',
    intro: '',
    cover: item.cover || '',
    totalEpisode: 1
  };
}

module.exports = {
  validCategory(category) {
    return !category || CATEGORIES.some(function (entry) { return entry.id === category; });
  },

  categories() {
    return CATEGORIES;
  },

  catalogPage(page, category) {
    if (!this.validCategory(category)) throw new Error('没有分类 ' + category);
    const items = parseCards(get(listPath(category, page))).map(toDrama);
    return { items: items, hasMore: items.length >= 20 };
  },

  search(page, query) {
    const kw = clean(query || '');
    if (!kw) return { items: [], hasMore: false };
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);

    const cacheKey = 'search-id:' + kw;
    let token = '';
    try { token = String(host.loadState(cacheKey) || ''); } catch (e) { /* 没有状态 */ }

    if (n > 1 && token) {
      const html = get('/search_result.php?search_id=' + encodeURIComponent(token) + '&search_type=search_videos&page=' + n);
      const items = parseCards(html).map(toDrama);
      if (items.length) return { items: items, hasMore: items.length >= 20 };
    }

    // 第 1 页（或令牌失效）：用关键词换令牌
    const first = get('/search_result.php?search_id=' + encodeURIComponent(kw) + '&search_type=search_videos');
    const m = first.match(/search_id=([0-9A-Fa-f]{5,12})&/);
    if (m) {
      token = m[1];
      try { host.saveState(cacheKey, token); } catch (e) { /* 忽略 */ }
    }
    if (n <= 1) {
      const items = parseCards(first).map(toDrama);
      return { items: items, hasMore: items.length >= 20 };
    }
    const html = get('/search_result.php?search_id=' + encodeURIComponent(token || kw) + '&search_type=search_videos&page=' + n);
    const items = parseCards(html).map(toDrama);
    return { items: items, hasMore: items.length >= 20 };
  },

  detail(sourceId) {
    const id = String(sourceId || '').match(/[0-9a-f]{12,32}/);
    if (!id) throw new Error('缺少 viewkey');
    const key = id[0];
    const html = get('/view_video.php?viewkey=' + key);
    const meta = detailMeta(html);

    // 播放地址必须走 /vlk.php。
    // 页面 HTML 里的 strencode2 地址是 fallback（fake()），实测大量视频在 CDN 上残缺：
    // 文件尾部 Range 直接返回 000，播放器读不到索引就黑屏/转圈。
    // /vlk.php 用页面里的 vbG / vbGT 令牌换取一条完整地址（实测尾部 206）。
    const page = SITE + '/view_video.php?viewkey=' + key;
    try {
      const live = fetchPlayUrl(html, page);
      const page_srcs = decodeSources(html).map(function (u) {
        return u.replace(/^(https?:\/\/[^\/]+)\/\//, '$1/');
      });
      // 主线路放最前，页面里的其它源作为备用线路
      const all = [];
      if (live) all.push(live);
      for (const u of page_srcs) if (all.indexOf(u) < 0) all.push(u);
      if (all.length) {
        host.cacheSet('srcs:' + key, JSON.stringify({
          urls: all,
          expiresMs: tokenExpiryMs(all[0]),
          durationMs: parseRuntimeMs(html)
        }), 15 * 60 * 1000);
      }
    } catch (e) { host.log('91porn 取播放地址失败: ' + e.message); }

    const drama = toDrama({ sourceId: key, title: meta.title || key, cover: meta.poster, duration: meta.duration });
    // 详情页「添加时间: 2026-11-19」→ onlineDate，UI 显示在发行/时间一栏。
    const added = String(html || '').match(/添加时间\s*:?\s*(?:<[^>]*>\s*)*([0-9]{4}-[0-9]{2}-[0-9]{2})/);
    if (added) drama.onlineDate = added[1];
    const author = authorOf(html, key);
    if (author) {
      drama.author = author.author;
      if (author.authorId) drama.authorId = author.authorId;
      if (author.authorUrl) drama.authorUrl = author.authorUrl;
      host.log('91作者 v3.3.6: ' + author.author + (author.authorId ? ' (UID ' + author.authorId + ')' : ' (无 UID)'));
    } else {
      const why = authorDiagShort(html);
      // 临时诊断：直接写在简介里，装了旧版 App 也能看见
      drama.desc = (drama.desc ? drama.desc + ' · ' : '') + '作者未识别[' + why + ']';
      host.log('91作者 v3.3.6: 未取到（' + why + '；' + authorDiag(html) + '）');
    }
    const chapter = {
      id: host.chapterId(key, 'video'),
      source: host.source,
      title: meta.title || '正片',
      currentEpisode: 1,
      pageUrl: page,
      referer: page
    };
    return { drama: drama, chapters: [chapter] };
  },

  // 作者二级页：/uvideos.php?UID=N 翻页列出该作者的全部作品。
  // 有 UID 走作者页；拿不到 UID（只有名字）时按名字搜索兜底。
  author(authorId, authorName, page) {
    const id = String(authorId == null ? '' : authorId).replace(/[^A-Za-z0-9_\-]/g, '');
    const name = clean(authorName || '').replace(/\s+/g, ' ').trim();
    const n = Number(page || 1) < 1 ? 1 : Number(page || 1);
    const seen = {};

    function pack(list, url) {
      const out = [];
      for (const it of list) {
        if (!it || !it.sourceId || seen[it.sourceId]) continue;
        seen[it.sourceId] = 1;
        const d = toDrama(it);
        if (name || id) {
          d.author = name || ('UID ' + id);
          if (id) d.authorId = id;
          if (url) d.authorUrl = url;
        }
        out.push(d);
      }
      return out;
    }

    if (id) {
      const url = SITE + '/uvideos.php?UID=' + id;
      try {
        const html = get(url + (n > 1 ? '&page=' + n : ''));
        let items = pack(parseCards(html), url);
        if (!items.length) items = pack(parseLooseCards(html), url);
        if (items.length) {
          // 作者页每页只有 5~8 条，靠「Videos 9-16 of 67」判断还有没有下一页
          const range = /Videos\s+\d+-(\d+)\s+of\s+(\d+)/.exec(html);
          const more = range
            ? Number(range[1]) < Number(range[2])
            : items.length >= 5;
          return { items: items, hasMore: more };
        }
      } catch (e) {
        host.log('91作者页失败: ' + e.message);
      }
    }

    if (name && n <= 1) {
      try {
        const html = get('/search_result.php?search_id=' + encodeURIComponent(name) + '&search_type=search_videos');
        let items = pack(parseCards(html), '');
        if (!items.length) items = pack(parseLooseCards(html), '');
        if (items.length) return { items: items, hasMore: items.length >= 20, warning: '按作者名搜索' };
      } catch (e) {
        host.log('91作者名搜索失败: ' + e.message);
      }
    }
    return { items: [], hasMore: false };
  },

  resolveMedia(task) {
    // DramaID 形如 "p91:<viewkey>"，Chapter.ID 形如 "p91:<viewkey>:video"，两种都兜住
    let key = '';
    const fromDrama = String((task && task.dramaId) || '').split(':');
    if (fromDrama.length >= 2 && /^[0-9a-f]{12,32}$/.test(fromDrama[1])) key = fromDrama[1];
    if (!key) {
      const fromChapter = String((task && task.chapter && task.chapter.id) || '').split(':');
      if (fromChapter.length >= 2) key = String(fromChapter[1]).trim();
    }
    if (!key) throw new Error('无法确定视频 ID');

    const page = SITE + '/view_video.php?viewkey=' + key;
    const now = Date.now();

    // ① 2 分钟内的重复播放：直接复用成品，0 请求
    try {
      const ready = host.cacheGet('ready:' + key);
      if (ready) {
        const m = JSON.parse(ready);
        const expires = Number(m.expiresMs || 0);
        if (m.url && (expires === 0 || expires > now + 30000)) {
          const cachedMedia = mediaOf(m.url, page, Number(m.durationMs || 0));
          if (m.variants && m.variants.length) cachedMedia.variants = m.variants;
          return cachedMedia;
        }
      }
    } catch (e) { /* 忽略 */ }

    // ② 详情页缓存下来的地址：主线路 + 备用线路
    // App 原生支持多线路：播放失败会自动切到 variants 里的下一条，
    // 日志里显示「线路=1/2」→「线路=2/2」。
    try {
      const cached = host.cacheGet('srcs:' + key);
      if (cached) {
        const c = JSON.parse(cached);
        const expires = Number(c.expiresMs || 0);
        const list = (c.urls && c.urls.length) ? c.urls : (c.url ? [c.url] : []);
        if (list.length && (expires === 0 || expires > now + 30000)) {
          const media = mediaWithRoutes(list, page, Number(c.durationMs || 0));
          rememberReady(key, media);
          return media;
        }
      }
    } catch (e) { /* 忽略 */ }

    // ③ 兜底：缓存没有或地址过期，现拉一次详情页
    const html = get('/view_video.php?viewkey=' + key);
    const urls = decodeSources(html);
    if (!urls.length) throw new Error('页面里没有找到播放地址（可能需要登录）');

    //   带 &f=  → HTTP 206 直接返回正片；不带 → 302 跳去提示片
    //   双斜杠 //mp43/ 在代理下会被改写成非法请求，必须修掉
    const list = urls.map(function (u) { return u.replace(/^(https?:\/\/[^\/]+)\/\//, '$1/'); });
    const durationMs = parseRuntimeMs(html);

    const live = fetchPlayUrl(html, page);
    const routes = [];
    if (live) routes.push(live);
    for (const u of list) if (routes.indexOf(u) < 0) routes.push(u);
    if (!routes.length) throw new Error('页面里没有可用的播放地址');

    try {
      host.cacheSet('srcs:' + key, JSON.stringify({
        urls: routes,
        expiresMs: tokenExpiryMs(routes[0]),
        durationMs: durationMs
      }), 15 * 60 * 1000);
    } catch (e) { /* 忽略 */ }

    const media = mediaWithRoutes(routes, page, durationMs);
    rememberReady(key, media);
    return media;
  }
};

// 地址里的 e=<epoch 秒> 就是失效时间
function tokenExpiryMs(url) {
  const m = String(url).match(/[?&]e=(\d{9,11})/);
  if (!m) return 0;
  const seconds = Number(m[1]);
  return seconds > 1000000000 ? seconds * 1000 : 0;
}

// 详情页的时长有两种标签：英文 "Runtime: <span class=video-info-span>00:15:30</span>"、
// 中文 "时长: <span class=video-info-span>00:01:43</span>"。
// 只匹配英文会拿到 0，导致 HLS 列表里的 EXTINF/TARGETDURATION 变成占位值。
function parseRuntimeMs(html) {
  let raw = '';
  const byLabel = html.match(/(?:Runtime|时长)\s*:\s*(?:<[^>]*>\s*)*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)/);
  if (byLabel) raw = byLabel[1];
  if (!raw) {
    const bySpan = html.match(/class="video-info-span"[^>]*>\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)/);
    if (bySpan) raw = bySpan[1];
  }
  if (!raw) return 0;
  const parts = raw.split(':').map(Number);
  let seconds = 0;
  if (parts.length === 3) seconds = parts[0] * 3600 + parts[1] * 60 + parts[2];
  else if (parts.length === 2) seconds = parts[0] * 60 + parts[1];
  return seconds * 1000;
}


// 直接给 MP4，不包 HLS。
// 教训来自 viral：HLS 的分片是原子的，单段 HLS 等于「整个文件 = 一个分片」，
// 91porn 一个视频几十到几百 MB，播放器必须从头缓冲，表现就是「一直转圈、播不出来」。
// MP4 走 HTTP Range，拖到哪取哪，seek 是瞬间的。
function mediaOf(url, page, durationMs) {
  const single = String(url).replace(/^(https?:\/\/[^\/]+)\/\//, '$1/');
  const media = {
    url: single,
    referer: page,
    quality: 720,
    durationMs: durationMs,
    credentials: {
      referer: page,
      origin: SITE,
      userAgent: UA
    }
  };
  const expiresMs = tokenExpiryMs(single);
  if (expiresMs > 0) media.credentials.expiresMs = expiresMs;
  return media;
}
// 记住成品，2 分钟内重复播放直接拿
function rememberReady(key, media) {
  try {
    host.cacheSet('ready:' + key, JSON.stringify({
      url: media.url,
      playlist: media.playlist,
      variants: media.variants || null,
      durationMs: media.durationMs || 0,
      expiresMs: (media.credentials && media.credentials.expiresMs) || 0
    }), 2 * 60 * 1000);
  } catch (e) { /* 忽略 */ }
}


// 调 /vlk.php 换一条完整可播的地址。
// 页面里的内联脚本是这么干的：
//   var vbG="…", vbGV=<id>, vbGT="…";
//   POST /vlk.php  body = JSON.stringify({g:vbG,t:vbGT,ev:"touchstart",op:…,gl:WebGL…,…})
//   → {"u":"https://…/xxx.mp4?…","ty":"video/mp4"}
// 指纹字段按 iOS Safari 手机填（服务端实测接受），换取到的地址尾部可读（HTTP 206）。
function fetchPlayUrl(html, page) {
  const g = (html.match(/vbG\s*=\s*"([^"]+)"/) || [])[1];
  const t = (html.match(/vbGT\s*=\s*"([^"]+)"/) || [])[1];
  if (!g || !t) return '';

  const fingerprint = {
    g: g,
    t: t,
    ev: 'touchstart',
    op: 3500,          // 打开页面到点击的毫秒数
    mc: 0, tc: 1, sc: 2, kc: 0,
    wd: 0,             // 不是自动化
    gl: 'ANGLE (Apple, Apple GPU, OpenGL ES 3.0)',
    sg: 0,             // 不是软件渲染
    nc: 0,
    pl: 0, lg: 2,
    ow: 390, oh: 844, sw: 390, sh: 844,
    tz: -480
  };

  try {
    const res = host.fetch({
      method: 'POST',
      url: SITE + '/vlk.php',
      timeoutMs: 12000,
      headers: {
        'User-Agent': UA,
        'Referer': page,
        'Origin': SITE,
        'Content-Type': 'text/plain',
        'Accept': '*/*'
      },
      body: JSON.stringify(fingerprint)
    });
    if (res.status !== 200) return '';
    let json = null;
    try { json = JSON.parse(res.body || '{}'); } catch (e) { return ''; }
    if (!json || !json.u) return '';
    return String(json.u).replace(/^(https?:\/\/[^\/]+)\/\//, '$1/');
  } catch (e) {
    return '';
  }
}


// 构造「主线路 + 备用线路」。
// App 的 app_playback_routes.go 会把 media 和 media.Variants 都注册成线路，
// 播放失败时按顺序切换（Dart 日志：「正在切换备用线路」/「线路=2/2」）。
function hostOf(url) {
  const m = String(url || '').match(/^https?:\/\/([^\/]+)/);
  return m ? m[1].toLowerCase() : '';
}

function mediaWithRoutes(urls, page, durationMs) {
  const main = mediaOf(urls[0], page, durationMs);
  // 同一个 CDN 上的第二个地址（只是 token 不同）没有切换价值，
  // 切过去照样失败，还白白多等一次退避，所以按域名去重。
  const seen = {};
  seen[hostOf(urls[0])] = 1;
  const variants = [];
  for (let i = 1; i < urls.length; i++) {
    if (!urls[i]) continue;
    const host = hostOf(urls[i]);
    if (seen[host]) continue;
    seen[host] = 1;
    variants.push(mediaOf(urls[i], page, durationMs));
  }
  if (variants.length) main.variants = variants;
  return main;
}
