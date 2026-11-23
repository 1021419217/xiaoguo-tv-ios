# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库注意事项

- 汇报结论必须区分「已验证」与「推断」：没有实际运行、日志或测试证据的一律写明「推断，未验证」，不得用确定语气陈述。
- 改完代码先做对抗性自查：检查新逻辑会不会破坏既有流程（抢占队列、死循环、并发、清理时机、异常路径），确认后再汇报。
- 不使用「这次一定行」「根本修复」这类断言；改为说明「改了什么、依据是什么、怎么验证」。
- 涉及真机行为的改动，一律标注「待实机验证」，并写清验证方法（看哪个日志、看哪个现象、几种结果分别代表什么）。
- 用户反馈某功能无效时，先找日志/证据定位，不靠猜测连续改代码。
- 全程用中文思考和汇报：动手前先用中文说明要做什么，命令后说明查到什么；不要用英文状态和英文解释。
- 更新版本前，检查项目 Github 该版本是否已经发布 Release，若未发布则继续在当前版本写。
- 每出一次包，版本号本身必须往上加：`2.3.0` → `2.3.1` → … → `2.3.9` → `2.4.0`（最后一位到 10 就往前一位进 1），不能只改 `+构建号`。
- 构建号也随每次出包 +1，不固定为 1；同样到 10 进位，不再无上限累加。
- 更新内容写在 `CHANGELOG.md` 。标题为完整版本号（如 `## 0.2.72+79`），每个版本的更新日志不得超过3500字。
- 每条更新日志只需简单描述，不需要具体的说明。
- 未验证的改动标为开发快照，提醒用户在对应平台进行实机测试，验证通过后，移除标记。
- 不新增解释性代码注释，必要的编译或工具指令除外。采用清晰命名和模块边界。
- 不为UI类内容编写单元测试，直接叫用户打开实际界面查看。
- 合并外部 PR 时，先用 `git merge --no-ff` 把 PR 原提交原样合进本地 `main`，合并提交只解决冲突（如 `CHANGELOG.md` 同版本标题去重），不改 PR 内容；需要的修订另起提交。不用 cherry-pick、squash 或 amend PR 提交，保证推送后 GitHub 将 PR 显示为 Merged。

## 站源

本体随包内置 `modules/` 下的 30 个站源，构建时由 `scripts/app_build.py` 拷进 `native/core/bundled`；站源仍是运行时加载的 JS 模块（`native/core/module_*.go`，示例 `native/module_example`）。官方站源正从私有仓库 `guoapp-sources`（本机 `../guoapp-sources`）里的 Go 代码改写成 JS 模块，改写后的模块放在同级文件夹 `../guoapp-modules/<标识>/`（那里有自己的 `CLAUDE.md`）；`guoapp-sources` 只读、只作对照，不要改动，也不再编译。探测脚本 skill `masked-probe` 在 `guoapp-sources` 的 `.claude/skills/` 里。

- 新写或改动站源模块时，详情页必须抓取作者/发布者信息，且必须支持点作者名进入作者二级页：
  - 个人上传站：`author` / `authorId` / `authorUrl` 填上传者，保证作者页能列出他的全部作品。
  - AV 站：`author` / `authorId` / `authorUrl` 优先填上传者或片商/频道；`actors` 填女优数组；`maker` 填片商；系列、厂牌、频道等信息能取到就一并抓取，模型暂无独立 `series` 字段时并入 `tags`，不要丢。
  - 不能只抓标题和封面；详情页能取到的作者、女优、片商、系列/标签必须全部映射。
  - 详情页能取到的「上传时间 / 添加时间 / 发行日期」必须填入 `onlineDate`（模块字段，会映射到 App 的 `releaseDate` 并显示在详情页时间一栏），格式统一为 `YYYY-MM-DD`；拿不到日期时才留空。
  - 列表卡片（`catalogPage()` / `search()` / `rankingPage()` 返回的每一条）也要把卡片上已有的信息映射到对应字段，**字段名必须跟 Go 侧一致**，写错名字界面就不会显示：
    - 卡片上有「2:15:53」这类时长角标 → 填 `durationText`（**不要塞进 `desc`、`remark` 或 `duration`**，那些字段界面不读）；
    - 卡片上有清晰度标记（HD / 4K / 1080P）→ 填 `badge`；
    - 卡片上有字幕标记（中文字幕 / 中字 / 有码无码等）→ 加进 `tags` 数组；
    - 卡片上有集数（共 X 集 / 全 X 集）→ 填 `badge` 或复用 `remark`，但不要和 `durationText` 抢同一个元素。
  - 反面例子（都踩过）：`missav` 列表卡片明明有 `2:15:53` 角标却完全没抓；`p91` 抓到了时长却塞进 `desc`（`'时长 ' + duration`），界面只认 `durationText`，用户以为功能没做。
- 新模块交付前逐项自查，缺一项都算没做完（这是长期要求，不再逐次请示）：
  1. `detail()` 必须返回非空的 `author`、`authorId`、`authorUrl`；
  2. AV 站同时返回 `actors`（女优数组）与 `maker`（片商），系列/厂牌/频道并入 `tags`；
  3. 必须导出 `author(authorId, authorName, page)`，直接请求该站作者页并翻页，返回 `{ items, hasMore }`；
  4. `author()` 返回的条目带 `author` / `authorId`，二级页里还能继续点进去；
  5. `catalogPage()` / `search()` 的条目在列表页能取到作者时也一并带上，不要让用户必须先点进详情；
  6. `detail()` 页面里有上传/添加/发行时间时，返回 `onlineDate`（格式 YYYY-MM-DD），不要漏；
  7. `catalogPage()` / `search()` / `rankingPage()` 的条目，卡片上能看到的时长/清晰度/字幕/集数要填进 `durationText` / `badge` / `tags`，**字段名必须跟 Go 侧一致**（写错就不显示）。
