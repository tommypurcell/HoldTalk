# Install HoldTalk on Windows

These steps are written for an AI agent helping someone set up HoldTalk on their
Windows PC. A person can follow them too. HoldTalk is a free, open-source
dictation app: hold Right Ctrl, speak, let go, and the text is typed at the cursor.

1. **Download the installer.** Get `HoldTalk_*_x64-setup.exe` from the newest
   release at https://github.com/tommypurcell/HoldTalk/releases (it may be marked
   pre-release). With the GitHub CLI:
   `gh release download --repo tommypurcell/HoldTalk --pattern "*-setup.exe"`.
   In PowerShell without it:
   ```powershell
   $release = Invoke-RestMethod https://api.github.com/repos/tommypurcell/HoldTalk/releases | Select-Object -First 1
   $asset = $release.assets | Where-Object name -like "*-setup.exe" | Select-Object -First 1
   Invoke-WebRequest $asset.browser_download_url -OutFile "$env:USERPROFILE\Downloads\$($asset.name)"
   ```
2. **Run it.** Ask the person to double-click it. It installs for the current user
   only and needs no administrator access. The build isn't code-signed yet, so
   Windows SmartScreen warns: they click **More info**, then **Run anyway**.
3. **Wait for the speech model.** HoldTalk starts in the tray, beside the clock (they
   may have to click **^** to see it). The first time, it downloads a 500 MB model
   to `%APPDATA%\HoldTalk\models`, and a small pill at the bottom of the screen
   shows when it's ready. The tray menu shows progress.
4. **Try it.** Ask the person to open Notepad, hold **Right Ctrl**, say a sentence
   and let go. You can't do this step for them: it needs their voice, and the app
   ignores keys sent by other programs.
5. **If nothing records,** have them turn on **Settings > Privacy & security >
   Microphone > Let desktop apps access your microphone**, then try again.

## Good to know

- **Double-tap Right Ctrl** records hands-free until one more tap. **Esc** cancels;
  pressing Right Ctrl within 5 seconds undoes that.
- **Settings:** tray menu > **Open Settings File** (`%APPDATA%\HoldTalk\config.json`),
  then **Reload Settings**. Keys and values are listed in
  https://github.com/tommypurcell/HoldTalk/blob/main/windows/README.md.
- **Optional cleanup** of filler words needs an API key in `%APPDATA%\HoldTalk\.env`,
  such as `GROQ_API_KEY=...`. Let the person paste their own key. Never read, print
  or share that file.
- **It can't paste into apps running as administrator.** The text is left on the
  clipboard instead.
- **Problems or ideas:** https://github.com/tommypurcell/HoldTalk/issues
