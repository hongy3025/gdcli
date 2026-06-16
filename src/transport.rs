use anyhow::{anyhow, Result};
use bytes::BytesMut;

/// 滚动缓冲区：从 TCP 字节流中解出一个完整 JSON-RPC body。
pub struct MessageBuffer {
    buf: BytesMut,
}

impl MessageBuffer {
    pub fn new() -> Self {
        Self { buf: BytesMut::new() }
    }

    pub fn append(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
    }

    /// 尝试读出一个 body（UTF-8 字符串）。返回 None 表示数据不足。
    pub fn try_read_message(&mut self) -> Result<Option<String>> {
        // 找 \r\n\r\n
        let sep = match find_double_crlf(&self.buf) {
            Some(i) => i,
            None => return Ok(None),
        };
        let header_str = std::str::from_utf8(&self.buf[..sep])
            .map_err(|_| anyhow!("invalid header bytes"))?;
        let mut content_length: Option<usize> = None;
        for line in header_str.split("\r\n") {
            if let Some((k, v)) = line.split_once(':') {
                if k.eq_ignore_ascii_case("Content-Length") {
                    content_length = v.trim().parse().ok();
                }
            }
        }
        let len = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
        let body_start = sep + 4;
        let total = body_start + len;
        if self.buf.len() < total {
            return Ok(None);
        }
        let body = std::str::from_utf8(&self.buf[body_start..total])
            .map_err(|_| anyhow!("invalid body utf-8"))?
            .to_string();
        let _ = self.buf.split_to(total);
        Ok(Some(body))
    }
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    if buf.len() < 4 {
        return None;
    }
    for i in 0..=buf.len() - 4 {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' && buf[i + 2] == b'\r' && buf[i + 3] == b'\n' {
            return Some(i);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(body: &str) -> Vec<u8> {
        format!("Content-Length: {}\r\n\r\n{}", body.len(), body).into_bytes()
    }

    #[test]
    fn single_complete_message() {
        let mut buf = MessageBuffer::new();
        buf.append(&frame(r#"{"jsonrpc":"2.0","id":1,"result":null}"#));
        let msg = buf.try_read_message().unwrap().expect("should read");
        assert!(msg.contains(r#""id":1"#));
    }

    #[test]
    fn split_across_chunks() {
        let mut buf = MessageBuffer::new();
        let full = frame(r#"{"a":1}"#);
        let (a, b) = full.split_at(8);
        buf.append(a);
        assert!(buf.try_read_message().unwrap().is_none());
        buf.append(b);
        let msg = buf.try_read_message().unwrap().expect("should read");
        assert_eq!(msg, r#"{"a":1}"#);
    }

    #[test]
    fn back_to_back_messages() {
        let mut buf = MessageBuffer::new();
        let mut combined = frame(r#"{"a":1}"#);
        combined.extend(frame(r#"{"b":2}"#));
        buf.append(&combined);
        assert_eq!(buf.try_read_message().unwrap().unwrap(), r#"{"a":1}"#);
        assert_eq!(buf.try_read_message().unwrap().unwrap(), r#"{"b":2}"#);
        assert!(buf.try_read_message().unwrap().is_none());
    }

    #[test]
    fn missing_content_length_errors() {
        let mut buf = MessageBuffer::new();
        buf.append(b"Foo: bar\r\n\r\nbody");
        assert!(buf.try_read_message().is_err());
    }
}
