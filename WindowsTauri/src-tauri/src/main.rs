#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod calendar;
mod dav;
mod engine;
mod model;
mod notifications;
mod operations;
mod platform;
mod tray_icon;

use engine::{publish, Engine, Navigation};
use model::{is_declined, now, Bounds, Range, MINUTE};
use serde_json::{json, Value};
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::NewWindowResponse,
    AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, RunEvent, Theme, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tokio::sync::Mutex;
use tray_icon::{TrayCountdown, TrayDisplay};

#[derive(Default)]
struct TrayAnchor(Mutex<Option<PhysicalPosition<f64>>>);

fn window_spec(view: &str) -> Option<(&'static str, f64, f64, f64, f64)> {
    Some(match view {
        "calendar" => ("CalendarBar", 1240., 780., 860., 600.),
        "settings" => ("Настройки CalendarBar", 800., 635., 720., 550.),
        "search" => ("Поиск встреч", 840., 645., 640., 500.),
        "meeting" => ("Встреча", 600., 650., 500., 460.),
        "activity" => ("Изменения и напоминания", 600., 620., 500., 470.),
        "pinned" => ("Закреплённые встречи", 520., 490., 440., 380.),
        "tray" => ("CalendarBar", 364., 280., 0., 0.),
        _ => return None,
    })
}

fn report(error: tauri::Error) -> String {
    error.to_string()
}

fn close_tray(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("tray") {
        let _ = window.close();
    }
}

pub fn open_window(
    app: &AppHandle,
    view: &str,
    navigation: Navigation,
) -> Result<WebviewWindow, String> {
    let (title, width, height, min_width, min_height) =
        window_spec(view).ok_or("Неизвестное окно.")?;
    let engine = app.state::<Engine>();
    engine.lock().set_navigation(view, navigation);
    if view != "tray" {
        close_tray(app);
    }
    if let Some(window) = app.get_webview_window(view) {
        window.unminimize().map_err(report)?;
        window.show().map_err(report)?;
        window.set_focus().map_err(report)?;
        let snapshot = engine.lock().snapshot(view);
        app.emit_to(view, "calendarbar-update", snapshot)
            .map_err(report)?;
        return Ok(window);
    }
    let saved = engine.lock().disk.bounds.get(view).cloned();
    let relative = format!("index.html?view={view}");
    let mut builder = WebviewWindowBuilder::new(app, view, WebviewUrl::App(relative.into()))
        .title(title)
        .inner_size(width, height)
        .center()
        .on_navigation(|url| {
            matches!(
                (url.scheme(), url.host_str()),
                ("tauri", Some("localhost")) | ("http" | "https", Some("tauri.localhost"))
            ) && matches!(url.path(), "/" | "/index.html")
        })
        .on_new_window(|_, _| NewWindowResponse::Deny);
    if view == "tray" {
        builder = builder
            .decorations(false)
            .skip_taskbar(true)
            .always_on_top(true)
            .resizable(false)
            .visible(false);
    } else {
        let area = app.primary_monitor().ok().flatten();
        let max = area
            .as_ref()
            .map(|m| {
                (
                    m.work_area().size.width as f64 / m.scale_factor(),
                    m.work_area().size.height as f64 / m.scale_factor(),
                )
            })
            .unwrap_or((width, height));
        builder = builder
            .min_inner_size(min_width.min(max.0), min_height.min(max.1))
            .inner_size(width.min(max.0), height.min(max.1));
    }
    let window = builder.build().map_err(report)?;
    if view != "tray" {
        if let Some(saved) = saved {
            restore_bounds(&window, saved);
        }
        let _ = window.set_focus();
    }
    Ok(window)
}

fn restore_bounds(window: &WebviewWindow, bounds: Bounds) {
    let monitor = window
        .monitor_from_point(f64::from(bounds.x), f64::from(bounds.y))
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let max = area.size;
        let width = bounds.width.min(max.width).max(1);
        let height = bounds.height.min(max.height).max(1);
        let x = bounds.x.clamp(
            area.position.x,
            area.position.x + max.width.saturating_sub(width) as i32,
        );
        let y = bounds.y.clamp(
            area.position.y,
            area.position.y + max.height.saturating_sub(height) as i32,
        );
        let _ = window.set_size(PhysicalSize::new(width, height));
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
}

pub fn apply_theme(app: &AppHandle, name: &str) {
    let theme = match name {
        "light" => Some(Theme::Light),
        "dark" => Some(Theme::Dark),
        _ => None,
    };
    app.set_theme(theme);
}

#[tauri::command]
fn get_state(window: WebviewWindow, engine: tauri::State<'_, Engine>) -> Value {
    engine.lock().snapshot(window.label())
}

async fn fit_tray(window: &WebviewWindow, height: u32) -> Result<(), String> {
    if window.label() != "tray" {
        return Ok(());
    }
    let anchor = window.state::<TrayAnchor>();
    let position = anchor.0.lock().await;
    let Some(position) = *position else {
        return Ok(());
    };
    let height = f64::from(height.clamp(132, 565));
    if let Some(monitor) = window
        .monitor_from_point(position.x, position.y)
        .map_err(report)?
        .or(window.primary_monitor().map_err(report)?)
    {
        let area = monitor.work_area();
        let x = area.position.x;
        let y = area.position.y;
        let right = x + area.size.width as i32;
        let bottom = y + area.size.height as i32;
        let scale = monitor.scale_factor();
        let width = ((364. * scale).round() as i32).min((area.size.width as i32 - 12).max(1));
        let height = ((height * scale).round() as i32).min((area.size.height as i32 - 12).max(1));
        let left = (position.x as i32 - width / 2).clamp(x + 4, (right - width - 4).max(x + 4));
        let top = if position.y as i32 >= y + area.size.height as i32 / 2 {
            bottom - height - 6
        } else {
            y + 6
        };
        let size = PhysicalSize::new(width as u32, height as u32);
        if window.outer_size().map_err(report)? != size {
            window.set_size(size).map_err(report)?;
        }
        let origin = PhysicalPosition::new(left, top);
        if window.outer_position().map_err(report)? != origin {
            window.set_position(origin).map_err(report)?;
        }
    }
    if !window.is_visible().map_err(report)? {
        window.show().map_err(report)?;
        window.set_focus().map_err(report)?;
    }
    Ok(())
}

async fn toggle_tray(app: &AppHandle, position: PhysicalPosition<f64>) -> Result<(), String> {
    let anchor = app.state::<TrayAnchor>();
    let mut anchor = anchor.0.lock().await;
    if let Some(window) = app.get_webview_window("tray") {
        *anchor = None;
        return window.close().map_err(report);
    }
    open_window(app, "tray", Navigation::default())?;
    *anchor = Some(position);
    Ok(())
}

fn dismiss_unfocused_tray(window: WebviewWindow) {
    tauri::async_runtime::spawn(async move {
        // The taskbar and WebView2 can report a brief blur during activation.
        tokio::time::sleep(Duration::from_millis(250)).await;
        let _ = window.run_on_main_thread({
            let window = window.clone();
            move || {
                if window.is_visible().unwrap_or(false) && !tray_is_foreground(&window) {
                    let _ = window.close();
                }
            }
        });
    });
}

#[cfg(windows)]
fn tray_is_foreground(window: &WebviewWindow) -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

    window
        .hwnd()
        .map_or(true, |hwnd| hwnd.0 == unsafe { GetForegroundWindow() })
}

#[cfg(not(windows))]
fn tray_is_foreground(window: &WebviewWindow) -> bool {
    window.is_focused().unwrap_or(true)
}

pub fn update_tray(app: &AppHandle) {
    let Some(tray) = app.tray_by_id("calendarbar") else {
        return;
    };
    let engine = app.state::<Engine>();
    let current = now();
    let countdown =
        {
            let data = engine.lock();
            let limit = data.disk.preferences().menu_countdown_window;
            let mut next = i64::MAX;
            let mut ongoing = false;
            if limit > 0 {
                for account in data.disk.active().filter(|profile| profile.visible) {
                    for meeting in account.meetings().filter(|meeting| {
                        !meeting.all_day
                            && !meeting.cancelled
                            && meeting.end > current
                            && meeting.start <= current + limit * MINUTE
                    }) {
                        if !account.calendars.iter().any(|cal| {
                            cal.info.id == meeting.calendar_id && cal.listed && cal.visible
                        }) || is_declined(meeting, &account.login)
                        {
                            continue;
                        }
                        if meeting.start <= current {
                            ongoing = true;
                            break;
                        }
                        next = next.min(meeting.start);
                    }
                    if ongoing {
                        break;
                    }
                }
            }
            if ongoing {
                TrayCountdown::Ongoing
            } else if next != i64::MAX {
                let minutes = (next - current + MINUTE - 1) / MINUTE;
                TrayCountdown::Upcoming(minutes)
            } else {
                TrayCountdown::Hidden
            }
        };
    // Serialize icon changes on the UI thread. The tooltip still has the exact
    // time for countdowns that won't fit in two digits.
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Err(error) = handle.state::<TrayDisplay>().update(&tray, countdown) {
            eprintln!("Не удалось обновить значок CalendarBar: {error}");
        }
    });
}

fn date_value(input: &Value) -> Result<i64, String> {
    input
        .as_i64()
        .filter(|at| chrono::DateTime::from_timestamp_millis(*at).is_some())
        .ok_or_else(|| "Укажите корректную дату.".into())
}

fn range(payload: &Value) -> Result<Range, String> {
    Range::checked(date_value(&payload["from"])?, date_value(&payload["to"])?)
}

async fn handle(
    app: &AppHandle,
    window: &WebviewWindow,
    action: &str,
    payload: &Value,
) -> Result<Value, String> {
    let view = window.label();
    match action {
        "open" => {
            let nav = Navigation {
                meeting: payload["meeting"].as_str().map(str::to_owned),
                date: payload["date"].as_i64(),
                query: payload["query"].as_str().map(str::to_owned),
                ..Default::default()
            };
            open_window(app, payload["view"].as_str().unwrap_or_default(), nav)?;
        }
        "close" => window.close().map_err(report)?,
        "fitTray" => {
            fit_tray(
                window,
                payload["height"].as_u64().unwrap_or(280).min(565) as u32,
            )
            .await?
        }
        "quit" => app.exit(0),
        "connect" => engine::connect(app, payload).await?,
        "sync" => {
            if payload["from"].is_number() && payload["to"].is_number() {
                engine::refresh(app, Some(view), Some(range(payload)?), true, None, false).await?;
                engine::spawn_refresh(app, None);
            } else {
                engine::refresh(app, None, None, true, None, false).await?;
            }
        }
        "load" | "search" => {
            engine::refresh(
                app,
                Some(view),
                Some(range(payload)?),
                payload["force"] == true,
                None,
                false,
            )
            .await?;
        }
        "join" | "browser" => notifications::open_link(
            payload["url"].as_str().unwrap_or_default(),
            action == "join",
        )?,
        "copyLink" => notifications::valid_copy(payload["url"].as_str().unwrap_or_default())?,
        "create" => {
            let start = date_value(&payload["start"])?;
            let end = if payload["end"].is_null() {
                None
            } else {
                Some(date_value(&payload["end"])?)
            };
            notifications::open_link(
                &calendar::yandex_create_url(start, end, model::display_zone())?,
                false,
            )?;
        }
        "edit" => {
            let engine = app.state::<Engine>();
            let data = engine.lock();
            let event = data
                .disk
                .event(payload["id"].as_str().unwrap_or_default())
                .ok_or("Встреча недоступна.")?;
            let url = calendar::yandex_edit_url(event, model::display_zone())?;
            drop(data);
            notifications::open_link(&url, false)?;
        }
        "testNotification" => notifications::test(app.clone()),
        "notificationSettings" => notifications::notification_settings()?,
        "clearCalendarCache" if view != "settings" => {
            return Err("Очистка кэша доступна в настройках.".into())
        }
        "settings" | "account" | "disconnect" | "calendar" | "pin" | "hideLast" | "reminder"
        | "color" | "markActivity" | "clearActivity" | "snooze" | "clearCalendarCache" => {
            return operations::mutate(app, action, payload)
        }
        _ => return Err("Неизвестное действие.".into()),
    }
    Ok(json!({}))
}

#[tauri::command]
async fn run_action(
    app: AppHandle,
    window: WebviewWindow,
    action: String,
    payload: Value,
) -> Value {
    match handle(&app, &window, &action, &payload).await {
        Ok(mut value) => {
            value["ok"] = json!(true);
            value
        }
        Err(error) => json!({ "ok": false, "error": error }),
    }
}

fn open_default(app: &AppHandle) -> Result<(), String> {
    let view = if app.state::<Engine>().lock().disk.accounts.is_empty() {
        "settings"
    } else {
        "calendar"
    };
    open_window(app, view, Navigation::default()).map(|_| ())
}

fn handle_launch(app: &AppHandle, args: Vec<String>) -> Result<(), String> {
    if let Some(url) = platform::activation_arg(args.iter().cloned()) {
        if notifications::handle_activation(app, &url).is_err() {
            open_window(app, "calendar", Navigation::default())?;
        }
    } else if !args.iter().any(|arg| arg == "--background") {
        open_default(app)?;
    }
    Ok(())
}

fn setup_tray(app: &tauri::App) -> tauri::Result<()> {
    let main = MenuItem::with_id(app, "calendar", "Календарь", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Настройки…", true, None::<&str>)?;
    let search = MenuItem::with_id(app, "search", "Поиск встреч", true, None::<&str>)?;
    let pinned = MenuItem::with_id(app, "pinned", "Закреплённые встречи…", true, None::<&str>)?;
    let activity = MenuItem::with_id(
        app,
        "activity",
        "Изменения и напоминания",
        true,
        None::<&str>,
    )?;
    let refresh = MenuItem::with_id(app, "refresh", "Обновить", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Выход", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[
            &main, &settings, &search, &pinned, &activity, &refresh, &quit,
        ],
    )?;
    let icon = tray_icon::default_icon()?;
    TrayIconBuilder::with_id("calendarbar")
        .icon(icon)
        .tooltip("CalendarBar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "quit" => app.exit(0),
            "refresh" => engine::spawn_refresh(app, None),
            view => {
                if let Err(error) = open_window(app, view, Navigation::default()) {
                    eprintln!("{error}");
                }
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                position,
                ..
            } = event
            {
                let app = tray.app_handle().clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = toggle_tray(&app, position).await {
                        eprintln!("{error}");
                    }
                });
            }
        })
        .build(app)?;
    Ok(())
}

fn main() {
    let app = tauri::Builder::default()
        .manage(TrayAnchor::default())
        .manage(TrayDisplay::default())
        .plugin(tauri_plugin_single_instance::init(|app, args, _| {
            if app.try_state::<Engine>().is_some() {
                if let Err(error) = handle_launch(app, args) {
                    eprintln!("{error}");
                }
            }
        }))
        .invoke_handler(tauri::generate_handler![get_state, run_action])
        .on_window_event(|window, event| {
            let app = window.app_handle();
            let view = window.label();
            match event {
                WindowEvent::Focused(false) if view == "tray" => {
                    if let Some(popup) = app.get_webview_window(view) {
                        if popup.is_visible().unwrap_or(false) {
                            dismiss_unfocused_tray(popup);
                        }
                    }
                }
                WindowEvent::CloseRequested { .. } if view != "tray" => {
                    if !window.is_minimized().unwrap_or(true)
                        && !window.is_maximized().unwrap_or(true)
                    {
                        if let (Ok(pos), Ok(size)) = (window.outer_position(), window.inner_size())
                        {
                            engine::remember_bounds(
                                app,
                                view,
                                Bounds {
                                    x: pos.x,
                                    y: pos.y,
                                    width: size.width,
                                    height: size.height,
                                },
                            );
                        }
                    }
                }
                WindowEvent::Destroyed => app.state::<Engine>().lock().remove_view(view),
                WindowEvent::Focused(true) => publish(app),
                _ => {}
            }
        })
        .setup(|app| {
            debug_assert_eq!(app.config().identifier, platform::APP_ID);
            let data = app.path().app_data_dir()?.join("calendarbar.json");
            #[cfg(windows)]
            let legacy = std::env::var_os("APPDATA")
                .map(std::path::PathBuf::from)
                .map(|folder| folder.join("CalendarBar"));
            #[cfg(not(windows))]
            let legacy = None;
            let engine = Engine::open(data, legacy).map_err(std::io::Error::other)?;
            if let Err(error) = platform::initialize() {
                engine.lock().notification_status =
                    format!("Не удалось настроить уведомления: {error}");
            }
            if engine.lock().disk.globals.auto_start {
                if let Err(error) = platform::set_auto_start(true) {
                    eprintln!("Не удалось восстановить автозапуск CalendarBar: {error}");
                }
            }
            let appearance = engine.lock().disk.globals.appearance.clone();
            app.manage(engine);
            apply_theme(app.handle(), &appearance);
            setup_tray(app)?;
            handle_launch(app.handle(), std::env::args().collect())
                .map_err(std::io::Error::other)?;
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(notifications::run(handle.clone()));
            tauri::async_runtime::spawn(async move {
                loop {
                    update_tray(&handle);
                    engine::refresh_if_due(&handle).await;
                    tokio::time::sleep(Duration::from_secs(15)).await;
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build CalendarBar");
    app.run(|_, event| {
        if let RunEvent::ExitRequested {
            code: None, api, ..
        } = event
        {
            api.prevent_exit();
        }
    });
}
