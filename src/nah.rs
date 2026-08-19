// NAH Support custom client.
//
// All Nutty About Hosting-specific behaviour lives in this module so the
// diff against upstream RustDesk stays small and reviewable across rebases.
// The two integration points are:
//   1. `apply_embedded_config()` called from `common::load_custom_client()`,
//      which pins the rendezvous server/key, renames the app identity, and
//      locks the "support" flavour down to incoming-only.
//   2. `spawn_session_reporter()` called from `core_main()` on a plain UI
//      launch, which parses a session code from the executable's filename
//      (e.g. `NahSupport-748291.exe`) and registers this client's ID with
//      the Nah.Support portal so the technician can connect.
//
// Build-time configuration (all optional, sane defaults below):
//   NAH_RENDEZVOUS_SERVER  hbbs host to pin (id/relay server)
//   NAH_RS_PUB_KEY         hbbs public key; empty = do not pin (dev builds)
//   NAH_API_BASE           Nah.Support API base URL for session registration
//   NAH_FLAVOR             "support" (customer, incoming-only, default)
//                          or "technician" (staff, full UI)

use hbb_common::{config, config::keys, log};

// Server endpoints are injected by CI from repository variables; an empty
// value disables the corresponding feature (dev builds stay unpinned and
// skip session registration).
pub const RENDEZVOUS_SERVER: &str = match option_env!("NAH_RENDEZVOUS_SERVER") {
    Some(v) => v,
    None => "",
};

pub const RS_PUB_KEY: &str = match option_env!("NAH_RS_PUB_KEY") {
    Some(v) => v,
    None => "",
};

pub const API_BASE: &str = match option_env!("NAH_API_BASE") {
    Some(v) => v,
    None => "",
};

const FLAVOR: &str = match option_env!("NAH_FLAVOR") {
    Some(v) => v,
    None => "support",
};

/// Customer-facing app identity. Also becomes the config directory name
/// (%AppData%\NahSupport, ~/Library/...), keeping our client's state fully
/// separate from any real RustDesk install on the same machine.
pub const APP_NAME: &str = "NAHSupport";
#[cfg(target_os = "macos")]
const ORG: &str = "uk.co.nuttyabouthosting";

#[inline]
pub fn is_support_flavor() -> bool {
    FLAVOR != "technician"
}

/// Equivalent of a RustDesk Pro signed custom-client config, baked in at
/// compile time. Must run before any config path/option is read, so it is
/// invoked at the top of `load_custom_client()` (every process entry point
/// already calls that).
pub fn apply_embedded_config() {
    *config::APP_NAME.write().unwrap() = APP_NAME.to_owned();
    // config::ORG only exists on macOS (it namespaces the config directory
    // there); Windows/Linux paths are derived from APP_NAME alone.
    #[cfg(target_os = "macos")]
    {
        *config::ORG.write().unwrap() = ORG.to_owned();
    }

    {
        let mut overwrite = config::OVERWRITE_SETTINGS.write().unwrap();
        if !RENDEZVOUS_SERVER.is_empty() {
            overwrite.insert(
                keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_owned(),
                RENDEZVOUS_SERVER.to_owned(),
            );
        }
        if !RS_PUB_KEY.is_empty() {
            overwrite.insert(keys::OPTION_KEY.to_owned(), RS_PUB_KEY.to_owned());
        }
        if is_support_flavor() {
            // Customers approve each session with a click; no passwords to
            // read out and nothing for the portal to transport.
            overwrite.insert(keys::OPTION_APPROVE_MODE.to_owned(), "click".to_owned());
        }
    }

    {
        // Suppress the Pro-only HTTP API (device registration / heartbeat /
        // sysinfo upload). Without this the client derives an api-server of
        // <rendezvous host>:21114, which we do not run, and logs a timeout
        // on every heartbeat. register-device=N makes no_register_device()
        // true, so get_api_server() returns empty and the sync loop no-ops.
        let mut buildin = config::BUILTIN_SETTINGS.write().unwrap();
        buildin.insert(keys::OPTION_REGISTER_DEVICE.to_owned(), "N".to_owned());
    }

    if is_support_flavor() {
        let mut hard = config::HARD_SETTINGS.write().unwrap();
        hard.insert("conn-type".to_owned(), "incoming".to_owned());
        hard.insert("disable-installation".to_owned(), "Y".to_owned());
        hard.insert("disable-account".to_owned(), "Y".to_owned());
        hard.insert("disable-settings".to_owned(), "Y".to_owned());
    }

    if is_support_flavor() {
        // Privacy default: the customer's audio is NOT shared with the
        // technician unless they turn it on via the permission grid. A DEFAULT
        // (not overwrite), so the toggle still works per session.
        let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
        defaults.insert(keys::OPTION_ENABLE_AUDIO.to_owned(), "N".to_owned());
    }
}

/// Parse the support session code from this executable's original filename.
/// The portable wrapper re-execs the inner binary from a temp directory but
/// forwards the original name via RUSTDESK_APPNAME (same mechanism upstream
/// uses for filename-embedded server config).
///
/// On macOS the code never reaches the executable name: the portal renames
/// the *download* (`NahSupport-<code>.dmg`), but the app inside the mounted
/// image is always `NAHSupport.app`. When we detect we are running from a
/// mounted dmg (exe under /Volumes/...), ask hdiutil which image file backs
/// that mount and parse the code from the dmg's filename instead.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn session_code_from_exe_name() -> Option<String> {
    let mut name = std::env::current_exe()
        .ok()?
        .file_name()?
        .to_str()?
        .to_owned();
    if let Ok(portable_name) = std::env::var(crate::common::PORTABLE_APPNAME_RUNTIME_ENV_KEY) {
        if !portable_name.trim().is_empty() {
            name = portable_name;
        }
    }
    let code = session_code_from_name(&name);
    #[cfg(target_os = "macos")]
    let code = code.or_else(session_code_from_mounted_dmg);
    code
}

/// macOS: if this process runs from a mounted disk image, recover the backing
/// .dmg file's name (which the portal stamped with the session code). Returns
/// None when launched from /Applications or anywhere else outside /Volumes.
#[cfg(target_os = "macos")]
fn session_code_from_mounted_dmg() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let exe = exe.to_str()?;
    let vol = exe.strip_prefix("/Volumes/")?.split('/').next()?;
    if vol.is_empty() {
        return None;
    }
    let mount_point = format!("/Volumes/{vol}");
    let out = std::process::Command::new("hdiutil")
        .arg("info")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let image_path = dmg_path_for_mount(&text, &mount_point)?;
    let file_name = image_path.rsplit('/').next()?;
    session_code_from_name(file_name)
}

/// Find which image file backs `mount_point` in `hdiutil info` output. The
/// output is a sequence of per-image blocks, each opening with an
/// `image-path : /path/to/file.dmg` line followed by its device/mount lines.
#[cfg(any(target_os = "macos", test))]
fn dmg_path_for_mount<'a>(hdiutil_info: &'a str, mount_point: &str) -> Option<&'a str> {
    let mut image_path: Option<&str> = None;
    for line in hdiutil_info.lines() {
        if let Some(rest) = line.strip_prefix("image-path") {
            image_path = rest.split_once(':').map(|(_, p)| p.trim());
        } else if line.trim_end().ends_with(mount_point) {
            if image_path.is_some() {
                return image_path;
            }
        }
    }
    None
}

/// `NahSupport-748291.exe` -> `748291`. Tolerates the ` (1)` / `(2)` suffixes
/// Windows appends to duplicate downloads, case differences, and a missing
/// extension. Returns None for a plain `NahSupport.exe`.
fn session_code_from_name(name: &str) -> Option<String> {
    let mut stem = name.trim();
    for ext in [".exe", ".dmg"] {
        if stem.len() > ext.len() && stem.to_ascii_lowercase().ends_with(ext) {
            stem = &stem[..stem.len() - ext.len()];
        }
    }
    // Strip trailing duplicate-download markers, repeatedly: "x (1)", "x(2)".
    let mut s = stem.trim_end();
    loop {
        let t = s.trim_end();
        if t.ends_with(')') {
            if let Some(open) = t.rfind('(') {
                let inner = &t[open + 1..t.len() - 1];
                if !inner.is_empty() && inner.chars().all(|c| c.is_ascii_digit()) {
                    s = t[..open].trim_end();
                    continue;
                }
            }
        }
        break;
    }
    let (_, tail) = s.rsplit_once('-')?;
    let tail = tail.trim();
    if (4..=12).contains(&tail.len()) && tail.chars().all(|c| c.is_ascii_digit()) {
        Some(tail.to_owned())
    } else {
        None
    }
}

/// Register this client against its session code so the portal can show
/// "customer online" and hand the technician our ID. Fire-and-forget: chat
/// and remote control work regardless; this only automates the handshake.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn spawn_session_reporter() {
    if !is_support_flavor() || API_BASE.is_empty() {
        return;
    }
    let Some(code) = session_code_from_exe_name() else {
        log::info!("nah: no session code in executable name, skipping registration");
        return;
    };
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    if let Err(e) = std::thread::Builder::new()
        .name("nah-session-reporter".to_owned())
        .spawn(move || report_session(&code))
    {
        log::error!("nah: failed to spawn session reporter: {e}");
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn report_session(code: &str) {
    let url = format!(
        "{}/api/v1/support/remote/sessions/{}/register",
        API_BASE.trim_end_matches('/'),
        code
    );
    let client = match reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            log::error!("nah: failed to build http client: {e}");
            return;
        }
    };
    for attempt in 1u64..=20 {
        // The ID is generated on first config access; wait for it.
        let id = config::Config::get_id();
        if id.is_empty() {
            std::thread::sleep(std::time::Duration::from_secs(2));
            continue;
        }
        let body = serde_json::json!({
            "rustdeskId": id,
            "platform": std::env::consts::OS,
            "hostname": crate::common::whoami_hostname(),
            "clientVersion": env!("CARGO_PKG_VERSION"),
        });
        match client.post(&url).json(&body).send() {
            Ok(r) if r.status().is_success() => {
                log::info!("nah: session {code} registered (id {id})");
                return;
            }
            Ok(r) if r.status().is_client_error() => {
                // Unknown/expired/closed session code: retrying cannot help.
                log::warn!("nah: session {code} rejected by portal: {}", r.status());
                return;
            }
            Ok(r) => {
                log::warn!("nah: session register attempt {attempt} failed: {}", r.status());
            }
            Err(e) => {
                log::warn!("nah: session register attempt {attempt} failed: {e}");
            }
        }
        std::thread::sleep(std::time::Duration::from_secs((3 * attempt).min(30)));
    }
    log::error!("nah: giving up registering session {code}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_code_from_name() {
        assert_eq!(
            session_code_from_name("NahSupport-748291.exe"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("nahsupport-748291.EXE"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291 (1).exe"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291(2).exe"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291 (1) (2).exe"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291.dmg"),
            Some("748291".to_owned())
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291"),
            Some("748291".to_owned())
        );
        // Codes must be 4-12 digits.
        assert_eq!(session_code_from_name("NahSupport-123.exe"), None);
        assert_eq!(
            session_code_from_name("NahSupport-1234567890123.exe"),
            None
        );
        // No code present.
        assert_eq!(session_code_from_name("NahSupport.exe"), None);
        assert_eq!(session_code_from_name("NahSupport (1).exe"), None);
        assert_eq!(session_code_from_name("rustdesk.exe"), None);
        // Not digits.
        assert_eq!(session_code_from_name("NahSupport-beta1.exe"), None);
    }

    #[test]
    fn test_dmg_path_for_mount() {
        let out = "framework       : 640.3\n\
                   driver          : 640.3\n\
                   ================================================\n\
                   image-path      : /Users/jo/Downloads/SomeOther.dmg\n\
                   image-alias     : /Users/jo/Downloads/SomeOther.dmg\n\
                   shadow-path     : <none>\n\
                   blockcount      : 350160\n\
                   /dev/disk4\tGUID_partition_scheme\t\n\
                   /dev/disk4s1\tApple_HFS\t/Volumes/SomeOther\n\
                   ================================================\n\
                   image-path      : /Users/jo/Downloads/NahSupport-748291 (1).dmg\n\
                   shadow-path     : <none>\n\
                   /dev/disk5\tGUID_partition_scheme\t\n\
                   /dev/disk5s1\tApple_HFS\t/Volumes/NAHSupport\n";
        assert_eq!(
            dmg_path_for_mount(out, "/Volumes/NAHSupport"),
            Some("/Users/jo/Downloads/NahSupport-748291 (1).dmg")
        );
        assert_eq!(
            session_code_from_name("NahSupport-748291 (1).dmg"),
            Some("748291".to_owned())
        );
        // A volume that merely shares a suffix must not match.
        assert_eq!(dmg_path_for_mount(out, "/Volumes/Other"), None);
        assert_eq!(dmg_path_for_mount(out, "/Volumes/Missing"), None);
    }

    #[test]
    fn test_flavor_default_is_support() {
        // Unless CI sets NAH_FLAVOR=technician, builds are customer builds.
        if option_env!("NAH_FLAVOR").is_none() {
            assert!(is_support_flavor());
        }
    }
}
