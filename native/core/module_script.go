package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

const (
	moduleInstanceLimit = 4
	moduleCallTimeout   = 60 * time.Second
	moduleQuickTimeout  = 5 * time.Second
)

var moduleInvoker = goja.MustCompile("module-invoker", `(function(exports) {
	return function(name, encoded) {
		var target = exports[name];
		if (typeof target !== "function") throw new Error("模块未导出函数 " + name);
		var result = target.apply(exports, JSON.parse(encoded));
		if (result instanceof Promise) throw new Error("模块函数 " + name + " 不能是异步函数");
		return JSON.stringify(result === undefined ? null : result);
	};
})`, true)

var moduleProbe = goja.MustCompile("module-probe", `(function(exports, name) {
	return typeof exports[name] === "function";
})`, true)

type jsProvider struct {
	module    *jsModule
	host      Host
	exclusive chan struct{}
	slots     chan struct{}
	idle      chan *jsInstance
	cacheMu   sync.Mutex
	cache     map[string]moduleCacheEntry
}

type jsInstance struct {
	vm        *goja.Runtime
	invoke    goja.Callable
	has       goja.Callable
	exports   goja.Value
	ctx       context.Context
	exclusive bool
}

type jsFetchRequest struct {
	Method          string            `json:"method"`
	URL             string            `json:"url"`
	Headers         map[string]string `json:"headers"`
	Body            string            `json:"body"`
	TimeoutMS       int64             `json:"timeoutMs"`
	Limit           int64             `json:"limit"`
	FollowRedirects bool              `json:"followRedirects"`
	AnyStatus       bool              `json:"anyStatus"`
	AcceptStatus    []int             `json:"acceptStatus"`
	Ticket          uint64            `json:"ticket"`
	Background      bool              `json:"background"`
	Direct          bool              `json:"direct"`
}

type jsFetchResponse struct {
	Status    int                 `json:"status"`
	Headers   map[string][]string `json:"headers"`
	Body      string              `json:"body"`
	Blocked   bool                `json:"blocked"`
	Oversized bool                `json:"oversized"`
}

type jsDramaPage struct {
	Items   []Drama `json:"items"`
	HasMore bool    `json:"hasMore"`
	Warning string  `json:"warning"`
}

type jsDetail struct {
	Drama    Drama     `json:"drama"`
	Chapters []Chapter `json:"chapters"`
}

type jsTextRequest struct {
	URL       string   `json:"url"`
	Referer   string   `json:"referer"`
	UserAgent string   `json:"userAgent"`
	Cookie    string   `json:"cookie"`
	NoCache   bool     `json:"noCache"`
	Body      string   `json:"body"`
	Mirrors   []string `json:"mirrors"`
}

type jsTextResponse struct {
	Body string `json:"body"`
	URL  string `json:"url"`
}

type jsPlaylistRequest struct {
	URL         string         `json:"url"`
	Referer     string         `json:"referer"`
	Credentials *jsCredentials `json:"credentials"`
}

type jsPlaylist struct {
	Playlist   string `json:"playlist"`
	URL        string `json:"url"`
	DurationMS int64  `json:"durationMs"`
}

type jsURL struct {
	Scheme   string `json:"scheme"`
	Host     string `json:"host"`
	Hostname string `json:"hostname"`
	Port     string `json:"port"`
	Path     string `json:"path"`
	Query    string `json:"query"`
	Fragment string `json:"fragment"`
	UserInfo bool   `json:"userInfo"`
	Href     string `json:"href"`
}

type jsCredentials struct {
	Cookie    string `json:"cookie"`
	Origin    string `json:"origin"`
	Referer   string `json:"referer"`
	UserAgent string `json:"userAgent"`
	ExpiresMS int64  `json:"expiresMs"`

	OmitFetchMetadata bool `json:"omitFetchMetadata"`
}

type jsMedia struct {
	Credentials *jsCredentials `json:"credentials"`
	URL         string         `json:"url"`
	Referer     string         `json:"referer"`
	Playlist    string         `json:"playlist"`
	HLSKey      []byte         `json:"hlsKey"`
	CENCKey     []byte         `json:"cencKey"`
	Quality     int            `json:"quality"`
	DurationMS  int64          `json:"durationMs"`
	Variants    []jsMedia      `json:"variants"`
}

func (media jsMedia) providerMedia() ProviderMedia {
	converted := ProviderMedia{URL: media.URL, Referer: media.Referer, Playlist: media.Playlist, Quality: media.Quality,
		HLSKey: media.HLSKey, CENCKey: media.CENCKey, Duration: time.Duration(media.DurationMS) * time.Millisecond}
	if credentials := media.Credentials; credentials != nil {
		converted.Credentials = &MediaCredentials{Cookie: credentials.Cookie, Origin: credentials.Origin,
			Referer: credentials.Referer, UserAgent: credentials.UserAgent, OmitFetchMetadata: credentials.OmitFetchMetadata}
		if credentials.ExpiresMS > 0 {
			converted.Credentials.Expires = time.UnixMilli(credentials.ExpiresMS)
		}
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, variant.providerMedia())
	}
	return converted
}

func moduleMedia(media ProviderMedia) jsMedia {
	converted := jsMedia{URL: media.URL, Referer: media.Referer, Playlist: media.Playlist, Quality: media.Quality,
		HLSKey: media.HLSKey, CENCKey: media.CENCKey, DurationMS: media.Duration.Milliseconds()}
	if credentials := media.Credentials; credentials != nil {
		converted.Credentials = &jsCredentials{Cookie: credentials.Cookie, Origin: credentials.Origin,
			Referer: credentials.Referer, UserAgent: credentials.UserAgent, OmitFetchMetadata: credentials.OmitFetchMetadata}
		if !credentials.Expires.IsZero() {
			converted.Credentials.ExpiresMS = credentials.Expires.UnixMilli()
		}
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, moduleMedia(variant))
	}
	return converted
}

func (module *jsModule) provider(host Host) Provider {
	p := &jsProvider{module: module, host: host, exclusive: make(chan struct{}, 1), cache: map[string]moduleCacheEntry{},
		slots: make(chan struct{}, moduleInstanceLimit), idle: make(chan *jsInstance, moduleInstanceLimit)}
	module.active.Store(p)
	return p
}

func (module *jsModule) validCategory(category string) bool {
	if category == "" {
		return true
	}
	// 分类列表拿过一次就以它为准：既快，也不会因为实例池排队超时被误判成
	// 「内容分类无效」。
	if known, ok := module.knownCategory(category); ok && known {
		return true
	}
	p := module.active.Load()
	if p == nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), moduleQuickTimeout)
	defer cancel()
	var valid bool
	if p.call(ctx, "validCategory", &valid, category) != nil || !valid {
		return false
	}
	module.categoryMu.Lock()
	if module.categoryIDs == nil {
		module.categoryIDs = map[string]bool{}
	}
	module.categoryIDs[category] = true
	module.categoryMu.Unlock()
	return true
}

func (p *jsProvider) Descriptor() SourceDescriptor { return p.module.descriptor() }

func (p *jsProvider) ProvidesCapability(capability reflect.Type) bool {
	return p.module.capabilities[capability]
}

func (p *jsProvider) Categories(ctx context.Context, force bool) ([]Category, error) {
	var raw json.RawMessage
	if err := p.call(ctx, "categories", &raw, force); err != nil {
		return nil, err
	}
	var categories []Category
	if json.Unmarshal(raw, &categories) == nil {
		p.module.rememberCategoryIDs(categories)
		return categories, nil
	}
	var partial struct {
		Items      []Category `json:"items"`
		Incomplete bool       `json:"incomplete"`
	}
	if err := json.Unmarshal(raw, &partial); err != nil {
		return nil, err
	}
	p.module.rememberCategoryIDs(partial.Items)
	if partial.Incomplete {
		return partial.Items, ErrCategoriesIncomplete
	}
	return partial.Items, nil
}

func (p *jsProvider) CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	var result jsDramaPage
	if err := p.call(ctx, "catalogPage", &result, page, category); err != nil {
		return nil, false, err
	}
	if result.Warning != "" {
		return result.Items, result.HasMore, errors.New(result.Warning)
	}
	return result.Items, result.HasMore, nil
}

func (p *jsProvider) Search(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	items, more, _, err := p.SearchWithWarning(ctx, page, query)
	return items, more, err
}

func (p *jsProvider) SearchWithWarning(ctx context.Context, page int, query string) ([]Drama, bool, string, error) {
	var result jsDramaPage
	err := p.call(ctx, "search", &result, page, query)
	return result.Items, result.HasMore, result.Warning, err
}

func (p *jsProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	var result jsDetail
	err := p.call(ctx, "detail", &result, sourceID)
	return result.Drama, result.Chapters, err
}

func (p *jsProvider) Account(ctx context.Context, command string, payload json.RawMessage) (any, error) {
	var result any
	return result, p.call(ctx, "account", &result, command, payload)
}

func (p *jsProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	var media jsMedia
	if err := p.call(ctx, "resolveMedia", &media, task); err != nil {
		return ProviderMedia{}, err
	}
	return media.providerMedia(), nil
}

// hasExport 判断模块是否导出了指定函数，用于可选能力的探测（不写进 manifest 也能用）。
func (p *jsProvider) hasExport(ctx context.Context, name string) bool {
	if ctx.Err() != nil {
		return false
	}
	instance, err := p.acquire(ctx)
	if err != nil {
		return false
	}
	defer func() { p.idle <- instance }()
	if instance.has == nil || instance.exports == nil {
		return false
	}
	value, err := instance.has(goja.Undefined(), instance.exports, instance.vm.ToValue(name))
	if err != nil || value == nil {
		return false
	}
	return value.ToBoolean()
}

// AuthorPage 走模块可选的 author(authorId, authorName, page) 导出。
// 模块没写这个函数时返回 ErrAuthorUnsupported，由内核退回到关键词搜索。
func (p *jsProvider) AuthorPage(ctx context.Context, author AuthorRef, page int) ([]Drama, bool, error) {
	if !p.hasExport(ctx, "author") {
		return nil, false, ErrAuthorUnsupported
	}
	var result jsDramaPage
	if err := p.call(ctx, "author", &result, author.ID, author.Name, page); err != nil {
		return nil, false, err
	}
	if result.Warning != "" && len(result.Items) == 0 {
		return result.Items, result.HasMore, errors.New(result.Warning)
	}
	return result.Items, result.HasMore, nil
}

func (p *jsProvider) call(ctx context.Context, function string, result any, arguments ...any) error {
	ctx, cancel := context.WithTimeout(ctx, moduleCallTimeout)
	defer cancel()
	encoded, err := json.Marshal(arguments)
	if err != nil {
		return err
	}
	instance, err := p.acquire(ctx)
	if err != nil {
		return err
	}
	defer func() { p.idle <- instance }()
	instance.ctx = ctx
	interrupted := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		instance.vm.Interrupt(ctx.Err())
		close(interrupted)
	})
	value, err := instance.invoke(goja.Undefined(), instance.vm.ToValue(function), instance.vm.ToValue(string(encoded)))
	if !stop() {
		<-interrupted
		instance.vm.ClearInterrupt()
	}
	if err != nil {
		return moduleError(ctx, err)
	}
	return json.Unmarshal([]byte(value.String()), result)
}

func moduleError(ctx context.Context, err error) error {
	var interrupted *goja.InterruptedError
	if errors.As(err, &interrupted) && ctx.Err() != nil {
		return ctx.Err()
	}
	var exception *goja.Exception
	if !errors.As(err, &exception) {
		return err
	}
	if cause := exception.Unwrap(); cause != nil {
		return cause
	}
	if thrown, ok := exception.Value().(*goja.Object); ok {
		if message := thrown.Get("message"); message != nil && !goja.IsUndefined(message) {
			if login := thrown.Get("loginRequired"); login != nil && login.ToBoolean() {
				return SourceLoginError(message.String())
			}
			return errors.New(message.String())
		}
	}
	return errors.New(exception.Value().String())
}

func (p *jsProvider) acquire(ctx context.Context) (*jsInstance, error) {
	select {
	case instance := <-p.idle:
		return instance, nil
	default:
	}
	select {
	case instance := <-p.idle:
		return instance, nil
	case p.slots <- struct{}{}:
		instance, err := p.newInstance()
		if err != nil {
			<-p.slots
		}
		return instance, err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (p *jsProvider) newInstance() (*jsInstance, error) {
	vm := goja.New()
	vm.SetFieldNameMapper(goja.TagFieldNameMapper("json", true))
	instance := &jsInstance{vm: vm, ctx: context.Background()}
	module, exports := vm.NewObject(), vm.NewObject()
	if err := module.Set("exports", exports); err != nil {
		return nil, err
	}
	wrapper, err := vm.RunProgram(p.module.program)
	if err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	load, _ := goja.AssertFunction(wrapper)
	if _, err := load(goja.Undefined(), module, exports, p.hostObject(instance)); err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	invoker, err := vm.RunProgram(moduleInvoker)
	if err != nil {
		return nil, err
	}
	bind, _ := goja.AssertFunction(invoker)
	bound, err := bind(goja.Undefined(), module.Get("exports"))
	if err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	instance.invoke, _ = goja.AssertFunction(bound)
	instance.exports = module.Get("exports")
	if probe, err := vm.RunProgram(moduleProbe); err == nil {
		check, _ := goja.AssertFunction(probe)
		instance.has = check
	}
	return instance, nil
}

func (p *jsProvider) hostObject(instance *jsInstance) *goja.Object {
	id := p.module.manifest.ID
	host := instance.vm.NewObject()
	members := map[string]any{
		"source":    id,
		"dramaId":   func(sourceID string) string { return ProviderDramaID(id, sourceID) },
		"chapterId": func(sourceID, key string) string { return ProviderChapterID(id, sourceID, key) },
		"fetch": func(request jsFetchRequest) jsFetchResponse {
			response, err := p.fetch(instance.ctx, request)
			if err != nil {
				instance.failResponse(err, response)
			}
			return response
		},
		"fetchText": func(request jsTextRequest) jsTextResponse {
			response, err := p.fetchText(instance.ctx, request)
			if err != nil {
				instance.fail(err, false)
			}
			return response
		},
		"parseUrl":      parseModuleURL,
		"preferredSite": func() string { return p.host.PreferredSite(id) },
		"fetchPlaylist": func(request jsPlaylistRequest) (jsPlaylist, error) {
			return p.fetchPlaylist(instance.ctx, request)
		},
		"exclusive": func(call goja.FunctionCall) goja.Value {
			critical, ok := goja.AssertFunction(call.Argument(0))
			if !ok {
				panic(instance.vm.NewTypeError("exclusive 需要一个函数"))
			}
			if instance.exclusive {
				panic(instance.vm.NewTypeError("exclusive 不可重入"))
			}
			select {
			case p.exclusive <- struct{}{}:
			case <-instance.ctx.Done():
				panic(instance.vm.NewGoError(instance.ctx.Err()))
			}
			instance.exclusive = true
			defer func() {
				instance.exclusive = false
				<-p.exclusive
			}()
			value, err := critical(goja.Undefined())
			if err != nil {
				panic(err)
			}
			return value
		},
		"prepareWebMedia": func(media jsMedia, sourceName string) (jsMedia, error) {
			prepared, err := p.host.PrepareWebMedia(instance.ctx, media.providerMedia(), sourceName)
			return moduleMedia(prepared), err
		},
		"loadState": func(name string) (string, error) {
			data, err := p.host.LoadState(moduleStatePrefix + id + "-" + name)
			return string(data), err
		},
		"saveState": func(name, value string) error {
			return p.host.SaveState(moduleStatePrefix+id+"-"+name, []byte(value))
		},
		// 站点验证拿到的 cookie / UA：模块直接拼进 fetchText 即可。
		"challengeCookie": ChallengeCookie,
		"challengeUA":     ChallengeUserAgent,
		// 模块解析失败时上报该 URL，App 会用验证过的 WebView 重抓并塞进页缓存。
		"noteChallenge": func(url string) { NoteChallenged(url) },
		"log": func(message string) {
			if downloader, ok := p.host.(*Downloader); ok {
				downloader.recordDiagnostic(diagnosticEvent{Time: time.Now(), Level: "info", Event: "module", Source: id, Message: message})
			}
		},
	}
	maps.Copy(members, p.hostUtilities(instance))
	for name, member := range members {
		_ = host.Set(name, member)
	}
	return host
}

func (instance *jsInstance) fail(err error, oversized bool) {
	instance.failResponse(err, jsFetchResponse{Oversized: oversized})
}

func (instance *jsInstance) failResponse(err error, response jsFetchResponse) {
	failure := instance.vm.NewGoError(err)
	var backoff *RequestBackoff
	_ = failure.Set("backoff", errors.As(err, &backoff))
	_ = failure.Set("oversized", response.Oversized)
	_ = failure.Set("status", response.Status)
	_ = failure.Set("body", response.Body)
	_ = failure.Set("blocked", response.Blocked)
	panic(failure)
}

func moduleBody(body string) []byte {
	if body == "" {
		return nil
	}
	return []byte(body)
}

func parseModuleURL(raw string) (jsURL, error) {
	address, err := url.Parse(raw)
	if err != nil {
		return jsURL{}, errors.New("地址无效")
	}
	return jsURL{Scheme: address.Scheme, Host: address.Host, Hostname: address.Hostname(), Port: address.Port(),
		Path: address.Path, Query: address.RawQuery, Fragment: address.Fragment, UserInfo: address.User != nil, Href: address.String()}, nil
}

func (p *jsProvider) allowedAddress(raw string) error {
	address, err := url.Parse(raw)
	if err != nil || address.Scheme != "https" && address.Scheme != "http" || address.Hostname() == "" {
		return errors.New("请求地址无效")
	}
	if !p.module.allowsHost(address.Hostname()) {
		return fmt.Errorf("模块清单未声明访问 %s", address.Hostname())
	}
	return nil
}

func (p *jsProvider) fetchPlaylist(ctx context.Context, request jsPlaylistRequest) (jsPlaylist, error) {
	media := jsMedia{Credentials: request.Credentials}.providerMedia()
	playlist, address, err := p.host.FetchPlaylist(ctx, request.URL, request.Referer, media.Credentials)
	return jsPlaylist{Playlist: playlist, URL: address, DurationMS: M3u8Duration(playlist).Milliseconds()}, err
}

// applyChallengeText 把该主机验证过的通行 cookie / 真实 UA 自动补进文本请求。
// 模块自己不必拼：任何站源在 App 里完成人机验证后，后续请求都会直接复用。
// UA 必须优先覆盖模块里的固定值——cf_clearance 是绑 UA 签发的，用别的 UA 会被直接拦。
func applyChallengeText(request *jsTextRequest) {
	host := hostOfURL(request.URL)
	if host == "" {
		return
	}
	if request.Cookie == "" {
		request.Cookie = ChallengeCookie(host)
	}
	if agent := ChallengeUserAgent(host); agent != "" {
		request.UserAgent = agent
	}
}

// applyChallengeFetch 对普通 fetch 补同样的 cookie / UA：cookie 模块显式设置的优先，
// UA 始终用验证时那串（cf_clearance 绑 UA，换 UA 必被拦）。
func applyChallengeFetch(request *jsFetchRequest) {
	host := hostOfURL(request.URL)
	if host == "" {
		return
	}
	cookie := ChallengeCookie(host)
	agent := ChallengeUserAgent(host)
	if cookie == "" && agent == "" {
		return
	}
	if request.Headers == nil {
		request.Headers = map[string]string{}
	}
	if cookie != "" && request.Headers["Cookie"] == "" && request.Headers["cookie"] == "" {
		request.Headers["Cookie"] = cookie
	}
	// 验证过的 UA 优先：cf_clearance 绑 UA，模块固定写死的 UA 会被 Cloudflare 判为不匹配。
	if agent != "" {
		delete(request.Headers, "user-agent")
		request.Headers["User-Agent"] = agent
	}
}

func (p *jsProvider) fetchText(ctx context.Context, request jsTextRequest) (jsTextResponse, error) {
	if err := p.allowedAddress(request.URL); err != nil {
		return jsTextResponse{}, err
	}
	applyChallengeText(&request)
	// 验证过的站点：优先用 App 那台真 WebView 抓回的页面。
	// tls-client 的 Safari 指纹和真 WebKit 对不上，Cloudflare 会二次拦截，
	// 缓存命中就等于复用了「过验证那次」的指纹会话。
	if host := hostOfURL(request.URL); host != "" && ChallengeCookie(host) != "" {
		// 缓存里若是挑战页，按未命中处理：否则每次都会读到坏内容且不再重抓。
		if body, ok := WebPage(request.URL); ok && !looksLikeChallengeBody(body) {
			return jsTextResponse{Body: body, URL: request.URL}, nil
		}
		// 还没抓过，或抓回来的是挑战页：交给 App 重抓，
		// 不要用 Go 客户端硬闯 TLS 指纹这一关。
		NoteChallenged(request.URL)
	}
	var mirrors []string
	for _, mirror := range request.Mirrors {
		if p.allowedAddress(mirror) == nil {
			mirrors = append(mirrors, mirror)
		}
	}
	response, err := p.host.FetchText(ctx, TextRequest{URL: request.URL, Referer: request.Referer, UserAgent: request.UserAgent,
		Cookie: request.Cookie, NoCache: request.NoCache, Body: moduleBody(request.Body), Mirrors: mirrors})
	// 被 Cloudflare 挑战：记下 URL，待 App 用验证过的 WebView 重抓。
	// 不要求已验证——首次进入正是先被挑战、验证后才回来重抓的。
	if err != nil || strings.TrimSpace(response.Body) == "" || looksLikeChallengeBody(response.Body) {
		NoteChallenged(request.URL)
	}
	return jsTextResponse{Body: response.Body, URL: response.URL}, err
}

func (p *jsProvider) fetch(ctx context.Context, request jsFetchRequest) (jsFetchResponse, error) {
	if err := p.allowedAddress(request.URL); err != nil {
		return jsFetchResponse{}, err
	}
	applyChallengeFetch(&request)
	// 同 fetchText：验证过的站点先查 WebView 抓回的页面缓存。
	if host := hostOfURL(request.URL); host != "" && ChallengeCookie(host) != "" {
		if body, ok := WebPage(request.URL); ok && !looksLikeChallengeBody(body) {
			return jsFetchResponse{Status: 200, Body: body}, nil
		}
		NoteChallenged(request.URL)
	}
	if request.Background {
		ctx = context.WithValue(ctx, BackgroundCatalogKey{}, true)
	}
	response, err := p.host.Fetch(ctx, HTTPRequest{
		Label: p.module.manifest.Name, Method: request.Method, URL: request.URL, Header: request.Headers,
		Body: moduleBody(request.Body), Timeout: time.Duration(request.TimeoutMS) * time.Millisecond, Limit: request.Limit,
		FollowRedirects: request.FollowRedirects, AnyStatus: request.AnyStatus, AcceptJSONStatus: request.AcceptStatus, Ticket: request.Ticket,
		Direct: request.Direct,
	})
	// 被 Cloudflare 挑战（错误、空响应、403/429/503 或挑战特征）：记下 URL 供 WebView 重抓。
	if err != nil || len(response.Body) == 0 || response.Status == 403 || response.Status == 429 ||
		response.Status == 503 || looksLikeChallengeBody(string(response.Body)) {
		NoteChallenged(request.URL)
	}
	if err != nil {
		return jsFetchResponse{Status: response.Status, Body: string(response.Body), Blocked: response.Blocked, Oversized: response.Oversized}, err
	}
	return jsFetchResponse{Status: response.Status, Headers: response.Header, Body: string(response.Body),
		Blocked: response.Blocked, Oversized: response.Oversized}, nil
}
