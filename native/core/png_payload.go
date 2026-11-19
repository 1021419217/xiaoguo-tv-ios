package core

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"io"
)

var pngSignature = []byte{137, 80, 78, 71, 13, 10, 26, 10}

// pngPayloadChunk 是站点自定义的 chunk 类型 0x726F5564（"roUd"）。
const pngPayloadChunk = 0x726F5564

// unwrapPNGPayload 解出站点塞在 PNG 自定义 chunk 里的真实数据。
//
// rou.video 把 m3u8 和分片都包成 PNG：找到 roUd chunk 后，首字节是标志位，
// flag&1 表示后面是 deflate 压缩的数据，否则就是明文。前端用
// DecompressionStream("deflate") 还原，这里对应 compress/zlib。
func unwrapPNGPayload(data []byte) ([]byte, bool) {
	if len(data) < 8 || !bytes.Equal(data[:8], pngSignature) {
		return nil, false
	}
	offset := 8
	for offset+8 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[offset:]))
		kind := binary.BigEndian.Uint32(data[offset+4:])
		start := offset + 8
		if length < 1 || start+length > len(data) {
			break
		}
		if kind == pngPayloadChunk {
			flag := data[start]
			payload := data[start+1 : start+length]
			if flag&1 == 0 {
				return payload, true
			}
			reader, err := zlib.NewReader(bytes.NewReader(payload))
			if err != nil {
				return nil, false
			}
			plain, err := io.ReadAll(reader)
			_ = reader.Close()
			if err != nil {
				return nil, false
			}
			return plain, true
		}
		offset = start + length + 4
	}
	return nil, false
}
