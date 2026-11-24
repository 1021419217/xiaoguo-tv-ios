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

```bash
node strict_check.mjs     # 6 条事故规则
node load_test.mjs        # 39 个模块能否加载
node audit_modules.mjs    # 10 项字段矩阵
```

`strict_check.mjs` 的规则全部来自上面的事故，新增事故就往里加一条。

---

## 网络与构建

- 所有 GitHub 操作（push / sync / build）都要带重试，`ECONNRESET` 是常态
- 构建失败先看是**编译失败**还是**脚本连不上 GitHub**——两者处理方式完全不同
- 个人模块索引走 `jsDelivr @latest`（无配额、实时），**不要**把 GitHub API 放第一位（未认证 60 次/小时，连点刷新就 403，然后掉进 12 小时缓存）
