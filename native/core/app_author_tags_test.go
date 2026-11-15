package core

import (
	"encoding/json"
	"testing"
)

// 多数模块不单独给作者字段，只把「主演 xxx」写进标签。这条兜底能让
// 详情页在没有 author 字段的源上也有作者入口。
func TestDramaAuthorFromTags(t *testing.T) {
	body := `{"id":"tag:1","title":"t","tags":["2024年","主演 张三、李四","日本"]}`
	var drama Drama
	if err := json.Unmarshal([]byte(body), &drama); err != nil {
		t.Fatal(err)
	}
	if drama.Author != "张三" {
		t.Fatalf("author = %q, want 张三", drama.Author)
	}
}

// 多作者字段只取第一个，否则拿整串去搜索一个都匹配不上。
func TestDramaAuthorSplitsList(t *testing.T) {
	body := `{"id":"list:1","title":"t","actors":"张三,李四,王五"}`
	var drama Drama
	if err := json.Unmarshal([]byte(body), &drama); err != nil {
		t.Fatal(err)
	}
	if drama.Author != "张三" {
		t.Fatalf("author = %q, want 张三", drama.Author)
	}
}

// 大小写不统一也要认（Author / UPLOADER / UserName）。
func TestDramaAuthorIgnoresCase(t *testing.T) {
	body := `{"id":"case:1","title":"t","UPLOADER":"阿强"}`
	var drama Drama
	if err := json.Unmarshal([]byte(body), &drama); err != nil {
		t.Fatal(err)
	}
	if drama.Author != "阿强" {
		t.Fatalf("author = %q, want 阿强", drama.Author)
	}
}

func TestAuthorIDFromProfileURL(t *testing.T) {
	cases := map[string]string{
		"https://www.xvideos.com/profiles/abc123":     "abc123",
		"https://www.pornhub.com/users/someone":       "someone",
		"https://www.pornhub.com/model/some-model":    "some-model",
		"https://example.com/@handle":                 "handle",
		"https://91porn.com/uvideos.php?UID=990011":   "990011",
		"https://example.com/channels/my-channel/vid": "my-channel",
		"https://example.com/video/123":               "",
	}
	for address, want := range cases {
		if got := authorIDFromURL(address); got != want {
			t.Fatalf("authorIDFromURL(%q) = %q, want %q", address, got, want)
		}
	}
}
