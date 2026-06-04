use std::env;
use std::path::PathBuf;
use tracing_appender::non_blocking::WorkerGuard;

pub fn init() -> Option<WorkerGuard> {
    env::var_os("MINGA_RUST_TUI_TRACE")?;

    let dir = minga_log_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return None;
    }

    let appender = tracing_appender::rolling::never(dir, "minga-rust-tui.log");
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let subscriber = tracing_subscriber::fmt()
        .with_writer(writer)
        .with_ansi(false)
        .with_target(false)
        .with_level(true)
        .compact()
        .finish();

    match tracing::subscriber::set_global_default(subscriber) {
        Ok(()) => Some(guard),
        Err(_) => None,
    }
}

fn minga_log_dir() -> PathBuf {
    env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("minga")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_dir_defaults_under_minga_data_home() {
        let dir = minga_log_dir();
        assert_eq!(
            dir.file_name().and_then(|name| name.to_str()),
            Some("minga")
        );
    }
}
