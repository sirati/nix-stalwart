//! The ordinary local RocksDB relay follows the same private startup lifecycle.
use super::{Setup, StartupSettings, cancelled, credential, redact, setup};
use serde::Deserialize;
use std::{
    fs,
    io::{Read, Write},
    os::unix::process::CommandExt,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Config {
    server: String,
    cli: String,
    curl: String,
    recovery_port: u16,
    config_path: String,
    bootstrap_file: String,
    bootstrap_plan: String,
    plan_file: String,
}
impl StartupSettings for Config {
    fn server(&self) -> &str {
        &self.server
    }
    fn cli(&self) -> &str {
        &self.cli
    }
    fn curl(&self) -> &str {
        &self.curl
    }
    fn recovery_port(&self) -> u16 {
        self.recovery_port
    }
    fn config_path(&self) -> &str {
        &self.config_path
    }
}
fn command(
    c: &Config,
    auth: &(String, String),
    args: &[&str],
    input: Option<Vec<u8>>,
) -> Result<(), String> {
    cancelled()?;
    let mut child = Setup(
        Command::new(&c.cli)
            .args(args)
            .env(
                "STALWART_URL",
                format!("http://127.0.0.1:{}", c.recovery_port),
            )
            .env("STALWART_USER", &auth.0)
            .env("STALWART_PASSWORD", &auth.1)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| "start relay configuration command")?,
    );
    let stderr = child
        .0
        .stderr
        .take()
        .ok_or("relay command stderr is unavailable")?;
    let diagnostic = thread::spawn(move || {
        let mut stream = stderr;
        let mut bytes = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let n = stream.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            let keep = (65536usize.saturating_sub(bytes.len())).min(n);
            bytes.extend_from_slice(&buffer[..keep]);
        }
        Ok::<_, std::io::Error>(bytes)
    });
    let writer = input.map(|bytes| {
        let mut pipe = child.0.stdin.take().expect("requested piped stdin");
        thread::spawn(move || pipe.write_all(&bytes))
    });
    let deadline = Instant::now() + Duration::from_secs(300);
    let outcome = loop {
        if let Err(error) = cancelled() {
            break Err(error);
        }
        if Instant::now() >= deadline {
            break Err("relay configuration command timed out".into());
        }
        match child.0.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(_) => break Err("inspect relay configuration process".into()),
        }
    };
    // Drop owns termination and reaping even on cancellation, and closes the
    // child pipe endpoints before joining their bounded reader/writer threads.
    drop(child);
    let written = writer.map(|thread| {
        thread
            .join()
            .map_err(|_| "relay plan writer failed")?
            .map_err(|_| "send relay configuration plan")
    });
    let bytes = diagnostic
        .join()
        .map_err(|_| "relay diagnostic reader failed")?
        .map_err(|_| "read relay configuration diagnostic")?;
    let status = outcome?;
    if !status.success() {
        return Err(format!(
            "relay configuration command failed ({status}): {}",
            redact(
                &String::from_utf8_lossy(&bytes),
                &[auth.1.clone(), format!("{}:{}", auth.0, auth.1)]
            )
        ));
    }
    if let Some(result) = written {
        result?;
    }
    Ok(())
}
pub(super) fn run(c: Config) -> Result<(), String> {
    let auth = credential(&c.bootstrap_file, None)?;
    let composite = format!("{}:{}", auth.0, auth.1);
    let initialize = match fs::metadata(&c.config_path) {
        Ok(metadata) => metadata.len() == 0,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Err(_) => return Err("inspect relay configuration".into()),
    };
    if initialize {
        let server = setup(&c, &composite, false)?;
        command(
            &c,
            &auth,
            &["update", "Bootstrap", "--file", &c.bootstrap_plan],
            None,
        )?;
        drop(server);
    }
    let server = setup(&c, &composite, true)?;
    let file = fs::File::open(&c.plan_file).map_err(|_| "read relay configuration plan")?;
    let mut plan = Vec::new();
    file.take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut plan)
        .map_err(|_| "read relay configuration plan")?;
    if plan.len() > 4 * 1024 * 1024 {
        return Err("relay configuration plan exceeds size limit".into());
    }
    command(&c, &auth, &["apply", "--stdin", "--quiet"], Some(plan))?;
    drop(server);
    cancelled()?;
    Err(format!(
        "execute Stalwart relay: {}",
        Command::new(&c.server)
            .arg(format!("--config={}", c.config_path))
            .exec()
    ))
}
