use core::ffi::c_int;
#[cfg(target_os = "linux")]
use core::ffi::c_long;
use std::fs::File;
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::os::unix::{io::FromRawFd, process::CommandExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use wait_timeout::ChildExt;

use crate::config::{FailPolicy, ModuleConfig};

pub(crate) const CHECKER_STDERR_LIMIT: usize = 512;
const CHECKER_TIMEOUT_GRACE: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckerOutcome {
    Clean,
    Pwned,
    ConfigError,
    ProviderFailure,
    Timeout,
    ExecFailure,
    UnexpectedExit(i32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckerRun {
    pub outcome: CheckerOutcome,
    pub stderr: String,
}

// Rust 2021 extern syntax is intentional for all extern blocks in this file
// until the distro MSRV/edition pin changes.
#[cfg(unix)]
extern "C" {
    fn close(fd: c_int) -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn setpgid(pid: c_int, pgid: c_int) -> c_int;
    fn sysconf(name: c_int) -> isize;
}

#[cfg(all(unix, not(target_os = "linux")))]
extern "C" {
    fn pipe(fds: *mut c_int) -> c_int;
}

#[cfg(target_os = "linux")]
extern "C" {
    fn pipe2(fds: *mut c_int, flags: c_int) -> c_int;
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
extern "C" {
    fn syscall(num: c_long, ...) -> c_long;
}

#[cfg(unix)]
const SIGTERM: c_int = 15;
#[cfg(unix)]
const SIGKILL: c_int = 9;
#[cfg(unix)]
const SC_OPEN_MAX: c_int = 5;
#[cfg(target_os = "linux")]
const O_CLOEXEC: c_int = 0o2000000;
#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
const CLOSE_RANGE_UNSHARE: u32 = 1 << 1;
#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
const SYS_CLOSE_RANGE: c_long = 436;

pub fn run_checker(config: &ModuleConfig, candidate: &[u8]) -> CheckerRun {
    if checker_is_obviously_unavailable(&config.checker) {
        return CheckerRun {
            outcome: CheckerOutcome::ExecFailure,
            stderr: String::new(),
        };
    }

    let mut stderr_capture = match StderrCapture::new() {
        Ok(capture) => capture,
        Err(_) => {
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            }
        }
    };

    let mut command = Command::new(&config.checker);
    command
        .arg("--stdin")
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::from(stderr_capture.take_writer()));

    configure_child_process(&mut command);

    if let Some(min_count) = config.min_count {
        command.arg("--min-count").arg(min_count.to_string());
    }

    match config.fail_policy {
        FailPolicy::Inherit => {}
        FailPolicy::FailOpen => {
            command.env("PWNED_CHECK_FAIL_CLOSED", "false");
        }
        FailPolicy::FailClosed => {
            command.env("PWNED_CHECK_FAIL_CLOSED", "true");
        }
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            drop(command);
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: stderr_capture.finish(),
            };
        }
    };
    drop(command);

    if let Some(mut stdin) = child.stdin.take() {
        if stdin.write_all(candidate).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            let stderr = stderr_capture.finish();
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr,
            };
        }
    }

    let status = match child.wait_timeout(Duration::from_secs(config.timeout_seconds)) {
        Ok(Some(status)) => Ok(Some(status)),
        Ok(None) => {
            terminate_child(&mut child, CHECKER_TIMEOUT_GRACE);
            Ok(None)
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(())
        }
    };

    let stderr = stderr_capture.finish();

    let outcome = match status {
        Err(()) => CheckerOutcome::ExecFailure,
        Ok(None) => CheckerOutcome::Timeout,
        Ok(Some(status)) => match status.code() {
            Some(0) => CheckerOutcome::Clean,
            Some(1) => CheckerOutcome::Pwned,
            Some(2) => CheckerOutcome::ConfigError,
            Some(3) => CheckerOutcome::ProviderFailure,
            Some(code) => CheckerOutcome::UnexpectedExit(code),
            None => CheckerOutcome::UnexpectedExit(-1),
        },
    };

    CheckerRun { outcome, stderr }
}

#[cfg(unix)]
fn checker_is_obviously_unavailable(checker: &str) -> bool {
    let path = Path::new(checker);
    if !path.is_absolute() && path.components().count() == 1 {
        return false;
    }

    // Best-effort preflight to disambiguate ExecFailure from UnexpectedExit(255).
    // execve performs the authoritative check; a swap between metadata and execve
    // is benign because a caller with that capability already controls the host.
    match std::fs::metadata(path) {
        Ok(metadata) => !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0,
        Err(_) => true,
    }
}

#[cfg(not(unix))]
fn checker_is_obviously_unavailable(_checker: &str) -> bool {
    false
}

#[cfg(unix)]
fn configure_child_process(command: &mut Command) {
    let max_fd = open_max();
    unsafe {
        // SAFETY: pre_exec runs after fork and before exec. Keep this closure limited
        // to async-signal-safe libc calls and simple integer work; do not allocate,
        // log, lock, or touch Rust-managed shared state here. The syscall call must
        // remain the thin libc trampoline, not a wrapper that allocates or locks.
        command.pre_exec(move || {
            if setpgid(0, 0) != 0 {
                return Err(io::Error::last_os_error());
            }

            close_inherited_fds(max_fd);

            Ok(())
        });
    }
}

#[cfg(not(unix))]
fn configure_child_process(_command: &mut Command) {}

#[cfg(unix)]
fn open_max() -> c_int {
    let value = unsafe { sysconf(SC_OPEN_MAX) };
    if value > 3 && value < 65_536 {
        value as c_int
    } else {
        // Primary Linux targets use close_range(2) first. This fallback cap is
        // for older/non-primary targets and may leave very high fd numbers open.
        1024
    }
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn close_inherited_fds(max_fd: c_int) {
    if unsafe { syscall(SYS_CLOSE_RANGE, 3_u32, u32::MAX, CLOSE_RANGE_UNSHARE) } == 0 {
        return;
    }

    if unsafe { syscall(SYS_CLOSE_RANGE, 3_u32, u32::MAX, 0_u32) } == 0 {
        return;
    }

    close_inherited_fds_by_loop(max_fd);
}

#[cfg(not(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
)))]
fn close_inherited_fds(max_fd: c_int) {
    close_inherited_fds_by_loop(max_fd);
}

#[cfg(unix)]
fn close_inherited_fds_by_loop(max_fd: c_int) {
    for fd in 3..max_fd {
        let _ = unsafe { close(fd) };
    }
}

#[cfg(unix)]
fn terminate_child(child: &mut std::process::Child, grace: Duration) {
    let pid = child.id() as c_int;
    let process_group = -pid;
    let _ = unsafe { kill(process_group, SIGTERM) };

    if matches!(child.wait_timeout(grace), Ok(Some(_))) {
        return;
    }

    let _ = unsafe { kill(process_group, SIGKILL) };
    // Reap the child to avoid a zombie. If the process is stuck in
    // uninterruptible sleep, this wait can outlive the configured PAM timeout.
    let _ = child.wait();
}

#[cfg(not(unix))]
fn terminate_child(child: &mut std::process::Child, _grace: Duration) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
struct StderrCapture {
    writer: Option<File>,
    reader: JoinHandle<String>,
}

#[cfg(unix)]
impl StderrCapture {
    fn new() -> io::Result<Self> {
        let fds = create_stderr_pipe()?;
        let reader_file = unsafe { File::from_raw_fd(fds[0]) };
        let writer = unsafe { File::from_raw_fd(fds[1]) };
        let reader = thread::spawn(move || read_bounded_stderr(reader_file));

        Ok(Self {
            writer: Some(writer),
            reader,
        })
    }

    fn take_writer(&mut self) -> File {
        self.writer.take().expect("stderr writer should be present")
    }

    fn finish(self) -> String {
        drop(self.writer);
        self.reader.join().unwrap_or_default()
    }
}

#[cfg(target_os = "linux")]
fn create_stderr_pipe() -> io::Result<[c_int; 2]> {
    let mut fds = [-1, -1];
    if unsafe { pipe2(fds.as_mut_ptr(), O_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fds)
}

#[cfg(all(unix, not(target_os = "linux")))]
fn create_stderr_pipe() -> io::Result<[c_int; 2]> {
    let mut fds = [-1, -1];
    if unsafe { pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fds)
}

#[cfg(not(unix))]
struct StderrCapture;

#[cfg(not(unix))]
impl StderrCapture {
    fn new() -> std::io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "native PAM checker runner requires Unix",
        ))
    }

    fn take_writer(&mut self) -> File {
        unreachable!("stderr capture cannot be created on non-Unix targets")
    }

    fn finish(self) -> String {
        String::new()
    }
}

fn read_bounded_stderr(mut file: File) -> String {
    let mut captured = Vec::with_capacity(CHECKER_STDERR_LIMIT);
    let mut buffer = [0_u8; 4096];

    loop {
        let read = match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(_) => break,
        };

        let remaining = CHECKER_STDERR_LIMIT.saturating_sub(captured.len());
        if remaining > 0 {
            captured.extend_from_slice(&buffer[..read.min(remaining)]);
        }
    }

    String::from_utf8_lossy(&captured).trim().to_string()
}
