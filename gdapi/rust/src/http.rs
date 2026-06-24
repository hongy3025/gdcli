//! HTTP/1.1 请求解析与响应序列化（极简，仅服务 gdapi 的需求）。
//!
//! 解析特性：
//! - 仅支持 Content-Length（不支持 chunked transfer encoding）
//! - 不区分大小写：header name 全部转为小写
//! - Body 上限 16 MiB
//! - 不解析 query string（path 保留原样）

use std::io::{self, Write};

pub const MAX_BODY: usize = 16 * 1024 * 1024;
pub const MAX_HEADER_BYTES: usize = 32 * 1024;
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
    let status = req
        .parse(buf)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("http parse: {:?}", e)))?;
    let header_end = match status {
        httparse::Status::Complete(n) => n,
        httparse::Status::Partial => return Ok(None),
    };
    if header_end > MAX_HEADER_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HTTP headers exceed 32 KiB",
        ));
    }
    let method = req
        .method
        .ok_or_else(|| invalid("missing method"))?
        .to_string();
    let path = req.path.ok_or_else(|| invalid("missing path"))?.to_string();

    let mut hdrs: Vec<(String, String)> = Vec::with_capacity(req.headers.len());
    let mut content_length: Option<usize> = None;
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
            if let Some(existing_cl) = content_length {
                if new_cl != existing_cl {
                    return Err(invalid("conflicting Content-Length values"));
                }
            } else {
                content_length = Some(new_cl);
            }
        }
        hdrs.push((name_lc, value));
    }

    let content_length = content_length.unwrap_or(0);

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

/// 校验 Godot 侧提供的响应头，避免协议注入与覆盖托管头。
pub fn validate_response_header(name: &str, value: &str) -> io::Result<()> {
    if name.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "header name is empty",
        ));
    }
    if name.contains('\r') || name.contains('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "header name contains CR/LF",
        ));
    }
    if value.contains('\r') || value.contains('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "header value contains CR/LF",
        ));
    }
    if name.eq_ignore_ascii_case("content-length") || name.eq_ignore_ascii_case("connection") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("managed response header cannot be supplied: {}", name),
        ));
    }
    Ok(())
}

/// Fallible HTTP/1.1 response serializer.
pub fn try_write_response(
    status: u16,
    headers: &[(String, String)],
    body: &[u8],
) -> io::Result<Vec<u8>> {
    if headers.len() > MAX_HEADERS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "too many response headers",
        ));
    }

    for (k, v) in headers {
        validate_response_header(k, v)?;
    }

    let reason = reason_phrase(status);
    let mut header_bytes = 9; // "HTTP/1.1 "
    header_bytes = checked_response_len(header_bytes, decimal_len(status as usize))?;
    header_bytes = checked_response_len(header_bytes, 1 + reason.len() + 2)?;
    for (k, v) in headers {
        header_bytes = checked_response_len(header_bytes, k.len())?;
        header_bytes = checked_response_len(header_bytes, 2 + v.len() + 2)?;
    }
    header_bytes = checked_response_len(header_bytes, 16 + decimal_len(body.len()) + 2)?;
    header_bytes = checked_response_len(header_bytes, b"connection: close\r\n".len())?;
    header_bytes = checked_response_len(header_bytes, b"\r\n".len())?;
    if header_bytes > MAX_HEADER_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "response headers exceed MAX_HEADER_BYTES",
        ));
    }

    let total_bytes = checked_response_len(header_bytes, body.len())?;
    let mut out = Vec::new();
    out.try_reserve_exact(total_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::Other, "response allocation failed"))?;

    write!(&mut out, "HTTP/1.1 {} {}\r\n", status, reason)?;
    for (k, v) in headers {
        out.write_all(k.as_bytes())?;
        out.write_all(b": ")?;
        out.write_all(v.as_bytes())?;
        out.write_all(b"\r\n")?;
    }
    write!(&mut out, "content-length: {}\r\n", body.len())?;
    out.write_all(b"connection: close\r\n")?;
    out.write_all(b"\r\n")?;
    out.write_all(body)?;
    Ok(out)
}

fn checked_response_len(current: usize, additional: usize) -> io::Result<usize> {
    current.checked_add(additional).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "response size calculation overflowed",
        )
    })
}

fn decimal_len(mut n: usize) -> usize {
    let mut len = 1;
    while n >= 10 {
        n /= 10;
        len += 1;
    }
    len
}

/// 序列化为 HTTP/1.1 响应字节流；无效输入返回安全 fallback 响应。
pub fn write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> Vec<u8> {
    match try_write_response(status, headers, body) {
        Ok(bytes) => bytes,
        Err(_) => fallback_response(500, br#"{"error":"internal response error"}"#),
    }
}

fn fallback_response(status: u16, body: &[u8]) -> Vec<u8> {
    let reason = reason_phrase(status);
    let mut out = Vec::with_capacity(128 + body.len());
    out.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", status, reason).as_bytes());
    out.extend_from_slice(b"content-type: application/json\r\n");
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
    fn max_header_bytes_is_smaller_than_max_body() {
        assert_eq!(MAX_HEADER_BYTES, 32 * 1024);
        assert!(MAX_HEADER_BYTES < MAX_BODY);
    }

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
        let mut buf: Vec<u8> =
            b"POST /scene/create HTTP/1.1\r\nHost: x\r\nContent-Length: 13\r\n\r\n".to_vec();
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
    fn parse_complete_headers_over_max_header_bytes_errors() {
        let buf = format!(
            "GET /x HTTP/1.1\r\nX-Fill: {}\r\n\r\n",
            "a".repeat(MAX_HEADER_BYTES)
        );
        let err = parse_request(buf.as_bytes()).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(err.to_string().contains("HTTP headers exceed 32 KiB"));
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
        let bytes = write_response(
            200,
            &[("content-type".into(), "application/json".into())],
            b"{}",
        );
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
        assert!(
            result.is_err(),
            "expected error for conflicting Content-Length"
        );
    }

    #[test]
    fn parse_zero_then_nonzero_content_length_conflict_errors() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\nabcde";
        let result = parse_request(buf);
        assert!(
            result.is_err(),
            "expected error for conflicting Content-Length"
        );
    }

    #[test]
    fn parse_duplicate_content_length_same_value_ok() {
        let mut buf: Vec<u8> =
            b"POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n".to_vec();
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
    fn try_write_response_rejects_header_injection_in_value() {
        let headers = vec![("content-type".into(), "text/html\r\nInjected: evil".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header value contains CR/LF"));
        assert!(!err.to_string().contains("Injected"));
    }

    #[test]
    fn try_write_response_rejects_header_injection_in_name() {
        let headers = vec![("content-type\r\nInjected".into(), "text/html".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header name contains CR/LF"));
        assert!(!err.to_string().contains("Injected"));
    }

    #[test]
    fn try_write_response_rejects_empty_header_name() {
        let headers = vec![("".into(), "text/html".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header name is empty"));
    }

    #[test]
    fn try_write_response_rejects_managed_headers() {
        let headers = vec![("content-length".into(), "999".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("managed response header"));
    }

    #[test]
    fn try_write_response_rejects_too_many_headers() {
        let headers: Vec<(String, String)> = (0..=MAX_HEADERS)
            .map(|i| (format!("x-test-{}", i), "ok".into()))
            .collect();
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("too many response headers"));
    }

    #[test]
    fn try_write_response_rejects_oversized_header_bytes() {
        let headers = vec![("x-test".into(), "a".repeat(MAX_HEADER_BYTES))];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("response headers exceed"));
    }

    #[test]
    fn write_response_falls_back_without_panicking() {
        let headers = vec![("content-type".into(), "text/html\r\nInjected: evil".into())];
        let bytes = write_response(200, &headers, b"ok");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 500 Internal Server Error\r\n"));
        assert!(s.contains("content-length:"));
        assert!(s.ends_with("{\"error\":\"internal response error\"}"));
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
