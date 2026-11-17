package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// 用户可能用本地文件或下载地址安装一个自定义模块（比如自己改过的旧版本）。
// 这种模块要「锁定」：App 启动时不让内置的高版本把它覆盖回去，也不再提示更新。
// 只有从「内置」分类主动安装，才算用户愿意回到内置版本，届时解除锁定。
//
// 状态写在模块根目录下，跟 .bundled-removed.json 并列，跟随用户数据持久化。
const pinnedModulesFile = ".module-pins.json"

func (d *Downloader) pinnedModules() map[string]bool {
	set := map[string]bool{}
	raw, err := os.ReadFile(filepath.Join(d.moduleRoot(), pinnedModulesFile))
	if err != nil {
		return set
	}
	var ids []string
	if json.Unmarshal(raw, &ids) == nil {
		for _, id := range ids {
			set[id] = true
		}
	}
	return set
}

func (d *Downloader) markModulePinned(id string, pinned bool) error {
	set := d.pinnedModules()
	if set[id] == pinned {
		return nil
	}
	if pinned {
		set[id] = true
	} else {
		delete(set, id)
	}
	ids := make([]string, 0, len(set))
	for name := range set {
		ids = append(ids, name)
	}
	sort.Strings(ids)
	raw, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(d.moduleRoot(), 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(d.moduleRoot(), pinnedModulesFile), raw, 0o600)
}
