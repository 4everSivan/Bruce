use crate::{HttpClient, HttpRequest, HttpResponse, ProviderError, UreqHttpClient};
use collector_runtime::CancellationToken;
use std::collections::BTreeMap;
use std::time::Duration;

struct UnconfiguredClient;

impl HttpClient for UnconfiguredClient {
    fn send(
        &self,
        _request: HttpRequest,
        _cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        panic!("代理不可用时不得回退直接请求")
    }
}

fn request() -> HttpRequest {
    HttpRequest {
        method: "GET".into(),
        url: "https://example.invalid/".into(),
        headers: BTreeMap::new(),
        body: None,
        timeout: Duration::from_secs(1),
        max_response_body_bytes: 1024,
    }
}

#[test]
fn unsupported_proxy_does_not_fall_back_to_direct_transport() {
    let error = UnconfiguredClient
        .send_via_loopback_proxy(10809, request(), &CancellationToken::new())
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "EGRESS_PROXY_UNAVAILABLE");
}

#[test]
fn zero_port_is_rejected_without_network_access() {
    let error = UreqHttpClient::default()
        .send_via_loopback_proxy(0, request(), &CancellationToken::new())
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "EGRESS_CONFIG_INVALID");
}

#[test]
fn connection_refused_is_classified_as_proxy_unreachable() {
    use std::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let error = UreqHttpClient::default()
        .send_via_loopback_proxy(port, request(), &CancellationToken::new())
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "EGRESS_PROXY_UNREACHABLE");
}

#[test]
fn https_request_uses_explicit_loopback_proxy() {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let server = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut buffer = [0u8; 2048];
                    let len = stream.read(&mut buffer).unwrap();
                    let _ =
                        stream.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                    return String::from_utf8_lossy(&buffer[..len]).into_owned();
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(std::time::Instant::now() < deadline, "代理没有收到连接");
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("监听代理失败: {error}"),
            }
        }
    });
    let _ = UreqHttpClient::default().send_via_loopback_proxy(
        port,
        request(),
        &CancellationToken::new(),
    );
    let received = server.join().unwrap();
    assert!(
        received.starts_with("CONNECT example.invalid:443 HTTP/1."),
        "{received}"
    );
}

/// 回环「代理」: 接受一个连接并读取请求头后, 回写 `response`; `None` 表示不应答,
/// 保持连接直到客户端 1 秒超时之后。
fn serve_once(response: Option<&'static [u8]>) -> (u16, std::thread::JoinHandle<()>) {
    use std::io::{Read, Write};
    use std::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut buffer = [0u8; 2048];
        let _ = stream.read(&mut buffer);
        match response {
            Some(response) => {
                let _ = stream.write_all(response);
            }
            None => std::thread::sleep(Duration::from_millis(1500)),
        }
    });
    (port, handle)
}

fn proxy_error_code(response: Option<&'static [u8]>) -> String {
    let (port, server) = serve_once(response);
    let error = UreqHttpClient::default()
        .send_via_loopback_proxy(port, request(), &CancellationToken::new())
        .unwrap_err();
    server.join().unwrap();
    error.diagnostic.code
}

#[test]
fn stalled_proxy_read_timeout_is_not_proxy_unreachable() {
    // C239: 代理接受连接后不应答 (信标慢 / 上游卡住) 是超时, 不是代理不可达。
    assert_eq!(proxy_error_code(None), "PROVIDER_TRANSPORT_ERROR");
}

#[test]
fn proxy_connect_407_is_classified_as_proxy_auth() {
    assert_eq!(
        proxy_error_code(Some(
            b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n"
        )),
        "EGRESS_PROXY_AUTH"
    );
}

#[test]
fn proxy_connect_502_is_classified_as_proxy_unreachable() {
    assert_eq!(
        proxy_error_code(Some(
            b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
        )),
        "EGRESS_PROXY_UNREACHABLE"
    );
}

#[test]
fn timeout_detection_walks_the_source_chain() {
    use std::io;

    #[derive(Debug)]
    struct Wrapper(io::Error);
    impl std::fmt::Display for Wrapper {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("wrapper")
        }
    }
    impl std::error::Error for Wrapper {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            Some(&self.0)
        }
    }

    for kind in [io::ErrorKind::TimedOut, io::ErrorKind::WouldBlock] {
        assert!(crate::is_transport_timeout(&Wrapper(io::Error::from(kind))));
    }
    for kind in [
        io::ErrorKind::ConnectionRefused,
        io::ErrorKind::ConnectionReset,
        io::ErrorKind::InvalidData,
    ] {
        assert!(!crate::is_transport_timeout(&Wrapper(io::Error::from(
            kind
        ))));
    }
}
