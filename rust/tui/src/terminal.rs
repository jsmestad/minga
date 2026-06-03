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
        match &mut self.backend {
            Backend::Real(terminal) => {
                let style = match shape {
                    1 => SetCursorStyle::BlinkingBar,
                    2 => SetCursorStyle::BlinkingUnderScore,
                    _ => SetCursorStyle::BlinkingBlock,
                };
                execute!(terminal.backend_mut(), style)?;
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
