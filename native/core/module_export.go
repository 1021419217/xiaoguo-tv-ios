package core

import (
	"archive/zip"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const moduleExportFolder = "module-exports"

// exportModules 把已安装的模块重新打包成 zip 供用户导出。
//
// 单个模块直接平铺 manifest.json 与 main.js，导出后还能用「手动安装」装回来；
// 多个模块每个一个子目录，方便一次带走整套站源。
func (engine *nativeEngine) exportModules(ids []string) (map[string]any, error) {
	root := engine.downloader.moduleRoot()
	selected := make([]string, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" || seen[id] || !filepath.IsLocal(id) ||
			filepath.Base(id) != id || strings.HasPrefix(id, ".") {
			continue
		}
		seen[id] = true
		selected = append(selected, id)
	}
	if len(selected) == 0 {
		return nil, errors.New("没有可导出的模块")
	}
	sort.Strings(selected)

	single := len(selected) == 1
	name := fmt.Sprintf("modules-%s.zip", time.Now().Format("20060102-150405"))
	if single {
		module, err := readModule(filepath.Join(root, selected[0]))
		if err != nil {
			return nil, fmt.Errorf("%s 读取失败：%w", selected[0], err)
		}
		version := module.manifest.Version
		if version == "" {
			version = "未标注"
		}
		name = fmt.Sprintf("%s-%s.zip", selected[0], version)
	}

	folder := filepath.Join(engine.cacheDirectory, moduleExportFolder)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return nil, err
	}
	target := filepath.Join(folder, name)
	file, err := os.Create(target)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	writer := zip.NewWriter(file)
	for _, id := range selected {
		prefix := ""
		if !single {
			prefix = id + "/"
		}
		for _, item := range []string{moduleManifest, moduleEntry} {
			raw, err := os.ReadFile(filepath.Join(root, id, item))
			if err != nil {
				_ = writer.Close()
				return nil, fmt.Errorf("%s 缺少 %s，无法导出", id, item)
			}
			entry, err := writer.Create(prefix + item)
			if err != nil {
				_ = writer.Close()
				return nil, err
			}
			if _, err := entry.Write(raw); err != nil {
				_ = writer.Close()
				return nil, err
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"path":  target,
		"name":  name,
		"count": len(selected),
		"bytes": info.Size(),
	}, nil
}
