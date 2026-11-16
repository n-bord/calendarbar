!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr HKCU "Software\Classes\AppUserModelId\${BUNDLEID}" "DisplayName" "${PRODUCTNAME}"
  WriteRegStr HKCU "Software\Classes\AppUserModelId\${BUNDLEID}" "IconUri" "$INSTDIR\calendarbar-notification.png"
  WriteRegStr HKCU "Software\Classes\AppUserModelId\${BUNDLEID}" "CustomActivator" "{9389962A-18C8-43B0-A291-612B0CF038BD}"
  WriteRegStr HKCU "Software\Classes\calendarbar-tauri-action" "" "URL:CalendarBar"
  WriteRegStr HKCU "Software\Classes\calendarbar-tauri-action" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\calendarbar-tauri-action\shell\open\command" "" '$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\"'
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "CalendarBar Tauri"
    DeleteRegKey HKCU "Software\Classes\calendarbar-tauri-action"
    DeleteRegKey HKCU "Software\Classes\AppUserModelId\${BUNDLEID}"
    !insertmacro IsShortcutTarget "$SMPROGRAMS\CalendarBar\CalendarBar.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      Delete "$SMPROGRAMS\CalendarBar\CalendarBar.lnk"
      RMDir "$SMPROGRAMS\CalendarBar"
    ${EndIf}
  ${EndIf}
!macroend
