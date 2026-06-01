use crate::protocol;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::PathBuf;

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

pub struct Terminal {
    writer: Box<dyn Write>,
    reader: Option<File>,
    fd: Option<RawFd>,
    original_termios: Option<libc::termios>,
    width: u16,
    height: u16,
    real_tty: bool,
    active: bool,
}

impl Terminal {
    pub fn open() -> io::Result<Self> {
        let tty = tty_file()?;
        let reader = tty.try_clone()?;
        let fd = tty.as_raw_fd();
        let original_termios = make_raw(fd)?;
        let (width, height) = query_terminal_size(fd).unwrap_or_else(|_| env_size());
        let mut terminal = Self {
            writer: Box::new(tty),
            reader: Some(reader),
            fd: Some(fd),
            original_termios: Some(original_termios),
            width,
            height,
            real_tty: true,
            active: true,
        };
        terminal
            .writer
            .write_all(b"\x1b[?1049h\x1b[?2004h\x1b[?25h")?;
        terminal.flush()?;
        Ok(terminal)
    }

    #[cfg(test)]
    pub fn memory(width: u16, height: u16) -> Self {
        Self {
            writer: Box::new(Vec::<u8>::new()),
            reader: None,
            fd: None,
            original_termios: None,
            width,
            height,
            real_tty: false,
            active: false,
        }
    }

    pub fn size(&self) -> (u16, u16) {
        (self.width, self.height)
    }

    pub fn fd(&self) -> Option<RawFd> {
        self.fd
    }

    pub fn read_input(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match &mut self.reader {
            Some(reader) => reader.read(buf),
            None => Ok(0),
        }
    }

    pub fn poll_size(&mut self) -> io::Result<Option<(u16, u16)>> {
        let Some(fd) = self.fd else {
            return Ok(None);
        };
        let (width, height) = query_terminal_size(fd)?;

        if width == self.width && height == self.height {
            Ok(None)
        } else {
            self.width = width;
            self.height = height;
            Ok(Some((width, height)))
        }
    }

    pub fn finish(&mut self) -> io::Result<()> {
        if self.real_tty && self.active {
            self.writer
                .write_all(b"\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l")?;
            if let (Some(fd), Some(termios)) = (self.fd, self.original_termios.take()) {
                restore_termios(fd, termios)?;
            }
            self.active = false;
        }

        self.flush()
    }

    pub fn set_title(&mut self, title: &str) -> io::Result<()> {
        write!(self.writer, "\x1b]0;{title}\x07")
    }

    pub fn set_cursor_shape(&mut self, shape: u8) -> io::Result<()> {
        let code = match shape {
            1 => 5,
            2 => 3,
            _ => 1,
        };
        write!(self.writer, "\x1b[{code} q")
    }

    pub fn show_cursor(&mut self, col: u16, row: u16) -> io::Result<()> {
        write!(self.writer, "\x1b[{};{}H", row as u32 + 1, col as u32 + 1)
    }

    pub fn scroll_region(&mut self, top: u16, bottom: u16, delta: i16) -> io::Result<()> {
        if delta == 0 || top >= bottom {
            return Ok(());
        }

        write!(
            self.writer,
            "\x1b[{};{}r",
            top as u32 + 1,
            bottom as u32 + 1
        )?;

        if delta > 0 {
            write!(self.writer, "\x1b[{}S", delta)?;
        } else {
            write!(self.writer, "\x1b[{}T", -delta)?;
        }

        self.writer.write_all(b"\x1b[r")
    }

    pub fn write_cell(
        &mut self,
        col: u16,
        row: u16,
        text: &str,
        style: CellStyle,
    ) -> io::Result<()> {
        self.show_cursor(col, row)?;
        self.write_style(style)?;
        write!(self.writer, "{text}")?;
        self.writer.write_all(b"\x1b[0m")
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }

    fn write_style(&mut self, style: CellStyle) -> io::Result<()> {
        self.writer.write_all(b"\x1b[0m")?;

        if style.attrs & protocol::ATTR_BOLD != 0 {
            self.writer.write_all(b"\x1b[1m")?;
        }
        if style.attrs & protocol::ATTR_ITALIC != 0 {
            self.writer.write_all(b"\x1b[3m")?;
        }
        if style.attrs & protocol::ATTR_UNDERLINE != 0 {
            self.writer.write_all(b"\x1b[4m")?;
        }
        if style.attrs & protocol::ATTR_REVERSE != 0 {
            self.writer.write_all(b"\x1b[7m")?;
        }
        if style.attrs & protocol::ATTR_STRIKETHROUGH != 0 {
            self.writer.write_all(b"\x1b[9m")?;
        }
        if style.blend < 50 {
            self.writer.write_all(b"\x1b[2m")?;
        }
        if style.fg != 0 {
            write_rgb(self.writer.as_mut(), 38, style.fg)?;
        }
        if style.bg != 0 {
            write_rgb(self.writer.as_mut(), 48, style.bg)?;
        }
        if style.ul_color != 0 {
            write_rgb(self.writer.as_mut(), 58, style.ul_color)?;
        }

        let underline_style = (style.attrs >> protocol::UL_STYLE_SHIFT) & 0x07;
        if underline_style != 0 {
            let code = match underline_style {
                1 => 3,
                2 => 4,
                3 => 5,
                4 => 6,
                _ => 1,
            };
            write!(self.writer, "\x1b[4:{code}m")?;
        }

        Ok(())
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

fn make_raw(fd: RawFd) -> io::Result<libc::termios> {
    let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
    let rc = unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    let original = unsafe { termios.assume_init() };
    let mut raw = original;
    unsafe {
        libc::cfmakeraw(&mut raw);
    }

    let rc = unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(original)
}

fn restore_termios(fd: RawFd, termios: libc::termios) -> io::Result<()> {
    let rc = unsafe { libc::tcsetattr(fd, libc::TCSANOW, &termios) };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn query_terminal_size(fd: RawFd) -> io::Result<(u16, u16)> {
    let mut winsize = std::mem::MaybeUninit::<libc::winsize>::zeroed();
    let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, winsize.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    let winsize = unsafe { winsize.assume_init() };
    if winsize.ws_col == 0 || winsize.ws_row == 0 {
        Ok(env_size())
    } else {
        Ok((winsize.ws_col, winsize.ws_row))
    }
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

fn write_rgb(writer: &mut dyn Write, prefix: u8, rgb: u32) -> io::Result<()> {
    let r = (rgb >> 16) & 0xFF;
    let g = (rgb >> 8) & 0xFF;
    let b = rgb & 0xFF;
    write!(writer, "\x1b[{prefix};2;{r};{g};{b}m")
}
