//! Per-user launchd agent management.
//!
//! macOS grants Input Monitoring (TCC) to a *process identity*, and an `.app`
//! bundle is a different identity from a bare executable: a grant made for
//! `LogiLight.app` does not extend to `bin/logilight`, and a launchd job that
//! runs the bare binary is denied even after the app was approved. The agent
//! therefore runs the executable **inside** an app bundle, and the installer
//! raises the prompt through LaunchServices so the row the user approves is the
//! row the agent runs under.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::config::{data_dir, Config};

/// launchd label for the agent.
pub const LABEL: &str = "com.luhui.logilight";

/// Bundle identifier, also the TCC identity of the agent.
const BUNDLE_ID: &str = "com.luhui.logilight";

/// Install location of the app bundle the agent runs from.
#[must_use]
pub fn installed_app() -> PathBuf {
    data_dir().join("LogiLight.app")
}

/// The executable inside the installed bundle.
#[must_use]
pub fn installed_binary() -> PathBuf {
    installed_app()
        .join("Contents")
        .join("MacOS")
        .join("logilight")
}

/// `~/Library/LaunchAgents/com.luhui.logilight.plist`.
#[must_use]
pub fn plist_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(PathBuf::new, PathBuf::from);
    home.join("Library")
        .join("LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

/// Install the agent and start it.
pub fn install(config: &Config, config_path: &Path) -> Result<()> {
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    if !config_path.exists() {
        std::fs::write(config_path, config.to_toml()?)
            .with_context(|| format!("write {}", config_path.display()))?;
    }

    let binary = installed_binary();
    ensure_signing_identity()?;
    install_app(&binary)?;
    let plist = render_plist(&binary, config_path);
    let path = plist_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    std::fs::write(&path, plist).with_context(|| format!("write {}", path.display()))?;

    let granted = ensure_permission(&binary)?;

    bootout();
    run_launchctl(&["bootstrap", &domain(), &path.to_string_lossy()])?;
    let _ = run_launchctl(&["enable", &format!("{}/{}", domain(), LABEL)]);
    // No `kickstart -k` here: bootstrap already started the job, and killing it
    // again hits launchd's ten-second respawn throttle.

    println!("installed {LABEL}");
    println!("  app:    {}", installed_app().display());
    println!("  config: {}", config_path.display());
    println!("  plist:  {}", path.display());
    println!(
        "  log:    {}",
        data_dir().join("log").join("logilight.log").display()
    );
    if !granted {
        println!(
            "\nInput Monitoring is still off. Turn on “LogiLight” here, then run\n  \
             launchctl kickstart -k {}/{}:\n  \
             System Settings → Privacy & Security → Input Monitoring",
            domain(),
            LABEL
        );
    }
    println!("\nCheck it: logilight status");
    Ok(())
}

/// Stop and remove the agent. `purge` also deletes config, state, and logs.
pub fn uninstall(purge: bool) -> Result<()> {
    bootout();
    let path = plist_path();
    if path.exists() {
        std::fs::remove_file(&path).with_context(|| format!("remove {}", path.display()))?;
        println!("removed {}", path.display());
    }
    let app = installed_app();
    if app.exists() {
        std::fs::remove_dir_all(&app).with_context(|| format!("remove {}", app.display()))?;
        println!("removed {}", app.display());
    }
    if purge {
        let dir = data_dir();
        if dir.exists() {
            std::fs::remove_dir_all(&dir).with_context(|| format!("remove {}", dir.display()))?;
            println!("removed {}", dir.display());
        }
    } else {
        println!("kept {} (use --purge to delete it)", data_dir().display());
    }
    println!("The Input Monitoring entry can be removed in System Settings → Privacy & Security.");
    Ok(())
}

/// Make sure the agent's bundle identity holds Input Monitoring.
///
/// When it does not, the app is opened through LaunchServices so macOS raises
/// the consent prompt under the app's identity, and the installer polls until
/// the user answers. A prompt that is dismissed without a decision is not fatal:
/// the agent still runs, and the next `install` retries.
fn ensure_permission(binary: &Path) -> Result<bool> {
    if permission_granted(binary) {
        return Ok(true);
    }
    // A stale TCC row from an earlier ad-hoc signature makes every later
    // launch fail its code-requirement check, even after the user approves the
    // new build. Reset it first so the prompt writes a row matching the
    // certificate the bundle is signed with now.
    let _ = Command::new("tccutil")
        .args(["reset", "ListenEvent", BUNDLE_ID])
        .status();
    println!("Requesting Input Monitoring for LogiLight.app …");
    let app = installed_app();
    let _ = Command::new("open")
        .arg("-a")
        .arg(&app)
        .args(["--args", "request-permission"])
        .status();
    println!(
        "Turn on “LogiLight” in System Settings → Privacy & Security → Input Monitoring.\n\
         Waiting up to two minutes for the grant …"
    );
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(2));
        if permission_granted(binary) {
            println!("Input Monitoring granted.");
            return Ok(true);
        }
    }
    Ok(false)
}

/// Whether the installed app holds Input Monitoring.
///
/// A fresh process is required: macOS caches the answer per process, so the
/// running installer can never observe a grant made during its own lifetime.
fn permission_granted(binary: &Path) -> bool {
    Command::new(binary)
        .arg("permission-status")
        .output()
        .map(|output| {
            output.status.success() && String::from_utf8_lossy(&output.stdout).trim() == "granted"
        })
        .unwrap_or(false)
}

/// Copy the running executable into a minimal app bundle and ad-hoc sign it.
///
/// A byte-identical binary is left alone. Replacing it changes the code hash
/// and invalidates the existing Input Monitoring grant, so reinstalling an
/// unchanged build must not touch it.
fn install_app(destination: &Path) -> Result<()> {
    let current = std::env::current_exe().context("locate the running executable")?;
    let app = installed_app();
    let contents = app.join("Contents");
    let macos = contents.join("MacOS");
    std::fs::create_dir_all(&macos).with_context(|| format!("create {}", macos.display()))?;

    // A signed binary differs from the unsigned build by its signature, so
    // compare against the fingerprint recorded the last time this exact build
    // was installed. Matching means there is nothing to do, and re-signing
    // would only risk another keychain prompt.
    // Keep the stamp outside the bundle: anything inside `Contents/MacOS` is
    // treated by codesign as a nested code object and must itself be signed.
    let stamp_path = data_dir().join("installed.build");
    let stamp = payload_fingerprint(&current)?;
    let installed_stamp = std::fs::read_to_string(&stamp_path)
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok());
    let unchanged = destination.exists() && installed_stamp == Some(stamp);
    if !unchanged {
        let staged = destination.with_extension("new");
        std::fs::copy(&current, &staged)
            .with_context(|| format!("copy {} to {}", current.display(), staged.display()))?;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&staged, destination)
            .with_context(|| format!("install {}", destination.display()))?;
    }

    let info = contents.join("Info.plist");
    let wanted = info_plist();
    let needs_write = std::fs::read_to_string(&info).map_or(true, |existing| existing != wanted);
    if needs_write {
        std::fs::write(&info, wanted).with_context(|| format!("write {}", info.display()))?;
    }

    if !unchanged || needs_write || !app.join("Contents").join("_CodeSignature").exists() {
        sign_app(&app)?;
    }
    if installed_stamp != Some(stamp) {
        std::fs::write(&stamp_path, format!("{stamp}\n"))
            .with_context(|| format!("write {}", stamp_path.display()))?;
    }
    Ok(())
}

/// Provision the local signing identity on first install.
///
/// A self-signed code-signing certificate gives every build the same
/// designated requirement (`identifier` plus certificate root). Without it each
/// rebuild would be a new identity to TCC and the user would have to re-approve
/// Input Monitoring after every update.
///
/// The identity lives in the **login** keychain on purpose. It is unlocked at
/// login with a password the user actually knows, and the first `codesign` call
/// offers “Always Allow”, which macOS then remembers. A separate keychain would
/// prompt for its own password, which no one can guess, and prompt forever.
pub fn ensure_signing_identity() -> Result<()> {
    if signing_identity().is_some() {
        return Ok(());
    }
    // Certificate and key are there but no longer trusted. Re-trusting keeps
    // the certificate hash, and therefore the existing Input Monitoring grant.
    if any_identity().is_some() && trust_existing_certificate()? {
        return Ok(());
    }
    create_signing_identity()?;
    trust_existing_certificate()?;
    if signing_identity().is_none() {
        bail!("could not provision a code-signing identity in the login keychain");
    }
    Ok(())
}

/// Generate a self-signed code-signing certificate and import it into the login
/// keychain. This runs once, on a machine that has no identity yet.
fn create_signing_identity() -> Result<()> {
    let temp = std::env::temp_dir().join(format!("logilight-signing-{}", std::process::id()));
    std::fs::create_dir_all(&temp)?;
    let config = temp.join("openssl.cnf");
    std::fs::write(
        &config,
        "[ req ]\n\
         distinguished_name = dn\n\
         x509_extensions = v3\n\
         prompt = no\n\
         [ dn ]\n\
         CN = LogiLight Local Signing\n\
         O = LogiLight\n\
         [ v3 ]\n\
         basicConstraints = critical,CA:FALSE\n\
         keyUsage = critical,digitalSignature\n\
         extendedKeyUsage = critical,codeSigning\n\
         subjectKeyIdentifier = hash\n",
    )?;
    let key = temp.join("key.pem");
    let cert = temp.join("cert.pem");
    let p12 = temp.join("identity.p12");
    let ok = Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
        ])
        .arg("-keyout")
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .arg("-config")
        .arg(&config)
        .status()
        .is_ok_and(|status| status.success());
    if ok {
        let _ = Command::new("openssl")
            .args(["pkcs12", "-export", "-legacy", "-inkey"])
            .arg(&key)
            .arg("-in")
            .arg(&cert)
            .arg("-out")
            .arg(&p12)
            .args(["-passout", "pass:logilight"])
            .status();
        // `-A` lets any program use this throwaway key, so macOS never asks for
        // a keychain password to release it.
        let _ = Command::new("security")
            .args(["import"])
            .arg(&p12)
            .arg("-k")
            .arg(home_login_keychain())
            .args(["-P", "logilight", "-A"])
            .status();
    }
    let _ = std::fs::remove_dir_all(&temp);
    Ok(())
}

fn home_login_keychain() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(PathBuf::new, PathBuf::from);
    home.join("Library")
        .join("Keychains")
        .join("login.keychain-db")
}

fn info_plist() -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>{BUNDLE_ID}</string>
  <key>CFBundleName</key><string>LogiLight</string>
  <key>CFBundleDisplayName</key><string>LogiLight</string>
  <key>CFBundleExecutable</key><string>logilight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>{}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
"#,
        env!("CARGO_PKG_VERSION")
    )
}

fn sign_app(app: &Path) -> Result<()> {
    // A stable self-signed identity keeps the TCC designated requirement
    // (`identifier` + certificate root) unchanged across rebuilds, so an
    // approved grant survives reinstalling a new binary. Ad-hoc signing gives
    // every build a fresh cdhash and silently invalidates the grant.
    ensure_signing_identity()?;
    let Some(name) = signing_identity() else {
        bail!(
            "no usable code-signing identity in the login keychain; \
             run `logilight permission-status` for details"
        );
    };
    // Always name the keychain. Letting codesign search every keychain makes
    // the choice of private key unpredictable.
    let status = Command::new("codesign")
        .args(["--force", "--sign", &name, "--keychain"])
        .arg(home_login_keychain())
        .args(["--identifier", BUNDLE_ID])
        .arg(app)
        .status()
        .context("run codesign")?;
    if !status.success() {
        bail!(
            "codesign failed for {}. If macOS asked for a keychain password, \
             choose “Always Allow” once; the grant is remembered.",
            app.display()
        );
    }
    Ok(())
}

/// The local signing identity's common name, when the login keychain holds a
/// usable (trusted and unrevoked) copy.
fn signing_identity() -> Option<String> {
    identity_name(true)
}

/// Any code-signing identity under our name, trusted or not.
fn any_identity() -> Option<String> {
    identity_name(false)
}

fn identity_name(valid_only: bool) -> Option<String> {
    let mut command = Command::new("security");
    command.arg("find-identity");
    if valid_only {
        command.arg("-v");
    }
    let output = command
        .args(["-p", "codesigning"])
        .arg(home_login_keychain())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().find_map(|line| {
        if !line.contains("LogiLight Local Signing") {
            return None;
        }
        let start = line.find('"')?;
        let end = line.rfind('"')?;
        (start < end).then(|| line[start + 1..end].to_string())
    })
}

/// Mark the existing certificate as trusted for code signing.
///
/// macOS asks for the login password here, so this only runs when the trust
/// setting is genuinely missing, never on a normal reinstall.
fn trust_existing_certificate() -> Result<bool> {
    let pem = std::env::temp_dir().join(format!("logilight-trust-{}.pem", std::process::id()));
    let exported = Command::new("security")
        .args(["find-certificate", "-c", "LogiLight Local Signing", "-p"])
        .arg(home_login_keychain())
        .output()
        .context("export the local signing certificate")?;
    if !exported.status.success() || exported.stdout.is_empty() {
        return Ok(false);
    }
    std::fs::write(&pem, &exported.stdout)?;
    let trusted = Command::new("security")
        .args([
            "add-trusted-cert",
            "-r",
            "trustRoot",
            "-p",
            "codeSign",
            "-k",
        ])
        .arg(home_login_keychain())
        .arg(&pem)
        .status()
        .is_ok_and(|status| status.success());
    let _ = std::fs::remove_file(&pem);
    Ok(trusted && signing_identity().is_some())
}

/// A cheap, deterministic fingerprint of a file's bytes (FNV-1a 64).
///
/// This only answers “did this build change?”, not “is this file authentic”, so
/// a fast non-cryptographic hash is the right tool.
fn payload_fingerprint(path: &Path) -> Result<u64> {
    let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    Ok(hash)
}

fn render_plist(binary: &Path, config_path: &Path) -> String {
    let log_dir = data_dir().join("log");
    let stdout = log_dir.join("logilight.log");
    let stderr = log_dir.join("logilight.err.log");
    let _ = std::fs::create_dir_all(&log_dir);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>--config</string>
        <string>{config}</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>{stdout}</string>
    <key>StandardErrorPath</key>
    <string>{stderr}</string>
</dict>
</plist>
"#,
        label = LABEL,
        binary = xml_escape(&binary.to_string_lossy()),
        config = xml_escape(&config_path.to_string_lossy()),
        stdout = xml_escape(&stdout.to_string_lossy()),
        stderr = xml_escape(&stderr.to_string_lossy()),
    )
}

fn xml_escape(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn domain() -> String {
    // `id -u` is the reliable source inside a launchd agent, where getuid and
    // the shell's `$UID` both exist but the former is what launchd matches on.
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| "501".to_string());
    format!("gui/{uid}")
}

fn bootout() {
    let _ = run_launchctl(&["bootout", &format!("{}/{}", domain(), LABEL)]);
}

fn run_launchctl(args: &[&str]) -> Result<()> {
    let output = Command::new("launchctl")
        .args(args)
        .output()
        .context("run launchctl")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("launchctl {} failed: {}", args.join(" "), stderr.trim());
    }
    Ok(())
}

/// Raise the macOS Input Monitoring prompt for this process.
///
/// Blocks until the user answers, then reports the result. A fresh grant only
/// becomes visible to a new process, which is why `install` runs this through
/// the app bundle and then starts the agent.
pub fn request_permission() -> Result<()> {
    if openlogi_hid::permissions::has_access() {
        println!("Input Monitoring is already granted to this binary.");
        return Ok(());
    }
    println!(
        "A macOS prompt should appear. If it does not, open System Settings → \
         Privacy & Security → Input Monitoring and enable LogiLight."
    );
    openlogi_hid::permissions::request_access();
    if openlogi_hid::permissions::has_access() {
        println!("Input Monitoring granted.");
    } else {
        println!(
            "Input Monitoring is still not granted — enable LogiLight in System Settings, \
             then restart the agent."
        );
    }
    Ok(())
}

/// Print `granted` or `denied` for this process, for `install` to read.
pub fn permission_status() -> Result<()> {
    println!(
        "{}",
        if openlogi_hid::permissions::has_access() {
            "granted"
        } else {
            "denied"
        }
    );
    Ok(())
}
