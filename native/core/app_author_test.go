package core

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestDramaAbsorbsAuthorAliases(t *testing.T) {
	cases := []struct {
		name string
		body string
		want AuthorRef
	}{
		{"author", `{"id":"a:1","title":"t","author":"阿强"}`, AuthorRef{Name: "阿强"}},
		{"uploader object", `{"id":"a:1","title":"t","uploader":{"name":"老李","uid":88}}`, AuthorRef{Name: "老李"}},
		{"actors array", `{"id":"a:1","title":"t","actors":["小美","小丽"]}`, AuthorRef{Name: "小美"}},
		{"user name", `{"id":"a:1","title":"t","user":{"userName":"王大"}}`, AuthorRef{Name: "王大"}},
		{"explicit id", `{"id":"a:1","title":"t","author":"张三","authorId":"42"}`, AuthorRef{Name: "张三", ID: "42"}},
		{"url uid", `{"id":"a:1","title":"t","author":"张三","authorUrl":"https://x.invalid/uvideos.php?UID=777"}`, AuthorRef{Name: "张三", ID: "777"}},
	}
	for _, item := range cases {
		var drama Drama
		if err := json.Unmarshal([]byte(item.body), &drama); err != nil {
			t.Fatalf("%s: %v", item.name, err)
		}
		if drama.Author != item.want.Name || drama.AuthorID != item.want.ID {
			t.Fatalf("%s: author = %q/%q, want %q/%q", item.name, drama.Author, drama.AuthorID, item.want.Name, item.want.ID)
		}
	}
}

func TestAuthorKeyMatches(t *testing.T) {
	want := AuthorRef{Name: "Lily Zhang", ID: "9"}
	if !authorKeyMatches(want, "lilyzhang", "") {
		t.Fatal("name should match ignoring spaces and case")
	}
	if !authorKeyMatches(want, "", "9") {
		t.Fatal("id should match")
	}
	if authorKeyMatches(want, "someone else", "10") {
		t.Fatal("unrelated author must not match")
	}
	if authorKeyMatches(AuthorRef{}, "someone", "10") {
		t.Fatal("empty reference must not match")
	}
}

func TestModuleAuthorPage(t *testing.T) {
	manifest := `{"id":"authortest","name":"作者测试","runtime":"js","api":1,"adult":false,"hosts":["api.example.invalid"]}`
	code := `
module.exports = {
  categories() { return [{ id: "all", name: "全部" }]; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail(id) { return { drama: { id: host.dramaId(id), title: "t" }, chapters: [] }; },
  resolveMedia() { return { url: "" }; },
  author(authorId, authorName, page) {
    return {
      items: [
        { id: host.dramaId(authorId + "-" + page), title: authorName + " 的作品 " + page, author: authorName, authorId: authorId },
      ],
      hasMore: page < 3,
    };
  },
};`
	module, err := readModule(writeTestModule(t, manifest, code))
	if err != nil {
		t.Fatal(err)
	}
	p := module.provider(&moduleTestHost{})
	pager, ok := p.(AuthorPager)
	if !ok {
		t.Fatal("js provider should expose AuthorPage")
	}
	items, more, err := pager.AuthorPage(context.Background(), AuthorRef{Source: "authortest", ID: "88", Name: "阿强"}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].ID != "authortest:88-2" || items[0].Author != "阿强" || !more {
		t.Fatalf("author page = %+v, more %v", items, more)
	}

	plain := `{"id":"plaintest","name":"无作者","runtime":"js","api":1,"adult":false,"hosts":["api.example.invalid"]}`
	plainCode := `
module.exports = {
  categories() { return []; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail(id) { return { drama: { id: host.dramaId(id), title: "t" }, chapters: [] }; },
  resolveMedia() { return { url: "" }; },
};`
	other, err := readModule(writeTestModule(t, plain, plainCode))
	if err != nil {
		t.Fatal(err)
	}
	plainPager, ok := other.provider(&moduleTestHost{}).(AuthorPager)
	if !ok {
		t.Fatal("js provider should expose AuthorPage")
	}
	if _, _, err := plainPager.AuthorPage(context.Background(), AuthorRef{Name: "阿强"}, 1); !errors.Is(err, ErrAuthorUnsupported) {
		t.Fatalf("missing author export error = %v", err)
	}
}

type authorFallbackProvider struct {
	items []Drama
}

func (p *authorFallbackProvider) Descriptor() SourceDescriptor {
	return SourceDescriptor{ID: "authorfallback", Name: "作者兜底源", Group: "test"}
}

func (p *authorFallbackProvider) Categories(context.Context, bool) ([]Category, error) {
	return nil, nil
}

func (p *authorFallbackProvider) CatalogPage(context.Context, int, string) ([]Drama, bool, error) {
	return nil, false, nil
}

func (p *authorFallbackProvider) Detail(context.Context, string) (Drama, []Chapter, error) {
	return Drama{}, nil, nil
}

func (p *authorFallbackProvider) ResolveMedia(context.Context, Task) (ProviderMedia, error) {
	return ProviderMedia{}, nil
}

func (p *authorFallbackProvider) Search(_ context.Context, page int, query string) ([]Drama, bool, error) {
	if page > 1 {
		return nil, false, nil
	}
	return p.items, false, nil
}

// 站源没有作者主页时，应退回「作者名搜索 + 过滤」：匹配的留下、别人的剔除、
// 结果里没写作者的保留（因为它来自按作者名的搜索）。
func TestNativeAuthorCatalogFallsBackToSearch(t *testing.T) {
	provider := &authorFallbackProvider{items: []Drama{
		{ID: "authorfallback:1", Title: "同作者作品", Author: "阿强", AuthorID: "7"},
		{ID: "authorfallback:2", Title: "别人作品", Author: "别人", AuthorID: "8"},
		{ID: "authorfallback:3", Title: "无作者字段作品"},
	}}
	Register(provider.Descriptor(), func(Host) Provider { return provider })
	defer Unregister("authorfallback")

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}}, cacheDirectory: t.TempDir()}
	result, err := engine.nativeAuthorCatalog(context.Background(), nativeInput{
		Action: "authorCatalog", Source: "authorfallback", Author: "阿强", Page: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 || result.Items[0].ID != "authorfallback:1" || result.Items[1].ID != "authorfallback:3" {
		t.Fatalf("fallback items = %+v", result.Items)
	}
	for _, item := range result.Items {
		if item.Source != "authorfallback" {
			t.Fatalf("item source = %q", item.Source)
		}
	}
}

func TestDramaAbsorbsWorkMetadata(t *testing.T) {
	body := `{"id":"a:1","title":"t",
		"actors":["真木今日子","笠木一香"],
		"serial":"TPIN-103","releaseDate":"2026-11-07","duration":"2:47:28",
		"maker":"S1","director":"山田","area":"日本","language":"日语","url2":"https://x.invalid/a"}`
	var drama Drama
	if err := json.Unmarshal([]byte(body), &drama); err != nil {
		t.Fatal(err)
	}
	if drama.Serial != "TPIN-103" || drama.ReleaseDate != "2026-11-07" ||
		drama.DurationText != "2:47:28" || drama.Maker != "S1" || drama.Director != "山田" {
		t.Fatalf("metadata = %+v", drama)
	}
	if len(drama.Actors) != 2 || drama.Actors[0] != "真木今日子" {
		t.Fatalf("actors = %v", drama.Actors)
	}
	if drama.Meta["area"] != "日本" || drama.Meta["language"] != "日语" {
		t.Fatalf("meta = %v", drama.Meta)
	}
	if _, noise := drama.Meta["url2"]; noise {
		t.Fatalf("url field should be filtered, meta = %v", drama.Meta)
	}
}
