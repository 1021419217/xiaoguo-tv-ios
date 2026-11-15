package core

import (
	"net/http"
	"testing"
)

// 代理被 iOS 挂起掐掉监听端口后，必须能被探活发现，否则 engine.stream
// 会一直返回死实例，用户只能杀 App 重开。
func TestStreamServerAliveDetectsClosedListener(t *testing.T) {
	stream, err := newNativeStreamServer(&Downloader{})
	if err != nil {
		t.Fatal(err)
	}
	if !stream.alive() {
		t.Fatal("新建的代理应该探活成功")
	}
	stream.shutdown()
	if stream.alive() {
		t.Fatal("关闭后的代理不应探活成功")
	}
}

// 重建后 engine.stream 必须换成新实例，且旧实例不会再被返回。
func TestEngineStreamServerRebuildsDeadProxy(t *testing.T) {
	engine := &nativeEngine{downloader: &Downloader{}}
	first, err := engine.streamServer()
	if err != nil {
		t.Fatal(err)
	}
	first.shutdown()

	second, err := engine.streamServer()
	if err != nil {
		t.Fatal(err)
	}
	if second == first {
		t.Fatal("代理已死，应该返回重建后的新实例")
	}
	if !second.alive() {
		t.Fatal("重建后的代理应该可用")
	}
	second.shutdown()
}

// 91porn 的 CDN 见到 Sec-Fetch-Mode 就 RST，媒体请求不能带这两个头。
func TestMediaRequestHeadersSkipSecFetch(t *testing.T) {
	request, err := http.NewRequest(http.MethodGet, "https://example.invalid/a.mp4", nil)
	if err != nil {
		t.Fatal(err)
	}
	mediaRequestHeaders(request, "https://example.invalid/watch/1")
	if value := request.Header.Get("Sec-Fetch-Mode"); value != "" {
		t.Fatalf("Sec-Fetch-Mode 不应该出现，实际 %q", value)
	}
	if value := request.Header.Get("Sec-Fetch-Dest"); value != "" {
		t.Fatalf("Sec-Fetch-Dest 不应该出现，实际 %q", value)
	}
	if request.Header.Get("Referer") == "" || request.Header.Get("Origin") == "" {
		t.Fatalf("Referer/Origin 要保留，实际 %+v", request.Header)
	}
}
