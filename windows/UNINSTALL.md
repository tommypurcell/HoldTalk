# Uninstall HoldTalk from Windows

These steps are written for an AI agent helping someone remove HoldTalk from
their Windows PC. A person can follow them too. They remove only what HoldTalk
installed or created. Delete only the exact paths listed here: never use
wildcards, and never delete a parent folder such as `%APPDATA%` itself.

1. **Quit HoldTalk.** Ask the person to right-click the HoldTalk icon in the tray,
   beside the clock, and choose **Quit HoldTalk**. This also stops
   `whisper-server.exe`, which HoldTalk runs in the background. To check:
   ```powershell
   Get-Process HoldTalk, whisper-server -ErrorAction SilentlyContinue
   ```
   If either is still listed, run `Stop-Process -Name HoldTalk, whisper-server`.

2. **Run the uninstaller.** Ask the person to open **Settings > Apps > Installed
   apps**, find **HoldTalk**, and choose **Uninstall**. It removes the app and its
   copy of whisper.cpp. If it offers **Delete the application data**, they can tick
   it. That removes the app's web view data, but not the settings and model in
   step 4.

3. **Remove launch at login,** in case it was on. This deletes only HoldTalk's own
   entry:
   ```powershell
   Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "HoldTalk" -ErrorAction SilentlyContinue
   ```

4. **Remove settings and the speech model.** This folder holds `config.json`, the
   500 MB model in `models`, and possibly a `.env` file with the person's API
   keys. **Ask the person first.** They may want to keep their keys, or the model
   if they plan to reinstall. Never open or print the `.env`.
   ```powershell
   Remove-Item -Recurse -Force "$env:APPDATA\HoldTalk"
   ```

5. **Remove leftovers.** These are usually already gone or empty:
   ```powershell
   Remove-Item -Recurse -Force "$env:TEMP\holdtalk" -ErrorAction SilentlyContinue
   Remove-Item -Recurse -Force "$env:LOCALAPPDATA\com.tommypurcell.holdtalk" -ErrorAction SilentlyContinue
   ```

6. **Check it's gone.** Each line should print `False`:
   ```powershell
   Test-Path "$env:APPDATA\HoldTalk"
   Test-Path "$env:LOCALAPPDATA\HoldTalk"
   Test-Path "$env:LOCALAPPDATA\com.tommypurcell.holdtalk"
   ```
   `$env:APPDATA\HoldTalk` may print `True` if the person chose to keep their settings in step 4.

HoldTalk adds no services, drivers or scheduled tasks, and needs no
administrator access to remove.
