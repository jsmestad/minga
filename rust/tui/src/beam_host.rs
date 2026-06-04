use crate::input;
use crate::protocol::{self, Command, DecodeError};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStderr, Command as ProcessCommand, ExitStatus, Stdio};
use std::thread;

pub trait PacketReader: Read + Send {}

impl<T> PacketReader for T where T: Read + Send {}

pub trait PacketWriter: Write {}

impl<T> PacketWriter for T where T: Write {}

pub enum BeamHost {
    Stdio {
        reader: Option<Box<dyn PacketReader>>,
        writer: Box<dyn PacketWriter>,
    },
    LocalChild {
        child: Child,
        reader: Option<Box<dyn PacketReader>>,
        writer: Box<dyn PacketWriter>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HostMode {
    Stdio,
    LocalChild,
}

pub fn open(cli_args: Vec<String>) -> io::Result<BeamHost> {
    match host_mode(env::var("MINGA_RUST_TUI_HOST").ok().as_deref()) {
        HostMode::LocalChild => spawn_local_child(cli_args),
        HostMode::Stdio => Ok(BeamHost::Stdio {
            reader: Some(Box::new(io::stdin())),
            writer: Box::new(io::stdout()),
        }),
    }
}

fn host_mode(value: Option<&str>) -> HostMode {
    match value {
        Some("local_child") => HostMode::LocalChild,
        _ => HostMode::Stdio,
    }
}

fn spawn_local_child(cli_args: Vec<String>) -> io::Result<BeamHost> {
    let mut command =
        ProcessCommand::new(env::var("MINGA_BEAM_EXECUTABLE").unwrap_or_else(|_| "mix".to_owned()));
    command.arg("minga").args(cli_args);

    if let Some(project_dir) = env::var_os("MINGA_PROJECT_DIR") {
        command.current_dir(PathBuf::from(project_dir));
    }

    command
        .env("MINGA_PORT_MODE", "connected")
        .env("MINGA_CONNECTED_BACKEND", "tui")
        .env("MINGA_TUI_IMPL", "rust")
        .env("MINGA_SKIP_NATIVE_LAUNCH_BUILD", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn()?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("BEAM child stdin was not piped"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("BEAM child stdout was not piped"))?;
    if let Some(stderr) = child.stderr.take() {
        drain_child_stderr(stderr);
    }

    Ok(BeamHost::LocalChild {
        child,
        reader: Some(Box::new(stdout)),
        writer: Box::new(stdin),
    })
}

fn drain_child_stderr(mut stderr: ChildStderr) {
    thread::spawn(move || {
        let mut sink = io::sink();
        match open_child_stderr_log() {
            Ok(mut log) => {
                let _ = io::copy(&mut stderr, &mut log);
            }
            Err(_) => {
                let _ = io::copy(&mut stderr, &mut sink);
            }
        }
    });
}

fn open_child_stderr_log() -> io::Result<fs::File> {
    let dir = minga_log_dir();
    fs::create_dir_all(&dir)?;
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("minga-rust-tui-beam.stderr.log"))
}

fn minga_log_dir() -> PathBuf {
    env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("minga")
}

impl BeamHost {
    pub fn take_reader(&mut self) -> io::Result<Box<dyn PacketReader>> {
        let reader = match self {
            Self::Stdio { reader, .. } | Self::LocalChild { reader, .. } => reader,
        };

        reader
            .take()
            .ok_or_else(|| io::Error::other("BEAM packet reader was already taken"))
    }

    pub fn output(&mut self) -> &mut dyn PacketWriter {
        match self {
            Self::Stdio { writer, .. } | Self::LocalChild { writer, .. } => writer.as_mut(),
        }
    }

    pub fn shutdown(&mut self) {
        if let Self::LocalChild { child, .. } = self {
            if let Ok(Some(_status)) = child.try_wait() {
                return;
            }
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    pub fn finish(&mut self) -> Option<ExitStatus> {
        match self {
            Self::Stdio { .. } => None,
            Self::LocalChild { child, .. } => child.try_wait().ok().flatten(),
        }
    }
}

impl Drop for BeamHost {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrontendCapabilities {
    pub width: u16,
    pub height: u16,
    pub image_support: u8,
}

pub fn send_ready(
    output: &mut (impl Write + ?Sized),
    caps: FrontendCapabilities,
) -> io::Result<()> {
    protocol::write_packet(
        output,
        &protocol::encode_ready_with_caps(caps.width, caps.height, caps.image_support),
    )
}

pub fn send_resize(output: &mut (impl Write + ?Sized), width: u16, height: u16) -> io::Result<()> {
    protocol::write_packet(output, &protocol::encode_resize(width, height))
}

pub fn send_input_event(event: input::Event, output: &mut (impl Write + ?Sized)) -> io::Result<()> {
    match event {
        input::Event::Key {
            codepoint,
            modifiers,
        } => protocol::write_packet(output, &protocol::encode_key_press(codepoint, modifiers)),
        input::Event::Paste(text) => {
            if text.is_empty() {
                Ok(())
            } else {
                protocol::write_packet(output, &protocol::encode_paste_event(&text))
            }
        }
        input::Event::Resize { .. } => Ok(()),
    }
}

pub fn log_info(output: &mut (impl Write + ?Sized), msg: &str) {
    let _ = protocol::write_packet(
        output,
        &protocol::encode_log_message(protocol::LOG_LEVEL_INFO, msg),
    );
}

pub fn log_warn(output: &mut (impl Write + ?Sized), msg: &str) {
    let _ = protocol::write_packet(
        output,
        &protocol::encode_log_message(protocol::LOG_LEVEL_WARN, msg),
    );
}

pub fn read_framed_packet(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0_u8; 4];

    match reader.read_exact(&mut len) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }

    let len = u32::from_be_bytes(len) as usize;
    let mut payload = vec![0_u8; len];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

pub fn decode_packet(packet: &[u8]) -> Vec<Result<Command, PacketDecodeError>> {
    let mut offset = 0;
    let mut commands = Vec::new();

    while offset < packet.len() {
        let command_size = match protocol::command_byte_size(&packet[offset..]) {
            Ok(size) => size,
            Err(error) => {
                commands.push(Err(PacketDecodeError { offset, error }));
                break;
            }
        };

        match protocol::decode_command(&packet[offset..]) {
            Ok(command) => commands.push(Ok(command)),
            Err(error) => {
                commands.push(Err(PacketDecodeError { offset, error }));
                break;
            }
        }

        offset += command_size;
    }

    commands
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacketDecodeError {
    pub offset: usize,
    pub error: DecodeError,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sends_extended_semantic_ready_capabilities() {
        let mut output = Vec::new();
        send_ready(
            &mut output,
            FrontendCapabilities {
                width: 80,
                height: 24,
                image_support: 0,
            },
        )
        .unwrap();

        assert_eq!(
            output,
            vec![
                0,
                0,
                0,
                14,
                protocol::opcodes::OP_READY,
                0,
                80,
                0,
                24,
                1,
                7,
                0,
                2,
                0,
                0,
                0,
                0,
                1
            ]
        );
    }

    #[test]
    fn reads_framed_beam_packets() {
        let mut input = &[0, 0, 0, 3, 1, 2, 3][..];
        assert_eq!(read_framed_packet(&mut input).unwrap(), Some(vec![1, 2, 3]));
        assert_eq!(read_framed_packet(&mut input).unwrap(), None);
    }

    #[test]
    fn host_mode_defaults_to_stdio_unless_local_child_is_requested() {
        assert_eq!(host_mode(None), HostMode::Stdio);
        assert_eq!(host_mode(Some("stdio")), HostMode::Stdio);
        assert_eq!(host_mode(Some("local_child")), HostMode::LocalChild);
    }
}
