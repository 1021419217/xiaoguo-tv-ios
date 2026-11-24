# 站点验证方法论（踩坑换来的，别改流程）

这份文档只写一件事：**怎么判断一个站源"能不能抓"、"有没有某个字段"、"是不是真的坏了"**。
每一条都对应一次真实误判，改流程前先看一遍事故记录。

---

## 铁律 1：先读配置，不要凭印象拼域名

模块的真实域名写在 `modules/<id>/manifest.json`：

```json
{ "baseUrl": "https://whos.tv", "hosts": ["whos.tv", "*.whos.tv", ...] }
```

**禁止**凭站点名自己拼域名去测。

事故记录：

| 站点 | 我拼的 | 实际 | 后果 |
|---|---|---|---|
| hscangku | `222.ajmck.cc` | `111.ajsck.cc` | 判定"站点已废"，实际好得很 |
| whostv | `whostv.com` | `whos.tv` | 判定"返回空壳"，实际 411KB 正常 |

---

## 铁律 2：判断"打不开"必须三级验证

只试一种方式就说"站点不可用"，是本项目最高频的错误。

### 第一级：curl + 完整浏览器指纹

```bash
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
curl -sL --max-time 25 -A "$UA" \
  -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
  -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8" \
  -H "Sec-Fetch-Dest: document" -H "Sec-Fetch-Mode: navigate" \
  -H "Sec-Fetch-Site: none" -H "Sec-Fetch-User: ?1" -H "Upgrade-Insecure-Requests: 1" \
  -H 'sec-ch-ua: "Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"' \
  -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' \
  "https://站点/" -o out.html -w "%{http_code} %{size_download}\n"
```

**简单 UA 被 Cloudflare 拦，不代表站点不可用。** jable / missav / javrate 都栽在这。

### 第二级：真实 Chrome（关键）

```js
import { chromium } from 'playwright';
// channel:'chrome' = 用用户机器上装的正版 Chrome，不是 Playwright 自带 Chromium
const browser = await chromium.launch({ channel: 'chrome', headless: false });
```

**Playwright 自带的 Chromium 无论 headless 还是有头，都会被 CF 识别**；换成 `channel:'chrome'` 走用户真实 IP + 真实指纹，javrate **0 秒通过、没有任何挑战**。

### 第三级：让用户开

前两级都过不去，再请用户用浏览器打开，或者存一份 HTML 给你：

> 打开页面 → `Ctrl+S` → 保存类型选「网页，仅 HTML」→ 把文件给我

拿到真实 HTML 就能分析结构，不需要我能访问站点。

### 三级都失败，才算"站点不可用"

---

## 铁律 3：判断"有字段"必须看真实输出

静态扫代码只能算**线索**，不能算证据。

事故记录：

| 模块 | 静态扫描结论 | 实际 |
|---|---|---|
| jable | "有 actors ✓" | `actors` 挂在 `drama` **外面**，界面永远读不到 |
| javrate | "缺 actors" | JSON-LD 里 `actor[]` 全有，只是没解析 |
| av8d | "缺作者" | 有 `/actor/{名字}` 作品集页，代码注释还写着"站点没建" |

**验证方式**：mock host + 真实 HTML 跑模块，打印实际字段：

```js
const d = module.exports.detail('样本ID').drama;
console.log({ actors: d.actors, durationText: d.durationText, onlineDate: d.onlineDate });
```

看到 `undefined` 才是真的没有。

---

## 铁律 4：先找 JSON-LD，再找 HTML

顺序不能反：

1. `<script type="application/ld+json">` → `uploadDate` / `duration` / `actor[]` / `contentUrl`
2. 页面信息区（`片商：` / `时长：` / `演员：` 这类中文标签）
3. 卡片角标（`2:15:53`、`1080p`）
4. 正则从 HTML 硬抠（最后手段）

av8d / javrate / jable 的时长和演员全在 JSON-LD 里，只 grep 中文关键词会全部漏掉。

---

## 铁律 5：域名池必须逐个验证「详情页」

多镜像站只测首页/列表页是不够的。

事故：hscangku 的 `looksLikeHome()` 把标题写死成 `黄色仓库-hsck.tv`，站点改成 `.pw` 后守卫静默失效，**7 个坏域名返回的首页被当成正常详情页**，标题和日期全错。

验证方法：对域名池每个域名请求一个**真实详情页 URL**，检查：

- 状态码 200
- 标题不是站点名（是具体片名）
- 内容不是 301 跳根路径的结果

---

## 铁律 6：字段名规范（血泪）

| 规范 | 说明 | 踩坑次数 |
|---|---|---|
| 时长字段叫 `durationText` | 写成 `duration` 或在 `desc` 里拼 `時長 xx` 界面都不显示 | **10 次**（p91/p91a/p91y/pornhub/hscangku/xchina/javtiful/xgroovy/ppp/eporner/jable） |
| `actors` 必须挂在 `drama` 里 | `return { drama, actors }` 读不到 | 1 次（jable） |
| `author` 不要硬写空串 | 站上有 `/actor/` 页就该填 | 1 次（av8d） |

---

## 交付前必跑

统一入口（工作区根目录）：

```bash
node precheck.mjs          # 全量：字段自检 + 模块加载 + 38 个域名探活（约 3-5 分钟）
node precheck.mjs --fast   # 跳过域名探活（约 15 秒，日常改代码用这个）
```

它串起三个脚本，任一**致命项**失败就退出码非 0：

| 脚本 | 检查什么 | 致命 |
|---|---|---|
| `strict_check.mjs` | 6 条事故规则（字段名、actors 层级、UA、域名池） | ✅ |
| `load_test.mjs` | 39 个模块能否 evaluate | ✅ |
| `check_domains.mjs` | 38 个域名探活，识别失效/年龄门/停放页 | ⚠ 仅报告 |

`strict_check.mjs` 的规则全部来自上面的事故，新增事故就往里加一条。

### check_domains 的坑（已修）

只探 `baseUrl` 根路径会误判：p91 的 `/` 是年龄验证页（2965B），真实功能在 `/v.php?next=watch`（94KB）。
脚本现在会在根路径异常时自动再试 `/videos`、`/latest-updates/`、`/cn/new`、`/index.php` 等常见功能路径，任一正常就算健康。

**注意**：9 个站点对 curl 返回 403（Cloudflare），这是正常的——真实 Chrome（`channel:'chrome'`）能过，不算法失效。脚本会标出来，人工判断即可。


---

## 附：模块 id → 真实域名对照表（id 与域名对不上的，占全部 39 个模块的 44%）

**动手测试前先查这张表。** 下表里的模块，凭 id 拼域名必错。

| 模块 id | 真实域名 | 说明 |
|---|---|---|
| `beabox` | `bh4066.top` | 完全不同 |
| `cg91` | `www.91cg1.com` | 数字顺序是 91cg1，不是 cg91 |
| `dsd` | `www.dsd.com.se` | 域名后缀是 `.com.se` |
| `hanxiaoquan` | `www.jennyhow.com` | 完全不同 |
| `hscangku` | `huangsecangku.net`（备用 `111.ajsck.cc`） | 拼音「黄色仓库」；注意 **ajsck 不是 ajmck** |
| `huangtao` | `aihuangdou.com` | 「黄涛」→ 爱黄豆 |
| `ikanbot` | `movie.douban.com` | 数据源是豆瓣电影 |
| `kanliao` | `www.kanliao20.net` | 带数字 20 |
| `p91` / `p91a` / `p91y` | `www.91porn.com` / `91porna.com` / `91porny.com` | 91porn 系列，后缀 a/y 区分 |
| `whostv` | `whos.tv` | **没有 whostv.com 这个站**（少一个 t 就是另一个域名） |
| `xgroovy` | `cn.xgroovy.com` | 带 cn 子域 |
| `yeguo` | `attract.vgbyziuz.cc` | 随机字符域名 |

其余模块（av8d / jable / missav / javrate / madou / spankbang / xchina 等）id 与域名基本对应，但仍要以 `manifest.json` 为准。

### 自查命令

```bash
node -e "
const fs=require('fs');
fs.readdirSync('xiaoguo-tv-ios/modules').forEach(id=>{
  try{
    const m=JSON.parse(fs.readFileSync(\`xiaoguo-tv-ios/modules/\${id}/manifest.json\`,'utf8'));
    console.log(id.padEnd(16), (m.baseUrl||'').replace(/^https?:\/\//,''));
  }catch(e){}
});
"
```

---

## 批量抓取的规矩（别拿有头浏览器刷屏）

**事故**：用 `chromium.launch({channel:'chrome', headless:false})` 跑批量脚本，对每个站试 6 个候选路径、每个路径开一个新页面、每次失败等 20 秒超时。15 个站 × 6 路径 = 90 次页面打开，用户看到的是「窗口不停弹、页面打不开还停在那儿」，白等 10 分钟。

### 正确的分工

| 场景 | 工具 | 原因 |
|---|---|---|
| 批量探活 / 抓 HTML | **curl + 完整指纹** | 不弹窗、几百毫秒、能读系统代理 |
| 需要过 Cloudflare | 真实 Chrome（`channel:'chrome'`） | curl 会被识别 |
| 需要执行 JS 后取 DOM | 真实 Chrome | 但注意广告脚本会改 DOM |

### 硬性要求

1. **批量任务禁止用有头浏览器**——除非单个站、且明确告诉用户会弹窗
2. 必须用真实 Chrome 时：**复用单个 page**，不要每站新建
3. 超时压到 **8 秒**，失败立刻下一个，不要死等 20 秒
4. **Node 的 `fetch` 不读 `HTTP_PROXY`**——本机代理是 `127.0.0.1:50696`。批量抓取用 curl，或给 undici 设 ProxyAgent，**绝不能用 `env -u http_proxy` 清代理再跑 fetch**（会全部超时，看起来像站点全挂）
5. Playwright 的 `page.content()` 是 JS 执行后的 DOM（missav 的视频链接会被广告脚本换成 `#`）；要原始 HTML 必须用 curl

## 网络与构建

- 所有 GitHub 操作（push / sync / build）都要带重试，`ECONNRESET` 是常态
- 构建失败先看是**编译失败**还是**脚本连不上 GitHub**——两者处理方式完全不同
- 个人模块索引走 `jsDelivr @latest`（无配额、实时），**不要**把 GitHub API 放第一位（未认证 60 次/小时，连点刷新就 403，然后掉进 12 小时缓存）
