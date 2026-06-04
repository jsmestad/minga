use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;

use crossterm::cursor::{Hide, SetCursorStyle, Show};
use crossterm::event::{DisableBracketedPaste, EnableBracketedPaste};
use crossterm::execute;
use crossterm::terminal::{
    BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen, LeaveAlternateScreen,
    SetTitle, disable_raw_mode, enable_raw_mode, size,
};
use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::CrosstermBackend;
#[cfg(test)]
use ratatui::backend::TestBackend;

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellStyle {
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub ul_color: u32,
    pub blend: u8,
}

impl Default for CellStyle {
    fn default() -> Self {
        Self {
            fg: 0,
            bg: 0,
            attrs: 0,
            ul_color: 0,
            blend: 100,
        }
    }
}

enum Backend {
    Real(RatatuiTerminal<CrosstermBackend<File>>),
    #[cfg(test)]
    Test(RatatuiTerminal<TestBackend>),
}

pub struct Terminal {
    backend: Backend,
    width: u16,
    height: u16,
    real_tty: bool,
    active: bool,
}

impl Terminal {
    pub fn open() -> io::Result<Self> {
        enable_raw_mode()?;
        let mut tty = tty_file()?;
        execute!(tty, EnterAlternateScreen, EnableBracketedPaste, Hide)?;
        let backend = CrosstermBackend::new(tty);
        let terminal = RatatuiTerminal::new(backend)?;
        let (width, height) = size().unwrap_or_else(|_| env_size());

        Ok(Self {
            backend: Backend::Real(terminal),
            width,
            height,
            real_tty: true,
            active: true,
        })
    }

    #[cfg(test)]
    pub fn memory(width: u16, height: u16) -> Self {
        let backend = TestBackend::new(width, height);
        let terminal = RatatuiTerminal::new(backend).expect("test terminal should initialize");
        Self {
            backend: Backend::Test(terminal),
            width,
            height,
            real_tty: false,
            active: false,
        }
    }

    pub fn size(&self) -> (u16, u16) {
        (self.width, self.height)
    }

    pub fn poll_size(&mut self) -> io::Result<Option<(u16, u16)>> {
        let (width, height) = match &mut self.backend {
            Backend::Real(terminal) => terminal.size().map(|rect| (rect.width, rect.height))?,
            #[cfg(test)]
            Backend::Test(_) => (self.width, self.height),
        };

        if width == self.width && height == self.height {
            Ok(None)
        } else {
            self.width = width;
            self.height = height;
            Ok(Some((width, height)))
        }
    }

    pub fn draw<F>(&mut self, render_callback: F) -> io::Result<()>
    where
        F: FnOnce(&mut ratatui::Frame<'_>),
    {
        match &mut self.backend {
            Backend::Real(terminal) => {
                execute!(terminal.backend_mut(), BeginSynchronizedUpdate)?;
                let draw_result = terminal.draw(render_callback).map(|_| ());
                let end_result = execute!(terminal.backend_mut(), EndSynchronizedUpdate);
                draw_result?;
                end_result?;
            }
            #[cfg(test)]
            Backend::Test(terminal) => {
                let _ = terminal.draw(render_callback);
            }
        }
        Ok(())
    }

    pub fn finish(&mut self) -> io::Result<()> {
        if self.real_tty && self.active {
            match &mut self.backend {
                Backend::Real(terminal) => {
                    let backend = terminal.backend_mut();
                    execute!(backend, Show, DisableBracketedPaste, LeaveAlternateScreen)?;
                }
                #[cfg(test)]
                Backend::Test(_) => {}
            }
            disable_raw_mode()?;
            self.active = false;
        }

        Ok(())
    }

    pub fn set_title(&mut self, title: &str) -> io::Result<()> {
        match &mut self.backend {
            Backend::Real(terminal) => execute!(terminal.backend_mut(), SetTitle(title))?,
            #[cfg(test)]
            Backend::Test(_) => {}
        }
        Ok(())
    }

    pub fn set_cursor_shape(&mut self, shape: u8) -> io::Result<()> {
        self.set_cursor_style(shape, true)
    }

    pub fn set_cursor_style(&mut self, shape: u8, animated: bool) -> io::Result<()> {
        match &mut self.backend {
            Backend::Real(terminal) => {
                execute!(terminal.backend_mut(), cursor_style(shape, animated))?;
            }
            #[cfg(test)]
            Backend::Test(_) => {}
        }
        Ok(())
    }

    pub fn write_clipboard(&mut self, text: &str) -> io::Result<()> {
        match &mut self.backend {
            Backend::Real(terminal) => {
                terminal
                    .backend_mut()
                    .write_all(osc52_clipboard_sequence(text).as_bytes())?;
            }
            #[cfg(test)]
            Backend::Test(_) => {}
        }
        Ok(())
    }

    pub fn flush(&mut self) -> io::Result<()> {
        match &mut self.backend {
            Backend::Real(terminal) => terminal.backend_mut().flush(),
            #[cfg(test)]
            Backend::Test(_) => Ok(()),
        }
    }

    #[cfg(test)]
    pub fn buffer_text(&self) -> String {
        match &self.backend {
            Backend::Real(_) => String::new(),
            Backend::Test(terminal) => terminal.backend().to_string(),
        }
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

fn tty_file() -> io::Result<File> {
    let path = env::var_os("MINGA_TTY")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/dev/tty"));
    OpenOptions::new().read(true).write(true).open(path)
}

fn env_size() -> (u16, u16) {
    (
        env_u16("COLUMNS").unwrap_or(80),
        env_u16("LINES").unwrap_or(24),
    )
}

fn env_u16(name: &str) -> Option<u16> {
    env::var(name).ok()?.parse().ok()
}

fn cursor_style(shape: u8, animated: bool) -> SetCursorStyle {
    match (shape, animated) {
        (1, true) => SetCursorStyle::BlinkingBar,
        (1, false) => SetCursorStyle::SteadyBar,
        (2, true) => SetCursorStyle::BlinkingUnderScore,
        (2, false) => SetCursorStyle::SteadyUnderScore,
        (_, true) => SetCursorStyle::BlinkingBlock,
        (_, false) => SetCursorStyle::SteadyBlock,
    }
}

fn osc52_clipboard_sequence(text: &str) -> String {
    format!("\x1b]52;c;{}\x07", base64_encode(text.as_bytes()))
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);

    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied().unwrap_or(0);
        let third = chunk.get(2).copied().unwrap_or(0);

        encoded.push(TABLE[(first >> 2) as usize] as char);
        encoded.push(TABLE[(((first & 0b0000_0011) << 4) | (second >> 4)) as usize] as char);

        if chunk.len() > 1 {
            encoded.push(TABLE[(((second & 0b0000_1111) << 2) | (third >> 6)) as usize] as char);
        } else {
            encoded.push('=');
        }

        if chunk.len() > 2 {
            encoded.push(TABLE[(third & 0b0011_1111) as usize] as char);
        } else {
            encoded.push('=');
        }
    }

    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_osc52_clipboard_sequence() {
        assert_eq!(osc52_clipboard_sequence("hello"), "\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(osc52_clipboard_sequence("λ\n"), "\x1b]52;c;zrsK\x07");
    }

    #[test]
    fn cursor_style_uses_animation_flag() {
        assert_eq!(cursor_style(0, true).to_string(), "\x1b[1 q");
        assert_eq!(cursor_style(0, false).to_string(), "\x1b[2 q");
        assert_eq!(cursor_style(2, true).to_string(), "\x1b[3 q");
        assert_eq!(cursor_style(2, false).to_string(), "\x1b[4 q");
        assert_eq!(cursor_style(1, true).to_string(), "\x1b[5 q");
        assert_eq!(cursor_style(1, false).to_string(), "\x1b[6 q");
    }
}
