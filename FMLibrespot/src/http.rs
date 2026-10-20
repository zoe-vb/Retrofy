//! Minimal blocking HTTPS client on rustls, for hosts iOS 6's Secure Transport can't talk to.
//! accounts.spotify.com only offers AES-GCM cipher suites, which iOS 6 doesn't support.

use std::ffi::{c_char, CStr};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::ptr;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

const TIMEOUT: Duration = Duration::from_secs(20);

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

fn client_config() -> Result<Arc<ClientConfig>, String> {
    static CONFIG: OnceLock<Result<Arc<ClientConfig>, String>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            // Bundled roots: iOS 6's trust store predates the CAs Spotify uses.
            let roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .map(|builder| Arc::new(builder.with_root_certificates(roots).with_no_client_auth()))
                .map_err(|error| error.to_string())
        })
        .clone()
}

/// Splits "https://host[:port]/path?query" into host, port and path.
fn parse_url(url: &str) -> Result<(String, u16, String), String> {
    let rest = url.strip_prefix("https://").ok_or("Only https:// URLs are supported")?;
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().map_err(|_| "Invalid port")?),
        None => (authority, 443),
    };
    if host.is_empty() {
        return Err("Missing host".into());
    }
    Ok((host.to_string(), port, path.to_string()))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn decode_chunked(mut data: &[u8]) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    loop {
        let line_end = find(data, b"\r\n").ok_or("Truncated chunk size")?;
        let size_line = std::str::from_utf8(&data[..line_end]).map_err(|_| "Invalid chunk size")?;
        let size_hex = size_line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_hex, 16).map_err(|_| "Invalid chunk size")?;
        data = &data[line_end + 2..];
        if size == 0 {
            return Ok(body);
        }
        if data.len() < size {
            return Err("Truncated chunk".into());
        }
        body.extend_from_slice(&data[..size]);
        data = data.get(size + 2..).unwrap_or(&[]);
    }
}

fn parse_response(raw: &[u8]) -> Result<Response, String> {
    let header_end = find(raw, b"\r\n\r\n").ok_or("Invalid HTTP response")?;
    let head = std::str::from_utf8(&raw[..header_end]).map_err(|_| "Invalid HTTP headers")?;
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .and_then(|code| code.parse().ok())
        .ok_or("Invalid HTTP status line")?;

    let mut chunked = false;
    let mut content_length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let value = value.trim();
            if name.eq_ignore_ascii_case("transfer-encoding") && value.eq_ignore_ascii_case("chunked") {
                chunked = true;
            } else if name.eq_ignore_ascii_case("content-length") {
                content_length = value.parse::<usize>().ok();
            }
        }
    }

    let body = &raw[header_end + 4..];
    let body = if chunked {
        decode_chunked(body)?
    } else if let Some(length) = content_length {
        body[..length.min(body.len())].to_vec()
    } else {
        body.to_vec()
    };
    Ok(Response { status, body })
}

pub fn request(
    method: &str,
    url: &str,
    headers: &[(&str, &str)],
    body: &[u8],
) -> Result<Response, String> {
    let (host, port, path) = parse_url(url)?;
    let server_name = ServerName::try_from(host.clone()).map_err(|_| format!("Invalid host name {host}"))?;
    let connection = ClientConnection::new(client_config()?, server_name).map_err(|e| e.to_string())?;

    let socket = TcpStream::connect((host.as_str(), port)).map_err(|e| format!("Couldn't connect to {host}: {e}"))?;
    socket.set_read_timeout(Some(TIMEOUT)).ok();
    socket.set_write_timeout(Some(TIMEOUT)).ok();
    let mut stream = StreamOwned::new(connection, socket);

    // One request per connection keeps this simple: the response ends when the server closes.
    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: FoxMusic\r\nAccept: */*\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).map_err(|e| format!("TLS error: {e}"))?;
    stream.write_all(body).map_err(|e| format!("TLS error: {e}"))?;
    stream.flush().map_err(|e| format!("TLS error: {e}"))?;

    let mut raw = Vec::new();
    if let Err(error) = stream.read_to_end(&mut raw) {
        // Some servers close without a TLS close_notify, which is fine once the response arrived.
        if error.kind() != std::io::ErrorKind::UnexpectedEof || raw.is_empty() {
            return Err(format!("TLS error: {error}"));
        }
    }
    parse_response(&raw)
}

unsafe fn optional_str<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        None
    } else {
        CStr::from_ptr(value).to_str().ok()
    }
}

/// Performs a blocking HTTPS request. Returns true on success and stores the HTTP status and the body
/// (NUL terminated for convenience, free it with fm_librespot_free_buffer). On failure stores a message
/// in error_out, free it with fm_librespot_free_string.
#[no_mangle]
pub unsafe extern "C" fn fm_https_request(
    method: *const c_char,
    url: *const c_char,
    content_type: *const c_char,
    authorization: *const c_char,
    body: *const u8,
    body_length: usize,
    status_out: *mut i32,
    body_out: *mut *mut u8,
    body_length_out: *mut usize,
    error_out: *mut *mut c_char,
) -> bool {
    let fail = |message: String| {
        if !error_out.is_null() {
            *error_out = std::ffi::CString::new(message).unwrap_or_default().into_raw();
        }
        false
    };
    let (Some(method), Some(url)) = (optional_str(method), optional_str(url)) else {
        return fail("Missing method or URL".into());
    };
    let body = if body.is_null() { &[][..] } else { std::slice::from_raw_parts(body, body_length) };
    let mut headers = Vec::new();
    if let Some(content_type) = optional_str(content_type) {
        headers.push(("Content-Type", content_type));
    }
    if let Some(authorization) = optional_str(authorization) {
        headers.push(("Authorization", authorization));
    }

    match request(method, url, &headers, body) {
        Ok(response) => {
            if !status_out.is_null() {
                *status_out = i32::from(response.status);
            }
            if !body_length_out.is_null() {
                *body_length_out = response.body.len();
            }
            if !body_out.is_null() {
                let mut buffer = response.body;
                buffer.push(0);
                *body_out = Box::into_raw(buffer.into_boxed_slice()) as *mut u8;
            }
            true
        }
        Err(message) => fail(message),
    }
}

/// Frees a body returned by fm_https_request. `length` is the body length it reported.
#[no_mangle]
pub unsafe extern "C" fn fm_librespot_free_buffer(buffer: *mut u8, length: usize) {
    if !buffer.is_null() {
        drop(Box::from_raw(ptr::slice_from_raw_parts_mut(buffer, length + 1)));
    }
}
