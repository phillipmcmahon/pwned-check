use core::ffi::c_int;
#[cfg(target_os = "linux")]
use core::ffi::c_long;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
#[cfg(unix)]
use std::{
    io,
    os::unix::{io::FromRawFd, process::CommandExt},
};

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

#[cfg(unix)]
#[repr(C)]
struct CFile {
    _private: [u8; 0],
}

#[cfg(unix)]
// Rust 2021 extern syntax is intentional until the distro MSRV/edition pin changes.
extern "C" {
    fn close(fd: c_int) -> c_int;
    fn dup(fd: c_int) -> c_int;
    fn fclose(stream: *mut CFile) -> c_int;
    fn fileno(stream: *mut CFile) -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn setpgid(pid: c_int, pgid: c_int) -> c_int;
    fn sysconf(name: c_int) -> isize;
    fn tmpfile() -> *mut CFile;
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
// Rust 2021 extern syntax is intentional until the distro MSRV/edition pin changes.
extern "C" {
    fn syscall(num: c_long, ...) -> c_long;
}

#[cfg(unix)]
const SIGTERM: c_int = 15;
#[cfg(unix)]
const SIGKILL: c_int = 9;
#[cfg(unix)]
const SC_OPEN_MAX: c_int = 5;
#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
const SYS_CLOSE_RANGE: c_long = 436;

pub fn run_checker(config: &ModuleConfig, candidate: &[u8]) -> CheckerRun {
    let mut stderr_file = match temp_stderr_file() {
        Ok(file) => file,
        Err(_) => {
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            }
        }
    };

    let stderr_for_child = match stderr_file.try_clone() {
        Ok(file) => file,
        Err(_) => {
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            };
        }
    };

    let mut command = Command::new(&config.checker);
    command
        .arg("--stdin")
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::from(stderr_for_child));

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
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            };
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        if stdin.write_all(candidate).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            let stderr = read_bounded_stderr(&mut stderr_file);
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr,
            };
        }
    }

    let deadline = Instant::now() + Duration::from_secs(config.timeout_seconds);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(Some(status)),
            Ok(None) => {
                if Instant::now() >= deadline {
                    terminate_child(&mut child, CHECKER_TIMEOUT_GRACE);
                    break Ok(None);
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(());
            }
        }
    };

    let stderr = read_bounded_stderr(&mut stderr_file);

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
        1024
    }
}

#[cfg(all(
    target_os = "linux",
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn close_inherited_fds(max_fd: c_int) {
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

    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {
                if Instant::now() >= deadline {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return,
        }
    }

    let _ = unsafe { kill(process_group, SIGKILL) };
    let _ = child.wait();
}

#[cfg(not(unix))]
fn terminate_child(child: &mut std::process::Child, _grace: Duration) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
fn temp_stderr_file() -> io::Result<File> {
    let stream = unsafe { tmpfile() };
    if stream.is_null() {
        return Err(io::Error::last_os_error());
    }

    let original_fd = unsafe { fileno(stream) };
    let owned_fd = if original_fd >= 0 {
        unsafe { dup(original_fd) }
    } else {
        -1
    };
    let close_result = unsafe { fclose(stream) };

    if original_fd < 0 || owned_fd < 0 || close_result != 0 {
        if owned_fd >= 0 {
            let _ = unsafe { close(owned_fd) };
        }
        return Err(io::Error::last_os_error());
    }

    Ok(unsafe { File::from_raw_fd(owned_fd) })
}

#[cfg(not(unix))]
fn temp_stderr_file() -> std::io::Result<File> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "native PAM checker runner requires Unix",
    ))
}

fn read_bounded_stderr(file: &mut File) -> String {
    if file.seek(SeekFrom::Start(0)).is_err() {
        return String::new();
    }
    let mut buffer = vec![0; CHECKER_STDERR_LIMIT + 1];
    let read = match file.read(&mut buffer) {
        Ok(read) => read,
        Err(_) => return String::new(),
    };
    buffer.truncate(read.min(CHECKER_STDERR_LIMIT));
    String::from_utf8_lossy(&buffer).trim().to_string()
}
