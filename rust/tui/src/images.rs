use ratatui_image::picker::{Picker, ProtocolType};

#[derive(Debug, Clone, Copy)]
pub struct ImageSupport {
    protocol: ProtocolType,
}

impl ImageSupport {
    pub fn fallback() -> Self {
        let picker = Picker::halfblocks();
        Self {
            protocol: picker.protocol_type(),
        }
    }

    pub fn capability_code(self) -> u8 {
        match self.protocol {
            ProtocolType::Kitty => 1,
            ProtocolType::Sixel => 2,
            ProtocolType::Iterm2 | ProtocolType::Halfblocks => 0,
        }
    }
}

impl Default for ImageSupport {
    fn default() -> Self {
        Self::fallback()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_image_support_uses_halfblocks_without_stdio_queries() {
        let support = ImageSupport::fallback();

        assert_eq!(support.capability_code(), 0);
    }
}
