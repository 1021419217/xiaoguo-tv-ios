package core

import (
	"net/url"
	"strings"
	"sync"
	"time"
)

// 站点验证通过后，由 App 侧那台真正过了 Cloudflare 挑战的 WKWebView 把页面抓回来，
// 注入到这里。Go 的 tls-client 指纹再像 Safari 也和真 WebKit 对不上，Cloudflare 会
// 二次拦截；模块取页时命中这份缓存就直接用 HTML，不再走自己的 TLS 栈。
// 这正是 iDuanJu「URLSession 被拦就改用验证过的 WebView fetch」那一层在小果同步
// FFI 架构下的等价实现。
type webPageEntry struct {
	Body string
	At   time.Time
}

var webPageCache = struct {
	sync.RWMutex
	pages   map[string]webPageEntry
	pending map[string]time.Time // 被挑战、待 WebView 抓取的 URL
}{
	pages:   map[string]webPageEntry{},
	pending: map[string]time.Time{},
}

// 页面缓存只服务短时间内的一轮取页，避免旧 HTML 长期压住站点更新。
const webPageTTL = 10 * time.Minute

// webPageKey 统一归一化 URL：去掉 fragment，空 host 也给个稳定串。
func webPageKey(raw string) string {
	raw = strings.TrimSpace(raw)
	if u, err := url.Parse(raw); err == nil {
		u.Fragment = ""
		return u.String()
	}
	return raw
}

// SetWebPage 注入一页 WebView 抓回的 HTML。
func SetWebPage(pageURL, body string) {
	key := webPageKey(pageURL)
	if key == "" || body == "" {
		return
	}
	webPageCache.Lock()
	webPageCache.pages[key] = webPageEntry{Body: body, At: time.Now()}
	delete(webPageCache.pending, key)
	webPageCache.Unlock()
}

// WebPage 命中未过期的缓存页。
func WebPage(pageURL string) (string, bool) {
	key := webPageKey(pageURL)
	webPageCache.RLock()
	entry, found := webPageCache.pages[key]
	webPageCache.RUnlock()
	if !found || time.Since(entry.At) > webPageTTL {
		return "", false
	}
	return entry.Body, true
}

// NoteChallenged 记录一个被 Cloudflare 挑战的 URL，供 App 侧用验证过的 WebView 重抓。
func NoteChallenged(pageURL string) {
	key := webPageKey(pageURL)
	if key == "" {
		return
	}
	webPageCache.Lock()
	webPageCache.pending[key] = time.Now()
	webPageCache.Unlock()
}

// TakePendingWebPages 取出并清空待抓 URL（验证成功后调用一次）。
func TakePendingWebPages() []string {
	webPageCache.Lock()
	defer webPageCache.Unlock()
	var out []string
	for key := range webPageCache.pending {
		if time.Since(webPageCache.pending[key]) <= webPageTTL {
			out = append(out, key)
		}
		delete(webPageCache.pending, key)
	}
	return out
}

// ClearWebPages 清空缓存与待抓队列（验证信息变化、切换用户时调用）。
func ClearWebPages() {
	webPageCache.Lock()
	webPageCache.pages = map[string]webPageEntry{}
	webPageCache.pending = map[string]time.Time{}
	webPageCache.Unlock()
}

// hostOfURL 取 URL 主机名，用和验证 cookie 相同的归一化规则，保证能对着
// ChallengeCookie 查到凭据。解析失败返回空串。
func hostOfURL(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}
	return challengeHostKey(u.Hostname())
}

// looksLikeChallengeBody 粗判一段 HTML 是不是 Cloudflare 挑战页。只用于决定
// 要不要把 URL 加入待抓队列，判断尺度宁可宽一点。
func looksLikeChallengeBody(body string) bool {
	head := body
	if len(head) > 8000 {
		head = head[:8000]
	}
	lower := strings.ToLower(head)
	return strings.Contains(lower, "just a moment") ||
		strings.Contains(lower, "cf-chl-opt") ||
		strings.Contains(lower, "cf_chl_opt") ||
		strings.Contains(lower, "attention required") ||
		strings.Contains(lower, "challenge-platform") ||
		strings.Contains(lower, "请稍候") ||
		strings.Contains(lower, "請稍候")
}
