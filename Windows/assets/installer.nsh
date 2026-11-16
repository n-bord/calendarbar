!macro customInstall
  WriteRegStr SHCTX "Software\Classes\calendarbar-action" "" "URL:CalendarBar"
  WriteRegStr SHCTX "Software\Classes\calendarbar-action" "URL Protocol" ""
  WriteRegStr SHCTX "Software\Classes\calendarbar-action\DefaultIcon" "" "$INSTDIR\${APP_EXECUTABLE_FILENAME},0"
  WriteRegStr SHCTX "Software\Classes\calendarbar-action\shell\open\command" "" '"$INSTDIR\${APP_EXECUTABLE_FILENAME}" "%1"'
!macroend

!macro customUnInstall
  DeleteRegKey SHCTX "Software\Classes\calendarbar-action"
  DeleteRegKey HKCU "Software\Classes\CLSID\{9DFB9A2E-FFC8-4D2E-91C3-EFE12E7C9A9B}"
!macroend
