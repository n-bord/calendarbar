use std::sync::Mutex;
use tauri::{image::Image, tray::TrayIcon};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub enum TrayCountdown {
    #[default]
    Hidden,
    Ongoing,
    Upcoming(i64),
}

impl TrayCountdown {
    fn tooltip(self) -> String {
        match self {
            Self::Hidden => "CalendarBar".into(),
            Self::Ongoing => "CalendarBar · Встреча по плану".into(),
            Self::Upcoming(minutes) if minutes < 60 => {
                format!("CalendarBar · До встречи {minutes} мин")
            }
            Self::Upcoming(minutes) if minutes % 60 == 0 => {
                format!("CalendarBar · До встречи {} ч", minutes / 60)
            }
            Self::Upcoming(minutes) => format!(
                "CalendarBar · До встречи {} ч {} мин",
                minutes / 60,
                minutes % 60
            ),
        }
    }

    #[cfg(any(windows, test))]
    fn badge(self) -> Option<TrayBadge> {
        match self {
            Self::Upcoming(minutes @ 1..=99) => Some(TrayBadge::Minutes(minutes as u8)),
            Self::Upcoming(100..) => Some(TrayBadge::MoreThan99),
            _ => None,
        }
    }
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TrayBadge {
    Minutes(u8),
    MoreThan99,
}

#[derive(Default)]
pub struct TrayDisplay(Mutex<TrayCountdown>);

impl TrayDisplay {
    pub fn update(&self, tray: &TrayIcon, countdown: TrayCountdown) -> tauri::Result<()> {
        let mut current = self.0.lock().expect("tray display lock");
        if *current == countdown {
            return Ok(());
        }
        #[cfg(windows)]
        if current.badge() != countdown.badge() {
            let icon = match countdown.badge() {
                Some(badge) => badge_icon(badge),
                None => default_icon()?,
            };
            tray.set_icon(Some(icon))?;
        }
        tray.set_tooltip(Some(countdown.tooltip()))?;
        *current = countdown;
        Ok(())
    }
}

pub fn default_icon() -> tauri::Result<Image<'static>> {
    Image::from_bytes(include_bytes!("../icons/icon.png"))
}

#[cfg(any(windows, test))]
const DIGIT_ROWS: [[u8; 7]; 10] = [
    [
        0b01110, 0b11011, 0b10001, 0b10001, 0b10001, 0b11011, 0b01110,
    ],
    [
        0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110,
    ],
    [
        0b01110, 0b11011, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111,
    ],
    [
        0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110,
    ],
    [
        0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010,
    ],
    [
        0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b10001, 0b01110,
    ],
    [
        0b01110, 0b10001, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110,
    ],
    [
        0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000,
    ],
    [
        0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110,
    ],
    [
        0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b10001, 0b01110,
    ],
];

#[cfg(any(windows, test))]
const ICON_SIZE: usize = 16;
#[cfg(any(windows, test))]
const NUMBER_COLOR: [u8; 4] = [240, 255, 246, 255];

#[cfg(any(windows, test))]
fn badge_icon(badge: TrayBadge) -> Image<'static> {
    let mut pixels = [[[0_u8; 4]; ICON_SIZE]; ICON_SIZE];
    // Draw at the smallest common Windows tray size so strokes survive downscaling.
    for (y, row) in pixels.iter_mut().enumerate().take(14).skip(2) {
        for (x, pixel) in row.iter_mut().enumerate() {
            let corner = matches!(x, 0 | 15) && matches!(y, 2 | 13);
            if !corner {
                *pixel = if matches!(x, 0 | 15) || matches!(y, 2 | 13) {
                    [26, 203, 100, 255]
                } else {
                    [18, 42, 30, 255]
                };
            }
        }
    }
    let mut draw_digit = |digit: u8, left: usize| {
        for (line, font_row) in [0, 1, 2, 2, 3, 4, 4, 5, 6].into_iter().enumerate() {
            let pattern = DIGIT_ROWS[usize::from(digit)][font_row];
            for column in 0..5 {
                if pattern & (0b10000 >> column) != 0 {
                    pixels[3 + line][left + column] = NUMBER_COLOR;
                }
            }
        }
    };
    match badge {
        TrayBadge::Minutes(minutes @ 10..) => {
            draw_digit(minutes / 10, 2);
            draw_digit(minutes % 10, 8);
        }
        TrayBadge::Minutes(minutes) => draw_digit(minutes, 5),
        TrayBadge::MoreThan99 => {
            draw_digit(9, 1);
            draw_digit(9, 7);
            pixels[6][13] = NUMBER_COLOR;
            pixels[7][12..15].fill(NUMBER_COLOR);
            pixels[8][13] = NUMBER_COLOR;
        }
    }

    const SCALE: usize = 2;
    let size = ICON_SIZE * SCALE;
    let mut rgba = Vec::with_capacity(size * size * 4);
    for y in 0..size {
        for x in 0..size {
            rgba.extend_from_slice(&pixels[y / SCALE][x / SCALE]);
        }
    }
    Image::new_owned(rgba, size as u32, size as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countdown_badge_uses_two_digits_and_signals_overflow() {
        let badge = |minutes| TrayCountdown::Upcoming(minutes).badge();
        assert_eq!(badge(0), None);
        assert_eq!(badge(1), Some(TrayBadge::Minutes(1)));
        assert_eq!(badge(99), Some(TrayBadge::Minutes(99)));
        assert_eq!(badge(100), Some(TrayBadge::MoreThan99));
        assert_eq!(badge(180), Some(TrayBadge::MoreThan99));
        assert_eq!(TrayCountdown::Ongoing.badge(), None);
        assert_eq!(
            TrayCountdown::Upcoming(128).tooltip(),
            "CalendarBar · До встречи 2 ч 8 мин"
        );
    }

    #[test]
    fn countdown_badges_render_distinct_pixels() {
        let mut seen = std::collections::HashSet::new();
        for minutes in 1..=100 {
            let icon = badge_icon(TrayCountdown::Upcoming(minutes).badge().unwrap());
            assert_eq!((icon.width(), icon.height()), (32, 32));
            assert_eq!(&icon.rgba()[..4], &[0; 4]);
            assert!(icon
                .rgba()
                .chunks_exact(4)
                .any(|pixel| pixel == NUMBER_COLOR));
            assert!(seen.insert(icon.rgba().to_vec()));
        }
    }
}
