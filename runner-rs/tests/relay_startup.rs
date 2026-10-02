use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Child, Command},
    thread,
    time::{Duration, Instant},
};
static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn fixture() -> Fixture {
    let root = std::env::temp_dir().join(format!(
        "relay-startup-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let python = std::env::var("PYTHON_TEST_BINARY").expect("pinned Python fixture interpreter");
    let script = format!(
        "#!{python}\n{}",
        r#"import json,os,pathlib,signal,sys,time
root=pathlib.Path(__file__).parent
role=pathlib.Path(__file__).stem
state=root/'state'
def note(event):
 with (root/'events').open('a') as f:f.write(json.dumps({'event':event,'pid':os.getpid()})+'\n')
if role=='curl':sys.exit(0 if (root/'ready').exists() else 1)
if role=='server':
 normal='STALWART_RECOVERY_ADMIN' not in os.environ
 phase='normal' if normal else ('recovery' if os.environ.get('STALWART_RECOVERY_MODE')=='1' else 'bootstrap')
 state.mkdir(exist_ok=True)
 if not (state/'config.json').exists():(state/'config.json').write_text('{}')
 note('start-'+phase)
 if normal:sys.exit(0)
 (root/'ready').write_text(str(os.getpid()))
 signal.signal(signal.SIGTERM,lambda *_:sys.exit(0))
 try:
  while True:time.sleep(.05)
 finally:
  (root/'ready').unlink(missing_ok=True);note('stop-'+phase)
if role=='cli':
 assert os.environ['STALWART_USER']=='operator'
 assert os.environ['STALWART_PASSWORD']
 assert os.environ['STALWART_URL'].startswith('http://127.0.0.1:')
 note('cli-'+sys.argv[1])
 if sys.argv[1]=='update':
  data=state/'data';data.mkdir(exist_ok=True)
  (data/'CURRENT').write_text('MANIFEST-000001\n');(data/'MANIFEST-000001').write_text('fixture')
 else:
  if (root/'block-cli').exists():
   signal.signal(signal.SIGTERM,lambda *_:sys.exit(0))
   note('cli-blocked')
   try:
    while True:time.sleep(.05)
   finally:note('stop-cli')
  sys.stdin.buffer.read()
  if (root/'fail-cli').exists():
   print('configuration error '+os.environ['STALWART_PASSWORD'],file=sys.stderr);sys.exit(7)
 print('unused generated initial password')
"#
    );
    for role in ["server", "cli", "curl"] {
        let path = root.join(format!("{role}.py"));
        fs::write(&path, &script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fs::write(
        root.join("credential"),
        "operator:private-fixture-password\n",
    )
    .unwrap();
    fs::set_permissions(root.join("credential"), fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(root.join("bootstrap.json"), "{}").unwrap();
    fs::write(root.join("plan"), "{\"@type\":\"upsert\"}\n").unwrap();
    let config = serde_json::json!({"mode":"relay","server":root.join("server.py"),"cli":root.join("cli.py"),"curl":root.join("curl.py"),"recoveryPort":8080,"configPath":root.join("state/config.json"),"bootstrapFile":root.join("credential"),"bootstrapPlan":root.join("bootstrap.json"),"planFile":root.join("plan")});
    fs::write(
        root.join("startup.json"),
        serde_json::to_vec(&config).unwrap(),
    )
    .unwrap();
    Fixture(root)
}
fn command(f: &Fixture) -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_stalwart-run"));
    c.arg(f.0.join("startup.json"));
    c
}
fn events(root: &Path) -> Vec<String> {
    fs::read_to_string(root.join("events"))
        .unwrap_or_default()
        .lines()
        .map(|s| {
            serde_json::from_str::<serde_json::Value>(s).unwrap()["event"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect()
}
fn wait(child: &mut Child) -> std::process::ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("owned startup process exceeded test deadline");
        }
        thread::sleep(Duration::from_millis(20));
    }
}
#[test]
fn fresh_and_restored_relay_preserve_private_modes_and_normal_lifecycle() {
    let f = fixture();
    let output = command(&f).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stdout.is_empty());
    let got = events(&f.0);
    assert_eq!(
        got,
        vec![
            "start-bootstrap",
            "cli-update",
            "stop-bootstrap",
            "start-recovery",
            "cli-apply",
            "stop-recovery",
            "start-normal"
        ]
    );
    for name in ["state", "state/data"] {
        assert_eq!(fs::metadata(f.0.join(name)).unwrap().mode() & 0o777, 0o700);
    }
    for name in [
        "state/config.json",
        "state/data/CURRENT",
        "state/data/MANIFEST-000001",
    ] {
        assert_eq!(fs::metadata(f.0.join(name)).unwrap().mode() & 0o777, 0o600);
    }
    fs::write(f.0.join("events"), "").unwrap();
    let saved = fs::read(f.0.join("state/config.json")).unwrap();
    let output = command(&f).output().unwrap();
    assert!(output.status.success());
    assert_eq!(
        events(&f.0),
        vec![
            "start-recovery",
            "cli-apply",
            "stop-recovery",
            "start-normal"
        ]
    );
    assert_eq!(saved, fs::read(f.0.join("state/config.json")).unwrap());
}
#[test]
fn failed_apply_reaps_setup_and_redacts_secret_without_running_normal_server() {
    let f = fixture();
    fs::write(f.0.join("fail-cli"), "").unwrap();
    let output = command(&f).output().unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.contains("private-fixture-password"));
    assert!(stderr.contains("<redacted>"));
    assert!(output.stdout.is_empty());
    let got = events(&f.0);
    assert!(got.contains(&"stop-recovery".into()));
    assert!(!got.contains(&"start-normal".into()));
    assert!(!f.0.join("ready").exists());
}
#[test]
fn cancellation_reaps_blocked_cli_and_setup_without_final_exec() {
    let f = fixture();
    fs::write(f.0.join("block-cli"), "").unwrap();
    let mut child = command(&f).spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !events(&f.0).contains(&"cli-blocked".into()) {
        assert!(Instant::now() < deadline);
        assert!(child.try_wait().unwrap().is_none());
        thread::sleep(Duration::from_millis(20));
    }
    unsafe {
        assert_eq!(libc::kill(child.id() as i32, libc::SIGTERM), 0);
    }
    assert!(!wait(&mut child).success());
    let got = events(&f.0);
    assert!(got.contains(&"stop-cli".into()));
    assert!(got.contains(&"stop-recovery".into()));
    assert!(!got.contains(&"start-normal".into()));
    assert!(!f.0.join("ready").exists());
}
