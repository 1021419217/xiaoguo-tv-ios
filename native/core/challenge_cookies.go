package core

import (
	"encoding/json"
	"strings"
	"sync"
)

// 站点人机验证（Cloudflare 的 cf_clearance 之类）拿到的东西。
//
// 纯 HTTP 客户端过不了带 JS 的挑战，只能由 App 侧用一个真正的 WebView 走一遍
// 验证，再把 cookie 和 WebView 的真实 User-Agent 回填到这里。Cloudflare 把
// cf_clearance 绑在「解挑战时用的 UA」上，所以后续所有请求必须原样带上这串
// UA，模块用 host.challengeUA(主机名) / host.challengeCookie(主机名) 取即可。
type challengeCookieStore struct {
	mu     sync.RWMutex
	values map[string]challengeCredential
}

type challengeCredential struct {
	Cookie    string `json:"cookie"`
	UserAgent string `json:"ua"`
}

var challengeCookies = &challengeCookieStore{values: map[string]challengeCredential{}}

func challengeHostKey(host string) string {
	key := strings.ToLower(strings.TrimSpace(host))
	key = strings.TrimPrefix(key, "www.")
	if index := strings.IndexByte(key, ':'); index >= 0 {
		key = key[:index]
	}
	return key
}

// 只有这几个站点真正依赖 Cloudflare cf_clearance 人机验证：它们验证后必须用
// WebView 的真实 UA + Safari 指纹重发，否则通行 cookie 会被判成「换了浏览器的
// 机器人」而作废。除此之外的所有站点（含 MissAV）一律不参与验证态切换，走与
// 上游一致的干净 Chrome 指纹——历史 cookie 不再影响它们的指纹/UA/取页方式，
// 从根本上避免被旧的、已失效的验证记录拖进反复验证的死循环。
var verifiedChallengeHosts = []string{
	"jable.tv", "fs1.app", "mushroomtrack.com",
	"avple.tv", "avple.app", "cdnedge.live",
	"5lxtv.com", "avtube.xyz",
}

func isVerifiedChallengeHost(host string) bool {
	key := challengeHostKey(host)
	if key == "" {
		return false
	}
	for _, root := range verifiedChallengeHosts {
		if key == root || strings.HasSuffix(key, "."+root) {
			return true
		}
	}
	return false
}

func challengeLookup(host string) challengeCredential {
	key := challengeHostKey(host)
	if key == "" || !isVerifiedChallengeHost(host) {
		return challengeCredential{}
	}
	challengeCookies.mu.RLock()
	defer challengeCookies.mu.RUnlock()
	if value, found := challengeCookies.values[key]; found {
		return value
	}
	// 父域兜底：m.jable.tv → jable.tv
	for name, value := range challengeCookies.values {
		if strings.HasSuffix(key, "."+name) {
			return value
		}
	}
	return challengeCredential{}
}

// ChallengeCookie 返回该主机可用的验证 cookie，没有则返回空串。
func ChallengeCookie(host string) string { return challengeLookup(host).Cookie }

// ChallengeUserAgent 返回解挑战时用的真实 UA，没有则返回空串。
func ChallengeUserAgent(host string) string { return challengeLookup(host).UserAgent }

func SetChallenge(host, cookie, userAgent string) string {
	key := challengeHostKey(host)
	if key == "" {
		return ""
	}
	challengeCookies.mu.Lock()
	defer challengeCookies.mu.Unlock()
	previous := challengeCookies.values[key]
	if strings.TrimSpace(cookie) == "" && strings.TrimSpace(userAgent) == "" {
		delete(challengeCookies.values, key)
		return ""
	}
	if strings.TrimSpace(cookie) != "" {
		previous.Cookie = strings.TrimSpace(cookie)
	}
	if strings.TrimSpace(userAgent) != "" {
		previous.UserAgent = strings.TrimSpace(userAgent)
	}
	challengeCookies.values[key] = previous
	return key
}

func loadChallengeCookies(data []byte) {
	if len(data) == 0 {
		return
	}
	var values map[string]challengeCredential
	if json.Unmarshal(data, &values) != nil {
		return
	}
	challengeCookies.mu.Lock()
	defer challengeCookies.mu.Unlock()
	for host, value := range values {
		if key := challengeHostKey(host); key != "" {
			challengeCookies.values[key] = value
		}
	}
}

func dumpChallengeCookies() []byte {
	challengeCookies.mu.RLock()
	defer challengeCookies.mu.RUnlock()
	if len(challengeCookies.values) == 0 {
		return nil
	}
	data, err := json.Marshal(challengeCookies.values)
	if err != nil {
		return nil
	}
	return data
}

const challengeCookieState = "challenge-cookies"
