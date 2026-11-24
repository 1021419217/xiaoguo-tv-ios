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
	personalIndexTTL   = 15 * time.Second
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
	// 顺序按「新鲜度」排，不是按速度排：
	//   API        缓存 60 秒，最实时；但未认证限流 60 次/小时，刷新太勤会 403
	//   raw main   缓存 5 分钟
	//   jsDelivr   对 @main 缓存 12 小时，最差
	// 之前 jsDelivr 排在 raw 前面，导致 API 被限流后直接掉到「12 小时前的索引」，
	// 用户越刷新越看不到更新。jsDelivr 只能放最后兜底。
	personalIndexAddresses = []string{
		"https://api.github.com/repos/1021419217/xg-modules/contents/index.json?ref=main",
		"https://raw.githubusercontent.com/1021419217/xg-modules/main/index.json",
		"https://cdn.jsdelivr.net/gh/1021419217/xg-modules@main/index.json",
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

// personalModuleIndex 读取个人在线仓库的索引（与官方索引完全独立）。
func (engine *nativeEngine) personalModuleIndex(ctx context.Context) ([]personalIndexEntry, int, error) {
	personalIndexMu.Lock()
	if personalIndexCached != nil && time.Since(personalIndexAt) < personalIndexTTL {
		entries, mirror := personalIndexCached, personalIndexMirror
		personalIndexMu.Unlock()
		return entries, mirror, nil
	}
	personalIndexMu.Unlock()

	var failures []string
	for mirror, address := range personalIndexAddresses {
		raw, err := engine.fetchModuleResource(ctx, address, moduleIndexBytes)
		if err == nil {
			var index struct {
				Format  int                 `json:"format"`
				Modules []personalIndexEntry `json:"modules"`
			}
			if err = json.Unmarshal(raw, &index); err == nil {
				if index.Format == moduleIndexFormat {
					entries := []personalIndexEntry{}
					for _, entry := range index.Modules {
						if entry.usable() {
							entries = append(entries, entry)
						}
					}
					personalIndexMu.Lock()
					personalIndexCached, personalIndexAt, personalIndexMirror = entries, time.Now(), mirror
					personalIndexMu.Unlock()
					return entries, mirror, nil
				}
				err = fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)
			} else {
				err = errors.New("索引格式无效")
			}
		}
		failures = append(failures, err.Error())
	}
	return nil, 0, fmt.Errorf("读取个人仓库失败：%s", strings.Join(failures, "；"))
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
