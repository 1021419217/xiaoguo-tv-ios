package core

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// logMissingAuthor 只在「详情解析完仍然没有作者」时落一条诊断。
//
// 用途是把两种情况分开：
//   - meta 为空、page 为空 → 模块压根没把作者带出来，App 侧再怎么识别也没用；
//   - meta 里有一堆键但作者仍为空 → 字段名没被 recognition 覆盖，照着键名补别名就行。
//
// 只记键名，不记字段内容，避免把无关数据写进日记。
func (engine *nativeEngine) logMissingAuthor(source string, drama LibraryDrama, raw Drama, chapters []Chapter) {
	if engine.downloader == nil {
		return
	}
	page := ""
	if len(chapters) > 0 {
		page = chapters[0].PageURL
	}
	keys := make([]string, 0, len(raw.Meta))
	for key := range raw.Meta {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	message := fmt.Sprintf("title=%s | tags=%s | metaKeys=%s | page=%s",
		Truncate(drama.Title, 60),
		Truncate(strings.Join(drama.Tags, "|"), 120),
		Truncate(strings.Join(keys, ","), 160),
		Truncate(page, 200))
	engine.downloader.recordDiagnostic(diagnosticEvent{
		Time:    time.Now(),
		Level:   "info",
		Event:   "author_missing",
		Source:  source,
		DramaID: drama.ID,
		Message: message,
	})
}
