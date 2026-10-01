//! Public OIDC metadata preflight. No user credentials or bearer tokens enter
//! this path. Failed discovery must prevent the final server from installing a
//! permanently unavailable directory while reporting ordinary HTTP health.
use serde_json::Value;
use std::{
    io::Read,
    os::fd::AsRawFd,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const MAX_DOCUMENT: usize = 1024 * 1024;
const POLL: Duration = Duration::from_millis(25);
const RETRY: Duration = Duration::from_secs(1);

// curl is the configured package executable; disabling curlrc, redirects and
// proxies makes requests independent of operator dotfiles/environment. Trust
// still comes from the configured SSL_CERT_FILE/system CA bundle.
fn command(curl: &str, url: &str, remaining: Duration) -> Command {
    let mut c = Command::new(curl);
    c.args([
        "--disable",
        "--fail",
        "--silent",
        "--proto",
        "=https",
        "--noproxy",
        "*",
        "--connect-timeout",
        "5",
        "--max-time",
        &remaining.as_secs_f64().min(10.0).to_string(),
        "--url",
        url,
    ]);
    c
}

struct Request(Child);
impl Drop for Request {
    fn drop(&mut self) {
        // Own and reap the exact child; no process-name signalling.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn document(
    mut command: Command,
    deadline: Instant,
    stop: &impl Fn() -> bool,
) -> Result<Value, &'static str> {
    let mut child = Request(
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "metadata request could not start")?,
    );
    let mut output = child.0.stdout.take().ok_or("metadata output unavailable")?;
    let fd = output.as_raw_fd();
    // Drain a nonblocking pipe while polling the owned child, rather than
    // waiting/joining a reader that could outlive cancellation.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err("metadata output unavailable");
        }
    }
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    let mut eof = false;
    loop {
        if stop() {
            return Err("startup interrupted");
        }
        if Instant::now() >= deadline {
            return Err("identity readiness timed out");
        }
        loop {
            match output.read(&mut buffer) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(n) => {
                    if bytes.len() + n > MAX_DOCUMENT {
                        return Err("metadata document too large");
                    }
                    bytes.extend_from_slice(&buffer[..n]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err("metadata output failed"),
            }
            if stop() {
                return Err("startup interrupted");
            }
            if Instant::now() >= deadline {
                return Err("identity readiness timed out");
            }
        }
        if let Some(status) = child
            .0
            .try_wait()
            .map_err(|_| "metadata request wait failed")?
        {
            if !status.success() {
                return Err("verified HTTPS metadata unavailable");
            }
            if eof {
                return serde_json::from_slice(&bytes).map_err(|_| "metadata is not JSON");
            }
        }
        thread::sleep(POLL.min(deadline.saturating_duration_since(Instant::now())));
    }
}

// Strict HTTPS URI syntax sufficient for configured OIDC metadata endpoints.
// In particular reject credentials, fragments, escapes in authority, and
// control/whitespace characters before giving curl any URI.
fn https_url(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("https://") else {
        return false;
    };
    if s.bytes()
        .any(|c| c <= 32 || c >= 127 || c == b'\\' || c == b'#')
    {
        return false;
    }
    let authority = rest.split(['/', '?']).next().unwrap_or("");
    if authority.is_empty() || authority.contains(['@', '%']) {
        return false;
    }
    let (host, port) = if authority.starts_with('[') {
        let Some(end) = authority.find(']') else {
            return false;
        };
        if authority[1..end].parse::<std::net::Ipv6Addr>().is_err() {
            return false;
        }
        (&authority[..=end], &authority[end + 1..])
    } else {
        let (host, port) = authority
            .split_once(':')
            .map_or((authority, ""), |(h, _)| (h, &authority[h.len()..]));
        if host.is_empty()
            || !host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        {
            return false;
        }
        (host, port)
    };
    !host.is_empty()
        && (port.is_empty()
            || port
                .strip_prefix(':')
                .and_then(|p| p.parse::<u16>().ok())
                .is_some_and(|p| p > 0))
}

fn discovery(issuer: &str, doc: &Value) -> Result<String, &'static str> {
    if doc.get("issuer").and_then(Value::as_str) != Some(issuer) {
        return Err("discovery issuer mismatch");
    }
    let uri = doc
        .get("jwks_uri")
        .and_then(Value::as_str)
        .ok_or("discovery has no JWKS URI")?;
    if !https_url(uri) {
        return Err("JWKS URI is not safe HTTPS");
    }
    // Match the pinned server's DiscoveryDocument schema, including fields
    // it deserializes even when this preflight does not use them.
    for field in [
        "userinfo_endpoint",
        "token_endpoint",
        "authorization_endpoint",
    ] {
        if !doc
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(https_url)
        {
            return Err("discovery endpoint is missing or not safe HTTPS");
        }
    }
    if doc
        .get("end_session_endpoint")
        .is_some_and(|v| !v.is_null() && !v.as_str().is_some_and(https_url))
    {
        return Err("discovery logout endpoint is not safe HTTPS");
    }
    for field in [
        "scopes_supported",
        "claims_supported",
        "code_challenge_methods_supported",
    ] {
        if doc.get(field).is_some_and(|v| {
            !v.is_null() && !v.as_array().is_some_and(|a| a.iter().all(Value::is_string))
        }) {
            return Err("discovery supported claims or methods have invalid types");
        }
    }
    Ok(uri.to_owned())
}

fn base64url_len(value: Option<&Value>) -> Option<usize> {
    let s = value?.as_str()?;
    if s.is_empty() || s.len() % 4 == 1 {
        return None;
    }
    let mut last = 0;
    for c in s.bytes() {
        last = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };
    }
    if (s.len() % 4 == 2 && last & 15 != 0) || (s.len() % 4 == 3 && last & 3 != 0) {
        return None;
    }
    Some(s.len() * 6 / 8)
}

fn signing_key(k: &Value) -> bool {
    if !k.is_object()
        || k.get("use").is_some_and(|v| v.as_str() != Some("sig"))
        || k.get("alg").is_some_and(|v| v.as_str().is_none())
        || k.get("key_ops").is_some_and(|v| {
            !v.as_array()
                .is_some_and(|a| a.iter().any(|v| v.as_str() == Some("verify")))
        })
        || ["d", "p", "q", "dp", "dq", "qi", "oth", "k"]
            .iter()
            .any(|v| k.get(v).is_some())
    {
        return false;
    }
    let alg = k.get("alg").and_then(Value::as_str);
    match k.get("kty").and_then(Value::as_str) {
        Some("EC") => {
            let (n, a) = match k.get("crv").and_then(Value::as_str) {
                Some("P-256") => (32, "ES256"),
                Some("P-384") => (48, "ES384"),
                _ => return false,
            };
            alg.is_none_or(|v| v == a)
                && base64url_len(k.get("x")) == Some(n)
                && base64url_len(k.get("y")) == Some(n)
        }
        Some("RSA") => {
            alg.is_none_or(|v| ["RS256", "RS384", "RS512", "PS256", "PS384", "PS512"].contains(&v))
                && base64url_len(k.get("n")).is_some_and(|n| n >= 256)
                && base64url_len(k.get("e")).is_some_and(|n| n > 0 && n <= 8)
        }
        Some("OKP") => {
            alg.is_none_or(|v| v == "EdDSA")
                && k.get("crv").and_then(Value::as_str) == Some("Ed25519")
                && base64url_len(k.get("x")) == Some(32)
        }
        _ => false,
    }
}

fn jwks(doc: &Value) -> Result<(), &'static str> {
    let keys = doc
        .get("keys")
        .and_then(Value::as_array)
        .ok_or("JWKS keys are missing or malformed")?;
    // Common JWK fields participate in server deserialization even on keys
    // not selected for authentication. Do not let a valid companion key hide
    // malformed types that would reject the entire server-side JwkSet.
    if !keys.iter().all(|k| {
        k.is_object()
            && match k.get("kty").and_then(Value::as_str) {
                Some("EC") => ["crv", "x", "y"]
                    .iter()
                    .all(|f| k.get(f).is_some_and(Value::is_string)),
                Some("RSA") => ["n", "e"]
                    .iter()
                    .all(|f| k.get(f).is_some_and(Value::is_string)),
                Some("OKP") => ["crv", "x"]
                    .iter()
                    .all(|f| k.get(f).is_some_and(Value::is_string)),
                _ => false,
            }
            && [
                "kty", "kid", "use", "alg", "crv", "x", "y", "n", "e", "x5u", "x5t", "x5t#S256",
            ]
            .iter()
            .all(|f| k.get(f).is_none_or(|v| v.is_null() || v.is_string()))
            && ["key_ops", "x5c"].iter().all(|f| {
                k.get(f).is_none_or(|v| {
                    v.is_null() || v.as_array().is_some_and(|a| a.iter().all(Value::is_string))
                })
            })
    }) {
        return Err("JWKS key fields have invalid types");
    }
    if keys.iter().any(signing_key) {
        Ok(())
    } else {
        Err("JWKS has no supported public signing key")
    }
}

fn gate(
    issuers: &[String],
    timeout: Duration,
    retry: Duration,
    stop: impl Fn() -> bool,
    mut fetch: impl FnMut(&str, Instant, &dyn Fn() -> bool) -> Result<Value, &'static str>,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    let mut ready = vec![false; issuers.len()];
    let mut last = "metadata unavailable";
    loop {
        if stop() {
            return Err("startup interrupted".into());
        }
        if Instant::now() >= deadline {
            return Err(format!("identity readiness timed out: {last}"));
        }
        for (i, issuer) in issuers.iter().enumerate() {
            if ready[i] {
                continue;
            }
            if !https_url(issuer) || issuer.contains('?') {
                return Err("configured identity issuer is not safe HTTPS".into());
            }
            let result = fetch(
                &format!(
                    "{}/.well-known/openid-configuration",
                    issuer.trim_end_matches('/')
                ),
                deadline,
                &stop,
            )
            .and_then(|doc| discovery(issuer, &doc))
            .and_then(|uri| fetch(&uri, deadline, &stop))
            .and_then(|doc| jwks(&doc));
            match result {
                Ok(()) => ready[i] = true,
                Err("startup interrupted") => return Err("startup interrupted".into()),
                Err(e) => last = e,
            }
        }
        if ready.iter().all(|v| *v) {
            return Ok(());
        }
        let next = (Instant::now() + retry).min(deadline);
        while Instant::now() < next {
            if stop() {
                return Err("startup interrupted".into());
            }
            thread::sleep(POLL.min(next.saturating_duration_since(Instant::now())));
        }
    }
}

pub fn wait(
    curl: &str,
    issuers: &[String],
    timeout: Duration,
    stop: impl Fn() -> bool,
) -> Result<(), String> {
    if issuers.is_empty() {
        return Ok(());
    }
    gate(issuers, timeout, RETRY, stop, |url, deadline, stop| {
        document(
            command(
                curl,
                url,
                deadline.saturating_duration_since(Instant::now()),
            ),
            deadline,
            &|| stop(),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicBool, Ordering};
    fn keys() -> Value {
        // RFC 7517 Appendix A.1 P-256 public key.
        json!({"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig",
            "x":"f83OJ3D2xF4c6n2MqGhvKfPtUC-V6g2JThIKj3OmwKQ",
            "y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI7Y4"}]})
    }
    fn metadata(issuer: &str) -> Value {
        json!({"issuer":issuer,"jwks_uri":format!("{issuer}/keys"),
            "userinfo_endpoint":format!("{issuer}/userinfo"),
            "token_endpoint":format!("{issuer}/token"),
            "authorization_endpoint":format!("{issuer}/authorize")})
    }
    #[test]
    fn every_provider_must_be_ready_and_unavailable_provider_is_retried() {
        let mut failures = 0;
        let mut discovered = Vec::new();
        let issuers = vec![
            "https://one.example/oidc".into(),
            "https://two.example/oidc".into(),
        ];
        gate(
            &issuers,
            Duration::from_secs(1),
            Duration::from_millis(1),
            || false,
            |url, _, _| {
                if url.contains("/.well-known/") {
                    if url.contains("two.example") && failures == 0 {
                        failures += 1;
                        return Err("not ready");
                    }
                    let issuer = url
                        .strip_suffix("/.well-known/openid-configuration")
                        .unwrap();
                    discovered.push(issuer.to_owned());
                    Ok(metadata(issuer))
                } else {
                    Ok(keys())
                }
            },
        )
        .unwrap();
        assert_eq!(failures, 1);
        assert_eq!(discovered, issuers);
    }
    #[test]
    fn mismatch_and_malformed_jwks_never_become_ready() {
        for mismatch in [true, false] {
            let err = gate(
                &["https://one.example".into()],
                Duration::from_millis(20),
                Duration::from_millis(1),
                || false,
                |url, _, _| {
                    if url.contains(".well-known") {
                        Ok(metadata(if mismatch {
                            "https://other.example"
                        } else {
                            "https://one.example"
                        }))
                    } else {
                        Ok(json!({"keys":[{"kty":"EC","crv":"P-256","x":"bad","y":"bad"}]}))
                    }
                },
            )
            .unwrap_err();
            assert!(err.contains(if mismatch {
                "issuer mismatch"
            } else {
                "no supported public signing key"
            }));
        }
    }
    #[test]
    fn malformed_discovery_rejected_before_fetching_jwks() {
        for field in [
            "userinfo_endpoint",
            "token_endpoint",
            "authorization_endpoint",
        ] {
            let mut doc = metadata("https://one.example");
            doc.as_object_mut().unwrap().remove(field);
            assert!(discovery("https://one.example", &doc).is_err());
            doc[field] = json!("http://one.example/endpoint");
            assert!(discovery("https://one.example", &doc).is_err());
        }
        for field in [
            "scopes_supported",
            "claims_supported",
            "code_challenge_methods_supported",
        ] {
            let mut doc = metadata("https://one.example");
            doc[field] = json!([true]);
            assert!(discovery("https://one.example", &doc).is_err());
            doc[field] = json!(["openid"]);
            assert!(discovery("https://one.example", &doc).is_ok());
        }
        let mut doc = metadata("https://one.example");
        doc["end_session_endpoint"] = json!(42);
        assert!(discovery("https://one.example", &doc).is_err());
    }
    #[test]
    fn unsafe_metadata_urls_and_private_or_encryption_keys_are_rejected() {
        for url in [
            "http://one.example",
            "https://u:p@one.example",
            "https://one.example#x",
            "https://one.example\\x",
            "https://%65xample",
            "https://one.example:0",
            "https://one.example\n",
        ] {
            assert!(!https_url(url), "{url:?}");
        }
        assert!(https_url("https://[::1]:443/keys"));
        assert!(https_url("https://one.example:8443/keys?a=b"));
        for field in ["d", "k"] {
            let mut doc = keys();
            doc["keys"][0][field] = json!("private");
            assert!(jwks(&doc).is_err());
        }
        let mut doc = keys();
        doc["keys"][0]["use"] = json!("enc");
        assert!(jwks(&doc).is_err());
        assert!(jwks(&json!({"keys":[]})).is_err());
        assert!(jwks(&keys()).is_ok());
        let mut doc = keys();
        doc["keys"][0]["kid"] = json!(42);
        assert!(jwks(&doc).is_err());
    }
    #[test]
    fn cancelled_gate_does_not_fetch() {
        assert_eq!(
            gate(
                &["https://one.example".into()],
                Duration::from_secs(1),
                RETRY,
                || true,
                |_, _, _| panic!("cancelled gate fetched")
            )
            .unwrap_err(),
            "startup interrupted"
        );
    }
    #[test]
    fn fixture_child() {
        if std::env::var_os("STALWART_READINESS_TEST_CHILD").is_some() {
            println!("{{\"partial\":");
            loop {
                thread::sleep(Duration::from_secs(1));
            }
        }
    }
    fn blocking_child() -> Command {
        let mut c = Command::new(std::env::current_exe().unwrap());
        c.args(["--exact", "readiness::tests::fixture_child", "--nocapture"])
            .env("STALWART_READINESS_TEST_CHILD", "1");
        c
    }
    #[test]
    fn stalled_request_is_killed_and_reaped_on_timeout_and_cancellation() {
        let start = Instant::now();
        assert_eq!(
            document(blocking_child(), start + Duration::from_millis(80), &|| {
                false
            })
            .unwrap_err(),
            "identity readiness timed out"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        let start = Instant::now();
        let interrupted = AtomicBool::new(false);
        assert_eq!(
            document(blocking_child(), start + Duration::from_secs(5), &|| {
                if start.elapsed() > Duration::from_millis(80) {
                    interrupted.store(true, Ordering::Relaxed);
                }
                interrupted.load(Ordering::Relaxed)
            })
            .unwrap_err(),
            "startup interrupted"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn curl_configuration_preserves_tls_and_uses_only_public_metadata() {
        let c = command(
            "/configured/curl",
            "https://one.example/keys",
            Duration::from_secs(30),
        );
        let args: Vec<_> = c.get_args().map(|v| v.to_str().unwrap()).collect();
        assert_eq!(args[0], "--disable");
        assert!(args.windows(2).any(|v| v == ["--proto", "=https"]));
        assert!(
            !args
                .iter()
                .any(|v| ["--insecure", "-k", "--location", "--user", "--header"].contains(v))
        );
        assert_eq!(args.last(), Some(&"https://one.example/keys"));
    }
}
