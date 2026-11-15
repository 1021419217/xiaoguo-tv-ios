package core

import (
	"context"
	"errors"
	"strings"
)

// nativeQualities 只解析播放地址拿清晰度清单，不建立播放会话、不预取数据。
// 详情页用它判断「这一集到底有几个画质」，源只给一个直链时就返回空列表。
func (engine *nativeEngine) nativeQualities(ctx context.Context, input nativeInput) (any, error) {
	if _, _, valid := SplitProviderDramaID(input.Drama.ID); !valid {
		return nil, errors.New("剧集信息无效")
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return nil, err
	}
	choice := nativePlaybackChoices(media, 0)
	qualities := choice.qualities
	if qualities == nil {
		qualities = []int{}
	}
	return map[string]any{
		"qualities": qualities,
		"quality":   media.Quality,
		"hls":       strings.Contains(strings.ToLower(media.URL), ".m3u8"),
	}, nil
}
