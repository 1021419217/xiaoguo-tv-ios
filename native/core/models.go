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
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	// tags / actors 有的源给数组、有的直接给「张三,李四」这种字符串，
	// 按 []string 硬解会让整条详情解析失败，先摘出来单独宽松处理。
	tags, hasTags := raw["tags"]
	actors, hasActors := raw["actors"]
	delete(raw, "tags")
	delete(raw, "actors")
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	type plain Drama
	var value plain
	if err := json.Unmarshal(encoded, &value); err != nil {
		return err
	}
	*d = Drama(value)
	if hasTags {
		d.Tags = stringList(tags)
	}
	if hasActors {
		d.Actors = actorList(actors)
	}
	d.absorbAuthor(raw)
	d.absorbMetadata(raw)
	return nil
}

// stringList 只把数组/单值收成 []string，不拆分隔符（标签里的斜杠有意义）。
func stringList(value any) []string {
	switch typed := value.(type) {
	case nil:
		return nil
	case []any:
		list := make([]string, 0, len(typed))
		for _, item := range typed {
			if text := strings.TrimSpace(authorValueText(item)); text != "" {
				list = append(list, text)
			}
		}
		return list
	default:
		if text := strings.TrimSpace(authorValueText(value)); text != "" {
			return []string{text}
		}
		return nil
	}
}

// actorList 把「张三,李四」「张三、李四」这类字符串拆成数组。
func actorList(value any) []string {
	text, single := value.(string)
	if !single {
		return stringList(value)
	}
	parts := strings.FieldsFunc(text, func(r rune) bool {
		switch r {
		case ',', '，', '、', ';', '；', '|', '/':
			return true
		}
		return false
	})
	list := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			list = append(list, trimmed)
		}
	}
	return list
}

func (d *Drama) absorbAuthor(raw map[string]any) {
	if d.Author == "" {
		d.Author = authorNameFieldText(raw, dramaAuthorNameKeys)
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
	// actors 在反序列化时已被摘出来单独宽松解析，raw 里没有它了。
	if d.Author == "" && len(d.Actors) > 0 {
		d.Author = authorNameText(d.Actors[0])
	}
	// 多数模块不单独给作者字段，只把「主演 xxx / UP主 xxx」写进标签，
	// 这里再兜一层，否则详情页永远没有作者入口。
	d.absorbAuthorFromTags()
}

var dramaAuthorNameKeys = []string{
	"author", "authorName", "author_name", "authors",
	"uploader", "uploaderName", "uploader_name", "upName", "up_name", "up", "upMaster",
	"creator", "creatorName", "creator_name", "maker", "studio",
	"artist", "artistName", "star", "performer", "performerName",
	"userName", "user_name", "username", "nickname", "screenName", "screen_name",
	"user", "member", "owner", "channelName2", "actor", "actors", "cast",
	// maccms 原始字段：模块若直接透传站点数据，键名会是 vod_ 前缀。
	"vod_actor", "vodActor", "vod_up", "vodUp", "vod_writer",
}

// 标签里用来标记「谁的作品」的常见前缀。
var dramaAuthorTagPrefixes = []string{
	"主演", "作者", "演员", "UP主", "up主", "上传者", "上传", "创作者", "模特", "女优",
}

func (d *Drama) absorbAuthorFromTags() {
	if d.Author != "" {
		return
	}
	for _, tag := range d.Tags {
		text := strings.TrimSpace(tag)
		for _, prefix := range dramaAuthorTagPrefixes {
			if !strings.HasPrefix(text, prefix) {
				continue
			}
			name := strings.TrimLeft(strings.TrimSpace(text[len(prefix):]), " :：·-—")
			name = authorNameText(name)
			if name == "" || len([]rune(name)) > 48 {
				continue
			}
			d.Author = name
			return
		}
	}
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
	// 不同模块的大小写习惯不一样（Author / AUTHOR / UserName），
	// 精确匹配落空后再忽略大小写扫一遍。
	for _, key := range keys {
		for actual, value := range raw {
			if !strings.EqualFold(actual, key) {
				continue
			}
			if text := authorValueText(value); text != "" {
				return text
			}
		}
	}
	return ""
}

func authorNameFieldText(raw map[string]any, keys []string) string {
	for _, key := range keys {
		value, found := raw[key]
		if !found {
			continue
		}
		if text := authorNameText(value); text != "" {
			return text
		}
	}
	for _, key := range keys {
		for actual, value := range raw {
			if !strings.EqualFold(actual, key) {
				continue
			}
			if text := authorNameText(value); text != "" {
				return text
			}
		}
	}
	return ""
}

// authorNameText 取「一个人」的名字：多作者字段（"张三,李四"）只留第一个，
// 否则拿整串去搜索一个都匹配不上。
func authorNameText(value any) string {
	text := authorValueText(value)
	if text == "" {
		return ""
	}
	if cut := strings.IndexAny(text, ",，、;；"); cut > 0 {
		text = strings.TrimSpace(text[:cut])
	}
	if len([]rune(text)) > 48 {
		return ""
	}
	return text
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

// authorIDFromURL 从作者主页地址里取出用户标识。站点写法差得很远：
// 有的走 ?UID=123，有的走 /profiles/xxx、/users/xxx、/model/xxx、/@handle，
// 这里两种都认，取不到 ID 时至少把 handle 当 ID 用。
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
	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	for index, segment := range segments {
		segment = strings.TrimSpace(segment)
		if segment == "" {
			continue
		}
		if strings.HasPrefix(segment, "@") && len(segment) > 1 {
			return segment[1:]
		}
		switch strings.ToLower(segment) {
		case "profiles", "users", "user", "model", "models", "pornstar", "pornstars",
			"channels", "channel", "amateur-channels", "members", "member", "author", "u":
			if index+1 < len(segments) && strings.TrimSpace(segments[index+1]) != "" {
				return strings.TrimSpace(segments[index+1])
			}
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
