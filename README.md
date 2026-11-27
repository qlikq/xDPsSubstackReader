# xDlabs.SubStackReader

![ModuleBuilder v3.2.18 passing, Pester v6.2.0 18/18 passed, Authenticode signed by xDlabs, PowerShell 7.6, MIT license](xDlabs.SubStackReader/Assets/readme-badges.svg)

<!-- project-intro -->
```text
             .oo.
           .o$$$$$o.       o$             .o$
           $$$'   `$$$o.   $$             $$$
 o$    $o  $$$      `$$$   $$  .o$$$o.    $$$$$o.  .o$$o.
   `$..$'.  $$$      $$$.  $$      `$$    $$' `$$  $$'
     .$$.`:. $$$    o$$':  $$  .o$$$$$    $$   $$  `$$$$o.
   .$$'`$$.:: $$$oo$$$'.:  $$  $$' `$$    $$$  $$      `$$
   $'    `$'   `$$$$$"'.:' $$  `$$$$$$$   `$$$$$' `$$$$$'      \>xDlabs.iNfO
```

An RSS reader for your favorite Substack publications, built for **PowerShell 7.6** on Windows and Linux, including WSL.
The terminal interface uses [PSTui 1.0.5](https://github.com/tui-cs/PSTui) and Terminal.Gui.
<!-- /project-intro -->

<!-- release-version -->
Current version: **1.0.2**.
<!-- /release-version -->

## Install

In a PowerShell 7.6 terminal, run:

```powershell
Install-PSResource PSTui -Version 1.0.5 -Repository PSGallery
Install-PSResource xDlabs.SubStackReader -Repository PSGallery
Show-Substack
```

If you downloaded the module as a ZIP, extract it and import its manifest:

```powershell
Import-Module ./xDlabs.SubStackReader/xDlabs.SubStackReader.psd1
Show-Substack -Name 'PowerShell.News' -NoAudio
```

## Use the reader

- Type `Show-Substack -Name ` and press **Tab** to complete a name from your favorites.
- Focus starts in the favorites pane on the right. Use **↑/↓** to select a publication and **Enter** to load it. Press **Enter** on the same favorite again to refresh its posts.
- **Tab** moves between panes. Press **Enter** on a post to focus its scrollable preview. Press **O** to open the post in your browser or to visit the publication if its feed is empty.
- The reader combines public RSS entries with Substack’s undocumented public archive, so posts that have reached the archive can appear before they reach RSS. Refreshing is manual.

xDlabs (`igregui.substack.com`) is pinned at the top and opens by default. Other starter favorites include Home Lab Weekly, PowerShell.News, Bite Code!, The Pragmatic Engineer, Platformer, and Boiling The Ocean.

Use **Add favorite** and **Remove** in the reader, or manage the same list from PowerShell:

```powershell
Get-SubstackFavorite
Add-SubstackFavorite -Name 'My Newsletter' -Url 'example.substack.com'
Remove-SubstackFavorite -Name 'My Newsletter'
```

Favorites are stored in `%LOCALAPPDATA%/xDlabs/Substack/favorites.json` on Windows and under `${XDG_CONFIG_HOME:-~/.config}/xDlabs/Substack/favorites.json` on Linux. Set `XDLABS_SUBSTACK_CONFIG` to use a different file.

**Exit** plays a ten-second XOR tunnel and leaves the xDlabs ASCII logo in your terminal. **Ctrl+C** in the reader exits immediately. During the animation, **Esc**, **Q**, or **Ctrl+C** stops playback.

The outro needs at least 49 columns and 14 rows. The reader attempts to maximize the window on supported hosts. Audio on Linux requires `paplay`, `aplay`, or `ffplay` and a working audio device. Use `-NoAudio` for silent playback.

## PowerShell help

```powershell
Get-Command -Module xDlabs.SubStackReader
Get-Help Show-Substack -Full
Get-Help Add-SubstackFavorite -Examples
```

## Local development

From the development workspace, restore the dependencies, build with ModuleBuilder, and run the Pester tests:

```powershell
./Restore-Dependencies.ps1
./Build.ps1
./Test.ps1
```

`./Test.ps1 -Live` also checks the live feeds. `./Test.ps1 -Terminal` runs the interactive test using Python 3, with `pywinpty` required on Windows.

The build includes the pre-rendered ANSI clip at 24 fps in four sizes and the original 48 kHz stereo WAV. The exporter in the development workspace can regenerate these assets from the xDlabs Retro Machine project:

```powershell
./Build.ps1 -RetroRuntimePath ../xDlabsxRetroMachine/src/Runtime
```

### Releases

- `./Build.ps1 -Sign` uses SimplySign on Windows to sign the built PowerShell files with SHA-256 and a timestamp. It retries for up to five minutes. Use `-CertificateThumbprint` to select a specific certificate.
- `./Build.ps1 -PushGitHub` publishes the built module and the generated README. The release checkout excludes the local development files. `-CreateGitHub` can create a private repository with the authenticated GitHub CLI if needed.
- `./Build.ps1 -Publish` builds, signs, and uploads to PowerShell Gallery with `Publish-PSResource`. Provide the key through `PSGALLERY_API_KEY` or `-ApiKey (Read-Host 'PSGallery API key' -AsSecureString)`. Set a new package version in the source manifest before publishing.
- `./Build.ps1 -PushGitHub -Publish -WhatIf` previews the release actions.

## Contribute

I’d love to build this reader with other people. If you’ve found a bug, have an idea, or spotted a small improvement, you’re welcome to [open an issue](https://github.com/qlikq/xDPsSubstackReader/issues/new) or [send a pull request](https://github.com/qlikq/xDPsSubstackReader/pulls). Even a short note about what worked for you or where you got stuck is welcome.

I’m AuDHD and found out I’m on the autism spectrum after an assessment at age 41. Meeting new people can bring up anxiety for me, and working together on a small piece of code feels like a good way to get to know someone. I’m happiest collaborating with people who understand AuDHD or are willing to listen and learn. Clear requests, a little patience, and room to reply in our own time go a long way.

AuDHD looks different for everyone. If you’re AuDHD too, I hope you find people you can build things with at a pace that feels right for you. Wishing you all the best, both in code and beyond it.
