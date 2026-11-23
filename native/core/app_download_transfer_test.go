package core

import (
	"bytes"
	"testing"
)

func nativeTestFakeImage(head []byte, payload []byte) []byte {
	// PNG 魔数 + 一段任意块 + IEND(含 4 字节 CRC) + 真实 TS 数据
	body := append([]byte{}, head...)
	body = append(body, 0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0)
	body = append(body, 0, 0, 0, 0)
	body = append(body, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82)
	return append(body, payload...)
}

func nativeTestTSPayload(packets int) []byte {
	data := make([]byte, 188*packets)
	for i := 0; i < packets; i++ {
		data[i*188] = 0x47
	}
	return data
}

func TestNativeDownloadFakeImageSkip(t *testing.T) {
	png := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	payload := nativeTestTSPayload(24)
	fake := nativeTestFakeImage(png, payload)

	if skip := nativeDownloadFakeImageSkip(fake); skip != len(fake)-len(payload) {
		t.Fatalf("伪装 PNG 分片应剥掉 %d 字节，得到 %d", len(fake)-len(payload), skip)
	}
	if !bytes.Equal(fake[nativeDownloadFakeImageSkip(fake):], payload) {
		t.Fatal("剥掉假头后应正好是 TS 数据")
	}

	plain := nativeTestTSPayload(24)
	if skip := nativeDownloadFakeImageSkip(plain); skip != 0 {
		t.Fatalf("正常 TS 分片不应被改动，得到 %d", skip)
	}

	notTS := nativeTestFakeImage(png, bytes.Repeat([]byte{0x11}, 512))
	if skip := nativeDownloadFakeImageSkip(notTS); skip != 0 {
		t.Fatalf("找不到 TS 同步字节时不应乱切，得到 %d", skip)
	}

	if skip := nativeDownloadFakeImageSkip(nil); skip != 0 {
		t.Fatalf("空数据不应被改动，得到 %d", skip)
	}
	if skip := nativeDownloadFakeImageSkip([]byte{0x89, 'P', 'N', 'G'}); skip != 0 {
		t.Fatalf("过短数据不应被改动，得到 %d", skip)
	}
}

func TestNativeDownloadMediaExtension(t *testing.T) {
	cases := map[string]string{
		"https://a.com/video/1.mp4?token=x": ".mp4",
		"https://a.com/a.MP4":               ".mp4",
		"https://a.com/m3u8/abcDEF":         "",
		"https://a.com/play/123":            "",
		"https://a.com/x.m3u8?t=1":          "",
	}
	for address, want := range cases {
		if got := nativeDownloadMediaExtension(address); got != want {
			t.Fatalf("%s 期望 %q，得到 %q", address, want, got)
		}
	}
}
