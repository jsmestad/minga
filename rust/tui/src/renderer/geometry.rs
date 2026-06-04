use crate::semantic;
use ratatui::layout::Rect;

pub fn centered_rect(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect {
        x: area.x.saturating_add(area.width.saturating_sub(width) / 2),
        y: area
            .y
            .saturating_add(area.height.saturating_sub(height) / 2),
        width,
        height,
    }
}

pub fn anchored_rect(area: Rect, col: u16, row: u16, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    let max_x = area.x.saturating_add(area.width.saturating_sub(width));
    let max_y = area.y.saturating_add(area.height.saturating_sub(height));
    Rect {
        x: area.x.saturating_add(col).min(max_x),
        y: area.y.saturating_add(row).min(max_y),
        width,
        height,
    }
}

pub fn bounded_dimension(requested: u16, min: u16, max: u16) -> u16 {
    if max == 0 {
        0
    } else {
        requested.max(min.min(max)).min(max)
    }
}

pub fn window_rect(window: &semantic::WindowContent, body: Rect) -> Rect {
    let x = body.x.saturating_add(window.origin_col);
    let y = body.y.saturating_add(window.origin_row);
    let max_width = body.x.saturating_add(body.width).saturating_sub(x);
    let max_height = body.y.saturating_add(body.height).saturating_sub(y);
    let requested_width = if window.text_width == 0 {
        max_width
    } else {
        window.text_width
    };
    let requested_height = if window.text_height == 0 {
        window.rows.len().min(u16::MAX as usize) as u16
    } else {
        window.text_height
    };
    Rect {
        x,
        y,
        width: requested_width.min(max_width),
        height: requested_height.min(max_height),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchored_rect_stays_inside_area() {
        let area = Rect {
            x: 10,
            y: 4,
            width: 20,
            height: 8,
        };

        assert_eq!(
            anchored_rect(area, 18, 7, 10, 4),
            Rect {
                x: 20,
                y: 8,
                width: 10,
                height: 4
            }
        );
    }

    #[test]
    fn bounded_dimension_handles_tiny_areas() {
        assert_eq!(bounded_dimension(10, 3, 0), 0);
        assert_eq!(bounded_dimension(1, 3, 2), 2);
        assert_eq!(bounded_dimension(8, 3, 6), 6);
    }
}
