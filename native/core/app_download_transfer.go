package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type nativeDownloadAsset struct {
	address string
	name    string
	data    []byte
	key     bool
}

type nativeDownloadBundle struct {
	assets    []nativeDownloadAsset
	playlists map[string][]byte
	quality   int
}

type nativeDownloadFileState struct {
	URL       string `json:"url"`
	Validator string `json:"validator"`
	Total     int64  `json:"total"`
	Complete  bool   `json:"complete"`
}

func (manager *nativeDownloads) transferMedia(ctx context.Context, job nativeDownloadJob, media ProviderMedia) (nativeDownloadResult, error) {
	ctx = providerMediaContext(ctx, media.Credentials)
	bundle := nativeDownloadBundle{quality: media.Quality, playlists: map[string][]byte{}}
	parsed, err := url.Parse(media.URL)
	if err != nil || !IsProviderHTTPMediaURL(media.URL) {
		return nativeDownloadResult{}, errors.New("下载地址无效")
	}
	hls := media.Playlist != "" || strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8")
	if !hls {
		// 有的站把播放列表挂在没有 .m3u8 后缀的地址上（av8d 是 /m3u8/{token}），
		// 只按后缀判断会把它当成视频文件下载，最后落盘一份 m3u8 文本。
		hls = manager.mediaLooksLikePlaylist(ctx, media)
	}
	entry := "media.mp4"
	if hls {
		bundle, err = manager.downloadBundle(ctx, media, job.Quality)
		if err != nil {
			return nativeDownloadResult{}, err
		}
		entry = "index.m3u8"
	} else {
		bundle.assets = []nativeDownloadAsset{{address: media.URL, name: entry}}
	}
	directory := manager.jobDirectory(job)
	identity := entry + "\x00" + media.URL + "\x00" + hex.EncodeToString(media.CENCKey) + "\x00" + strconv.Itoa(bundle.quality)
	if hls {
		for _, asset := range bundle.assets {
			identity += "\x00" + asset.address + "\x00" + string(asset.data)
		}
		encoded, _ := json.Marshal(bundle.playlists)
		identity += "\x00" + string(encoded)
	}
	fingerprint := sha256.Sum256([]byte(identity))
	marker := filepath.Join(directory, ".bundle")
	previous, _ := os.ReadFile(marker)
	if len(previous) > 0 && string(previous) != hex.EncodeToString(fingerprint[:]) {
		if err := os.RemoveAll(directory); err != nil {
			return nativeDownloadResult{}, errors.New("无法替换旧的下载文件")
		}
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nativeDownloadResult{}, errors.New("无法创建下载文件，请检查存储空间")
	}
	if err := nativeDownloadWrite(marker, []byte(hex.EncodeToString(fingerprint[:]))); err != nil {
		return nativeDownloadResult{}, err
	}
	var completedBytes int64
	var stateMu sync.Mutex
	var firstErr error
	downloadCtx, cancelDownloads := context.WithCancel(ctx)
	defer cancelDownloads()
	// HLS 分片之间互不依赖，串行下是最主要的慢因；限 8 路并发兼顾速度与站点压力。
	const parallel = 8
	slots := make(chan struct{}, parallel)
	var pending sync.WaitGroup
	for index, asset := range bundle.assets {
		if downloadCtx.Err() != nil {
			break
		}
		target := filepath.Join(directory, asset.name)
		if asset.data != nil {
			if err := nativeDownloadWrite(target, asset.data); err != nil {
				stateMu.Lock()
				firstErr = err
				stateMu.Unlock()
				cancelDownloads()
				break
			}
			stateMu.Lock()
			completedBytes += int64(len(asset.data))
			done := completedBytes
			stateMu.Unlock()
			manager.progress(job.ID, done, 0, float64(index+1)/float64(len(bundle.assets)))
			continue
		}
		pending.Add(1)
		go func(index int, asset nativeDownloadAsset, target string) {
			defer pending.Done()
			select {
			case slots <- struct{}{}:
			case <-downloadCtx.Done():
				return
			}
			defer func() { <-slots }()
			size, err := manager.downloadFile(downloadCtx, asset.address, media.Referer, target, asset.key, hls, func(received, total int64) {
				progress := 0.0
				if total > 0 {
					progress = min(1, float64(received)/float64(total))
				}
				if hls {
					progress = (float64(index) + progress) / float64(len(bundle.assets))
				}
				overallTotal := int64(0)
				if !hls {
					overallTotal = total
				}
				stateMu.Lock()
				base := completedBytes
				stateMu.Unlock()
				manager.progress(job.ID, base+received, overallTotal, progress)
			})
			stateMu.Lock()
			defer stateMu.Unlock()
			if err != nil {
				if firstErr == nil {
					firstErr = err
				}
				cancelDownloads()
				return
			}
			completedBytes += size
		}(index, asset, target)
	}
	pending.Wait()
	if err := ctx.Err(); err != nil {
		return nativeDownloadResult{}, err
	}
	if firstErr != nil {
		return nativeDownloadResult{}, firstErr
	}
	for name, body := range bundle.playlists {
		if err := nativeDownloadWrite(filepath.Join(directory, name), body); err != nil {
			return nativeDownloadResult{}, err
		}
	}
	manager.progress(job.ID, completedBytes, completedBytes, 1)
	return nativeDownloadResult{file: entry, key: hex.EncodeToString(media.CENCKey), quality: bundle.quality}, nil
}

func nativeDownloadValidator(header http.Header) string {
	if value := header.Get("ETag"); value != "" && !strings.HasPrefix(value, "W/") {
		return value
	}
	if value := header.Get("Last-Modified"); value != "" {
		if _, err := http.ParseTime(value); err == nil {
			return value
		}
	}
	return ""
}

func nativeDownloadRange(value string) (int64, int64, int64, bool) {
	var start, end, total int64
	if count, err := fmt.Sscanf(value, "bytes %d-%d/%d", &start, &end, &total); err != nil || count != 3 {
		return 0, 0, 0, false
	}
	return start, end, total, start >= 0 && end >= start && total > end
}

func (manager *nativeDownloads) downloadFile(ctx context.Context, address, referer, target string, key, stripImage bool, progress func(int64, int64)) (int64, error) {
	var metadata nativeDownloadFileState
	if data, err := os.ReadFile(target + ".json"); err == nil {
		_ = json.Unmarshal(data, &metadata)
	}
	if metadata.URL != address {
		metadata = nativeDownloadFileState{}
	}
	if metadata.Complete {
		if info, err := os.Stat(target); err == nil && info.Size() == metadata.Total && info.Size() > 0 && (!key || info.Size() == 16) {
			progress(info.Size(), info.Size())
			return info.Size(), nil
		}
	}
	partial := target + ".part"
	offset := int64(0)
	if metadata.Validator != "" && !key {
		if info, err := os.Stat(partial); err == nil && info.Size() > 0 && (metadata.Total <= 0 || info.Size() <= metadata.Total) {
			offset = info.Size()
		}
	}
	// 网络抖动在下载时很常见：给 1s/2s/4s 三次退避重试，4xx（除 408/429）直接失败不空转。
	const maxAttempts = 4
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			wait := time.Duration(1<<(attempt-1)) * time.Second
			select {
			case <-ctx.Done():
				return 0, ctx.Err()
			case <-time.After(wait):
			}
		}
		size, restart, err := manager.downloadFileAttempt(ctx, address, referer, target, key, stripImage, offset, metadata, progress)
		if restart {
			offset, metadata = 0, nativeDownloadFileState{}
			lastErr = nil
			continue
		}
		if err == nil {
			return size, nil
		}
		if !nativeDownloadRetryable(err) {
			return 0, err
		}
		lastErr = err
	}
	if lastErr != nil {
		return 0, lastErr
	}
	return 0, errors.New("服务器无法恢复下载，请重试")
}

func (manager *nativeDownloads) downloadFileAttempt(ctx context.Context, address, referer, target string, key, stripImage bool, offset int64, old nativeDownloadFileState, progress func(int64, int64)) (int64, bool, error) {
	if !IsProviderHTTPMediaURL(address) {
		return 0, false, errors.New("媒体下载地址无效")
	}
	requestCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	inactivity := time.AfterFunc(60*time.Second, cancel)
	defer inactivity.Stop()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, address, nil)
	if err != nil {
		return 0, false, err
	}
	request.Header.Set("User-Agent", UserAgent)
	request.Header.Set("Referer", referer)
	request.Header.Set("Accept-Encoding", "identity")
	if offset > 0 {
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
		request.Header.Set("If-Range", old.Validator)
	}
	client := *manager.engine.downloader.client
	client.Timeout = 0
	response, err := manager.engine.downloader.doMediaRequestWithClient(request, &client)
	if err != nil {
		if ctx.Err() != nil {
			return 0, false, ctx.Err()
		}
		if requestCtx.Err() != nil {
			return 0, false, errors.New("下载连接 60 秒没有响应，请检查网络后继续")
		}
		var transport *url.Error
		if errors.As(err, &transport) {
			return 0, false, fmt.Errorf("下载连接失败：%w", transport.Err)
		}
		return 0, false, err
	}
	defer response.Body.Close()
	if offset > 0 && (response.StatusCode == http.StatusRequestedRangeNotSatisfiable || response.StatusCode == http.StatusPreconditionFailed) {
		return 0, true, nil
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return 0, false, nativeDownloadError(response.StatusCode)
	}
	if response.StatusCode == http.StatusOK {
		offset = 0
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		return 0, false, errors.New("服务器返回了压缩媒体响应，无法安全续传")
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	if !key && (strings.Contains(contentType, "text/html") || strings.Contains(contentType, "application/json")) {
		return 0, false, fmt.Errorf("下载地址返回的类型是 %s，不是视频，请刷新下载地址后重试", Truncate(contentType, 64))
	}
	total := response.ContentLength
	validator := nativeDownloadValidator(response.Header)
	if response.StatusCode == http.StatusPartialContent {
		start, end, full, valid := nativeDownloadRange(response.Header.Get("Content-Range"))
		if !valid || start != offset || (response.ContentLength >= 0 && response.ContentLength != end-start+1) {
			return 0, false, errors.New("服务器返回的续传范围不正确，已停止下载")
		}
		if offset > 0 && ((validator != "" && validator != old.Validator) || (old.Total > 0 && old.Total != full)) {
			return 0, true, nil
		}
		total = full
	}
	if key && (total > 64 || offset > 0) {
		return 0, false, errors.New("视频密钥格式无效")
	}
	// 有的站把 TS 分片伪装成 PNG（av8d 是 .image 后缀 + 假图片头）。播放走本地代理时会剥掉，
	// 下载若原样落盘，ffmpeg 读到 PNG 头会直接失败。这里在写第一个数据块前判断并剥掉。
	var head []byte
	if stripImage && !key && offset == 0 {
		head = make([]byte, 4096)
		count, readErr := io.ReadFull(response.Body, head)
		head = head[:count]
		if readErr != nil && readErr != io.EOF && readErr != io.ErrUnexpectedEOF {
			return 0, false, errors.New("媒体文件读取失败，请稍后重试")
		}
		if skip := nativeDownloadFakeImageSkip(head); skip > 0 {
			head = head[skip:]
			// 落盘字节比远端少一个假头，Range 续传的偏移会对不上，这类分片只能整段重下。
			validator = ""
			if total > 0 {
				total -= int64(skip)
			}
		}
	}
	metadata := nativeDownloadFileState{URL: address, Validator: validator, Total: total}
	encoded, _ := json.Marshal(metadata)
	if err := nativeDownloadWrite(target+".json", encoded); err != nil {
		return 0, false, err
	}
	flags := os.O_CREATE | os.O_WRONLY
	if offset == 0 {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_APPEND
	}
	file, err := os.OpenFile(target+".part", flags, 0600)
	if err != nil {
		return 0, false, errors.New("无法写入下载文件，请检查存储空间")
	}
	received := offset
	if len(head) > 0 {
		written, writeErr := file.Write(head)
		received += int64(written)
		if writeErr != nil || written != len(head) {
			closeErr := file.Close()
			if closeErr != nil {
				return 0, false, closeErr
			}
			return 0, false, errors.New("写入下载文件失败，请检查剩余空间")
		}
		progress(received, total)
	}
	buffer := make([]byte, 64<<10)
	for {
		n, readErr := response.Body.Read(buffer)
		if n > 0 {
			if key && received+int64(n) > 64 {
				err = errors.New("视频密钥过大")
				break
			}
			written, writeErr := file.Write(buffer[:n])
			received += int64(written)
			if writeErr != nil || written != n {
				err = errors.New("写入下载文件失败，请检查剩余空间")
				break
			}
			inactivity.Reset(30 * time.Second)
			progress(received, total)
		}
		if readErr != nil {
			if readErr != io.EOF {
				err = errors.New("媒体文件未接收完整，点击继续下载")
			}
			break
		}
	}
	if err == nil {
		err = requestCtx.Err()
	}
	if err == nil && (received == 0 || (total >= 0 && received != total)) {
		err = errors.New("媒体文件未接收完整，点击继续下载")
	}
	if err == nil && key && received != 16 {
		err = errors.New("视频密钥长度无效")
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return received, false, err
	}
	if closeErr != nil {
		return received, false, closeErr
	}
	if err = os.Rename(target+".part", target); err != nil {
		return received, false, err
	}
	metadata.Complete, metadata.Total = true, received
	encoded, _ = json.Marshal(metadata)
	if err = nativeDownloadWrite(target+".json", encoded); err != nil {
		return received, false, err
	}
	return received, false, nil
}

func (manager *nativeDownloads) downloadPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	return manager.engine.downloader.fetchMediaPlaylist(ctx, address, referer)
}

// mediaLooksLikePlaylist 判断一个没有 .m3u8 后缀的地址实际返回的是不是播放列表。
// 只看响应头与开头字节，读 2KB 就断开，不影响随后的正式下载。
func (manager *nativeDownloads) mediaLooksLikePlaylist(ctx context.Context, media ProviderMedia) bool {
	// 明确是视频/音频文件的地址不做探测，避免给一次性签名链接多发一次请求。
	if nativeDownloadMediaExtension(media.URL) != "" {
		return false
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, media.URL, nil)
	if err != nil {
		return false
	}
	request.Header.Set("Referer", media.Referer)
	request.Header.Set("Range", "bytes=0-2047")
	client := *manager.engine.downloader.client
	client.Timeout = 10 * time.Second
	response, err := manager.engine.downloader.doMediaRequestWithClient(request, &client)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return false
	}
	if strings.Contains(strings.ToLower(response.Header.Get("Content-Type")), "mpegurl") {
		return true
	}
	head, _ := io.ReadAll(io.LimitReader(response.Body, 2048))
	head = bytes.TrimSpace(bytes.TrimPrefix(head, []byte("\xef\xbb\xbf")))
	return bytes.HasPrefix(head, []byte("#EXTM3U"))
}

var nativeDownloadPNGMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// nativeDownloadMediaExtension 返回地址路径里明确的媒体文件后缀（小写）；没有后缀时返回空。
func nativeDownloadMediaExtension(address string) string {
	parsed, err := url.Parse(address)
	if err != nil {
		return ""
	}
	slash := strings.LastIndex(parsed.Path, "/")
	dot := strings.LastIndex(parsed.Path, ".")
	if dot <= slash {
		return ""
	}
	switch extension := strings.ToLower(parsed.Path[dot:]); extension {
	case ".mp4", ".m4v", ".mov", ".webm", ".mkv", ".flv", ".avi", ".mp3", ".m4a", ".aac", ".ogg", ".wav":
		return extension
	}
	return ""
}

// nativeDownloadFakeImageSkip 返回真实媒体数据在 head 里的起点；不是伪装成图片的分片时返回 0。
func nativeDownloadFakeImageSkip(head []byte) int {
	if len(head) < len(nativeDownloadPNGMagic) || !bytes.HasPrefix(head, nativeDownloadPNGMagic) {
		return 0
	}
	if end := bytes.Index(head, []byte("IEND")); end >= 0 && end+8 < len(head) && head[end+8] == 0x47 {
		return end + 8
	}
	if trimmed := stripFakeTSHeader(head); len(trimmed) < len(head) {
		return len(head) - len(trimmed)
	}
	return 0
}
