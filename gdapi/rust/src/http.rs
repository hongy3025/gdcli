//! HTTP/1.1 请求解析与响应序列化（极简，仅服务 gdapi 的需求）。
//!
//! 解析特性：
//! - 仅支持 Content-Length（不支持 chunked transfer encoding）
//! - 不区分大小写：header name 全部转为小写
//! - Body 上限 16 MiB
//! - 不解析 query string（path 保留原样）

use std::io;

pub const MAX_BODY: usize = 16 * 1024 * 1024;
const MAX_HEADERS: usize = 64;

/// 已解析的 HTTP 请求结构体。
///
/// 包含从原始字节流中解析出的 HTTP 请求各组成部分。
#[derive(Debug, PartialEq)]
pub struct ParsedRequest {
    /// HTTP 方法（GET、POST 等）
    pub method: String,
    /// 请求路径（包含 query string，不解析）
    pub path: String,
    /// 请求头列表（键已转为小写）
    pub headers: Vec<(String, String)>,
    /// 请求体字节
    pub body: Vec<u8>,
}

/// 解析 HTTP/1.1 请求。
///
/// 返回值：
///   Ok(None)     => 缓冲区数据不完整，调用方应继续 read 后再调
///   Ok(Some(r))  => 解析成功
///   Err(e)       => 不可恢复错误（应返回 400 并关闭连接）
pub fn parse_request(buf: &[u8]) -> io::Result<Option<ParsedRequest>> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut req = httparse::Request::new(&mut headers);
    let status = req.parse(buf).map_err(|e| {
        io::Error::new(io::ErrorKind::InvalidData, format!("http parse: {:?}", e))
    })?;
    let header_end = match status {
        httparse::Status::Complete(n) => n,
        httparse::Status::Partial => return Ok(None),
    };
    let method = req.method.ok_or_else(|| invalid("missing method"))?.to_string();
    let path = req.path.ok_or_else(|| invalid("missing path"))?.to_string();

    let mut hdrs: Vec<(String, String)> = Vec::with_capacity(req.headers.len());
    let mut content_length: usize = 0;
    for h in req.headers.iter() {
        let name_lc = h.name.to_ascii_lowercase();
        let value = std::str::from_utf8(h.value)
            .map_err(|_| invalid("non-utf8 header"))?
            .to_string();
        if name_lc == "content-length" {
            let new_cl = value
                .trim()
                .parse::<usize>()
                .map_err(|_| invalid("invalid Content-Length"))?;
            if content_length != 0 && new_cl != content_length {
                return Err(invalid("conflicting Content-Length values"));
            }
            content_length = new_cl;
        }
        hdrs.push((name_lc, value));
    }

    if content_length > MAX_BODY {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Content-Length exceeds 16 MiB",
        ));
    }

    let total_needed = header_end + content_length;
    if buf.len() < total_needed {
        return Ok(None);
    }

    let body = buf[header_end..total_needed].to_vec();
    Ok(Some(ParsedRequest {
        method,
        path,
        headers: hdrs,
        body,
    }))
}

/// 序列化为 HTTP/1.1 响应字节流。
///
/// 自动生成 `Content-Length` 和 `Connection: close` 头部。
///
/// # Arguments
/// * `status` - HTTP 状态码（如 200、404）
/// * `headers` - 自定义响应头列表
/// * `body` - 响应体字节
///
/// # Returns
/// 完整的 HTTP 响应字节流，可直接写入 TCP 连接
///
/// # Panics
/// 如果 header name 或 value 包含 `\r\n`，会 panic（防止 header 注入）
pub fn write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> Vec<u8> {
    let reason = reason_phrase(status);
    let mut out = Vec::with_capacity(128 + body.len());
    out.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", status, reason).as_bytes());
    for (k, v) in headers {
        // 防止 header 注入：检查 name 和 value 中的 \r\n
        if k.contains('\r') || k.contains('\n') {
            panic!("header name contains CR/LF: {:?}", k);
        }
        if v.contains('\r') || v.contains('\n') {
            panic!("header value contains CR/LF: {:?}", v);
        }
        out.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }
    out.extend_from_slice(format!("content-length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"connection: close\r\n");
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);
    out
}

/// 创建 InvalidData 类型的 IO 错误。
///
/// # Arguments
/// * `msg` - 错误描述信息
fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

/// 根据 HTTP 状态码返回对应的 Reason Phrase。
///
/// # Arguments
/// * `s` - HTTP 状态码
///
/// # Returns
/// 对应的 Reason Phrase 字符串，未知状态码返回空字符串
fn reason_phrase(s: u16) -> &'static str {
    match s {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_minimal_get() {
        let buf = b"GET /ping HTTP/1.1\r\nHost: x\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.method, "GET");
        assert_eq!(parsed.path, "/ping");
        assert!(parsed.body.is_empty());
    }

    #[test]
    fn parse_post_with_body() {
        let mut buf: Vec<u8> = b"POST /scene/create HTTP/1.1\r\nHost: x\r\nContent-Length: 13\r\n\r\n".to_vec();
        buf.extend_from_slice(br#"{"foo":"bar"}"#);
        let parsed = parse_request(&buf).unwrap().unwrap();
        assert_eq!(parsed.method, "POST");
        assert_eq!(parsed.path, "/scene/create");
        assert_eq!(parsed.body, br#"{"foo":"bar"}"#.to_vec());
    }

    #[test]
    fn parse_incomplete_returns_none() {
        let buf = b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort";
        let result = parse_request(buf).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn parse_partial_headers_returns_none() {
        let buf = b"POST /x HTTP/1.1\r\nHost: x";
        let result = parse_request(buf).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn parse_malformed_errors() {
        let buf = b"NOTAREQUEST\r\n\r\n";
        assert!(parse_request(buf).is_err());
    }

    #[test]
    fn parse_body_too_large_errors() {
        let big = 17 * 1024 * 1024;
        let buf = format!("POST /x HTTP/1.1\r\nContent-Length: {}\r\n\r\n", big);
        assert!(parse_request(buf.as_bytes()).is_err());
    }

    #[test]
    fn header_names_are_lowercased() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Type: application/json\r\nX-Foo: Bar\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        let names: Vec<&str> = parsed.headers.iter().map(|(k, _)| k.as_str()).collect();
        assert!(names.contains(&"content-type"));
        assert!(names.contains(&"x-foo"));
    }

    #[test]
    fn write_response_basic() {
        let bytes = write_response(200, &[("content-type".into(), "application/json".into())], b"{}");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(s.contains("content-type: application/json\r\n"));
        assert!(s.contains("content-length: 2\r\n"));
        assert!(s.contains("connection: close\r\n"));
        assert!(s.ends_with("\r\n\r\n{}"));
    }

    #[test]
    fn write_response_413() {
        let bytes = write_response(413, &[], b"");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 413 Payload Too Large\r\n"));
    }

    #[test]
    fn parse_conflicting_content_length_errors() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 3\r\n\r\nabcde";
        let result = parse_request(buf);
        assert!(result.is_err(), "expected error for conflicting Content-Length");
    }

    #[test]
    fn parse_duplicate_content_length_same_value_ok() {
        let mut buf: Vec<u8> = b"POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n".to_vec();
        buf.extend_from_slice(b"abc");
        let parsed = parse_request(&buf).unwrap().unwrap();
        assert_eq!(parsed.body, b"abc".to_vec());
    }

    #[test]
    fn parse_zero_content_length() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert!(parsed.body.is_empty());
    }

    #[test]
    fn write_response_empty_body() {
        let bytes = write_response(204, &[], b"");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("content-length: 0\r\n"));
    }

    #[test]
    fn parse_query_string_preserved_in_path() {
        let buf = b"GET /search?q=hello&limit=10 HTTP/1.1\r\nHost: x\r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.path, "/search?q=hello&limit=10");
    }

    #[test]
    #[should_panic(expected = "header value contains CR/LF")]
    fn write_response_rejects_header_injection_in_value() {
        let headers = vec![("content-type".into(), "text/html\r\nInjected: evil".into())];
        write_response(200, &headers, b"ok");
    }

    #[test]
    #[should_panic(expected = "header name contains CR/LF")]
    fn write_response_rejects_header_injection_in_name() {
        let headers = vec![("content-type\r\nInjected".into(), "text/html".into())];
        write_response(200, &headers, b"ok");
    }

    #[test]
    fn parse_header_value_empty() {
        let buf = b"GET /x HTTP/1.1\r\nHost: \r\n\r\n";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.headers[0].1, "");
    }

    #[test]
    fn parse_content_length_with_leading_zero() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Length: 007\r\n\r\nabcdefg";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.body, b"abcdefg".to_vec());
    }

    #[test]
    fn parse_content_length_uppercase() {
        let buf = b"POST /x HTTP/1.1\r\nCONTENT-LENGTH: 3\r\n\r\nabc";
        let parsed = parse_request(buf).unwrap().unwrap();
        assert_eq!(parsed.body, b"abc".to_vec());
    }

    #[test]
    fn parse_missing_method_errors() {
        let buf = b"/ping HTTP/1.1\r\nHost: x\r\n\r\n";
        assert!(parse_request(buf).is_err());
    }

    #[test]
    fn parse_missing_path_errors() {
        let buf = b"GET HTTP/1.1\r\nHost: x\r\n\r\n";
        assert!(parse_request(buf).is_err());
    }

    #[test]
    fn write_response_unknown_status_code() {
        let bytes = write_response(418, &[], b"");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 418 \r\n"));
    }
}
