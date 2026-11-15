package core

import (
	"context"
	"errors"
	"strings"
)

// authorCatalogSearchPages 限制兜底搜索的翻页数，避免一条作者链接把整站翻完。
const authorCatalogSearchPages = 3

// nativeAuthorCatalog 取某位作者在同一个站源里的其它作品。
//
// 三层降级，保证「装了任何源都能用」：
//  1. 站源自己实现了作者主页（模块导出 author 函数）→ 直接用；
//  2. 站源支持搜索 → 用作者名当关键词搜索，再按作者字段过滤；
//  3. 站源既不支持作者主页也没有搜索 → 在本源已缓存的目录里按作者筛选。
func (engine *nativeEngine) nativeAuthorCatalog(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	source := canonicalProviderSource(input.Source)
	page := max(1, input.Page)
	result := nativeCatalogResult{Items: []LibraryDrama{}, Page: page}
	if !registeredProviderSource(source) {
		return result, errors.New("请选择有效站源")
	}
	author := AuthorRef{
		Source: source,
		ID:     strings.TrimSpace(input.AuthorID),
		Name:   strings.TrimSpace(input.Author),
		URL:    strings.TrimSpace(input.AuthorURL),
	}
	if author.ID == "" && author.Name == "" {
		return result, errors.New("缺少作者信息")
	}
	provider, ok := engine.downloader.provider(source)
	if !ok {
		return result, errors.New("请选择有效站源")
	}
	if pager, supported := provider.(AuthorPager); supported {
		items, more, err := pager.AuthorPage(ctx, author, page)
		if err == nil {
			return authorCatalogResult(source, items, more, page), nil
		}
		if !errors.Is(err, ErrAuthorUnsupported) {
			return result, err
		}
	}
	if author.Name != "" {
		if searcher, supported := providerAs[Searcher](provider); supported {
			return engine.searchAuthorCatalog(ctx, searcher, source, author, page), nil
		}
	}
	return engine.cachedAuthorCatalog(source, author), nil
}

func (engine *nativeEngine) searchAuthorCatalog(ctx context.Context, searcher Searcher, source string, author AuthorRef, page int) nativeCatalogResult {
	result := nativeCatalogResult{Items: []LibraryDrama{}, Page: page}
	seen := map[string]bool{}
	for offset := 0; offset < authorCatalogSearchPages; offset++ {
		if ctx.Err() != nil {
			break
		}
		items, more, err := searcher.Search(ctx, page+offset, author.Name)
		if err != nil {
			if len(result.Items) == 0 {
				result.Warning = err.Error()
			}
			break
		}
		for _, drama := range items {
			if !authorMatchesDrama(drama, author) {
				continue
			}
			normalized := authorNormalizeDrama(source, drama)
			if seen[normalized.ID] {
				continue
			}
			seen[normalized.ID] = true
			result.Items = append(result.Items, normalized)
		}
		result.HasMore = more
		if !more || len(result.Items) > 0 {
			break
		}
	}
	if len(result.Items) == 0 {
		if cached := engine.cachedAuthorCatalog(source, author); len(cached.Items) > 0 {
			return cached
		}
		if result.Warning == "" {
			result.Warning = "这个源里没有找到该作者的其它作品"
		}
	}
	return result
}

func (engine *nativeEngine) cachedAuthorCatalog(source string, author AuthorRef) nativeCatalogResult {
	result := nativeCatalogResult{Items: []LibraryDrama{}, Page: 1}
	engine.mu.Lock()
	items := append([]LibraryDrama{}, engine.catalogs[source]...)
	engine.mu.Unlock()
	seen := map[string]bool{}
	for _, item := range items {
		if !authorKeyMatches(author, item.Author, item.AuthorID) || seen[item.ID] {
			continue
		}
		seen[item.ID] = true
		item.Cover = engine.downloader.repairCover(item)
		result.Items = append(result.Items, item)
	}
	result.LocalSearch = true
	return result
}

func authorCatalogResult(source string, items []Drama, more bool, page int) nativeCatalogResult {
	result := nativeCatalogResult{Items: make([]LibraryDrama, 0, len(items)), HasMore: more, Page: page}
	if result.Page < 1 {
		result.Page = 1
	}
	seen := map[string]bool{}
	for _, drama := range items {
		normalized := authorNormalizeDrama(source, drama)
		if normalized.ID == "" || seen[normalized.ID] {
			continue
		}
		seen[normalized.ID] = true
		result.Items = append(result.Items, normalized)
	}
	return result
}

// authorNormalizeDrama 补齐站源身份后再归一化，避免模块返回裸 ID 时详情页取不到数据。
func authorNormalizeDrama(source string, drama Drama) LibraryDrama {
	if _, _, ok := SplitProviderDramaID(drama.ID); !ok && strings.TrimSpace(drama.ID) != "" {
		drama.ID = ProviderDramaID(source, drama.ID)
	}
	if strings.TrimSpace(drama.Source) == "" {
		drama.Source = source
	}
	return NativeNormalize(drama)
}

func authorMatchesDrama(drama Drama, author AuthorRef) bool {
	name, id := strings.TrimSpace(drama.Author), strings.TrimSpace(drama.AuthorID)
	if name == "" && id == "" {
		// 结果本身就来自作者名搜索，缺字段时保留，避免误杀。
		return true
	}
	return authorKeyMatches(author, name, id)
}

func authorKeyMatches(want AuthorRef, name, id string) bool {
	wantID := strings.TrimSpace(want.ID)
	if wantID != "" && strings.EqualFold(strings.TrimSpace(id), wantID) {
		return true
	}
	wantName := normalizeAuthorName(want.Name)
	haveName := normalizeAuthorName(name)
	if wantName == "" || haveName == "" {
		return false
	}
	return haveName == wantName || strings.Contains(haveName, wantName) || strings.Contains(wantName, haveName)
}

func normalizeAuthorName(name string) string {
	replacer := strings.NewReplacer(" ", "", "\u3000", "", "　", "", "@", "", "#", "")
	return strings.ToLower(replacer.Replace(strings.TrimSpace(name)))
}
