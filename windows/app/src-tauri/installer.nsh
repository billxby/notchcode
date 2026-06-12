; Notchcode NSIS hooks, wired in via bundle.windows.nsis.installerHooks.
; Macro names are the four fixed hook points Tauri's installer.nsi template
; looks for; $UpdateMode and ${MAINBINARYNAME} are defined by that template.

!macro NSIS_HOOK_PREUNINSTALL
  ; Real uninstall only — an app update runs this same uninstaller silently
  ; with /UPDATE, and stripping the hooks there would leave the (still
  ; installed) app blind until its next launch reinstalled them, and would
  ; silently drop the user's opt-in Codex hooks.
  ;
  ; While the exe still exists, have it remove Notchcode's hook entries from
  ; ~/.claude/settings.json and ~/.codex/hooks.json — otherwise the agents
  ; keep invoking a deleted notchcode.exe on every lifecycle event. The
  ; template itself already removes the autostart Run key.
  ${If} $UpdateMode <> 1
    ExecWait '"$INSTDIR\${MAINBINARYNAME}.exe" __notch_uninstall'
  ${EndIf}
!macroend
