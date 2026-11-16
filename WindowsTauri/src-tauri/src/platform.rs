use std::path::Path;
use url::Url;

pub const APP_ID: &str = "com.nbord.CalendarBar.Tauri";
pub const ACTIVATION_SCHEME: &str = "calendarbar-tauri-action";

#[derive(Debug)]
pub enum NotificationError {
    #[cfg_attr(not(windows), allow(dead_code))]
    Disabled(String),
    Failed(String),
}

impl std::fmt::Display for NotificationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Disabled(message) | Self::Failed(message) => formatter.write_str(message),
        }
    }
}

fn activation_url(input: &str) -> Option<Url> {
    let url = Url::parse(input).ok()?;
    if url.scheme() != ACTIVATION_SCHEME
        || !matches!(
            url.host_str(),
            Some("calendar" | "meeting" | "join" | "snooze" | "start" | "mute")
        )
        || !matches!(url.path(), "" | "/")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    Some(url)
}

pub fn activation_arg(args: impl IntoIterator<Item = String>) -> Option<Url> {
    args.into_iter().find_map(|arg| activation_url(&arg))
}

pub fn action_url(command: &str, meeting_id: Option<&str>, date: Option<i64>) -> String {
    let mut url = Url::parse(&format!("{ACTIVATION_SCHEME}://{command}"))
        .expect("constant notification action name");
    if let Some(id) = meeting_id {
        url.query_pairs_mut().append_pair("id", id);
    }
    if let Some(date) = date {
        url.query_pairs_mut().append_pair("date", &date.to_string());
    }
    url.into()
}

fn check_external(input: &str) -> bool {
    if input == "ms-settings:notifications" {
        return true;
    }
    if input.chars().any(char::is_control) {
        return false;
    }
    if let Some(target) = input.strip_prefix("telemost://") {
        let Ok(url) = Url::parse(target) else {
            return false;
        };
        let meeting = url.path().strip_prefix("/j/");
        return url.scheme() == "https"
            && url.port().is_none()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && matches!(
                url.host_str(),
                Some(
                    "telemost.yandex.ru"
                        | "telemost.360.yandex.ru"
                        | "telemost.yandex.com"
                        | "telemost.360.yandex.com"
                )
            )
            && meeting
                .is_some_and(|id| !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()));
    }
    Url::parse(input).is_ok_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.has_host()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

pub fn open_external(input: &str) -> Result<(), String> {
    if !check_external(input) {
        return Err("Недопустимая ссылка.".into());
    }
    imp::open_external(input)
}

#[cfg(any(target_os = "windows", test))]
fn xml_escape(value: &str, limit: usize) -> String {
    let mut escaped = String::new();
    for ch in value.chars().take(limit) {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            '\t'
            | '\n'
            | '\r'
            | '\u{0020}'..='\u{d7ff}'
            | '\u{e000}'..='\u{fffd}'
            | '\u{10000}'..='\u{10ffff}' => escaped.push(ch),
            _ => {}
        }
    }
    escaped
}

#[cfg(any(target_os = "windows", test))]
fn toast_xml(
    title: &str,
    body: &str,
    launch: &str,
    actions: &[(&str, &str)],
    logo: Option<&Url>,
) -> Result<String, String> {
    if activation_url(launch).is_none()
        || actions.iter().any(|(_, url)| activation_url(url).is_none())
    {
        return Err("Недопустимое действие уведомления.".into());
    }
    let mut xml = format!(
        r#"<toast activationType="protocol" launch="{}"><visual><binding template="ToastGeneric"><text>{}</text><text>{}</text>"#,
        xml_escape(launch, usize::MAX),
        xml_escape(title, 256),
        xml_escape(body, 500)
    );
    if let Some(logo) = logo {
        xml.push_str(&format!(
            r#"<image placement="appLogoOverride" src="{}"/>"#,
            xml_escape(logo.as_str(), usize::MAX)
        ));
    }
    xml.push_str("</binding></visual>");
    if !actions.is_empty() {
        xml.push_str("<actions>");
        for (label, url) in actions.iter().take(5) {
            xml.push_str(&format!(
                r#"<action content="{}" activationType="protocol" arguments="{}"/>"#,
                xml_escape(label, 128),
                xml_escape(url, usize::MAX)
            ));
        }
        xml.push_str("</actions>");
    }
    xml.push_str("</toast>");
    Ok(xml)
}

#[cfg(any(target_os = "windows", test))]
fn meeting_tag(id: &str) -> String {
    // Toast tags are limited to 16 characters. FNV-1a gives a stable key across restarts.
    let hash = id.bytes().fold(0xcbf29ce484222325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3)
    });
    format!("{hash:016x}")
}

pub use imp::{
    copy_text, import_electron_password, initialize, protect_password, remove_notification,
    set_auto_start, show_notification, unprotect_password,
};

#[cfg(target_os = "windows")]
mod imp {
    use super::{
        action_url, activation_url, meeting_tag, toast_xml, NotificationError, Path, Url,
        ACTIVATION_SCHEME, APP_ID,
    };
    use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
    use base64::{engine::general_purpose::STANDARD, Engine};
    use std::{
        ffi::{OsStr, OsString},
        io,
        mem::ManuallyDrop,
        os::windows::ffi::{OsStrExt, OsStringExt},
        ptr::{null, null_mut},
        slice,
    };
    use windows::{
        core::{Error as WinError, Interface, GUID, HRESULT, HSTRING, PCWSTR},
        Data::Xml::Dom::XmlDocument,
        Win32::{
            Foundation::{
                ERROR_NOT_FOUND, WPN_E_NOTIFICATION_DISABLED, WPN_E_NOTIFICATION_TYPE_DISABLED,
            },
            Storage::EnhancedStorage::{
                PKEY_AppUserModel_ID, PKEY_AppUserModel_ToastActivatorCLSID,
            },
            System::{
                Com::{
                    CoCreateInstance, CoTaskMemFree, IPersistFile,
                    StructuredStorage::{
                        InitPropVariantFromCLSID, PropVariantClear, PropVariantToGUID,
                        PropVariantToString, PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0,
                        PROPVARIANT_0_0_0,
                    },
                    CLSCTX_INPROC_SERVER, STGM_READWRITE,
                },
                Variant::VT_LPWSTR,
                WinRT::{RoInitialize, RoUninitialize, RO_INIT_SINGLETHREADED},
            },
            UI::Shell::{
                FOLDERID_Programs, IShellLinkW, PropertiesSystem::IPropertyStore, SHChangeNotify,
                SHGetKnownFolderPath, SHStrDupW, ShellLink, KF_FLAG_CREATE, SHCNE_CREATE,
                SHCNE_UPDATEITEM, SHCNF_FLUSH, SHCNF_PATHW, SLGP_RAWPATH,
            },
        },
        UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager},
    };
    use windows_sys::Win32::{
        Foundation::{GlobalFree, LocalFree, ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, HWND},
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
        System::{
            DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData},
            Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE},
            Registry::{
                RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegSetValueExW, HKEY,
                HKEY_CURRENT_USER, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
            },
        },
        UI::{
            Shell::{SetCurrentProcessExplicitAppUserModelID, ShellExecuteW},
            WindowsAndMessaging::{CreateWindowExW, DestroyWindow, HWND_MESSAGE, SW_SHOWNORMAL},
        },
    };
    use zeroize::{Zeroize, Zeroizing};

    const PASSWORD_PREFIX: &str = "dpapi:";
    const TOAST_GROUP: &str = "CalendarBar";
    const NOTIFICATION_ICON: &str = "calendarbar-notification.png";
    const TOAST_NOT_FOUND: HRESULT = HRESULT::from_win32(ERROR_NOT_FOUND.0);
    // The toast body and buttons all use protocol activation. No COM server is needed.
    const TOAST_ACTIVATOR: GUID = GUID::from_u128(0x9389962a_18c8_43b0_a291_612b0cf038bd);
    const TOAST_ACTIVATOR_TEXT: &str = "{9389962A-18C8-43B0-A291-612B0CF038BD}";
    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const RUN_NAME: &str = "CalendarBar Tauri";
    const CF_UNICODETEXT: u32 = 13;

    fn error(message: &str) -> String {
        format!("{message} ({})", io::Error::last_os_error())
    }

    fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
        value
            .as_ref()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    fn executable_command(suffix: &str) -> Result<Vec<u16>, String> {
        let exe = std::env::current_exe().map_err(|err| err.to_string())?;
        Ok("\""
            .encode_utf16()
            .chain(exe.as_os_str().encode_wide())
            .chain("\"".encode_utf16())
            .chain(suffix.encode_utf16())
            .chain(std::iter::once(0))
            .collect())
    }

    struct RegistryKey(HKEY);

    impl RegistryKey {
        fn create(path: &str) -> Result<Self, String> {
            let mut key = null_mut();
            let result = unsafe {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    wide(path).as_ptr(),
                    0,
                    null(),
                    REG_OPTION_NON_VOLATILE,
                    KEY_SET_VALUE,
                    null(),
                    &mut key,
                    null_mut(),
                )
            };
            if result == 0 {
                Ok(Self(key))
            } else {
                Err(format!("Ошибка доступа к реестру Windows ({result})."))
            }
        }

        fn set(&self, name: Option<&str>, value: &[u16]) -> Result<(), String> {
            let name = name.map(wide);
            let name = name.as_ref().map_or(null(), |key| key.as_ptr());
            let status = unsafe {
                RegSetValueExW(
                    self.0,
                    name,
                    0,
                    REG_SZ,
                    value.as_ptr().cast(),
                    (value.len() * 2) as u32,
                )
            };
            if status == 0 {
                Ok(())
            } else {
                Err(format!("Не удалось записать настройку Windows ({status})."))
            }
        }
    }

    impl Drop for RegistryKey {
        fn drop(&mut self) {
            unsafe {
                RegCloseKey(self.0);
            }
        }
    }

    pub fn initialize() -> Result<(), String> {
        let status = unsafe { SetCurrentProcessExplicitAppUserModelID(wide(APP_ID).as_ptr()) };
        if status < 0 {
            return Err(format!(
                "Не удалось зарегистрировать идентификатор CalendarBar ({status:#x})."
            ));
        }
        register_notification_sender()
    }

    fn register_notification_sender() -> Result<(), String> {
        let scheme = format!(r"Software\Classes\{ACTIVATION_SCHEME}");
        let key = RegistryKey::create(&scheme)?;
        key.set(None, &wide("URL:CalendarBar"))?;
        key.set(Some("URL Protocol"), &wide(""))?;
        RegistryKey::create(&format!(r"{scheme}\shell\open\command"))?
            .set(None, &executable_command(" \"%1\"")?)?;
        let app_key = RegistryKey::create(&format!(r"Software\Classes\AppUserModelId\{APP_ID}"))?;
        app_key.set(Some("DisplayName"), &wide("CalendarBar"))?;
        app_key.set(Some("CustomActivator"), &wide(TOAST_ACTIVATOR_TEXT))?;
        if let Some(icon) = notification_icon_path() {
            if let Err(err) = app_key.set(Some("IconUri"), &wide(icon)) {
                eprintln!("Не удалось зарегистрировать значок уведомлений CalendarBar: {err}");
            }
        }
        ensure_notification_shortcut()
            .map_err(|err| format!("Не удалось зарегистрировать ярлык для уведомлений: {err}"))
    }

    fn notification_icon_path() -> Option<std::path::PathBuf> {
        let icon = std::env::current_exe()
            .ok()?
            .with_file_name(NOTIFICATION_ICON);
        icon.is_file().then_some(icon)
    }

    struct PropertyValue(PROPVARIANT);

    impl PropertyValue {
        fn string(value: &[u16]) -> windows::core::Result<Self> {
            let value = unsafe { SHStrDupW(PCWSTR(value.as_ptr()))? };
            Ok(Self(PROPVARIANT {
                Anonymous: PROPVARIANT_0 {
                    Anonymous: ManuallyDrop::new(PROPVARIANT_0_0 {
                        vt: VT_LPWSTR,
                        Anonymous: PROPVARIANT_0_0_0 { pwszVal: value },
                        ..Default::default()
                    }),
                },
            }))
        }
    }

    impl Drop for PropertyValue {
        fn drop(&mut self) {
            let _ = unsafe { PropVariantClear(&mut self.0) };
        }
    }

    fn ensure_notification_shortcut() -> Result<(), String> {
        let _apartment = Apartment::enter()?;
        let programs = unsafe {
            let path = SHGetKnownFolderPath(&FOLDERID_Programs, KF_FLAG_CREATE, None)
                .map_err(|err| err.to_string())?;
            let programs = std::path::PathBuf::from(OsString::from_wide(path.as_wide()));
            CoTaskMemFree(Some(path.0.cast()));
            programs
        };
        let exe = std::env::current_exe().map_err(|err| err.to_string())?;
        // If CalendarBar.lnk points to the Electron edition, keep its shortcut.
        for directory in [&programs, &programs.join("CalendarBar")] {
            std::fs::create_dir_all(directory).map_err(|err| err.to_string())?;
            let shortcut = directory.join("CalendarBar.lnk");
            let exists = shortcut.try_exists().map_err(|err| err.to_string())?;
            if repair_notification_shortcut(&shortcut, &exe, exists)
                .map_err(|err| err.to_string())?
            {
                return Ok(());
            }
        }
        Err("Ярлыки CalendarBar в меню «Пуск» заняты другим приложением.".into())
    }

    fn repair_notification_shortcut(
        shortcut: &Path,
        exe: &Path,
        exists: bool,
    ) -> windows::core::Result<bool> {
        let shortcut = wide(shortcut);
        let path = PCWSTR(shortcut.as_ptr());
        let app_id = wide(APP_ID);
        unsafe {
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
            let file: IPersistFile = link.cast()?;
            if exists {
                let mut target = [0; 32768];
                if file.Load(path, STGM_READWRITE).is_err()
                    || link
                        .GetPath(&mut target, null_mut(), SLGP_RAWPATH.0 as u32)
                        .is_err()
                {
                    return Ok(false);
                }
                let length = target
                    .iter()
                    .position(|unit| *unit == 0)
                    .unwrap_or(target.len());
                let target = OsString::from_wide(&target[..length]);
                if !target.eq_ignore_ascii_case(exe.as_os_str()) {
                    return Ok(false);
                }
            } else {
                let exe = wide(exe);
                link.SetPath(PCWSTR(exe.as_ptr()))?;
            }

            let properties: IPropertyStore = link.cast()?;
            if exists && shortcut_has_notification_identity(&properties, &app_id) {
                return Ok(true);
            }
            let id = PropertyValue::string(&app_id)?;
            let activator = PropertyValue(InitPropVariantFromCLSID(&TOAST_ACTIVATOR)?);
            properties.SetValue(&PKEY_AppUserModel_ID, &id.0)?;
            properties.SetValue(&PKEY_AppUserModel_ToastActivatorCLSID, &activator.0)?;
            properties.Commit()?;
            file.Save(path, true)?;
            SHChangeNotify(
                if exists {
                    SHCNE_UPDATEITEM
                } else {
                    SHCNE_CREATE
                },
                SHCNF_PATHW | SHCNF_FLUSH,
                Some(shortcut.as_ptr().cast()),
                None,
            );
        }
        Ok(true)
    }

    fn shortcut_has_notification_identity(properties: &IPropertyStore, app_id: &[u16]) -> bool {
        let mut value = [0; 128];
        unsafe {
            properties
                .GetValue(&PKEY_AppUserModel_ID)
                .map(PropertyValue)
                .is_ok_and(|id| {
                    PropVariantToString(&id.0, &mut value).is_ok() && value.starts_with(app_id)
                })
                && properties
                    .GetValue(&PKEY_AppUserModel_ToastActivatorCLSID)
                    .map(PropertyValue)
                    .and_then(|activator| PropVariantToGUID(&activator.0))
                    .is_ok_and(|guid| guid == TOAST_ACTIVATOR)
        }
    }

    pub fn set_auto_start(enabled: bool) -> Result<(), String> {
        if enabled {
            return RegistryKey::create(RUN_KEY)?
                .set(Some(RUN_NAME), &executable_command(" --background")?);
        }
        let mut key = null_mut();
        let status = unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                wide(RUN_KEY).as_ptr(),
                0,
                KEY_SET_VALUE,
                &mut key,
            )
        };
        match status {
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => return Ok(()),
            0 => {}
            code => {
                return Err(format!(
                    "Не удалось открыть настройки автозапуска ({code})."
                ))
            }
        }
        let key = RegistryKey(key);
        match unsafe { RegDeleteValueW(key.0, wide(RUN_NAME).as_ptr()) } {
            0 | ERROR_FILE_NOT_FOUND => Ok(()),
            code => Err(format!("Не удалось отключить автозапуск ({code}).")),
        }
    }

    fn dpapi(data: &[u8], encrypt: bool) -> Result<Zeroizing<Vec<u8>>, String> {
        if data.is_empty() {
            return Err("Пустой пароль или ключ шифрования.".into());
        }
        let size = u32::try_from(data.len()).map_err(|_| "Слишком большой пароль или ключ.")?;
        let source = CRYPT_INTEGER_BLOB {
            cbData: size,
            pbData: data.as_ptr().cast_mut(),
        };
        let mut result = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };
        let success = unsafe {
            if encrypt {
                CryptProtectData(
                    &source,
                    null(),
                    null(),
                    null(),
                    null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut result,
                )
            } else {
                CryptUnprotectData(
                    &source,
                    null_mut(),
                    null(),
                    null(),
                    null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut result,
                )
            }
        };
        if success == 0 {
            return Err(error(
                "Не удалось получить доступ к защищённым данным Windows.",
            ));
        }
        if result.pbData.is_null() {
            return Err("Хранилище паролей Windows вернуло пустые данные.".into());
        }
        let output = unsafe {
            let bytes = slice::from_raw_parts_mut(result.pbData, result.cbData as usize);
            let saved = Zeroizing::new(bytes.to_vec());
            bytes.zeroize();
            LocalFree(result.pbData.cast());
            saved
        };
        Ok(output)
    }

    pub fn protect_password(password: &str) -> Result<String, String> {
        let result = dpapi(password.as_bytes(), true)?;
        Ok(format!(
            "{PASSWORD_PREFIX}{}",
            STANDARD.encode(result.as_slice())
        ))
    }

    pub fn unprotect_password(value: &str) -> Result<String, String> {
        let ciphertext = value
            .strip_prefix(PASSWORD_PREFIX)
            .and_then(|encoded| STANDARD.decode(encoded).ok())
            .ok_or_else(|| {
                "Пароль сохранён в неизвестном формате. Введите его заново.".to_string()
            })?;
        let plain = dpapi(&ciphertext, false)?;
        Ok(std::str::from_utf8(&plain)
            .map_err(|_| "Не удалось расшифровать сохранённый пароль.")?
            .to_owned())
    }

    pub fn import_electron_password(value: &str, local_state: &Path) -> Result<String, String> {
        let failed = || {
            "Не удалось перенести пароль из CalendarBar 0.6.4. Введите пароль приложения заново."
                .to_string()
        };
        let encrypted = STANDARD.decode(value).map_err(|_| failed())?;
        let plain = if let Some(encrypted) = encrypted.strip_prefix(b"v10") {
            if encrypted.len() < 12 + 16 {
                return Err(failed());
            }
            let state = std::fs::read(local_state).map_err(|_| failed())?;
            let state: serde_json::Value = serde_json::from_slice(&state).map_err(|_| failed())?;
            let encoded = state
                .pointer("/os_crypt/encrypted_key")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(failed)?;
            let protected_key = STANDARD.decode(encoded).map_err(|_| failed())?;
            let key = dpapi(
                protected_key.strip_prefix(b"DPAPI").ok_or_else(failed)?,
                false,
            )
            .map_err(|_| failed())?;
            let decryptor = Aes256Gcm::new_from_slice(&key).map_err(|_| failed())?;
            let (nonce, ciphertext) = encrypted.split_at(12);
            Zeroizing::new(
                decryptor
                    .decrypt(Nonce::from_slice(nonce), ciphertext)
                    .map_err(|_| failed())?,
            )
        } else {
            // Older versions used DPAPI directly for each value.
            dpapi(&encrypted, false).map_err(|_| failed())?
        };
        protect_password(std::str::from_utf8(&plain).map_err(|_| failed())?)
    }

    pub fn open_external(url: &str) -> Result<(), String> {
        let _apartment = Apartment::enter()?;
        let code = unsafe {
            ShellExecuteW(
                null_mut(),
                wide("open").as_ptr(),
                wide(url).as_ptr(),
                null(),
                null(),
                SW_SHOWNORMAL,
            )
        } as isize;
        if code > 32 {
            Ok(())
        } else {
            Err(format!("Windows не смогла открыть ссылку ({code})."))
        }
    }

    struct ClipboardOwner(HWND);

    impl Drop for ClipboardOwner {
        fn drop(&mut self) {
            unsafe {
                DestroyWindow(self.0);
            }
        }
    }

    struct OpenedClipboard;
    impl Drop for OpenedClipboard {
        fn drop(&mut self) {
            unsafe {
                CloseClipboard();
            }
        }
    }

    pub fn copy_text(text: &str) -> Result<(), String> {
        if text.contains('\0') {
            return Err("Текст содержит недопустимый символ.".into());
        }
        let data = wide(text);
        let hwnd = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                0,
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                null_mut(),
                null_mut(),
                null(),
            )
        };
        if hwnd.is_null() {
            return Err(error("Не удалось открыть буфер обмена."));
        }
        let owner = ClipboardOwner(hwnd);
        if unsafe { OpenClipboard(owner.0) } == 0 {
            return Err(error("Буфер обмена Windows занят."));
        }
        let _clipboard = OpenedClipboard;
        let memory = unsafe { GlobalAlloc(GMEM_MOVEABLE, data.len() * 2) };
        if memory.is_null() {
            return Err(error("Не удалось выделить память для буфера обмена."));
        }
        let target = unsafe { GlobalLock(memory) }.cast::<u16>();
        if target.is_null() {
            unsafe {
                GlobalFree(memory);
            }
            return Err(error("Не удалось получить память буфера обмена."));
        }
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
            GlobalUnlock(memory);
            if EmptyClipboard() == 0 || SetClipboardData(CF_UNICODETEXT, memory).is_null() {
                let message = error("Не удалось скопировать текст.");
                GlobalFree(memory);
                return Err(message);
            }
        }
        // Windows owns the allocation after SetClipboardData succeeds.
        Ok(())
    }

    struct Apartment(bool);

    impl Apartment {
        fn enter() -> Result<Self, String> {
            match unsafe { RoInitialize(RO_INIT_SINGLETHREADED) } {
                Ok(()) => Ok(Self(true)),
                Err(err) if err.code().0 as u32 == 0x80010106 => Ok(Self(false)),
                Err(err) => Err(err.to_string()),
            }
        }
    }

    impl Drop for Apartment {
        fn drop(&mut self) {
            if self.0 {
                unsafe {
                    RoUninitialize();
                }
            }
        }
    }

    pub fn show_notification(
        title: &str,
        body: &str,
        launch: Option<&str>,
        actions: &[(&str, &str)],
    ) -> Result<(), NotificationError> {
        let _apartment = Apartment::enter()
            .map_err(|err| NotificationError::Failed(format!("Инициализация WinRT: {err}")))?;
        let default_url = action_url("calendar", None, None);
        let launch = launch.unwrap_or(&default_url);
        let logo = notification_icon_path().and_then(|icon| Url::from_file_path(icon).ok());
        let content = toast_xml(title, body, launch, actions, logo.as_ref())
            .map_err(NotificationError::Failed)?;
        let xml = XmlDocument::new().map_err(|err| toast_error("Создание XML", err))?;
        xml.LoadXml(&HSTRING::from(content))
            .map_err(|err| toast_error("Чтение XML", err))?;
        let toast = ToastNotification::CreateToastNotification(&xml)
            .map_err(|err| toast_error("Создание уведомления", err))?;
        if let Some(url) = activation_url(launch) {
            if let Some((_, meeting)) = url.query_pairs().find(|(name, _)| name == "id") {
                toast
                    .SetGroup(&HSTRING::from(TOAST_GROUP))
                    .map_err(|err| toast_error("Группа уведомления", err))?;
                toast
                    .SetTag(&HSTRING::from(meeting_tag(&meeting)))
                    .map_err(|err| toast_error("Метка уведомления", err))?;
            }
        }

        let shown = send_to_windows(&toast);
        if matches!(&shown, Err(ToastDeliveryError::Operation(_, err)) if err.code() == TOAST_NOT_FOUND)
        {
            // A renamed or upgraded installation can leave stale shell metadata.
            register_notification_sender().map_err(|err| {
                NotificationError::Failed(format!("Повторная регистрация отправителя: {err}"))
            })?;
            return send_to_windows(&toast).map_err(NotificationError::from);
        }
        shown.map_err(NotificationError::from)
    }

    enum ToastDeliveryError {
        Operation(&'static str, WinError),
        Setting(NotificationSetting),
    }

    impl From<ToastDeliveryError> for NotificationError {
        fn from(error: ToastDeliveryError) -> Self {
            match error {
                ToastDeliveryError::Operation(stage, err) => toast_error(stage, err),
                ToastDeliveryError::Setting(setting) => match setting {
                    NotificationSetting::DisabledForApplication => Self::Disabled(
                        "Уведомления CalendarBar отключены в параметрах Windows.".into(),
                    ),
                    NotificationSetting::DisabledForUser => Self::Disabled(
                        "Системные уведомления отключены для пользователя Windows.".into(),
                    ),
                    NotificationSetting::DisabledByGroupPolicy => {
                        Self::Disabled("Уведомления отключены политикой Windows.".into())
                    }
                    NotificationSetting::DisabledByManifest => Self::Disabled(
                        "Windows запретила уведомления согласно манифесту приложения.".into(),
                    ),
                    _ => Self::Failed(format!(
                        "Windows вернула неизвестное состояние уведомлений ({}).",
                        setting.0
                    )),
                },
            }
        }
    }

    fn toast_error(stage: &str, error: WinError) -> NotificationError {
        let code = error.code();
        let message = format!("{stage}: {} (0x{:08X}).", error.message(), code.0 as u32);
        if matches!(
            code,
            WPN_E_NOTIFICATION_DISABLED | WPN_E_NOTIFICATION_TYPE_DISABLED
        ) {
            NotificationError::Disabled(message)
        } else {
            NotificationError::Failed(message)
        }
    }

    fn send_to_windows(toast: &ToastNotification) -> Result<(), ToastDeliveryError> {
        use ToastDeliveryError::{Operation, Setting};

        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))
            .map_err(|err| Operation("Открытие отправителя CalendarBar", err))?;
        match notifier.Setting() {
            Ok(NotificationSetting::Enabled) => {}
            Ok(state) => return Err(Setting(state)),
            // For unpackaged Win32 apps this lookup can fail before Show has
            // registered the sender. The Windows notification service still
            // enforces its settings when it receives the toast.
            Err(err) if err.code() == TOAST_NOT_FOUND => {}
            Err(err) => return Err(Operation("Проверка параметров уведомлений Windows", err)),
        }
        notifier
            .Show(toast)
            .map_err(|err| Operation("Отправка уведомления в Windows", err))
    }

    pub fn remove_notification(meeting_id: &str) -> Result<(), String> {
        let _apartment = Apartment::enter()?;
        ToastNotificationManager::History()
            .and_then(|history| {
                history.RemoveGroupedTagWithId(
                    &HSTRING::from(meeting_tag(meeting_id)),
                    &HSTRING::from(TOAST_GROUP),
                    &HSTRING::from(APP_ID),
                )
            })
            .map_err(|err| err.to_string())
    }

    #[cfg(test)]
    #[test]
    fn writes_notification_identity_only_to_our_shortcut() {
        let _apartment = Apartment::enter().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let shortcut = directory.path().join("CalendarBar.lnk");
        let exe = std::env::current_exe().unwrap();
        let link: IShellLinkW =
            unsafe { CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).unwrap() };
        let file: IPersistFile = link.cast().unwrap();
        let path = wide(&shortcut);
        let target = wide(&exe);
        unsafe {
            link.SetPath(PCWSTR(target.as_ptr())).unwrap();
            file.Save(PCWSTR(path.as_ptr()), true).unwrap();
        }
        let original = std::fs::read(&shortcut).unwrap();
        assert!(
            !repair_notification_shortcut(&shortcut, &exe.with_file_name("other.exe"), true)
                .unwrap()
        );
        assert_eq!(std::fs::read(&shortcut).unwrap(), original);
        assert!(repair_notification_shortcut(&shortcut, &exe, true).unwrap());
        unsafe { file.Load(PCWSTR(path.as_ptr()), STGM_READWRITE).unwrap() };
        assert!(shortcut_has_notification_identity(
            &link.cast().unwrap(),
            &wide(APP_ID),
        ));
    }

    #[cfg(test)]
    #[test]
    fn upgrades_authenticated_electron_ciphertext_to_dpapi() {
        use std::io::Write;

        let key = [42; 32];
        let nonce = [7; 12];
        let password = "fixture-only calendar password";
        let mut wrapped_key = b"DPAPI".to_vec();
        wrapped_key.extend_from_slice(&dpapi(&key, true).unwrap());
        let mut file = tempfile::NamedTempFile::new().unwrap();
        write!(
            file,
            "{{\"os_crypt\":{{\"encrypted_key\":\"{}\"}}}}",
            STANDARD.encode(wrapped_key)
        )
        .unwrap();
        file.flush().unwrap();

        let mut legacy = b"v10".to_vec();
        legacy.extend_from_slice(&nonce);
        let ciphertext = Aes256Gcm::new_from_slice(&key)
            .unwrap()
            .encrypt(Nonce::from_slice(&nonce), password.as_bytes())
            .unwrap();
        legacy.extend_from_slice(&ciphertext);
        let upgraded = import_electron_password(&STANDARD.encode(&legacy), file.path()).unwrap();
        assert!(upgraded.starts_with(PASSWORD_PREFIX));
        assert_eq!(unprotect_password(&upgraded).unwrap(), password);
        let last = legacy.last_mut().unwrap();
        *last ^= 1;
        assert!(import_electron_password(&STANDARD.encode(&legacy), file.path()).is_err());
    }
}

#[cfg(not(target_os = "windows"))]
mod imp {
    use super::NotificationError;
    use super::Path;

    const WINDOWS_ONLY: &str = "Эта возможность доступна в установленном приложении Windows.";

    pub fn initialize() -> Result<(), String> {
        Ok(())
    }

    pub fn protect_password(_password: &str) -> Result<String, String> {
        Err(WINDOWS_ONLY.into())
    }

    pub fn unprotect_password(_value: &str) -> Result<String, String> {
        Err(WINDOWS_ONLY.into())
    }

    pub fn import_electron_password(_value: &str, _local_state: &Path) -> Result<String, String> {
        Err(WINDOWS_ONLY.into())
    }

    pub fn set_auto_start(_enabled: bool) -> Result<(), String> {
        Err(WINDOWS_ONLY.into())
    }

    pub fn open_external(url: &str) -> Result<(), String> {
        let command = if cfg!(target_os = "macos") {
            "/usr/bin/open"
        } else {
            "xdg-open"
        };
        let launched = std::process::Command::new(command)
            .arg(url)
            .status()
            .map_err(|err| err.to_string())?;
        if launched.success() {
            Ok(())
        } else {
            Err("Не удалось открыть ссылку.".into())
        }
    }

    pub fn copy_text(text: &str) -> Result<(), String> {
        use std::{
            io::Write,
            process::{Command, Stdio},
        };
        if !cfg!(target_os = "macos") {
            return Err(WINDOWS_ONLY.into());
        }
        let mut child = Command::new("/usr/bin/pbcopy")
            .stdin(Stdio::piped())
            .spawn()
            .map_err(|err| err.to_string())?;
        let written = child
            .stdin
            .take()
            .expect("piped stdin")
            .write_all(text.as_bytes());
        let status = child.wait().map_err(|err| err.to_string())?;
        written.map_err(|err| err.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("Не удалось скопировать текст.".into())
        }
    }

    pub fn show_notification(
        _title: &str,
        _body: &str,
        _launch: Option<&str>,
        _actions: &[(&str, &str)],
    ) -> Result<(), NotificationError> {
        Err(NotificationError::Failed(WINDOWS_ONLY.into()))
    }

    pub fn remove_notification(_meeting_id: &str) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_actions_round_trip_and_xml_escapes_untrusted_text() {
        let destination = action_url("meeting", Some("one & два"), Some(15));
        let action = action_url("snooze", Some("one & два"), None);
        let url = activation_arg([String::from("--background"), destination.clone()]).unwrap();
        assert_eq!(url.host_str(), Some("meeting"));
        assert_eq!(url.query_pairs().next().unwrap().1, "one & два");
        let xml = toast_xml(
            "Title < &",
            "body\u{1}",
            &destination,
            &[("Later \"", &action)],
            None,
        )
        .unwrap();
        assert!(xml.contains("Title &lt; &amp;"));
        assert!(xml.contains("&amp;date=15"));
        assert!(xml.contains("Later &quot;"));
        assert!(!xml.contains('\u{1}'));
        assert!(toast_xml(
            "",
            "",
            &destination,
            &[("Open", "https://example.test")],
            None
        )
        .is_err());
        assert_eq!(meeting_tag("same").len(), 16);
        assert_ne!(meeting_tag("same"), meeting_tag("different"));
    }

    #[test]
    fn toast_logo_preserves_local_uri_and_optional_text_only_payload() {
        let destination = action_url("calendar", None, None);
        let icon =
            Url::parse("file:///C:/Users/Name%20%26%20Co/CalendarBar/calendarbar-notification.png")
                .unwrap();
        for logo in [Some(&icon), None] {
            let xml = toast_xml("CalendarBar", "Test", &destination, &[], logo).unwrap();
            let document = roxmltree::Document::parse(&xml).unwrap();
            let image = document
                .descendants()
                .find(|node| node.has_tag_name("image"));
            assert_eq!(
                image.map(|node| (node.attribute("placement"), node.attribute("src"))),
                logo.map(|url| (Some("appLogoOverride"), Some(url.as_str())))
            );
        }
    }

    #[test]
    fn restrict_shell_destinations_and_notification_activation() {
        assert!(check_external("https://example.test"));
        assert!(check_external(
            "telemost://https://telemost.yandex.ru/j/123"
        ));
        assert!(!check_external("telemost://https://other.test/j/123"));
        assert!(!check_external("https://user:pass@example.test"));
        assert!(!check_external("file:///C:/file"));
        assert!(activation_url("calendarbar-tauri-action://meeting?id=123").is_some());
        assert!(activation_url("calendarbar-tauri-action://unknown").is_none());
        assert!(activation_url("calendarbar-tauri-action://meeting/extra").is_none());
    }
}
