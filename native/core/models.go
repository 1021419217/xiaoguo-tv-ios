package core

import (
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
)

type Drama struct {
	VIP               *bool              `json:"vip,omitempty"`
	ID                string             `json:"id"`
	Source            string             `json:"source,omitempty"`
	SourceID          string             `json:"sourceId,omitempty"`
	Title             string             `json:"title"`
	Name              string             `json:"name"`
	Desc              string             `json:"desc"`
	Intro             string             `json:"intro"`
	Cover             any                `json:"cover"`
	CoverURL          any                `json:"coverUrl"`
	CoverURLSnake     any                `json:"cover_url"`
	Image             any                `json:"image"`
	ImageURL          any                `json:"imageUrl"`
	ImageURLSnake     any                `json:"image_url"`
	Img               any                `json:"img"`
	Pic               any                `json:"pic"`
	Picture           any                `json:"picture"`
	Poster            any                `json:"poster"`
	Thumb             any                `json:"thumb"`
	Thumbnail         any                `json:"thumbnail"`
	TotalEpisode      any                `json:"totalEpisode"`
	TotalEpisodeSnake any                `json:"total_episode"`
	ChapterCount      any                `json:"chapterCount"`
	ChapterCountSnake any                `json:"chapter_count"`
	EpisodeCount      any                `json:"episodeCount"`
	EpisodeCountSnake any                `json:"episode_count"`
	Total             any                `json:"total"`
	Episodes          any                `json:"episodes"`
	Duration          any                `json:"duration"`
	ChannelName       string             `json:"channelName"`
	Category          string             `json:"category"`
	CategoryName      string             `json:"categoryName"`
	CategoryNameSnake string             `json:"category_name"`
	TypeName          string             `json:"typeName"`
	TypeNameSnake     string             `json:"type_name"`
	SortName          string             `json:"sortName"`
	SortNameSnake     string             `json:"sort_name"`
	Remark            string             `json:"remark,omitempty"`
	Badge             string             `json:"badge,omitempty"`
	Score             string             `json:"score,omitempty"`
	Views             string             `json:"views,omitempty"`
	Heat              string             `json:"heat,omitempty"`
	OnlineDate        string             `json:"onlineDate,omitempty"`
	Tags              []string           `json:"tags,omitempty"`
	ReleaseStatus     string             `json:"releaseStatus,omitempty"`
	SortMetadata      *sortMetadataState `json:"sortMetadata,omitempty"`
	Author            string             `json:"author,omitempty"`
	AuthorID          string             `json:"authorId,omitempty"`
	AuthorURL         string             `json:"authorUrl,omitempty"`
	Actors            []string           `json:"actors,omitempty"`
	Serial            string             `json:"serial,omitempty"`
	ReleaseDate       string             `json:"releaseDate,omitempty"`
	DurationText      string             `json:"durationText,omitempty"`
	Maker             string             `json:"maker,omitempty"`
	Director          string             `json:"director,omitempty"`
	Meta              map[string]string  `json:"meta,omitempty"`
}

// UnmarshalJSON 在常规反序列化之外，额外从上层返回的原始字段里识别作者信息。
// 不同站源给作者字段起的名字五花八门（author / uploader / user / actor …），
// 这里统一收敛到 Author / AuthorID / AuthorURL，让详情页与作者主页对所有源通用。
func (d *Drama) UnmarshalJSON(data []byte) error {
	type plain Drama
	var value plain
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*d = Drama(value)
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil
	}
	d.absorbAuthor(raw)
	d.absorbMetadata(raw)
	return nil
}

func (d *Drama) absorbAuthor(raw map[string]any) {
	if d.Author == "" {
		d.Author = authorFieldText(raw, dramaAuthorNameKeys)
	}
	if d.AuthorURL == "" {
		d.AuthorURL = authorFieldText(raw, dramaAuthorURLKeys)
	}
	if d.AuthorID == "" {
		d.AuthorID = authorFieldText(raw, dramaAuthorIDKeys)
	}
	if d.AuthorID == "" && d.AuthorURL != "" {
		d.AuthorID = authorIDFromURL(d.AuthorURL)
	}
}

var dramaAuthorNameKeys = []string{
	"author", "authorName", "author_name", "authors",
	"uploader", "uploaderName", "uploader_name", "upName", "up_name",
	"creator", "creatorName", "creator_name", "maker", "studio",
	"artist", "artistName", "star", "performer", "performerName",
	"userName", "user_name", "username", "nickname", "screenName", "screen_name",
	"user", "member", "owner", "channelName2", "actor", "actors", "cast",
}

var dramaAuthorIDKeys = []string{
	"authorId", "author_id", "uploaderId", "uploader_id",
	"creatorId", "creator_id", "userId", "user_id", "uid", "UID",
	"memberId", "member_id", "channelId", "channel_id", "upId", "up_id",
}

var dramaAuthorURLKeys = []string{
	"authorUrl", "authorURL", "author_url", "uploaderUrl", "uploader_url", "uploaderURL",
	"creatorUrl", "creator_url", "userUrl", "user_url", "userURL",
	"homepage", "homePage", "profileUrl", "profile_url", "authorPage", "author_page",
}

func authorFieldText(raw map[string]any, keys []string) string {
	for _, key := range keys {
		value, found := raw[key]
		if !found {
			continue
		}
		if text := authorValueText(value); text != "" {
			return text
		}
	}
	return ""
}

func authorValueText(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(typed)
	case []any:
		for _, item := range typed {
			if text := authorValueText(item); text != "" {
				return text
			}
		}
	case map[string]any:
		for _, key := range []string{"name", "nickname", "title", "username", "userName", "text", "label"} {
			if text := authorValueText(typed[key]); text != "" {
				return text
			}
		}
	default:
		return NativeText(value)
	}
	return ""
}

// authorIDFromURL 从作者主页地址里取出用户标识，兼容常见的 UID/uid/user_id 写法。
func authorIDFromURL(address string) string {
	if address == "" {
		return ""
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return ""
	}
	query := parsed.Query()
	for _, key := range []string{"UID", "uid", "userId", "user_id", "id", "authorId", "author_id", "mid"} {
		if value := strings.TrimSpace(query.Get(key)); value != "" {
			return value
		}
	}
	return ""
}

var (
	dramaActorKeys   = []string{"actors", "actor", "stars", "star", "cast", "performers", "performer", "主演"}
	dramaSerialKeys  = []string{"serial", "serialNumber", "serial_number", "code", "dvdId", "dvd_id", "productCode", "product_code", "品番", "番号"}
	dramaReleaseKeys = []string{"releaseDate", "release_date", "releasedAt", "released_at", "publishedAt", "published_at", "publishDate", "publish_date", "发行日期", "発売日"}
	dramaMakerKeys   = []string{"maker", "studio", "label", "brand", "publisher", "片商", "メーカー"}
	dramaDirectorKey = []string{"director", "directors", "导演"}
)

// absorbMetadata 抓取作品本身的资料（主演、番号、发行日期、时长、片商…）。
// 站源字段名不统一，这里按常见别名收敛；收不进来的键留在 Meta 里备用。
func (d *Drama) absorbMetadata(raw map[string]any) {
	if len(d.Actors) == 0 {
		d.Actors = actorNames(raw, dramaActorKeys)
	}
	if d.Serial == "" {
		d.Serial = authorFieldText(raw, dramaSerialKeys)
	}
	if d.ReleaseDate == "" {
		d.ReleaseDate = FirstNonEmpty(authorFieldText(raw, dramaReleaseKeys), ProviderReleaseDate(NativeText(raw["onlineDate"])))
	}
	if d.Maker == "" {
		d.Maker = authorFieldText(raw, dramaMakerKeys)
	}
	if d.Director == "" {
		d.Director = authorFieldText(raw, dramaDirectorKey)
	}
	if d.DurationText == "" {
		d.DurationText = nativeDurationText(raw["duration"])
	}
	if len(d.Meta) == 0 {
		d.Meta = nativeMeta(raw)
	}
}

func actorNames(raw map[string]any, keys []string) []string {
	for _, key := range keys {
		value, found := raw[key]
		if !found {
			continue
		}
		var names []string
		switch typed := value.(type) {
		case []any:
			for _, item := range typed {
				if text := authorValueText(item); text != "" {
					names = append(names, text)
				}
			}
		case string:
			for _, part := range strings.FieldsFunc(typed, func(r rune) bool {
				return r == ',' || r == '，' || r == '/' || r == '、' || r == '|' || r == ';'
			}) {
				if text := strings.TrimSpace(part); text != "" {
					names = append(names, text)
				}
			}
		default:
			if text := authorValueText(value); text != "" {
				names = append(names, text)
			}
		}
		if len(names) > 0 {
			return dedupeAuthors(names, 8)
		}
	}
	return nil
}

func dedupeAuthors(names []string, limit int) []string {
	out := make([]string, 0, len(names))
	seen := map[string]bool{}
	for _, name := range names {
		key := normalizeAuthorName(name)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, name)
		if len(out) >= limit {
			break
		}
	}
	return out
}

// nativeDurationText 只做展示：字符串原样，数字按秒/分钟粗分。
func nativeDurationText(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return durationFromNumber(int64(typed))
	case int:
		return durationFromNumber(int64(typed))
	case int64:
		return durationFromNumber(typed)
	case json.Number:
		if parsed, err := typed.Int64(); err == nil {
			return durationFromNumber(parsed)
		}
	}
	return ""
}

func durationFromNumber(seconds int64) string {
	if seconds <= 0 {
		return ""
	}
	if seconds >= 3600 {
		return strconv.FormatInt(seconds/3600, 10) + ":" +
			padTwo(seconds%3600/60) + ":" + padTwo(seconds%60)
	}
	if seconds > 90 {
		return strconv.FormatInt(seconds/60, 10) + " 分钟"
	}
	return ""
}

func padTwo(value int64) string {
	if value < 10 {
		return "0" + strconv.FormatInt(value, 10)
	}
	return strconv.FormatInt(value, 10)
}

var nativeMetaSkip = map[string]bool{
	"id": true, "source": true, "sourceid": true, "source_id": true, "title": true, "name": true,
	"desc": true, "description": true, "intro": true, "summary": true, "content": true,
	"cover": true, "coverurl": true, "cover_url": true, "image": true, "imageurl": true,
	"image_url": true, "img": true, "pic": true, "picture": true, "poster": true, "thumb": true,
	"thumbnail": true, "url": true, "link": true, "href": true, "playurl": true, "play_url": true,
	"videourl": true, "video_url": true, "m3u8": true, "mp4": true, "api": true, "token": true,
	"sign": true, "signature": true, "cookie": true, "headers": true, "referer": true,
	"useragent": true, "user_agent": true, "category": true, "categoryname": true,
	"category_name": true, "typename": true, "type_name": true, "sortname": true, "sort_name": true,
	"tags": true, "badge": true, "vip": true, "episodes": true, "totalepisode": true,
	"total_episode": true, "chaptercount": true, "chapter_count": true,
	"episodecount": true, "episode_count": true, "total": true, "createdat": true, "created_at": true,
	"updatedat": true, "updated_at": true, "timestamp": true, "sort": true, "weight": true,
	"index": true, "page": true, "hasmore": true, "has_more": true, "items": true, "data": true,
	"list": true, "author": true, "authorid": true, "author_id": true, "authorurl": true,
	"author_url": true, "actors": true, "actor": true, "stars": true, "star": true, "cast": true,
	"performers": true, "performer": true, "serial": true, "serialnumber": true, "serial_number": true,
	"code": true, "dvdd": true, "dvddid": true, "dvdid": true, "dvd_id": true, "productcode": true,
	"product_code": true, "releasedate": true, "release_date": true, "releasedat": true,
	"released_at": true, "publishedat": true, "published_at": true, "publishdate": true,
	"publish_date": true, "maker": true, "studio": true, "label": true, "brand": true,
	"publisher": true, "director": true, "directors": true, "duration": true, "length": true,
	"runtime": true, "onlinedate": true, "online_date": true, "score": true, "rating": true,
	"views": true, "heat": true, "remark": true, "releasestatus": true, "release_status": true,
	"metadataschema": true, "metadata_schema": true, "channelname": true, "channel_name": true,
}

// nativeMeta 收罗白名单之外、但看起来像人话的资料字段（番号、日期、地区…），
// 让详情页在没适配过的源上也能列出作品信息。
func nativeMeta(raw map[string]any) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	meta := map[string]string{}
	total := 0
	for key, value := range raw {
		if len(meta) >= 12 || total >= 400 {
			break
		}
		trimmed := strings.TrimSpace(key)
		if len(trimmed) < 2 || len(trimmed) > 24 || strings.HasPrefix(trimmed, "_") {
			continue
		}
		if nativeMetaSkip[strings.ToLower(trimmed)] || nativeMetaSkip[trimmed] {
			continue
		}
		text := nativeMetaText(value)
		if text == "" {
			continue
		}
		meta[trimmed] = text
		total += len(text)
	}
	if len(meta) == 0 {
		return nil
	}
	return meta
}

func nativeMetaText(value any) string {
	var text string
	switch typed := value.(type) {
	case string:
		text = strings.TrimSpace(typed)
	case float64:
		if typed == float64(int64(typed)) {
			text = strconv.FormatInt(int64(typed), 10)
		} else {
			text = strconv.FormatFloat(typed, 'f', -1, 64)
		}
	case bool:
		if typed {
			text = "是"
		} else {
			text = "否"
		}
	default:
		return ""
	}
	if text == "" || len([]rune(text)) > 60 {
		return ""
	}
	lower := strings.ToLower(text)
	if strings.Contains(lower, "http") || strings.Contains(lower, "://") ||
		strings.ContainsAny(text, "{}\n\r<>") {
		return ""
	}
	return text
}

func (d Drama) DisplayTitle() string {
	if strings.TrimSpace(d.Title) != "" {
		return d.Title
	}
	if strings.TrimSpace(d.Name) != "" {
		return d.Name
	}
	return "短剧"
}

type Chapter struct {
	VIP            bool            `json:"vip,omitempty"`
	ID             string          `json:"id"`
	Source         string          `json:"source,omitempty"`
	Title          string          `json:"title"`
	VideoURL       string          `json:"videoUrl"`
	CurrentEpisode json.RawMessage `json:"currentEpisode"`
	MediaSize      int64           `json:"mediaSize"`
	PageURL        string          `json:"pageUrl,omitempty"`
	Referer        string          `json:"referer,omitempty"`
	Vertical       *bool           `json:"vertical,omitempty"`
}

func (c Chapter) EpisodeString(fallback int) string {
	if len(c.CurrentEpisode) > 0 && string(c.CurrentEpisode) != "null" {
		var s string
		if err := json.Unmarshal(c.CurrentEpisode, &s); err == nil && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
		var n int
		if err := json.Unmarshal(c.CurrentEpisode, &n); err == nil && n > 0 {
			return strconv.Itoa(n)
		}
		var f float64
		if err := json.Unmarshal(c.CurrentEpisode, &f); err == nil && f > 0 {
			return strconv.Itoa(int(f))
		}
	}
	return strconv.Itoa(fallback)
}

type Task struct {
	DramaID         string  `json:"dramaId"`
	DramaTitle      string  `json:"dramaTitle"`
	Chapter         Chapter `json:"chapter"`
	Index           int     `json:"index"`
	Total           int     `json:"total"`
	OutPath         string  `json:"outPath"`
	ReleaseStatus   string  `json:"releaseStatus,omitempty"`
	DownloadQuality int     `json:"downloadQuality,omitempty"`
}
