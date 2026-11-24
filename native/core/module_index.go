package core

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 个人索引的短缓存：用户连点刷新时不必每次都打 GitHub API
// （未认证限流 60 次/小时，点几十下就会被 403，反而掉到旧缓存）。
var (
	personalIndexMu     sync.Mutex
	personalIndexAt     time.Time
	personalIndexCached []personalIndexEntry
	personalIndexMirror int
)

const (
	moduleIndexFormat  = 1
	moduleIndexBytes   = 1 << 20
	moduleFetchTimeout = 20 * time.Second
)

var (
	moduleIndexAddresses = []string{
		"https://raw.githubusercontent.com/guoapp-modules/index/main/index.json",
		"https://cdn.jsdelivr.net/gh/guoapp-modules/index@main/index.json",
	}
	moduleFileAddresses = []string{
		"https://raw.githubusercontent.com/%s/%s/%s",
		"https://cdn.jsdelivr.net/gh/%s@%s/%s",
	}
	moduleIndexRepo = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
	moduleIndexTag  = regexp.MustCompile(`^v\d+\.\d+\.\d+$`)
	moduleIndexHash = regexp.MustCompile(`^[0-9a-f]{64}$`)

	// 个人在线仓库：单仓库放全部模块，地址独立于官方索引。
	// 改这里的地址即可换自己的仓库，不影响官方模块商店。
	// 顺序有讲究：raw.githubusercontent.com 的 main 分支带 max-age=300，
	// 加时间戳也绕不过（实测 ?t= 仍返回旧内容）。GitHub API 配合
	// Accept: application/vnd.github.raw 直接返回原文、缓存只有 60 秒，
	// 是唯一能及时看到刚同步内容的通道，放第一位。
	// 完全对齐上游官方模块商店的做法：只用 raw + jsDelivr，**不碰 GitHub API**。
	// API 未认证只有 60 次/小时，连点刷新就 403，这是本功能之前所有麻烦的来源；
	// 上游压根不用它，也就没有这个限制。
	//   raw main        缓存 5 分钟，内容 = 最新 commit，无任何配额
	//   jsDelivr @latest 国内可达，但实测会缓存旧内容
	//                  （2026-11-25：@latest 返回 v1.0.18 而最新是 v1.0.24）
	// 两个源**并发**请求、取 tag 最新的那份，脏的那个不会把索引带旧。
	personalIndexAddresses = []string{
		"https://raw.githubusercontent.com/1021419217/xg-modules/main/index.json",
		"https://cdn.jsdelivr.net/gh/1021419217/xg-modules@latest/index.json",
	}
	// %s 依次是：仓库名、tag、模块在仓库里的子目录、文件名
	personalFileAddresses = []string{
		"https://raw.githubusercontent.com/%s/%s/%s/%s",
		"https://cdn.jsdelivr.net/gh/%s@%s/%s/%s",
	}
	personalIndexPath = regexp.MustCompile(`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`)
)

// 个人索引的条目：和官方条目同构，多一个 path 字段指向单仓库里的子目录。
type personalIndexEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Version     string            `json:"version"`
	Description string            `json:"description"`
	API         int               `json:"api"`
	Adult       bool              `json:"adult"`
	Repo        string            `json:"repo"`
	Tag         string            `json:"tag"`
	Path        string            `json:"path"`
	SHA256      map[string]string `json:"sha256"`
}

func (entry personalIndexEntry) usable() bool {
	return entry.API == moduleAPIVersion && moduleIDPattern.MatchString(entry.ID) &&
		strings.TrimSpace(entry.Name) != "" && moduleIndexRepo.MatchString(entry.Repo) &&
		moduleIndexTag.MatchString(entry.Tag) && personalIndexPath.MatchString(entry.Path) &&
		moduleIndexHash.MatchString(entry.SHA256[moduleManifest]) &&
		moduleIndexHash.MatchString(entry.SHA256[moduleEntry])
}

type moduleIndexEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Version     string            `json:"version"`
	Description string            `json:"description"`
	API         int               `json:"api"`
	Adult       bool              `json:"adult"`
	Repo        string            `json:"repo"`
	Tag         string            `json:"tag"`
	SHA256      map[string]string `json:"sha256"`
	Bundled     bool              `json:"bundled,omitempty"`
}

func (entry moduleIndexEntry) usable() bool {
	return entry.API == moduleAPIVersion && moduleIDPattern.MatchString(entry.ID) && strings.TrimSpace(entry.Name) != "" &&
		moduleIndexRepo.MatchString(entry.Repo) && moduleIndexTag.MatchString(entry.Tag) &&
		moduleIndexHash.MatchString(entry.SHA256[moduleManifest]) && moduleIndexHash.MatchString(entry.SHA256[moduleEntry])
}

func parseModuleIndex(raw []byte) ([]moduleIndexEntry, error) {
	var index struct {
		Format  int                `json:"format"`
		Modules []moduleIndexEntry `json:"modules"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		return nil, errors.New("索引格式无效")
	}
	if index.Format != moduleIndexFormat {
		return nil, fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)
	}
	entries := []moduleIndexEntry{}
	for _, entry := range index.Modules {
		if entry.usable() {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

func (engine *nativeEngine) moduleIndex(ctx context.Context) ([]moduleIndexEntry, int, error) {
	var failures []string
	for mirror, address := range moduleIndexAddresses {
		raw, err := engine.fetchModuleResource(ctx, address, moduleIndexBytes)
		if err == nil {
			var entries []moduleIndexEntry
			if entries, err = parseModuleIndex(raw); err == nil {
				return entries, mirror, nil
			}
		}
		failures = append(failures, err.Error())
	}
	return nil, 0, fmt.Errorf("读取模块索引失败：%s", strings.Join(failures, "；"))
}

func (engine *nativeEngine) moduleStore(ctx context.Context) (map[string]any, error) {
	entries, _, err := engine.moduleIndex(ctx)
	bundled := bundledIndexEntries()
	if err != nil && len(bundled) == 0 {
		return nil, err
	}
	items := append(bundled, entries...)
	result := map[string]any{"items": items}
	if err != nil {
		result["warning"] = err.Error()
	}
	return result, nil
}

func (engine *nativeEngine) indexedModulePackage(ctx context.Context, id string, bundled bool) ([]byte, error) {
	if bundled {
		modules, _ := readBundledModules()
		if modules[id].raw == nil {
			return nil, fmt.Errorf("安装包没有内置 %s", id)
		}
		return zipModuleFiles(modules[id].raw, modules[id].code)
	}
	entries, mirror, err := engine.moduleIndex(ctx)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.ID != id {
			continue
		}
		manifest, err := engine.fetchIndexedFile(ctx, entry, mirror, moduleManifest, moduleManifestBytes)
		if err != nil {
			return nil, err
		}
		code, err := engine.fetchIndexedFile(ctx, entry, mirror, moduleEntry, moduleEntryBytes)
		if err != nil {
			return nil, err
		}
		return zipModuleFiles(manifest, code)
	}
	return nil, fmt.Errorf("模块索引里没有 %s", id)
}

func (engine *nativeEngine) fetchIndexedFile(ctx context.Context, entry moduleIndexEntry, mirror int, name string, limit int) ([]byte, error) {
	var failures []string
	for offset := range moduleFileAddresses {
		pattern := moduleFileAddresses[(mirror+offset)%len(moduleFileAddresses)]
		data, err := engine.fetchModuleResource(ctx, fmt.Sprintf(pattern, entry.Repo, entry.Tag, name), limit)
		if err == nil {
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) == entry.SHA256[name] {
				return data, nil
			}
			err = errors.New("文件校验不符")
		}
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("下载 %s 的 %s 失败：%s", entry.Name, name, strings.Join(failures, "；"))
}

func (engine *nativeEngine) fetchModuleResource(ctx context.Context, address string, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, moduleFetchTimeout)
	defer cancel()
	return engine.fetchLimited(ctx, address, limit)
}

func zipModuleFiles(manifest, code []byte) ([]byte, error) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct {
		name string
		data []byte
	}{{moduleManifest, manifest}, {moduleEntry, code}} {
		writer, err := archive.Create(file.name)
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(file.data); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

// tagRank 把 v1.0.24 拆成 [1,0,24]，用于比较哪份索引更新。
func tagRank(tag string) [3]int {
	var out [3]int
	tag = strings.TrimPrefix(strings.TrimSpace(tag), "v")
	parts := strings.Split(tag, ".")
	for i := 0; i < 3 && i < len(parts); i++ {
		value, err := strconv.Atoi(parts[i])
		if err != nil {
			value = 0
		}
		out[i] = value
	}
	return out
}

// tagNewer 判断 a 是否比 b 新。
func tagNewer(a, b string) bool {
	ra, rb := tagRank(a), tagRank(b)
	for i := 0; i < 3; i++ {
		if ra[i] != rb[i] {
			return ra[i] > rb[i]
		}
	}
	return false
}

// personalModuleIndex 读取个人在线仓库的索引（与官方索引完全独立）。
//
// 并发请求所有镜像，取 tag 最新的那一份：某些 CDN（jsDelivr 的 @latest、
// raw 的 main 分支）会缓存旧内容，顺序取第一个成功的话，可能一直拿到几天前
// 的索引，表现就是「同步了新模块但 App 里看不到更新」。
func (engine *nativeEngine) personalModuleIndex(ctx context.Context) ([]personalIndexEntry, int, error) {
	type fetched struct {
		entries []personalIndexEntry
		mirror  int
		tag     string
		err     error
	}
	results := make(chan fetched, len(personalIndexAddresses))
	for mirror, address := range personalIndexAddresses {
		go func(mirror int, address string) {
			raw, err := engine.fetchModuleResource(ctx, address, moduleIndexBytes)
			if err != nil {
				results <- fetched{mirror: mirror, err: err}
				return
			}
			var index struct {
				Format  int                  `json:"format"`
				Modules []personalIndexEntry `json:"modules"`
			}
			if err = json.Unmarshal(raw, &index); err != nil {
				results <- fetched{mirror: mirror, err: errors.New("索引格式无效")}
				return
			}
			if index.Format != moduleIndexFormat {
				results <- fetched{mirror: mirror, err: fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)}
				return
			}
			entries := []personalIndexEntry{}
			for _, entry := range index.Modules {
				if entry.usable() {
					entries = append(entries, entry)
				}
			}
			tag := ""
			if len(index.Modules) > 0 {
				tag = index.Modules[0].Tag
			}
			results <- fetched{entries: entries, mirror: mirror, tag: tag}
		}(mirror, address)
	}

	var failures []string
	var best *fetched
	for i := 0; i < len(personalIndexAddresses); i++ {
		item := <-results
		if item.err != nil {
			failures = append(failures, item.err.Error())
			continue
		}
		if best == nil || tagNewer(item.tag, best.tag) {
			copied := item
			best = &copied
		}
	}
	if best == nil {
		return nil, 0, fmt.Errorf("读取个人仓库失败：%s", strings.Join(failures, "；"))
	}
	personalIndexMu.Lock()
	personalIndexCached, personalIndexAt, personalIndexMirror = best.entries, time.Now(), best.mirror
	personalIndexMu.Unlock()
	return best.entries, best.mirror, nil
}

func (engine *nativeEngine) personalModuleStore(ctx context.Context) (map[string]any, error) {
	entries, _, err := engine.personalModuleIndex(ctx)
	if err != nil {
		return nil, err
	}
	// 转成与官方索引一致的字段，界面直接复用 _IndexCard。
	items := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		items = append(items, map[string]any{
			"id":          entry.ID,
			"name":        entry.Name,
			"version":     entry.Version,
			"description": entry.Description,
			"api":         entry.API,
			"adult":       entry.Adult,
			"repo":        entry.Repo,
			"tag":         entry.Tag,
			"sha256":      entry.SHA256,
			"bundled":     false,
		})
	}
	return map[string]any{"items": items}, nil
}

func (engine *nativeEngine) personalIndexedModulePackage(ctx context.Context, id string) ([]byte, error) {
	entries, mirror, err := engine.personalModuleIndex(ctx)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.ID != id {
			continue
		}
		manifest, err := engine.fetchPersonalFile(ctx, entry, mirror, moduleManifest, moduleManifestBytes)
		if err != nil {
			return nil, err
		}
		code, err := engine.fetchPersonalFile(ctx, entry, mirror, moduleEntry, moduleEntryBytes)
		if err != nil {
			return nil, err
		}
		return zipModuleFiles(manifest, code)
	}
	return nil, fmt.Errorf("个人仓库里没有 %s", id)
}

func (engine *nativeEngine) fetchPersonalFile(ctx context.Context, entry personalIndexEntry, mirror int, name string, limit int) ([]byte, error) {
	var failures []string
	for offset := range personalFileAddresses {
		pattern := personalFileAddresses[(mirror+offset)%len(personalFileAddresses)]
		address := fmt.Sprintf(pattern, entry.Repo, entry.Tag, entry.Path, name)
		data, err := engine.fetchModuleResource(ctx, address, limit)
		if err == nil {
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) == entry.SHA256[name] {
				return data, nil
			}
			err = errors.New("文件校验不符")
		}
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("下载 %s 的 %s 失败：%s", entry.Name, name, strings.Join(failures, "；"))
}
