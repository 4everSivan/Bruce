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
