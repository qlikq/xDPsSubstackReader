#Region '.\Private\ConvertFrom-FeedHtml.ps1' -1

function ConvertFrom-FeedHtml {
    param([string] $Html)

    $text = $Html -replace '(?is)<(script|style)\b[^>]*>.*?</\1\s*>', '' `
                  -replace '(?i)<br\s*/?>|</(?:p|div|h[1-6]|li|blockquote)\s*>', "`n`n" `
                  -replace '<[^>]*>', ''
    $text = [Net.WebUtility]::HtmlDecode($text) -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ''
    ($text -replace '\r\n?', "`n" -replace '\n{3,}', "`n`n").Trim()
}
#EndRegion '.\Private\ConvertFrom-FeedHtml.ps1' 10
#Region '.\Private\ConvertTo-PublicationUrl.ps1' -1

function ConvertTo-PublicationUrl {
    param([string] $Url)

    $text = $Url.Trim()
    if ($text -notmatch '^[a-z][a-z0-9+.-]*://') { $text = "https://$text" }
    $uri = $null
    if (-not [uri]::TryCreate($text, 'Absolute', [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.HostNameType -ne 'Dns' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw 'Enter an HTTPS publication address, for example example.substack.com.'
    }
    'https://' + $uri.IdnHost.TrimEnd('.').ToLowerInvariant()
}
#EndRegion '.\Private\ConvertTo-PublicationUrl.ps1' 15
#Region '.\Private\Expand-SubstackTerminal.ps1' -1

function Expand-SubstackTerminal {
    if (-not $IsWindows) {
        [Console]::Write("`e[9;1t")
        return
    }
    if (-not ('xDlabs.SubStackReader.TerminalWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace xDlabs.SubStackReader {
    public static class TerminalWindow {
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder title, int size);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);

        public static void Maximize(string consoleTitle) {
            var window = GetConsoleWindow();
            if (!IsWindowVisible(window)) {
                window = GetForegroundWindow();
                var name = new StringBuilder(256);
                var title = new StringBuilder(1024);
                GetClassName(window, name, name.Capacity);
                GetWindowText(window, title, title.Capacity);
                if (name.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS" ||
                    String.IsNullOrWhiteSpace(consoleTitle) ||
                    !title.ToString().Contains(consoleTitle, StringComparison.OrdinalIgnoreCase))
                    return;
            }
            ShowWindowAsync(window, 3);
        }
    }
}
'@
    }
    [xDlabs.SubStackReader.TerminalWindow]::Maximize([Console]::Title)
}
#EndRegion '.\Private\Expand-SubstackTerminal.ps1' 42
#Region '.\Private\Get-FavoritePath.ps1' -1

function Get-FavoritePath {
    if ($env:XDLABS_SUBSTACK_CONFIG) {
        return [IO.Path]::GetFullPath($env:XDLABS_SUBSTACK_CONFIG)
    }
    $base = if ($IsWindows) { [Environment]::GetFolderPath('LocalApplicationData') }
            elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME }
            else { Join-Path $HOME '.config' }
    Join-Path $base 'xDlabs/Substack/favorites.json'
}
#EndRegion '.\Private\Get-FavoritePath.ps1' 10
#Region '.\Private\Get-SubstackArchive.ps1' -1

function Get-SubstackArchive {
    param([string] $Url)

    $archive = Invoke-RestMethod -Uri "$Url/api/v1/archive?sort=new&limit=10" `
        -ConnectionTimeoutSeconds 5 -OperationTimeoutSeconds 8 -ErrorAction Stop
    $entries = if ($archive -is [array]) { $archive } elseif ($null -ne $archive.posts) { $archive.posts }
               elseif ($archive.slug) { $archive }
    foreach ($entry in $entries) {
        $link = $null
        if (-not [uri]::TryCreate([string]$entry.canonical_url, 'Absolute', [ref]$link) -or
            $link.Scheme -ne 'https' -or $link.UserInfo) { continue }
        $detailsUrl = if ($entry.audience -eq 'everyone' -and $entry.slug -match '^[a-zA-Z0-9_-]+$') {
            "$Url/api/v1/posts/$($entry.slug)"
        }
        [pscustomobject]@{
            Title = (ConvertFrom-FeedHtml $entry.title) -replace '\s+', ' '
            Url = $link.AbsoluteUri
            Published = [string]$entry.post_date
            Text = ConvertFrom-FeedHtml $entry.subtitle
            DetailsUrl = $detailsUrl
        }
    }
}
#EndRegion '.\Private\Get-SubstackArchive.ps1' 24
#Region '.\Private\Get-SubstackPostPreview.ps1' -1

function Get-SubstackPostPreview {
    param($Post)

    if ($Post.DetailsUrl) {
        try {
            $details = Invoke-RestMethod -Uri $Post.DetailsUrl -ConnectionTimeoutSeconds 5 -OperationTimeoutSeconds 8 -ErrorAction Stop
            $body = ConvertFrom-FeedHtml $details.body_html
            if ($body) { $Post.Text = $body }
            $Post.DetailsUrl = $null
        } catch { Write-Verbose $_.Exception.Message }
    }
    $Post.Text
}
#EndRegion '.\Private\Get-SubstackPostPreview.ps1' 14
#Region '.\Private\Get-SubstackPosts.ps1' -1

function Get-SubstackPosts {
    param([string] $Url)

    $response = Invoke-WebRequest -Uri "$Url/feed" -ConnectionTimeoutSeconds 5 -OperationTimeoutSeconds 8 -ErrorAction Stop
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = 'Prohibit'
    $settings.MaxCharactersInDocument = 8MB
    $source = [IO.StringReader]::new($response.Content)
    $reader = [Xml.XmlReader]::Create($source, $settings)
    try {
        $feed = [xml]::new()
        $feed.Load($reader)
    } finally {
        $reader.Dispose()
        $source.Dispose()
    }
    if (-not $feed.SelectSingleNode('/rss/channel')) { throw 'The publication did not return an RSS feed.' }

    $items = $feed.SelectNodes('/rss/channel/item')
    if ($items.Count -eq 0) {
        Get-SubstackArchive $Url
        return
    }
    foreach ($item in $items) {
        $link = $null
        if (-not [uri]::TryCreate($item.SelectSingleNode('link').InnerText, 'Absolute', [ref]$link) -or
            $link.Scheme -ne 'https' -or $link.UserInfo) { continue }

        $body = $item.SelectSingleNode("*[local-name()='encoded' and namespace-uri()='http://purl.org/rss/1.0/modules/content/']")
        if (-not $body) { $body = $item.SelectSingleNode('description') }
        $title = (ConvertFrom-FeedHtml ($item.SelectSingleNode('title').InnerText)) -replace '\s+', ' '
        [pscustomobject]@{
            Title = $title
            Url = $link.AbsoluteUri
            Published = $item.SelectSingleNode('pubDate').InnerText
            Text = ConvertFrom-FeedHtml $body.InnerText
        }
    }
}
#EndRegion '.\Private\Get-SubstackPosts.ps1' 40
#Region '.\Private\Import-SubstackTui.ps1' -1

function Import-SubstackTui {
    $module = Import-Module -Name PSTui -RequiredVersion 1.0.5 -PassThru -ErrorAction Stop
    $expected = Join-Path $module.ModuleBase 'Terminal.Gui.dll'
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Terminal.Gui' }
    if ($loaded -and $loaded.Location -notcontains $expected) {
        throw 'Another Terminal.Gui assembly is loaded. Open a fresh PowerShell session for Show-Substack.'
    }
    [void][Reflection.Assembly]::LoadFrom($expected)
}
#EndRegion '.\Private\Import-SubstackTui.ps1' 10
#Region '.\Private\Read-SubstackOutro.ps1' -1

function Read-SubstackOutro {
    param([string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.BinaryReader]::new($gzip)
    try {
        $fps = $reader.ReadInt32()
        $count = $reader.ReadInt32()
        if ($fps -ne 24 -or $count -ne 240) { throw 'Invalid outro clip header.' }
        $frames = [string[]]::new($count)
        for ($index = 0; $index -lt $count; $index++) { $frames[$index] = $reader.ReadString() }
        [pscustomobject]@{ FramesPerSecond = $fps; Frames = $frames }
    } finally { $reader.Dispose() }
}
#EndRegion '.\Private\Read-SubstackOutro.ps1' 16
#Region '.\Private\Show-SubstackOutro.ps1' -1

function Show-SubstackOutro {
    param([switch] $NoAudio)

    try { Expand-SubstackTerminal } catch { Write-Verbose $_.Exception.Message }
    Start-Sleep -Milliseconds 200
    $assets = Join-Path $PSScriptRoot 'Assets/Outro'
    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    $size = foreach ($preset in @(@(179, 49), @(119, 34), @(79, 23), @(48, 14))) {
        if ($preset[0] -lt $width -and $preset[1] -le $height) { $preset; break }
    }
    if (-not $size) {
        Write-Warning 'The outro needs a terminal of at least 49 columns by 14 rows.'
        return
    }
    $clip = Read-SubstackOutro (Join-Path $assets "$($size[0])-$($size[1]).frames.gz")
    $player = $null
    $originalControl = [Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput = $true
        [Console]::Write("`e[?1049h`e[?25l`e[?7l`e[40m`e[2J")
        if (-not $NoAudio) {
            try { $player = Start-SubstackAudio (Join-Path $assets 'outro.wav') }
            catch { Write-Verbose $_.Exception.Message }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $last = -1
        while ($clock.Elapsed.TotalSeconds -lt 10) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -in 'Escape', 'Q' -or $key.KeyChar -eq [char]3) { break }
            }
            $index = [int][Math]::Floor($clock.Elapsed.TotalSeconds * $clip.FramesPerSecond)
            if ($index -ge $clip.Frames.Count) { break }
            if ($index -gt $last) {
                [Console]::Write($clip.Frames[$index])
                $last = $index
            }
            [Threading.Thread]::Sleep(4)
        }
    } finally {
        [Console]::Write("`e[0m`e[?7h`e[?25h`e[?1049l")
        [Console]::TreatControlCAsInput = $originalControl
        if ($player) {
            try {
                if ($IsWindows) { $player.Stop() }
                elseif (-not $player.HasExited) { $player.Kill() }
            } finally { $player.Dispose() }
        }
    }

    $logo = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Assets/xDlabs-logo.txt'))
    [Console]::WriteLine($logo.TrimEnd("`r", "`n"))
}
#EndRegion '.\Private\Show-SubstackOutro.ps1' 55
#Region '.\Private\Show-SubstackReader.ps1' -1

function Show-SubstackReader {
    param($Favorites, $Selected)

    $ErrorActionPreference = 'Stop'
    Import-SubstackTui
    $app = [Terminal.Gui.App.Application]::Create($null)
    $window = [Terminal.Gui.Views.Window]::new()
    $state = @{ Favorites = $Favorites; Posts = @(); ActiveUrl = ''; PlayExit = $false }
    try {
        [void]$app.Init($null)
        $window.Title = 'xDlabs | Substack Reader'
        $window.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
        $window.Height = [Terminal.Gui.ViewBase.Dim]::Fill()

        $postsFrame = [Terminal.Gui.Views.FrameView]::new()
        $postsFrame.Width = [Terminal.Gui.ViewBase.Dim]::Fill(27)
        $postsFrame.Height = [Terminal.Gui.ViewBase.Dim]::Percent(35)
        $posts = [Terminal.Gui.Views.ListView]::new()
        $posts.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
        $posts.Height = [Terminal.Gui.ViewBase.Dim]::Fill()
        [void]$postsFrame.Add($posts)

        $previewFrame = [Terminal.Gui.Views.FrameView]::new()
        $previewFrame.Title = 'Article'
        $previewFrame.Y = [Terminal.Gui.ViewBase.Pos]::Bottom($postsFrame)
        $previewFrame.Width = [Terminal.Gui.ViewBase.Dim]::Fill(27)
        $previewFrame.Height = [Terminal.Gui.ViewBase.Dim]::Fill(2)
        $preview = [Terminal.Gui.Views.TextView]::new()
        $preview.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
        $preview.Height = [Terminal.Gui.ViewBase.Dim]::Fill()
        $preview.ReadOnly = $true
        $preview.WordWrap = $true
        $preview.TabKeyAddsTab = $false
        $foreground = [Terminal.Gui.Drawing.Color]::new(222, 236, 245, 255)
        $background = [Terminal.Gui.Drawing.Color]::new(14, 23, 34, 255)
        $articleColors = [Terminal.Gui.Drawing.Attribute]::new([ref]$foreground, [ref]$background)
        $articleScheme = [Terminal.Gui.Drawing.Scheme]::new($articleColors)
        $articleScheme.ReadOnly = $articleColors
        [void]$preview.SetScheme($articleScheme)
        [void]$previewFrame.Add($preview)

        $favoritesFrame = [Terminal.Gui.Views.FrameView]::new()
        $favoritesFrame.Title = 'Favorites'
        $favoritesFrame.X = [Terminal.Gui.ViewBase.Pos]::AnchorEnd(27)
        $favoritesFrame.Width = 27
        $favoritesFrame.Height = [Terminal.Gui.ViewBase.Dim]::Fill(2)
        $list = [Terminal.Gui.Views.ListView]::new()
        $list.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
        $list.Height = [Terminal.Gui.ViewBase.Dim]::Fill()
        [void]$favoritesFrame.Add($list)
        $window.Add([Terminal.Gui.ViewBase.View[]]@($postsFrame, $previewFrame, $favoritesFrame))
        $brand = [Terminal.Gui.Views.Label]::new()
        $brand.Text = '>xDlabs'
        $brand.X = [Terminal.Gui.ViewBase.Pos]::AnchorEnd($brand.Text.Length)
        $brand.Y = [Terminal.Gui.ViewBase.Pos]::AnchorEnd(1)
        [void]$window.Add($brand)
        $status = [Terminal.Gui.Views.Label]::new()
        $status.Y = [Terminal.Gui.ViewBase.Pos]::AnchorEnd(2)
        $status.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
        [void]$window.Add($status)

        $showPreview = {
            $index = $posts.Value
            if ($null -eq $index -or $index -ge $state.Posts.Count) { return }
            $post = $state.Posts[$index]
            $body = Get-SubstackPostPreview $post
            if (-not $body) { $body = 'Open the original in your browser.' }
            $preview.Text = "$($post.Title)`n$($post.Published)`n`n$body"
        }
        $load = {
            param($publication)
            $state.ActiveUrl = $publication.Url
            $postsFrame.Title = $publication.Name
            $preview.Text = ''
            $state.Posts = @()
            $labels = [Collections.ObjectModel.ObservableCollection[string]]::new()
            try {
                $state.Posts = @(Get-SubstackPosts $publication.Url)
                foreach ($post in $state.Posts) { $labels.Add($post.Title) }
                if ($labels.Count -eq 0) { $preview.Text = 'No posts are available in this feed. Press O to visit the publication.' }
            } catch {
                $preview.Text = "Could not load $($publication.Name).`n$($_.Exception.Message)"
            }
            $posts.SetSource[string]($labels)
            if ($labels.Count) { $posts.Value = 0; & $showPreview }
        }
        $setFavorites = {
            param([string] $selectedUrl)
            $labels = [Collections.ObjectModel.ObservableCollection[string]]::new()
            $index = 0
            foreach ($favorite in $state.Favorites) {
                if ($favorite.Url -eq $selectedUrl) { $index = $labels.Count }
                $label = if ($favorite.Pinned) { "$($favorite.Name) (pinned)" } else { $favorite.Name }
                $labels.Add($label)
            }
            $list.SetSource[string]($labels)
            $list.Value = $index
        }
        $open = {
            $url = $state.ActiveUrl
            if ($null -ne $posts.Value -and $posts.Value -lt $state.Posts.Count) {
                $url = $state.Posts[$posts.Value].Url
            }
            try { Start-Process $url -ErrorAction Stop }
            catch { $status.Text = "Could not open browser. $($_.Exception.Message)" }
        }
        $remove = {
            [void]$list.SetFocus()
            $favorite = $state.Favorites[$list.Value]
            if ($favorite.Pinned) {
                $status.Text = 'xDlabs is pinned.'
                return
            }
            try { Remove-SubstackFavorite -Name $favorite.Name }
            catch {
                $status.Text = $_.Exception.Message
                return
            }
            $state.Favorites = @(Get-SubstackFavorite)
            if ($state.ActiveUrl -eq $favorite.Url) { & $load $state.Favorites[0] }
            & $setFavorites $state.ActiveUrl
            $status.Text = "Removed $($favorite.Name)."
        }
        $editor = [Terminal.Gui.Views.FrameView]::new()
        $editor.Title = 'Add favorite'
        $editor.CanFocus = $true
        $editor.Width = [Terminal.Gui.ViewBase.Dim]::Fill(27)
        $editor.Height = [Terminal.Gui.ViewBase.Dim]::Fill(2)
        $editor.Visible = $false
        $fields = @()
        foreach ($label in 'Name', 'HTTPS address') {
            $caption = [Terminal.Gui.Views.Label]::new()
            $caption.Text = $label
            $caption.Y = $fields.Count * 2
            $field = [Terminal.Gui.Views.TextField]::new()
            $field.Y = $fields.Count * 2 + 1
            $field.Width = [Terminal.Gui.ViewBase.Dim]::Fill()
            [void]$editor.Add($caption)
            [void]$editor.Add($field)
            $fields += $field
        }
        $add = {
            $fields[0].Text = ''
            $fields[1].Text = ''
            $status.Text = ''
            $editor.Visible = $true
            $postsFrame.Visible = $false
            $previewFrame.Visible = $false
            foreach ($button in $footerButtons) { $button.Visible = $false }
            [void]$fields[0].SetFocus()
        }
        $closeEditor = {
            $postsFrame.Visible = $true
            $previewFrame.Visible = $true
            $editor.Visible = $false
            foreach ($button in $footerButtons) { $button.Visible = $true }
            [void]$list.SetFocus()
        }
        $save = [Terminal.Gui.Views.Button]::new()
        $save.Text = 'Save'
        $save.Y = 5
        $save.add_Accepting({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            try { Add-SubstackFavorite -Name $fields[0].Text -Url $fields[1].Text }
            catch { $status.Text = $_.Exception.Message; return }
            $state.Favorites = @(Get-SubstackFavorite)
            $favorite = $state.Favorites | Where-Object Name -eq $fields[0].Text.Trim()
            $status.Text = ''
            & $closeEditor
            if ($favorite) {
                & $setFavorites $favorite.Url
                & $load $favorite
            }
        })
        $cancel = [Terminal.Gui.Views.Button]::new()
        $cancel.Text = 'Cancel'
        $cancel.Y = 5
        $cancel.X = 12
        $cancel.add_Accepting({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            $status.Text = ''
            & $closeEditor
        })
        [void]$editor.Add($save)
        [void]$editor.Add($cancel)
        [void]$window.Add($editor)
        $exit = {
            $state.PlayExit = $true
            $app.RequestStop()
        }

        $list.add_Accepting({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            & $load $state.Favorites[$list.Value]
        })
        $list.add_KeyDown({
            param($sender, $key)
            if ($key.KeyCode -eq [Terminal.Gui.Input.Key]::Enter.KeyCode) {
                $key.Handled = $true
                & $load $state.Favorites[$list.Value]
                return
            }
            $direction = switch ($key.KeyCode) {
                ([Terminal.Gui.Input.Key]::CursorUp.KeyCode) { -1 }
                ([Terminal.Gui.Input.Key]::CursorDown.KeyCode) { 1 }
            }
            if ($direction) {
                $key.Handled = $true
                $list.Value = [Math]::Clamp(([int]$list.Value + $direction), 0, $state.Favorites.Count - 1)
                $list.EnsureSelectedItemVisible()
            }
        })
        $posts.add_ValueChanged({ & $showPreview })
        $posts.add_Accepting({
            param($sender, $eventArgs)
            $eventArgs.Handled = $true
            [void]$preview.SetFocus()
        })
        $app.Keyboard.add_KeyDown({
            param($sender, $key)
            if ($app.TopRunnable -ne $window) { return }
            if ($key.KeyCode -eq [Terminal.Gui.Input.Key]::C.WithCtrl.KeyCode) {
                $key.Handled = $true
                $app.RequestStop()
            } elseif ($editor.Visible -and $key.KeyCode -eq [Terminal.Gui.Input.Key]::Esc.KeyCode) {
                $key.Handled = $true
                $status.Text = ''
                & $closeEditor
            } elseif ($editor.Visible -and $key.KeyCode -eq [Terminal.Gui.Input.Key]::Tab.KeyCode -and
                      ($fields[0].HasFocus -or $fields[1].HasFocus)) {
                $key.Handled = $true
                if ($fields[0].HasFocus) { [void]$fields[1].SetFocus() }
                else { [void]$save.SetFocus() }
            } elseif (-not $editor.Visible -and
                $key.KeyCode -in @([Terminal.Gui.Input.Key]::O.KeyCode, [Terminal.Gui.Input.Key]::O.WithShift.KeyCode)) {
                $key.Handled = $true
                & $open
            }
        })
        $position = 0
        $footerButtons = @()
        $actions = @($open, $add, $remove, $exit)
        $captions = @('_Open', '_Add favorite', '_Remove', 'E_xit')
        foreach ($caption in $captions) {
            $button = [Terminal.Gui.Views.Button]::new()
            $button.Text = $caption
            $button.X = $position
            $button.Y = [Terminal.Gui.ViewBase.Pos]::AnchorEnd(1)
            $button.Data = $actions[[array]::IndexOf($captions, $caption)]
            $button.add_Accepting({
                param($sender, $eventArgs)
                $eventArgs.Handled = $true
                & $sender.Data
            })
            [void]$window.Add($button)
            $footerButtons += $button
            $position += $caption.Length + 5
        }
        & $setFavorites $Selected.Url
        & $load $Selected
        [void]$list.SetFocus()
        [void]$app.Run($window, $null)
        if ($state.PlayExit) { 'PlayExit' }
    } finally {
        $window.Dispose()
        $app.Dispose()
    }
}
#EndRegion '.\Private\Show-SubstackReader.ps1' 272
#Region '.\Private\Start-SubstackAudio.ps1' -1

function Start-SubstackAudio {
    param([string] $Path)

    if ($IsWindows) {
        $player = [Media.SoundPlayer]::new($Path)
        try { $player.Load(); $player.Play(); return $player }
        catch { $player.Dispose(); throw }
    }
    foreach ($candidate in 'paplay', 'aplay', 'ffplay') {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        $info = [Diagnostics.ProcessStartInfo]::new($command.Source)
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $options = switch ($candidate) {
            'aplay' { '-q' }
            'ffplay' { '-nodisp'; '-autoexit'; '-loglevel'; 'quiet' }
        }
        foreach ($option in $options) { $info.ArgumentList.Add($option) }
        $info.ArgumentList.Add($Path)
        return [Diagnostics.Process]::Start($info)
    }
    Write-Verbose 'Install paplay, aplay or ffplay to play the outro audio on Linux.'
}
#EndRegion '.\Private\Start-SubstackAudio.ps1' 26
#Region '.\Private\Update-SubstackFavorites.ps1' -1

function Update-SubstackFavorites {
    param([scriptblock] $Update)

    $path = Get-FavoritePath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        try { $lock = [IO.File]::Open("$path.lock", 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 50
        }
    } until ($lock)

    $temporary = "$path.$([guid]::NewGuid()).tmp"
    try {
        $updated = @(& $Update @(Get-SubstackFavorite))
        $saved = @($updated | Where-Object { -not $_.Pinned } | Select-Object Name, Url)
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $saved))
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        $lock.Dispose()
        [IO.File]::Delete($temporary)
    }
}
#EndRegion '.\Private\Update-SubstackFavorites.ps1' 26
#Region '.\Public\Add-SubstackFavorite.ps1' -1

function Add-SubstackFavorite {
    <#
    .SYNOPSIS
    Adds a publication to the favorites list.
    .PARAMETER Name
    A unique name to display in the reader and in tab completion.
    .PARAMETER Url
    The HTTPS home address of the publication. The scheme may be omitted.
    .EXAMPLE
    Add-SubstackFavorite -Name 'My Newsletter' -Url 'example.substack.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Url
    )

    $Name = $Name.Trim()
    if (-not $Name -or $Name -match '\p{Cc}') { throw 'Enter a single-line publication name.' }
    $address = ConvertTo-PublicationUrl $Url
    Update-SubstackFavorites {
        param($favorites)
        if ($favorites.Name -contains $Name -or $favorites.Url -contains $address) {
            throw 'This name or address is already in Favorites.'
        }
        $favorites
        [pscustomobject]@{ Name = $Name; Url = $address; Pinned = $false }
    }
}
#EndRegion '.\Public\Add-SubstackFavorite.ps1' 30
#Region '.\Public\Get-SubstackFavorite.ps1' -1

function Get-SubstackFavorite {
    <#
    .SYNOPSIS
    Lists saved Substack favorites.
    .DESCRIPTION
    Returns the pinned xDlabs publication first, followed by the user's other favorites.
    .EXAMPLE
    Get-SubstackFavorite
    #>
    [CmdletBinding()]
    param()

    $defaults = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Assets/favorites.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    $path = Get-FavoritePath
    $favorites = if ([IO.File]::Exists($path)) {
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
    } else { $defaults | Select-Object -Skip 1 }

    [pscustomobject]@{ Name = $defaults[0].Name; Url = $defaults[0].Url; Pinned = $true }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $urls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$names.Add($defaults[0].Name)
    [void]$urls.Add($defaults[0].Url)
    foreach ($favorite in $favorites) {
        $name = ([string]$favorite.Name).Trim()
        if (-not $name -or $name -match '\p{Cc}') { continue }
        try { $url = ConvertTo-PublicationUrl $favorite.Url } catch { continue }
        if ($names.Contains($name) -or $urls.Contains($url)) { continue }
        [void]$names.Add($name)
        [void]$urls.Add($url)
        [pscustomobject]@{ Name = $name; Url = $url; Pinned = $false }
    }
}
#EndRegion '.\Public\Get-SubstackFavorite.ps1' 34
#Region '.\Public\Remove-SubstackFavorite.ps1' -1

function Remove-SubstackFavorite {
    <#
    .SYNOPSIS
    Removes a publication from the favorites list.
    .DESCRIPTION
    Removes the named favorite. The pinned xDlabs publication cannot be removed.
    .PARAMETER Name
    The name of the favorite to remove.
    .EXAMPLE
    Remove-SubstackFavorite -Name 'My Newsletter'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)

    Update-SubstackFavorites {
        param($favorites)
        $match = $favorites | Where-Object Name -eq $Name
        if (-not $match) { throw "Favorite '$Name' was not found." }
        if ($match.Pinned) { throw 'xDlabs is pinned and cannot be removed.' }
        $favorites | Where-Object Name -ne $Name
    }
}
#EndRegion '.\Public\Remove-SubstackFavorite.ps1' 23
#Region '.\Public\Show-Substack.ps1' -1

function Show-Substack {
    <#
    .SYNOPSIS
    Opens the Substack reader in the terminal.
    .DESCRIPTION
    Starts on the selected favorite or opens the pinned xDlabs publication by default.
    Use the arrow keys and Enter in the favorites pane to load or refresh a publication.
    .PARAMETER Name
    The name of a saved favorite. Press Tab to complete a name.
    .PARAMETER NoAudio
    Mutes the exit animation.
    .EXAMPLE
    Show-Substack
    .EXAMPLE
    Show-Substack -Name 'PowerShell.News' -NoAudio
    #>
    [CmdletBinding()]
    param(
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $prefix = $wordToComplete.TrimStart("'", '"')
            foreach ($favorite in Get-SubstackFavorite) {
                if ($favorite.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $completion = "'" + $favorite.Name.Replace("'", "''") + "'"
                    [Management.Automation.CompletionResult]::new($completion, $favorite.Name, 'ParameterValue', $favorite.Url)
                }
            }
        })]
        [string] $Name = 'xDlabs',
        [switch] $NoAudio
    )

    $favorites = @(Get-SubstackFavorite)
    $selected = $favorites | Where-Object Name -eq $Name
    if (-not $selected) { throw "Favorite '$Name' was not found. Use Tab or Get-SubstackFavorite." }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Show-Substack needs an interactive terminal.'
    }
    if ((Show-SubstackReader -Favorites $favorites -Selected $selected) -eq 'PlayExit') {
        Show-SubstackOutro -NoAudio:$NoAudio
    }
}
#EndRegion '.\Public\Show-Substack.ps1' 43


# SIG # Begin signature block
# MIIodAYJKoZIhvcNAQcCoIIoZTCCKGECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDlt47YYC1oRLaw
# +oRugJcQ5quyTbMziCXULgOL/VAhP6CCIKgwggXJMIIEsaADAgECAhAbtY8lKt8j
# AEkoya49fu0nMA0GCSqGSIb3DQEBDAUAMH4xCzAJBgNVBAYTAlBMMSIwIAYDVQQK
# ExlVbml6ZXRvIFRlY2hub2xvZ2llcyBTLkEuMScwJQYDVQQLEx5DZXJ0dW0gQ2Vy
# dGlmaWNhdGlvbiBBdXRob3JpdHkxIjAgBgNVBAMTGUNlcnR1bSBUcnVzdGVkIE5l
# dHdvcmsgQ0EwHhcNMjEwNTMxMDY0MzA2WhcNMjkwOTE3MDY0MzA2WjCBgDELMAkG
# A1UEBhMCUEwxIjAgBgNVBAoTGVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAl
# BgNVBAsTHkNlcnR1bSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMb
# Q2VydHVtIFRydXN0ZWQgTmV0d29yayBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAvfl4+ObVgAxknYYblmRnPyI6HnUBfe/7XGeMycxca6mR5rlC
# 5SBLm9qbe7mZXdmbgEvXhEArJ9PoujC7Pgkap0mV7ytAJMKXx6fumyXvqAoAl4Va
# qp3cKcniNQfrcE1K1sGzVrihQTib0fsxf4/gX+GxPw+OFklg1waNGPmqJhCrKtPQ
# 0WeNG0a+RzDVLnLRxWPa52N5RH5LYySJhi40PylMUosqp8DikSiJucBb+R3Z5yet
# /5oCl8HGUJKbAiy9qbk0WQq/hEr/3/6zn+vZnuCYI+yma3cWKtvMrTscpIfcRnNe
# GWJoRVfkkIJCu0LW8GHgwaM9ZqNd9BjuiMmNF0UpmTJ1AjHuKSbIawLmtWJFfzcV
# WiNoidQ+3k4nsPBADLxNF8tNorMe0AZa3faTz1d1mfX6hhpneLO/lv403L3nUlbl
# s+V1e9dBkQXcXWnjlQ1DufyDljmVe2yAWk8TcsbXfSl6RLpSpCrVQUYJIP4ioLZb
# MI28iQzV13D4h1L92u+sUS4Hs07+0AnacO+Y+lbmbdu1V0vc5SwlFcieLnhO+Nqc
# noYsylfzGuXIkosagpZ6w7xQEmnYDlpGizrrJvojybawgb5CAKT41v4wLsfSRvbl
# jnX98sy50IdbzAYQYLuDNbdeZ95H7JlI8aShFf6tjGKOOVVPORa5sWOd/7cCAwEA
# AaOCAT4wggE6MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFLahVDkCw6A/joq8
# +tT4HKbROg79MB8GA1UdIwQYMBaAFAh2zcsH/yT2xc3tu5C84oQ3RnX3MA4GA1Ud
# DwEB/wQEAwIBBjAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8vY3JsLmNlcnR1bS5w
# bC9jdG5jYS5jcmwwawYIKwYBBQUHAQEEXzBdMCgGCCsGAQUFBzABhhxodHRwOi8v
# c3ViY2Eub2NzcC1jZXJ0dW0uY29tMDEGCCsGAQUFBzAChiVodHRwOi8vcmVwb3Np
# dG9yeS5jZXJ0dW0ucGwvY3RuY2EuY2VyMDkGA1UdIAQyMDAwLgYEVR0gADAmMCQG
# CCsGAQUFBwIBFhhodHRwOi8vd3d3LmNlcnR1bS5wbC9DUFMwDQYJKoZIhvcNAQEM
# BQADggEBAFHCoVgWIhCL/IYx1MIy01z4S6Ivaj5N+KsIHu3V6PrnCA3st8YeDrJ1
# BXqxC/rXdGoABh+kzqrya33YEcARCNQOTWHFOqj6seHjmOriY/1B9ZN9DbxdkjuR
# mmW60F9MvkyNaAMQFtXx0ASKhTP5N+dbLiZpQjy6zbzUeulNndrnQ/tjUoCFBMQl
# lVXwfqefAcVbKPjgzoZwpic7Ofs4LphTZSJ1Ldf23SIikZbr3WjtP6MZl9M7JYjs
# NhI9qX7OAo0FmpKnJ25FspxihjcNpDOO16hO0EoXQ0zF8ads0h5YbBRRfopUofbv
# n3l6XYGaFpAP4bvxSgD5+d2+7arszgowggaCMIIEaqADAgECAhAo8HfBHDa9/l90
# MkdwJy4DMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhB
# c3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3Rh
# bXBpbmcgMjAyMSBDQTAeFw0yNjAzMTEwNzM0NTRaFw0zNjAyMjcwNzM0NTRaMFAx
# CzAJBgNVBAYTAlBMMSEwHwYDVQQKDBhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4x
# HjAcBgNVBAMMFUNlcnR1bSBUaW1lc3RhbXAgMjAyNjCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALi9zfBw+xI12hi2F9uNQBNOSTkTIi13fuh3DiWybI53
# 92bBfJw6tO7zDs7UqP/rejVf4xFTU3XNOPsuOFkP5SPFsnWwn3VJL+NhNhsuujvY
# sQtaQnvNo1wk46reTgws1L8OFEdKaxgyqT4zOQx81mLwNZSqXNU9Rrb9oAJWJF4M
# ydz+C1ebu0D0+vgM3tqAQ8TU203fqgKCPqIdHloaFqH9eyR+8tnpmy2hnnN59ZOt
# msuHeRwf5iTOhlhf0d/qqquLOSIGPgGVL1Hj5XBUox2OE7tQRr+l/xxNbL6OuwBO
# 4Aa2EbuxYg37cpXv5i2/lTL4NASB/duf9W4fjA3Ro+GP+bC54n2OYiM3Cq8z92ej
# x8F5HWO2e4/75eC95B9tMw/eq7109GDyW2+2ut5Bn0o8MXJTERkyystWbqcnUkom
# A97qfiDCwvpWuOMdfTOksXe9S+xDxOJaCbiyTivgPulxcT+tfQTRXBr5UwtPvc+I
# NnafOEilzVHA11tv+pHcylryxBc08cUihf/ttqkZS0bmx3VxQay8uohaTp0//ECA
# 9vYGW51SKdJMJhXvKyIdBLy8WYNchTt8yRITv9Adxg9JqGujh+TnP1bW3aQjFtlE
# l7SzgNeI8OVA/CJAWWUuRT3Au9ToOpHy/flrrknhN4heEw7/6ILMv4HSsj0YZ4ot
# AgMBAAGjggFQMIIBTDB1BggrBgEFBQcBAQRpMGcwOwYIKwYBBQUHMAKGL2h0dHA6
# Ly9zdWJjYS5yZXBvc2l0b3J5LmNlcnR1bS5wbC9jdHNjYTIwMjEuY2VyMCgGCCsG
# AQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMB8GA1UdIwQYMBaA
# FL5UAi+/QGxzQ86sCSVOnkNEGu7gMAwGA1UdEwEB/wQCMAAwOQYDVR0fBDIwMDAu
# oCygKoYoaHR0cDovL3N1YmNhLmNybC5jZXJ0dW0ucGwvY3RzY2EyMDIxLmNybDAW
# BgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwIgYDVR0gBBsw
# GTAIBgZngQwBBAIwDQYLKoRoAYb2dwIFAQswHQYDVR0OBBYEFCM5aiirmhKnpKfy
# H/lFmr+N/oIDMA0GCSqGSIb3DQEBDAUAA4ICAQBm/pObrAveTqYFPCSthxNVwBHT
# W4TfuBQY2KGCdMlH6ALjVPYf2XARNGMTXScR0JQ2/c2LxLpoHHhRwxFf3d933DhF
# S165rYj6iPSQKm41rc9AMpTCjMdmai1aK9o870pOzTzLRhWFVIxm+5Qf+t4V5z14
# tPoUsAWdfRKD1Zzvzfe5AHlE9rxOZcGROiULxs3Edf7ZJ8RZI0jzD9juj2oEX2XS
# 7BVKuNCK1W0h1mjapv028yqo8UtZh5/1Ib48Yyp88BDYShh5PSGUUuS5tYXVfcdu
# IPBe3PdNTYRYdT5VNxkwLgjMzIcr/6SH2fejFJDjnCxjvXLuarErJg/IdI+hXdGI
# BDVOGv1zrkF4ktoQvFZIp5DIAYh0GwyUhc87qqn5UaYTj2+iyiBDSNh7aGCrkuAn
# qg7Qh7frhX+QhMGeJ9SpLpnG76qN85hLyjvYR6gRYiLTj8G4fxjqV400/buPw0rB
# o9yJZyq/8cGdCOLPOYf9qpefTcrZKeO9pg+UJHx8UABbaTqizRxm8sUSEycccCCF
# hIit3AI/3wGuSOADeiA676NcQ7+dsP04YvzvdN7pTZNyg672WpBDJdg0eItHl4yo
# mvNeIOWh1qs4QqOW6TI8Ocsi4uSDTLorxLUDnBTwKQzzpxd1YUctEgRh32R0J9Fk
# FkeEruJU94RljFr1uDCCBrkwggShoAMCAQICEQCZo4AKJlU7ZavcboSms+o5MA0G
# CSqGSIb3DQEBDAUAMIGAMQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5pemV0byBU
# ZWNobm9sb2dpZXMgUy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmljYXRpb24g
# QXV0aG9yaXR5MSQwIgYDVQQDExtDZXJ0dW0gVHJ1c3RlZCBOZXR3b3JrIENBIDIw
# HhcNMjEwNTE5MDUzMjE4WhcNMzYwNTE4MDUzMjE4WjBWMQswCQYDVQQGEwJQTDEh
# MB8GA1UEChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0
# dW0gQ29kZSBTaWduaW5nIDIwMjEgQ0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCdI88EMCM7wUYs5zNzPmNdenW6vlxNur3rLfi+5OZ+U3iZIB+AspO+
# CC/bj+taJUbMbFP1gQBJUzDUCPx7BNLgid1TyztVLn52NKgxxu8gpyTr6EjWyGzK
# U/gnIu+bHAse1LCitX3CaOE13rbuHbtrxF2tPU8f253QgX6eO8yTbGps1Mg+yda3
# DcTsOYOhSYNCJiL+5wnjZ9weoGRtvFgMHtJg6i671OPXIciiHO4Lwo2p9xh/tnj+
# JmCQEn5QU0NxzrOiRna4kjFaA9ZcwSaG7WAxeC/xoZSxF1oK1UPZtKVt+yrsGKqW
# ONoK6f5EmBOAVEK2y4ATDSkb34UD7JA32f+Rm0wsr5ajzftDhA5mBipVZDjHpwzv
# 8bTKzCDUSUuUmPo1govD0RwFcTtMXcfJtm1i+P2UNXadPyYVKRxKQATHN3imsfBi
# NRdN5kiVVeqP55piqgxOkyt+HkwIA4gbmSc3hD8ke66t9MjlcNg73rZZlrLHsAIV
# /nJ0mmgSjBI/TthoGJDydekOQ2tQD2Dup/+sKQptalDlui59SerVSJg8gAeV7N/i
# a4mrGoiez+SqV3olVfxyLFt3o/OQOnBmjhKUANoKLYlKmUpKEFI0PfoT8Q1W/y6s
# 9LTI6ekbi0igEbFUIBE8KDUGfIwnisEkBw5KcBZ3XwnHmfznwlKo8QIDAQABo4IB
# VTCCAVEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU3XRdTADbe5+gdMqxbvc8
# wDLAcM0wHwYDVR0jBBgwFoAUtqFUOQLDoD+Oirz61PgcptE6Dv0wDgYDVR0PAQH/
# BAQDAgEGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMDAGA1UdHwQpMCcwJaAjoCGGH2h0
# dHA6Ly9jcmwuY2VydHVtLnBsL2N0bmNhMi5jcmwwbAYIKwYBBQUHAQEEYDBeMCgG
# CCsGAQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMDIGCCsGAQUF
# BzAChiZodHRwOi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RuY2EyLmNlcjA5BgNV
# HSAEMjAwMC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3dy5jZXJ0dW0u
# cGwvQ1BTMA0GCSqGSIb3DQEBDAUAA4ICAQB1iFgP5Y9QKJpTnxDsQ/z0O23JmoZi
# fZdEOEmQvo/79PQg9nLF/GJe6ZiUBEyDBHMtFRK0mXj3Qv3gL0sYXe+PPMfwmreJ
# HvgFGWQ7XwnfMh2YIpBrkvJnjwh8gIlNlUl4KENTK5DLqsYPEtRQCw7R6p4s2EtW
# yDDr/M58iY2UBEqfUU/ujR9NuPyKk0bEcEi62JGxauFYzZ/yld13fHaZskIoq2Xa
# zjaD0pQkcQiIueL0HKiohS6XgZuUtCKA7S6CHttZEsObQJ1j2s0urIDdqF7xaXFV
# aTHKtAuMfwi0jXtF3JJphrJfc+FFILgCbX/uYBPBlbBIP4Ht4xxk2GmfzMn7oxPI
# TpigQFJFWuzTMUUgdRHTxaTSKRJ/6Uh7ki/pFjf9sUASWgxT69QF9Ki4JF5nBIuj
# xZ2sOU9e1HSCJwOfK07t5nnzbs1LbHuAIGJsRJiQ6HX/DW1XFOlXY1rc9HufFhWU
# +7Uk+hFkJsfzqBz3pRO+5aI6u5abI4Qws4YaeJH7H7M8X/YNoaArZbV4Ql+jarKs
# E0+8XvC4DJB+IVcvC9Ydqahi09mjQse4fxfef0L7E3hho2O3bLDM6v60rIRUCi2f
# JT2/IRU5ohgyTch4GuYWefSBsp5NPJh4QRTP9DC3gc5QEKtbrTY0Ka87Web7/zSc
# vLmvQBm8JDFpDjCCBrkwggShoAMCAQICEQDn/2nHOzXOS5Em2HR8aKWHMA0GCSqG
# SIb3DQEBDAUAMIGAMQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5pemV0byBUZWNo
# bm9sb2dpZXMgUy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmljYXRpb24gQXV0
# aG9yaXR5MSQwIgYDVQQDExtDZXJ0dW0gVHJ1c3RlZCBOZXR3b3JrIENBIDIwHhcN
# MjEwNTE5MDUzMjA3WhcNMzYwNTE4MDUzMjA3WjBWMQswCQYDVQQGEwJQTDEhMB8G
# A1UEChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0g
# VGltZXN0YW1waW5nIDIwMjEgQ0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQDpEh8ENe25XXrFppVBvoplf0530W0lddNmjtv4YSh/f7eDQKFaIqc7tHj7
# ox+u8vIsJZlroakUeMS3i3T8aJRC+eQs4FF0GqvkM6+WZO8kmzZfxmZaBYmMLs8F
# ktgFYCzywmXeQ1fEExflee2OpbHVk665eXRHjH7MYZIzNnjl2m8Hy8ulB9mR8wL/
# W0v0pjKNT6G0sfrx1kk+3OGosFUb7yWNnVkWKU4qSxLv16kJ6oVJ4BSbZ4xMak6J
# LeB8szrK9vwGDpvGDnKCUMYL3NuviwH1x4gZG0JAXU3x2pOAz91JWKJSAmRy/l0s
# 0l5bEYKolg+DMqVhlOANd8Yh5mkQWaMEvBRE/kAGzIqgWhwzN2OsKIVtO8mf5sPW
# SrvyplSABAYa13rMYnzwfg08nljZHghquCJYCa/xHK9acev9UD7Y+usr15d7mrsz
# zxhF1JOr1Mpup2chNSBlyOObhlSO16rwrffVrg/SzaKfSndS5swRhr8bnDqNJY9T
# NyEYvBYpgF95K7p0g4LguR4A++Z1nFIHWVY5v0fNVZmgzxD9uVo/gta3onGOQj3J
# CxgYx0KrCXu4yc9QiVwTFLWbNdHFSjBCt5/8Q9pLuRhVocdCunhcHudMS1CGQ/Rn
# 0+7P+fzMgWdRKfEOh/hjLrnQ8BdJiYrZNxvIOhM2aa3zEDHNwwIDAQABo4IBVTCC
# AVEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUvlQCL79AbHNDzqwJJU6eQ0Qa
# 7uAwHwYDVR0jBBgwFoAUtqFUOQLDoD+Oirz61PgcptE6Dv0wDgYDVR0PAQH/BAQD
# AgEGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMDAGA1UdHwQpMCcwJaAjoCGGH2h0dHA6
# Ly9jcmwuY2VydHVtLnBsL2N0bmNhMi5jcmwwbAYIKwYBBQUHAQEEYDBeMCgGCCsG
# AQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMDIGCCsGAQUFBzAC
# hiZodHRwOi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RuY2EyLmNlcjA5BgNVHSAE
# MjAwMC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3dy5jZXJ0dW0ucGwv
# Q1BTMA0GCSqGSIb3DQEBDAUAA4ICAQC4k1l3yUwV/ZQHCKCneqAs8EGTnwEUJLdD
# pokN/dMhKjK0rR5qX8nIIHzxpQR3TAw2IRw1Uxsr2PliG3bCFqSdQTUbfaTq6V3v
# BzEebDru9QFjqlKnxCF2h1jhLNFFplbPJiW+JSnJTh1fKEqEdKdxgl9rVTvlxfEJ
# 7exOn25MGbd/wGPwuSmMxRJVO0wnqgS7kmoJjNF9zqeehFSDDP8ZVkWg4EZ2tIS0
# M3uZmByRr+1Lkwjjt8AtW83mVnZTyTsOb+FNfwJY7DS4FmWhkRbgcHRetreoTirP
# Or/ozyDKhT8MTSTf6Lttg6s6T/u08mDWw6HK04ZRDfQ9sb77QV8mKgO44WGP31vX
# nVKoWVJpFBjPvjL8/Zck/5wXX2iqjOaLStFOR/IQki+Ehn4zlcgVm22ZVCBPF+l8
# nAwUUShCtKuSU7GmZLKCmmxQMkSiWILTm8EtVD6AxnJhoq8EnhjEEyUoflkeRF2W
# hFiVQOmWTwZRr44IxWGkNJC6tTorW5rl2Zl+2e9JLPYf3pStAPMDoPKIjVXd6NW2
# +fZrNUBeDo2eOa5Fn7Brs/HLQff5Xgris5MeUbdVgDrF8uxO6cLPvZPo63j62SsN
# g55pTWk9fUIF9iPoRbb4QurjoY/woI1RAOKtYtTic6aAJq3u83RIPpGXBSJKwx4K
# JAOZnCDCtTCCBtcwggS/oAMCAQICEBDvKijbxBHkfB51dwwvF+YwDQYJKoZIhvcN
# AQELBQAwVjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3Rl
# bXMgUy5BLjEkMCIGA1UEAxMbQ2VydHVtIENvZGUgU2lnbmluZyAyMDIxIENBMB4X
# DTI2MTEyMzEwNDEyOVoXDTI4MDIyNTEwNDEyOFowfTELMAkGA1UEBhMCUEwxEjAQ
# BgNVBAgMCXBvbW9yc2tpZTEQMA4GA1UEBwwHR2RhxYRzazEjMCEGA1UECgwaeERs
# YWJzIEdyemVnb3J6IEt1bGlrb3dza2kxIzAhBgNVBAMMGnhEbGFicyBHcnplZ29y
# eiBLdWxpa293c2tpMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAk/Zd
# 6qSdAQ3L9BECicqWAGSDNG73qUNr4iVjgvgAQUL2zRSE/ecrxZSxsdGzicFviiyF
# vr9nIDVoCj0HbSq0ZGzavaN4lgOXkBCFZ+t7v7YOEhvEk2NuIGvboH/KWMGyorXv
# v5To+2k0s1A9Ep8RNT38GZ2XoFRfLhoagNiBkeOfMVECmjLZbGQonGfgbaXTc8Cy
# lj0TiC6NcKBjCH666Nv71EY+rUdYXcq1qhJbt/JiwjcCcLWKv17NrpuO4zxz/MMj
# fMkbS0HOtEXS6EXiDhVxUjwnzfE97tvdRo9lU9V9XzznFDvaRHFCKm0Qg8DpMnbP
# 874aqvaglWQZyRkbAXzBp4Wfo1YtRO3hhrM5tJYTWnRsGuzxO820g70sfkiaNO/B
# o2j0p/iBiuYAKjHuv5MUjWS8uld3e3VRA3EeYcqfelFccPefNdSZlKvyEdxfxE6H
# t7y17xY7Q1+VGQdSDkbZtDb+WxcQxXkqFfm9VW5RqHl+rVQZOlbHBuHb/GiLpOBb
# HahKOsxP+3YlSpuGOlOaVaM/jA8Tw3GkG0zMSsq2Yv3qJZrF7WpWUE6lE82yvtbL
# 9lg2r7/nhQTs4F3Lnx7fOyyP0wAsdKQQzz3CpXCHGvYiwM3o8aUaxyHpgvHprhW5
# SVUfNwIle1YsOsdbwQ3W8Uu+Tii28BQAeykx6X8CAwEAAaOCAXgwggF0MAwGA1Ud
# EwEB/wQCMAAwPQYDVR0fBDYwNDAyoDCgLoYsaHR0cDovL2Njc2NhMjAyMS5jcmwu
# Y2VydHVtLnBsL2Njc2NhMjAyMS5jcmwwcwYIKwYBBQUHAQEEZzBlMCwGCCsGAQUF
# BzABhiBodHRwOi8vY2NzY2EyMDIxLm9jc3AtY2VydHVtLmNvbTA1BggrBgEFBQcw
# AoYpaHR0cDovL3JlcG9zaXRvcnkuY2VydHVtLnBsL2Njc2NhMjAyMS5jZXIwHwYD
# VR0jBBgwFoAU3XRdTADbe5+gdMqxbvc8wDLAcM0wHQYDVR0OBBYEFO2iQOyHh0wS
# z0VDhZUtZKA8lK0tMEsGA1UdIAREMEIwCAYGZ4EMAQQBMDYGCyqEaAGG9ncCBQEE
# MCcwJQYIKwYBBQUHAgEWGWh0dHBzOi8vd3d3LmNlcnR1bS5wbC9DUFMwEwYDVR0l
# BAwwCgYIKwYBBQUHAwMwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAkSu7CvJjSVr74lRElbdVuSJkHs0pHJJLBk9JeNJR43eNMcWFmH/mBP3PuAHNz
# 6BQGsy+U4nhHkMSn+9ZBI05I/D68Xzm9A6Si+M5O0vrvUOHgCXP0SVB+mo/LZYNs
# yx/PRRdeWzQw7u5iprKtRvBnIvilw6XSLfeNWHuEQDM5MiNSj/t7ai0/+buB+yTr
# NEN4Hy/1N/CPWbCWk8DmjQEz+oqz++dHoeaE3AL6EWL+LM/r6CNVSNXQABa6IdC1
# hPJygcX3KDs2xsmNqgEXQ2SdIn9iGr4n2DZd5zvlSJuFDTN07/w5k+0OW6oWMRUK
# he+dA0uBoqFQySC1WKS0mClv1tCZa1eDbrunzE7QK73SkGH7gk8d41TZkxCf5Zzy
# lJeE+CIjXSKn9lbN09qWwFkUJE0J6wJyrKFFFu675oXnYXjp0T+SlJbHcGSiivE+
# aCN2UHWuIwoY+5v6TXpoWCkgAmB1IubbT/X4cTRp1OWyeNxmSVxj2D1qmuLJcAmN
# kLhGMGX04ApTZ8tQdxscmvdD9SMoifjDEKnM/i0Yg7JubwvwaYWA3G18+hnqa2cZ
# fhTJQGIHbTJixbgXLhS9K+KGUbcccT2Mo07YmT//aqx7bp/pqoQd19V2JA/xwCcl
# 1of7rlnKHGEoDq2YwmUtXK8R8XMjoEgkAmf+6tNJDj8k/zGCByIwggceAgEBMGow
# VjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5B
# LjEkMCIGA1UEAxMbQ2VydHVtIENvZGUgU2lnbmluZyAyMDIxIENBAhAQ7yoo28QR
# 5HwedXcMLxfmMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKA
# AKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIM/9eLPhukL7KbMJXOXmqBj5
# MVEbk/Z78vQbQcZUbz9tMA0GCSqGSIb3DQEBAQUABIICAB1RQGoIWVz+aER981jr
# LAanvio/iUmYiaBt4g1PYAoWUjdDVkpqpvxR0366e334qRY34xSqPftdrWrmX9AE
# ymPAhkGm/u42NCwANvrDDSIrn3AA6qWvRYjaNEi9c4Nv/r328E5LAJUlQ4kyoc/h
# hlTFcr1ln7M1Je6D4Z04QjGavoUrkE8faNw1DYO31B9Yd9S3Zsjm1gcwu0EeToht
# mxaLDMjsScqHneTceyPZ6RmVSMLFtJmisNnPcS2udDAcw2s72XVjiZqEIA8nLDCI
# RuiD1wr97cPMEp9mFVwbjs7gbgkcL86Ajy8l7NpJsleVsyJzzQY2Qhkqh6+n2c1V
# +5H53mJzRuECVPrcS00Cm4uG/cILYJDN1Ow5AZKmMHgjACam3OJY6ZSLjDufw4cM
# dRL/obMTcctKQoFU1V/2id3Xe8hGw+AMaI8UZ1AHNbwp8hVgM0uwIUWaPcIGcGxj
# 7FLCupjze0t/Ek0cVJTvre9acZD79ODuMFpojQ46626v5aEi84qIKDN1qbhfPcze
# iuKheJDTWtmy5VuxPcAzpCvcx0k29hqDQflY6nL8BgcXAkFoXmFavI6VrQMFqQmi
# 96aNgy6kMg5wSYo7/cOZ2EAW6bSEXYiwARBStNOCnVfwjjavtwligM1D6Hf4ynwJ
# lwh8dzw6UiDRQi8fvc9f7XSEoYIEAjCCA/4GCSqGSIb3DQEJBjGCA+8wggPrAgEB
# MGowVjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMg
# Uy5BLjEkMCIGA1UEAxMbQ2VydHVtIFRpbWVzdGFtcGluZyAyMDIxIENBAhAo8HfB
# HDa9/l90MkdwJy4DMA0GCWCGSAFlAwQCAgUAoIIBVjAaBgkqhkiG9w0BCQMxDQYL
# KoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MTEyNzAwMjcxNlowNwYLKoZI
# hvcNAQkQAi8xKDAmMCQwIgQghb6Q4QrSQ418ySi2r0iwmrIIF3zs+LASbFjTkQUl
# xDwwPwYJKoZIhvcNAQkEMTIEMDDoW7c5mZLMKKDb8ZQ3FqbyIG4a0meNvriqOWXv
# YeQzds4bgo0H9qGq6nZ01lKfIzCBnwYLKoZIhvcNAQkQAgwxgY8wgYwwgYkwgYYE
# FFcUaEEMqFrzQk75FkpRNhD0042YMG4wWqRYMFYxCzAJBgNVBAYTAlBMMSEwHwYD
# VQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBU
# aW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2vf5fdDJHcCcuAzANBgkqhkiG9w0B
# AQEFAASCAgChhrF3LXGxJOJFN23PF55Hy+DfDM8bZRJDdz46yOQjJhz6yT1EP/hL
# ySOZYNrzkDVkq+aLjO924JWQptPAHtPjRXzAykfY2z8Mxbi4xgy5sjFzPG2E297f
# f828IYU3IhDAeegrLyzGt/f8o7SjbTPoYWyuZ4fE/Qnd74p69pFklw8vkm2dPsk5
# NxdUt9hLR307/Fo6w16lVejbcnqN/N1cJwQ9/QNCh9+wrmEvmvdARuQf4R77CY+G
# tH0UDy4IO8nWzKJ+q6kpVQVisYooM518+F3BB8veEHH3GoRMwQ1kmVn1DrwKpQfL
# ynGc05167/eMBdESmz8VzVu/EbLXodR6b9+flRwNAl4sDv+ywGs2xiyTcSNJqgrf
# oSKdwIe0Scc9z0vBjIVKO2d5ysIYqypn1TfNqj/iXlR33J/No/3vRWjxrf8JCf2A
# Hd/60xjMfaXI95JrKuddnF3b4Lo8aeTwlYsgpriMP5oAFNGVBgs7d/2HWVManUkB
# mZeeIh+rR8WbBclaVomZylmSi8OQgMXvQvw2LHwKePXShUf2wFZKsPkcc7wexuJo
# OJcgSvqcCLxW5mw6D6g65u8Is8qLnKhYY8wd+kFdtF2sSDzXXRrb4ZwQxSZKsJeN
# 6wr502YXW62J26rQjI+9DSo5fJOWn2XhfgEkM1F0lHa5fL5uRsIuNw==
# SIG # End signature block
