use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::process::CommandExt,
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    server: String,
    cli: String,
    curl: String,
    pg_is_ready: String,
    database_host: String,
    database_port: u16,
    database_name: String,
    database_user: String,
    recovery_port: u16,
    #[serde(default)]
    identity_issuers: Vec<String>,
    default_domain: String,
    administrator_domain: String,
    bootstrap_file: String,
    bootstrap_username: Option<String>,
    administrator_file: String,
    administrator_username: Option<String>,
    accounts: Vec<Account>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Account {
    id: String,
    plan_file: String,
    password_file: Option<String>,
}

trait StartupSettings {
    fn server(&self) -> &str;
    fn cli(&self) -> &str;
    fn curl(&self) -> &str;
    fn recovery_port(&self) -> u16;
    fn config_path(&self) -> &str;
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
        "/var/lib/stalwart/config.json"
    }
}
fn secret(path: &str) -> Result<String, String> {
    let value =
        fs::read_to_string(path).map_err(|_| format!("cannot read credential file {path}"))?;
    let value = value.strip_suffix('\n').unwrap_or(&value);
    let value = value.strip_suffix('\r').unwrap_or(value);
    if value.is_empty() || value.contains(['\r', '\n']) {
        return Err(format!("invalid credential file {path}"));
    }
    Ok(value.to_owned())
}
fn credential(path: &str, username: Option<&str>) -> Result<(String, String), String> {
    let value = secret(path)?;
    match username {
        Some(user) => Ok((user.to_owned(), value)),
        None => value
            .split_once(':')
            .filter(|(u, p)| !u.is_empty() && !p.is_empty())
            .map(|(u, p)| (u.to_owned(), p.to_owned()))
            .ok_or_else(|| format!("invalid composite credential file {path}")),
    }
}
fn cancelled() -> Result<(), String> {
    if STOP.load(Ordering::Relaxed) {
        Err("startup interrupted".into())
    } else {
        Ok(())
    }
}
struct Setup(Child);
impl Drop for Setup {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(Some(_))) {
            return;
        }
        // The child remains owned and unreaped while its PID is signalled.
        unsafe {
            libc::kill(self.0.id() as libc::pid_t, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if matches!(self.0.try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn setup(c: &impl StartupSettings, auth: &str, recovery: bool) -> Result<Setup, String> {
    let mut command = Command::new(c.server());
    command
        .arg(format!("--config={}", c.config_path()))
        .env("STALWART_RECOVERY_ADMIN", auth)
        .env("STALWART_RECOVERY_MODE_PORT", c.recovery_port().to_string());
    if recovery {
        command.env("STALWART_RECOVERY_MODE", "1");
    }
    let mut child = Setup(
        command
            .spawn()
            .map_err(|e| format!("start setup server: {e}"))?,
    );
    for _ in 0..120 {
        cancelled()?;
        if child.0.try_wait().map_err(|e| e.to_string())?.is_some() {
            return Err("setup server exited before becoming ready".into());
        }
        if Command::new(c.curl())
            .args([
                "--fail",
                "--silent",
                "--max-time",
                "1",
                &format!("http://127.0.0.1:{}/", c.recovery_port()),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| e.to_string())?
            .success()
        {
            return Ok(child);
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err("setup listener did not become ready".into())
}
fn redact(text: &str, secrets: &[String]) -> String {
    let mut result = text.to_owned();
    let mut forms: Vec<String> = secrets
        .iter()
        .filter(|s| !s.is_empty())
        .flat_map(|s| {
            let escaped = serde_json::to_string(s).unwrap();
            [s.clone(), escaped[1..escaped.len() - 1].to_owned()]
        })
        .collect();
    forms.sort_by_key(|s| std::cmp::Reverse(s.len()));
    for value in forms {
        result = result.replace(&value, "<redacted>");
    }
    result
        .chars()
        .flat_map(|c| {
            if c.is_control() && c != '\n' {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .take(4096)
        .collect()
}
fn cli(
    c: &impl StartupSettings,
    auth: &(String, String),
    args: &[&str],
    input: Option<&[u8]>,
    secrets: &[String],
) -> Result<(), String> {
    cancelled()?;
    let mut child = Command::new(c.cli())
        .args(args)
        .env(
            "STALWART_URL",
            format!("http://127.0.0.1:{}", c.recovery_port()),
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
        .map_err(|e| e.to_string())?;
    if let Some(bytes) = input {
        let written = child.stdin.take().unwrap().write_all(bytes);
        if let Err(error) = written {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("send configuration plan: {error}"));
        }
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Stalwart configuration command failed ({}): {}",
            output.status,
            redact(&String::from_utf8_lossy(&output.stderr), secrets)
        ))
    }
}
fn plan(
    c: &Config,
    admin: &(String, String),
    secrets: &mut Vec<String>,
) -> Result<Vec<u8>, String> {
    if admin.0 != format!("admin@{}", c.administrator_domain) {
        return Err(
            "administrator username differs from the configured administrator domain".into(),
        );
    }
    let mut result = fs::read_to_string("/config/plan.ndjson").map_err(|e| e.to_string())?;
    result.push('\n');
    if c.administrator_domain != c.default_domain {
        result.push_str(
            &json!({"@type":"upsert","object":"Domain","matchOn":["name"],"value":{
                format!("domain-{}", c.administrator_domain.replace('.',"-")): {
                    "name":c.administrator_domain,"isEnabled":true,"directoryId":null
                }
            }})
            .to_string(),
        );
        result.push('\n');
    }
    for account in &c.accounts {
        let mut operation: Value =
            serde_json::from_slice(&fs::read(&account.plan_file).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if let Some(file) = &account.password_file {
            let password = secret(file)?;
            secrets.push(password.clone());
            let entry = operation
                .get_mut("value")
                .and_then(|v| v.get_mut(&account.id))
                .and_then(Value::as_object_mut)
                .ok_or("invalid account plan")?;
            entry.insert(
                "credentials".into(),
                json!({"0":{"@type":"Password","secret":password}}),
            );
        }
        result.push_str(&operation.to_string());
        result.push('\n');
    }
    let operation = json!({"@type":"upsert","object":"Account","matchOn":["name","domainId"],"value":{"administrator":{"@type":"User","name":"admin","domainId":format!("#domain-{}", c.administrator_domain.replace('.',"-")),"credentials":{"0":{"@type":"Password","secret":admin.1}},"roles":{"@type":"Admin"}}}});
    result.push_str(&operation.to_string());
    result.push('\n');
    Ok(result.into_bytes())
}
fn run() -> Result<(), String> {
    unsafe {
        libc::signal(libc::SIGTERM, stop as libc::sighandler_t);
        libc::signal(libc::SIGINT, stop as libc::sighandler_t);
        libc::umask(0o077);
    }

    let path = std::env::args()
        .nth(1)
        .ok_or("missing public startup configuration")?;
    let value: Value = serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    if value["mode"] == "relay" {
        return relay::run(serde_json::from_value(value).map_err(|e| e.to_string())?);
    }
    if !value["mode"].is_null() && value["mode"] != "full" {
        return Err("invalid Stalwart startup mode".into());
    }
    let c: Config = serde_json::from_value(value).map_err(|e| e.to_string())?;
    let auth = credential(&c.bootstrap_file, c.bootstrap_username.as_deref())?;
    let admin = credential(&c.administrator_file, c.administrator_username.as_deref())?;
    let mut secrets = vec![
        auth.1.clone(),
        admin.1.clone(),
        format!("{}:{}", auth.0, auth.1),
    ];
    let mut ready = false;
    for _ in 0..300 {
        cancelled()?;
        if Command::new(&c.pg_is_ready)
            .args([
                "--quiet",
                "--host",
                &c.database_host,
                "--port",
                &c.database_port.to_string(),
                "--dbname",
                &c.database_name,
                "--username",
                &c.database_user,
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| e.to_string())?
            .success()
        {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_secs(1));
    }
    if !ready {
        return Err("Stalwart database did not become ready".into());
    }
    if fs::metadata("/var/lib/stalwart/config.json").map_or(true, |m| m.len() == 0) {
        let server = setup(&c, &format!("{}:{}", auth.0, auth.1), false)?;
        cli(
            &c,
            &auth,
            &["update", "Bootstrap", "--file", "/config/bootstrap.json"],
            None,
            &secrets,
        )?;
        drop(server);
    }
    let server = setup(&c, &format!("{}:{}", auth.0, auth.1), true)?;
    let input = plan(&c, &admin, &mut secrets)?;
    cli(
        &c,
        &auth,
        &["apply", "--stdin", "--quiet"],
        Some(&input),
        &secrets,
    )?;
    drop(server);
    match fs::remove_file("/var/lib/stalwart/initial-admin.txt") {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.to_string()),
    }
    cancelled()?;
    readiness::wait(
        &c.curl,
        &c.identity_issuers,
        Duration::from_secs(180),
        || STOP.load(Ordering::Relaxed),
    )?;
    Err(format!(
        "execute Stalwart: {}",
        Command::new(&c.server)
            .arg("--config=/var/lib/stalwart/config.json")
            .exec()
    ))
}
mod readiness;
mod relay;
fn main() {
    if let Err(error) = run() {
        eprintln!("stalwart-run: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn diagnostic_redacts_plain_and_json_escaped_credentials() {
        let password = "secret\\\"credential".to_owned();
        let json = serde_json::to_string(&password).unwrap();
        let diagnostic = redact(
            &format!("failure: {password} {json}\x1b[31m"),
            &[password.clone()],
        );
        assert!(!diagnostic.contains(&password));
        assert!(!diagnostic.contains(&json[1..json.len() - 1]));
        assert!(!diagnostic.contains('\x1b'));
        assert!(diagnostic.contains("failure:"));
    }
}
