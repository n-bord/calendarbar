!include "${__FILEDIR__}/windows-hooks.nsh"

LangString CalendarBarInstallScope 1049 "Установка для текущего пользователя"
LangString CalendarBarInstallScope 1033 "Install for the current user"
LangString CalendarBarInstallDescription 1049 "CalendarBar установится в профиль текущего пользователя. Права администратора не нужны.$\r$\n$\r$\nМастер использует уже установленный Microsoft Edge WebView2 Runtime."
LangString CalendarBarInstallDescription 1033 "CalendarBar will install in the current user's profile. Administrator rights are not required.$\r$\n$\r$\nSetup uses the Microsoft Edge WebView2 Runtime already installed on this PC."
LangString CalendarBarMissingWebView2 1049 "Для CalendarBar нужен Microsoft Edge WebView2 Runtime. Попросите ИТ-службу установить этот компонент и снова запустите установщик CalendarBar."
LangString CalendarBarMissingWebView2 1033 "CalendarBar needs Microsoft Edge WebView2 Runtime. Ask your IT team to install it, then run CalendarBar Setup again."

!define MUI_WELCOMEPAGE_TITLE "$(CalendarBarInstallScope)"
!define MUI_WELCOMEPAGE_TEXT "$(CalendarBarInstallDescription)"
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE CalendarBarRequireWebView2

Function CalendarBarRequireWebView2
  Push $0
  SetRegView 32
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${If} $0 == ""
  ${OrIf} $0 == "0.0.0.0"
    ReadRegStr $0 HKLM "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  ${EndIf}
  SetRegView lastused
  ${If} $0 == ""
  ${OrIf} $0 == "0.0.0.0"
    Pop $0
    DetailPrint "$(CalendarBarMissingWebView2)"
    MessageBox MB_OK|MB_ICONSTOP "$(CalendarBarMissingWebView2)" /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
  Pop $0
  SetErrorLevel 0
FunctionEnd

!macro NSIS_HOOK_PREINSTALL
  Call CalendarBarRequireWebView2
!macroend
