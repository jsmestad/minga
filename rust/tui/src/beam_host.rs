use crate::input;
use crate::protocol::{self, Command, DecodeError};
use std::io::{self, Read, Write};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrontendCapabilities {
    pub width: u16,
    pub height: u16,
    pub image_support: u8,
}

pub fn send_ready(output: &mut impl Write, caps: FrontendCapabilities) -> io::Result<()> {
    protocol::write_packet(
        output,
        &protocol::encode_ready_with_caps(caps.width, caps.height, caps.image_support),
    )
}

pub fn send_resize(output: &mut impl Write, width: u16, height: u16) -> io::Result<()> {
    protocol::write_packet(output, &protocol::encode_resize(width, height))
}

pub fn send_input_event(event: input::Event, output: &mut impl Write) -> io::Result<()> {
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

pub fn log_info(output: &mut impl Write, msg: &str) {
    let _ = protocol::write_packet(
        output,
        &protocol::encode_log_message(protocol::LOG_LEVEL_INFO, msg),
    );
}

pub fn log_warn(output: &mut impl Write, msg: &str) {
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
}
