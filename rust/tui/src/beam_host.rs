use crate::input;
use crate::protocol::{self, Command, DecodeError};
use std::env;
use std::io::{self, Read, Write};

pub trait PacketReader: Read + Send {}

impl<T> PacketReader for T where T: Read + Send {}

pub trait PacketWriter: Write {}

impl<T> PacketWriter for T where T: Write {}

pub struct BeamHost {
    reader: Option<Box<dyn PacketReader>>,
    writer: Box<dyn PacketWriter>,
}

pub fn open() -> BeamHost {
    BeamHost {
        reader: Some(Box::new(io::stdin())),
        writer: Box::new(io::stdout()),
    }
}

pub fn trace(message: impl AsRef<str>) {
    if env::var_os("MINGA_RUST_TUI_TRACE").is_none() {
        return;
    }

    tracing::info!("{}", message.as_ref());
}

impl BeamHost {
    pub fn take_reader(&mut self) -> io::Result<Box<dyn PacketReader>> {
        self.reader
            .take()
            .ok_or_else(|| io::Error::other("BEAM packet reader was already taken"))
    }

    pub fn output(&mut self) -> &mut dyn PacketWriter {
        self.writer.as_mut()
    }

    pub fn shutdown(&mut self) {
        let _ = self.writer.flush();
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
        input::Event::Mouse {
            row,
            col,
            button,
            modifiers,
            event_type,
            click_count,
        } => protocol::write_packet(
            output,
            &protocol::encode_mouse_event(row, col, button, modifiers, event_type, click_count),
        ),
    }
}

pub fn read_framed_packet(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0_u8; 4];

    match reader.read_exact(&mut len) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => {
            trace(format!("packet length read failed error={error}"));
            return Err(error);
        }
    }

    let len_bytes = len;
    let len = u32::from_be_bytes(len_bytes) as usize;
    if len > 16 * 1024 * 1024 {
        trace(format!(
            "packet length unreasonable len={} header={:02X} {:02X} {:02X} {:02X}",
            len, len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]
        ));
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unreasonable BEAM packet length {len}"),
        ));
    }
    let mut payload = vec![0_u8; len];
    if let Err(error) = reader.read_exact(&mut payload) {
        trace(format!(
            "packet payload read failed len={} header={:02X} {:02X} {:02X} {:02X} error={error}",
            len, len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]
        ));
        return Err(error);
    }
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
                1,
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
}
