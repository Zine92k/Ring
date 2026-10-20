<# : Ring.bat - double-clique ici pour lancer Ring
@echo off
if not "%~1"=="go" (
  start "Ring" /min "%~f0" go
  exit /b
)
set "RING_FILE=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:RING_FILE, [Text.Encoding]::UTF8))"
exit /b
#>
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Ring - laisse cette fenetre ouverte (reduite)' } catch {}

$RingFile = $env:RING_FILE
if (-not $RingFile) { $RingFile = $PSCommandPath }
$Dir = Split-Path -Parent $RingFile
$StorePath = Join-Path $Dir 'Ring-sauvegarde.json'
$BackupPath = Join-Path $Dir 'Ring-sauvegarde-secours.json'
$LegacyPath = Join-Path $Dir 'ring-cine.html'
$Port = if ($env:RING_PORT) { [int]$env:RING_PORT } else { 8765 }
$Base = "http://localhost:$Port/"

# ---------------------------------------------------------------- mise a jour automatique (depuis GitHub)
$RingVersion = '2026.10.20.1'
$UpdateBase = 'https://raw.githubusercontent.com/Zine92k/Ring/main/'
function Get-RingUrl([string]$u) {
  $r = [Net.HttpWebRequest]::Create($u + '?t=' + [DateTime]::UtcNow.Ticks)
  $r.Timeout = 6000; $r.ReadWriteTimeout = 20000; $r.UserAgent = 'Ring-updater'
  $resp = $r.GetResponse(); $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $resp.Close()
  return ,$ms.ToArray()
}
if (-not $env:RING_NO_UPDATE) {
  try {
    $remote = ([Text.Encoding]::UTF8.GetString((Get-RingUrl ($UpdateBase + 'version.txt')))).Trim()
    if ($remote -match '^\d+\.\d+\.\d+\.\d+$' -and ([version]$remote) -gt ([version]$RingVersion)) {
      Write-Host ('  Nouvelle version de Ring trouvee (' + $remote + '), mise a jour...')
      $bytes = Get-RingUrl ($UpdateBase + 'Ring.bat')
      $txt = [Text.Encoding]::UTF8.GetString($bytes)
      if ($bytes.Length -gt 100000 -and $txt.TrimStart([char]0xFEFF).StartsWith('<# : Ring.bat') -and $txt.Contains("`$RingVersion = '" + $remote + "'")) {
        [IO.File]::WriteAllBytes($RingFile + '.new', $bytes)
        Copy-Item -LiteralPath $RingFile -Destination ($RingFile + '.old') -Force
        Move-Item -LiteralPath ($RingFile + '.new') -Destination $RingFile -Force
        Write-Host '  Ring est a jour ! Redemarrage...'
        Start-Process -FilePath $RingFile -ArgumentList 'go' -WindowStyle Minimized
        return
      }
    }
  } catch { Write-Host '  (verification de mise a jour impossible : Ring demarre avec la version actuelle)' }
}

# ---------------------------------------------------------------- outils partagés (aussi dans les tâches de fond)
$Common = @'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
function JStr([string]$s) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}
function ToJson($o) {
  if ($null -eq $o) { return 'null' }
  if ($o -is [string]) { return (JStr $o) }
  if ($o -is [bool]) { if ($o) { return 'true' } else { return 'false' } }
  if ($o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal] -or $o -is [single]) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $o) }
  if ($o -is [Collections.IDictionary]) {
    $parts = New-Object Collections.ArrayList
    foreach ($k in $o.Keys) { [void]$parts.Add((JStr ([string]$k)) + ':' + (ToJson $o[$k])) }
    return '{' + ($parts -join ',') + '}'
  }
  if ($o -is [Collections.IEnumerable]) {
    $parts = New-Object Collections.ArrayList
    foreach ($x in $o) { [void]$parts.Add((ToJson $x)) }
    return '[' + ($parts -join ',') + ']'
  }
  return (JStr ([string]$o))
}
function Web([string]$u, [hashtable]$h = @{}, [string]$body = '') {
  $req = [Net.HttpWebRequest]::Create($u)
  $req.UserAgent = $UA
  $req.Timeout = 30000
  $req.ReadWriteTimeout = 30000
  $req.Accept = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
  $req.Headers.Add('Accept-Language', 'fr-FR,fr;q=0.9,en;q=0.8')
  $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
  foreach ($k in $h.Keys) {
    if ($k -eq 'Accept') { $req.Accept = $h[$k] }
    elseif ($k -eq 'Content-Type') { $req.ContentType = $h[$k] }
    else { $req.Headers.Add($k, $h[$k]) }
  }
  if ($body) {
    $req.Method = 'POST'
    $b = [Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $b.Length
    $st = $req.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close()
  }
  try { $res = $req.GetResponse() }
  catch [Net.WebException] {
    if ($_.Exception.Response) { throw ('HTTP ' + [int]$_.Exception.Response.StatusCode) }
    throw ('connexion impossible (' + $_.Exception.Message + ')')
  }
  $sr = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
  $t = $sr.ReadToEnd(); $sr.Close(); $res.Close()
  return $t
}
function YT([string]$q) {
  try {
    $body = '{"context":{"client":{"clientName":"WEB","clientVersion":"2.20250925.01.00","hl":"fr","gl":"FR"}},"query":' + (JStr $q) + '}'
    $t = Web 'https://www.youtube.com/youtubei/v1/search?prettyPrint=false&key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8' @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json' } $body
    $m = [regex]::Match($t, '"videoRenderer":\{"videoId":"([\w-]{11})"')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch {}
  return ''
}
function YTList([string]$q) {
  $out = New-Object Collections.ArrayList
  try {
    $body = '{"context":{"client":{"clientName":"WEB","clientVersion":"2.20250925.01.00","hl":"fr","gl":"FR"}},"query":' + (JStr $q) + '}'
    $t = Web 'https://www.youtube.com/youtubei/v1/search?prettyPrint=false&key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8' @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json' } $body
    $ms = [regex]::Matches($t, '"videoRenderer":\{"videoId":"([\w-]{11})".{0,4000}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"')
    foreach ($m in $ms) { if ($out.Count -ge 10) { break }; [void]$out.Add('{"id":"' + $m.Groups[1].Value + '","t":"' + $m.Groups[2].Value + '"}') }
  } catch {}
  return '[' + ($out -join ',') + ']'
}
function YTReq([string]$u, [string]$ua, [string]$body) {
  $w = [Net.HttpWebRequest]::Create($u); $w.UserAgent = $ua; $w.Timeout = 15000; $w.ReadWriteTimeout = 15000
  $w.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
  $w.Headers.Add('Accept-Language', 'fr-FR,fr;q=0.9,en;q=0.8')
  if ($body) { $w.Method = 'POST'; $w.ContentType = 'application/json'; $b = [Text.Encoding]::UTF8.GetBytes($body); $w.ContentLength = $b.Length; $st = $w.GetRequestStream(); $st.Write($b, 0, $b.Length); $st.Close() }
  $r = $w.GetResponse(); $sr = New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $r.Close(); return $t
}
function YTSubs([string]$v) {
  if ($v -notmatch '^[\w-]{11}$') { return '{"data":null}' }
  $clients = @(
    @{ n = 'ANDROID'; v = '19.44.38'; ua = 'com.google.android.youtube/19.44.38 (Linux; U; Android 14) gzip'; x = ',"androidSdkVersion":34' },
    @{ n = 'WEB'; v = '2.20250925.01.00'; ua = $UA; x = '' },
    @{ n = 'IOS'; v = '19.45.4'; ua = 'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1 like Mac OS X)'; x = ',"deviceModel":"iPhone16,2"' }
  )
  foreach ($cl in $clients) {
    try {
      $body = '{"context":{"client":{"clientName":"' + $cl.n + '","clientVersion":"' + $cl.v + '"' + $cl.x + ',"hl":"fr","gl":"FR"}},"videoId":"' + $v + '"}'
      $j = (YTReq 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false' $cl.ua $body) | ConvertFrom-Json
      $tracks = @($j.captions.playerCaptionsTracklistRenderer.captionTracks | Where-Object { $_ })
      if ($tracks.Count -eq 0) { continue }
      $tl = ''
      $pick = $tracks | Where-Object { $_.languageCode -like 'fr*' -and $_.kind -ne 'asr' } | Select-Object -First 1
      if (-not $pick) { $pick = $tracks | Where-Object { $_.languageCode -like 'en*' -and $_.kind -ne 'asr' } | Select-Object -First 1; $tl = 'fr' }
      if (-not $pick) { $pick = $tracks | Where-Object { $_.kind -ne 'asr' } | Select-Object -First 1; $tl = 'fr' }
      if (-not $pick) { $pick = $tracks | Select-Object -First 1; if ([string]$pick.languageCode -notlike 'fr*') { $tl = 'fr' } }
      $u = ([string]$pick.baseUrl) -replace '&fmt=[^&]*', ''
      $u += '&fmt=json3'; if ($tl) { $u += '&tlang=' + $tl }
      $data = YTReq $u $cl.ua ''
      if ((-not $data -or $data.Length -lt 30) -and $tl) { $data = YTReq ((([string]$pick.baseUrl) -replace '&fmt=[^&]*', '') + '&fmt=json3') $cl.ua ''; $tl = '' }
      if ($data -and $data.Length -ge 30) { return '{"lang":' + (JStr ([string]$pick.languageCode)) + ',"tr":' + $(if ($tl) { 'true' } else { 'false' }) + ',"data":' + (JStr $data) + '}' }
    } catch {}
  }
  return '{"data":null}'
}
function RunParallel($items, [string]$script, [string]$CommonText, $J, [int]$threads) {
  $pool = [runspacefactory]::CreateRunspacePool(1, $threads); $pool.Open()
  $tasks = New-Object Collections.ArrayList
  foreach ($it in $items) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript("param(`$it, `$CommonText)`n" + $CommonText + "`n" + $script).AddArgument($it).AddArgument($CommonText)
    [void]$tasks.Add(@($ps, $ps.BeginInvoke()))
  }
  $out = New-Object Collections.ArrayList
  foreach ($t in $tasks) {
    try { $r = $t[0].EndInvoke($t[1]); foreach ($x in $r) { [void]$out.Add($x.psobject.BaseObject) } } catch {}
    $t[0].Dispose(); $J.done = $J.done + 1
  }
  $pool.Close()
  return ,$out
}
'@
. ([scriptblock]::Create($Common))

# ---------------------------------------------------------------- tâches de mise à jour
$JobScripts = @{}
$JobScripts['lbList'] = @'
$user = [string]$A.user
$first = Web ('https://letterboxd.com/' + $user + '/films/')
if ($first -match 'Just a moment\.\.\.|challenge-platform') { throw 'Letterboxd demande une verification anti-robot : utilise Ring Sync (plan B)' }
$name = $user
$mt = [regex]::Match($first, '<title>([^<]*)</title>')
if ($mt.Success) {
  $n = [Net.WebUtility]::HtmlDecode($mt.Groups[1].Value) -replace '[\u200e\u200f]', ''
  $n = ($n -replace '[\u2019\x27]s films.*$', '').Trim()
  if ($n) { $name = $n }
}
$last = 1
foreach ($m in [regex]::Matches($first, '/films/page/(\d+)/')) { $v = [int]$m.Groups[1].Value; if ($v -gt $last) { $last = $v } }
$J.total = $last; $J.done = 1
$pages = New-Object Collections.ArrayList
[void]$pages.Add($first)
for ($p = 2; $p -le $last; $p++) { [void]$pages.Add((Web ('https://letterboxd.com/' + $user + '/films/page/' + $p + '/'))); $J.done = $p }
$films = New-Object Collections.ArrayList
$seen = @{}
foreach ($h in $pages) {
  foreach ($chunk in ($h -split '<li ')) {
    $mn = [regex]::Match($chunk, 'data-item-name="([^"]*)"')
    $ms = [regex]::Match($chunk, 'data-item-slug="([^"]*)"')
    if ($mn.Success -and $ms.Success) {
      $slug = $ms.Groups[1].Value
      if (-not $seen.ContainsKey($slug)) {
        $seen[$slug] = 1
        $r = 0
        $mr = [regex]::Match($chunk, 'rated-(\d+)')
        if ($mr.Success) { $r = [int]$mr.Groups[1].Value }
        [void]$films.Add(@([Net.WebUtility]::HtmlDecode($mn.Groups[1].Value), $slug, $r))
      }
    }
  }
}
$J.result = @{ name = $name; films = $films }
'@
$JobScripts['lbDetails'] = @'
$slugs = @($A.slugs)
$J.total = $slugs.Count
$one = @"
try {
  `$o = (Web ('https://letterboxd.com/film/' + `$it + '/json/')) | ConvertFrom-Json
  `$u = ''
  try { `$pj = (Web ('https://letterboxd.com/film/' + `$it + '/poster/std/150/')) | ConvertFrom-Json; if (`$pj.url2x) { `$u = [string]`$pj.url2x } elseif (`$pj.url) { `$u = [string]`$pj.url } } catch {}
  `$dirs = (@(`$o.directors) | Where-Object { `$_ } | ForEach-Object { [string]`$_.name }) -join ', '
  ,@([string]`$it, [string]`$o.name, [int]`$o.releaseYear, [string]`$dirs, [string]`$u)
} catch { ,@([string]`$it, '', 0, '', '') }
"@
$J.result = RunParallel $slugs $one $CommonText $J 6
'@
$JobScripts['spList'] = @'
$pl = [string]$A.pl
$html = Web ('https://open.spotify.com/embed/playlist/' + $pl)
$m = [regex]::Match($html, '<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', 'Singleline')
if (-not $m.Success) { throw 'page Spotify illisible' }
$d = $m.Groups[1].Value | ConvertFrom-Json
$tok = [string]$d.props.pageProps.state.settings.session.accessToken
$ent = $d.props.pageProps.state.data.entity
if (-not $tok) { throw 'jeton Spotify introuvable' }
$pj = (Web ('https://spclient.wg.spotify.com/playlist/v2/playlist/' + $pl + '?format=json') @{ 'Authorization' = ('Bearer ' + $tok); 'Accept' = 'application/json' }) | ConvertFrom-Json
$ids = New-Object Collections.ArrayList
foreach ($it in @($pj.contents.items)) { $u = [string]$it.uri; if ($u -like 'spotify:track:*') { [void]$ids.Add($u.Substring(14)) } }
$name = [string]$ent.name
if ($pj.attributes -and $pj.attributes.name) { $name = [string]$pj.attributes.name }
$J.result = @{ name = $name; owner = [string]$ent.subtitle; token = $tok; ids = $ids }
'@
$JobScripts['spDetails'] = @'
$tok = [string]$A.token
$items = New-Object Collections.ArrayList
$noyt = [bool]$A.noyt
foreach ($x in @($A.items)) { [void]$items.Add(@([string]$x[0], [string]$x[1], $tok, $noyt)) }
$J.total = $items.Count
$one = @"
`$id = `$it[0]; `$gid = `$it[1]; `$tk = `$it[2]
try {
  `$o = (Web ('https://spclient.wg.spotify.com/metadata/4/track/' + `$gid + '?market=from_token') @{ 'Authorization' = ('Bearer ' + `$tk); 'Accept' = 'application/json' }) | ConvertFrom-Json
  `$arts = @(`$o.artist | Where-Object { `$_ } | ForEach-Object { [string]`$_.name })
  `$cover = ''
  foreach (`$im in @(`$o.album.cover_group.image)) { if (`$im.size -eq 'DEFAULT') { `$cover = [string]`$im.file_id } }
  if (-not `$cover) { `$first = @(`$o.album.cover_group.image) | Select-Object -First 1; if (`$first) { `$cover = [string]`$first.file_id } }
  if (`$cover.Length -eq 40 -and `$cover.StartsWith('ab67616d00001e02')) { `$cover = `$cover.Substring(16) } elseif (`$cover) { `$cover = '!' + `$cover }
  `$clean = ([string]`$o.name) -replace '\s*[\(\[](feat|with|ft)\.?[^\)\]]*[\)\]]', ''
  `$yt = ''
  if (`$arts.Count -and -not `$it[3]) { `$yt = YT (`$arts[0] + ' ' + `$clean) }
  ,@([string]`$id, [string]`$o.name, (`$arts -join ', '), [string]`$cover, [string]`$yt)
} catch { ,@([string]`$id, '', '', '', '') }
"@
$J.result = RunParallel $items $one $CommonText $J 4
'@

$Jobs = [hashtable]::Synchronized(@{})
$Pool = [runspacefactory]::CreateRunspacePool(1, 3); $Pool.Open()
function Start-RingJob([string]$kind, $jobArgs) {
  $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
  $state = [hashtable]::Synchronized(@{ status = 'run'; done = 0; total = 0; result = $null; error = $null })
  $ps = [powershell]::Create(); $ps.RunspacePool = $Pool
  $text = 'param($J, $A, $CommonText)' + "`n" + $Common + "`ntry {`n" + $JobScripts[$kind] + "`n`$J.status = 'done'`n} catch { `$J.error = [string]`$_.Exception.Message; `$J.status = 'error' }"
  [void]$ps.AddScript($text).AddArgument($state).AddArgument($jobArgs).AddArgument($Common)
  $state.ps = $ps
  $state.handle = $ps.BeginInvoke()
  $Jobs[$id] = $state
  return $id
}

# ---------------------------------------------------------------- page du site
$HTML = @'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Ring</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:ital,wdth,wght@0,62..125,400..900;1,62..125,400..900&family=Inter:wght@400;500;600;700;800&display=swap">
<style>
:root{
  color-scheme: dark;
  --bg:#0B0D12; --bg2:#10131A; --panel:#151922; --panel2:#1C212B; --panel3:#242A36;
  --line:rgba(255,255,255,.07); --line2:rgba(255,255,255,.13);
  --text:#EEF0F3; --muted:#8C93A1; --faint:#5E6573;
  --red:#F0464C; --blue:#3F7DFF; --gold:#F2BE4B; --green:#3CC380;
  --display:"Anton","Impact","Arial Narrow",sans-serif;
  --body:"Barlow","Segoe UI",system-ui,sans-serif;
  --mono:"JetBrains Mono",ui-monospace,Consolas,monospace;
  --r:14px; --side:252px;
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text)}
body{font-family:var(--body);font-size:15px;line-height:1.45;min-height:100vh}
button,input,select,textarea{font:inherit;color:inherit}
button{cursor:pointer}
a{color:var(--blue)}
:focus-visible{outline:2px solid var(--gold);outline-offset:2px}
img{max-width:100%}

/* ---------- Structure ---------- */
.app{display:grid;grid-template-columns:var(--side) minmax(0,1fr);min-height:100vh}
.side{position:sticky;top:0;height:100vh;overflow:auto;background:var(--bg2);border-right:1px solid var(--line);padding:22px 14px;display:flex;flex-direction:column;gap:18px}
.logo{font-family:var(--display);font-size:34px;line-height:.95;letter-spacing:.02em;text-transform:uppercase;padding:0 8px;display:flex;gap:8px;align-items:baseline;background:none;border:0;text-align:left}
.logo b{color:var(--red);font-weight:400}.logo i{color:var(--blue);font-style:normal}
.slabel{font:600 11px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--faint);padding:0 8px;margin-bottom:-8px}
.snav{display:grid;gap:2px}
.sitem{display:grid;grid-template-columns:38px minmax(0,1fr);gap:10px;align-items:center;padding:7px 8px;border-radius:10px;background:none;border:0;text-align:left;color:var(--muted);transition:background .15s,color .15s}
.sitem:hover{background:var(--panel);color:var(--text)}
.sitem[aria-current="true"]{background:var(--panel2);color:var(--text);box-shadow:inset 3px 0 0 var(--gold)}
.sitem .ico{width:38px;height:38px;border-radius:8px;display:grid;place-items:center;background:var(--panel2);overflow:hidden;font-size:17px}
.sitem .ico img{width:100%;height:100%;object-fit:cover}
.sitem .nm,.sitem .sub{display:block}
.sitem .nm{font-weight:600;font-size:14px;line-height:1.2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sitem .sub{font-size:12px;color:var(--faint);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sadd{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:10px;border:1px dashed var(--line2);background:none;color:var(--gold);font-weight:700;font-size:14px}
.sadd:hover{background:color-mix(in srgb,var(--acc) 8.0%,transparent)}
.sfoot{margin-top:auto;display:grid;gap:4px}
.sfoot button{display:flex;align-items:center;gap:10px;padding:8px;border-radius:8px;background:none;border:0;color:var(--muted);font-size:14px;text-align:left}
.sfoot button:hover{background:var(--panel);color:var(--text)}
.conn{width:8px;height:8px;border-radius:50%;background:var(--faint);display:inline-block;flex:none}
.conn.ok{background:var(--green)}.conn.off{background:var(--red)}

.main{min-width:0;display:flex;flex-direction:column}
.top{position:sticky;top:0;z-index:5;background:rgba(11,13,18,.86);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--line);padding:14px clamp(16px,3vw,36px) 0}
.tophead{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;flex-wrap:wrap}
.ttl{display:grid;gap:2px;min-width:0}
.ttl .kicker{font:600 11px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
.ttl h1{margin:0;font-family:var(--display);font-weight:400;font-size:clamp(26px,3.4vw,38px);line-height:1;letter-spacing:.02em;text-transform:uppercase;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pills{display:flex;flex-wrap:wrap;gap:6px}
.pill{font:600 12px var(--mono);color:var(--muted);background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:5px 10px;white-space:nowrap}
.pill b{color:var(--text)}
.tabs{display:flex;gap:4px;margin-top:12px;overflow-x:auto;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tab{background:none;border:0;padding:10px 14px 12px;font-weight:700;font-size:14px;color:var(--muted);border-bottom:2px solid transparent;white-space:nowrap}
.tab:hover{color:var(--text)}
.tab[aria-selected="true"]{color:var(--text);border-bottom-color:var(--gold)}
.tab kbd{margin-left:6px}
#view{padding:22px clamp(16px,3vw,36px) 60px;flex:1;position:relative}
.pickbtn{display:none}

/* ---------- Commun ---------- */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;font-weight:700;font-size:14px;color:var(--text);background:var(--panel2);border:1px solid var(--line2);border-radius:10px;padding:9px 16px;transition:background .15s,border-color .15s,transform .1s}
.btn:hover{background:var(--panel3)}
.btn:active{transform:translateY(1px)}
.btn:disabled{opacity:.4;cursor:default}
.btn.primary{background:var(--gold);color:#16120A;border-color:var(--gold)}
.btn.primary:hover{background:#FFD06A}
.btn.ghost{background:none}
.btn.danger{color:var(--red)}
.btn.sm{padding:6px 11px;font-size:13px;border-radius:8px}
.lnk{background:none;border:0;padding:0;color:var(--blue);font-weight:600;font-size:13px;text-decoration:underline;text-underline-offset:3px}
.lnk.danger{color:var(--red)}
kbd{font:600 10px var(--mono);background:var(--panel3);border:1px solid var(--line2);border-bottom-width:2px;border-radius:4px;padding:1px 5px;color:var(--muted)}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:16px}
.panel h3,.h3{margin:0 0 12px;font:700 12px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}
.note{color:var(--muted);font-size:13px;margin:0}
.note b{color:var(--text)}
.empty{color:var(--muted);font-size:14px;padding:6px 2px}
.input,select{background:var(--panel);border:1px solid var(--line2);border-radius:10px;padding:9px 12px;font-size:14px;min-width:0}
.input{flex:1 1 220px}
textarea{background:var(--bg);border:1px solid var(--line2);border-radius:10px;padding:10px;font:12px var(--mono);width:100%;min-height:70px;resize:vertical}
.tools{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:14px}
.chips{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;padding-bottom:2px}
.chips::-webkit-scrollbar{display:none}
.chip{flex:none;font-weight:600;font-size:13px;color:var(--muted);background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:6px 12px;white-space:nowrap}
.chip:hover{color:var(--text);border-color:var(--line2)}
.chip[aria-pressed="true"]{color:#16120A;background:var(--gold);border-color:var(--gold)}
.poster{width:100%;aspect-ratio:2/3;object-fit:cover;display:block;background:var(--panel2);border-radius:10px}
.poster.sq,.noposter.sq{aspect-ratio:1/1}
.noposter{width:100%;aspect-ratio:2/3;border-radius:10px;background:repeating-linear-gradient(135deg,var(--panel2) 0 12px,var(--panel) 12px 24px);display:grid;place-items:center;padding:10px;text-align:center;font-family:var(--display);font-size:20px;color:var(--muted);text-transform:uppercase;line-height:1.1;overflow:hidden}
.th{width:30px;flex:none;border-radius:4px}
.noposter.th,.noposter.mini-i{font-size:0;padding:0}
.stars{color:var(--gold);letter-spacing:1px}
.toast{position:fixed;left:50%;bottom:calc(24px + env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:var(--panel3);border:1px solid var(--line2);padding:11px 18px;border-radius:12px;font-size:14px;font-weight:600;box-shadow:0 14px 40px rgba(0,0,0,.5);z-index:60;max-width:calc(100vw - 32px)}
.bar{height:5px;background:var(--panel2);border-radius:3px;overflow:hidden}
.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--red),var(--gold),var(--blue))}
.up{color:var(--green)}.down{color:var(--red)}
.fx{display:flex;align-items:center;gap:8px;min-width:0}
.fx .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.filehint{padding:10px 14px;border:1px solid color-mix(in srgb,var(--acc) 35.0%,transparent);background:color-mix(in srgb,var(--acc) 7.0%,transparent);border-radius:10px;font-size:13px;margin-bottom:16px}

/* ---------- Accueil ---------- */
.hero{position:relative;overflow:hidden;border-radius:18px;border:1px solid var(--line);background:var(--panel);min-height:260px;display:grid;align-items:end;margin-bottom:26px}
.hero-bg{position:absolute;inset:0;display:grid;grid-template-columns:repeat(6,1fr);opacity:.5}
.hero-bg img,.hero-bg div{width:100%;height:100%;object-fit:cover;filter:saturate(.9)}
.hero::after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,rgba(11,13,18,.97) 0%,rgba(11,13,18,.85) 45%,rgba(11,13,18,.35) 100%),linear-gradient(0deg,rgba(11,13,18,.9),transparent 60%)}
.hero-in{position:relative;z-index:1;padding:clamp(20px,4vw,40px);display:grid;gap:10px;max-width:620px}
.hero .kicker{font:600 12px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--gold)}
.hero h2{margin:0;font-family:var(--display);font-weight:400;font-size:clamp(34px,5vw,58px);line-height:.98;text-transform:uppercase;letter-spacing:.01em;text-wrap:balance}
.hero p{margin:0;color:var(--muted);max-width:52ch}
.hero .row{display:flex;flex-wrap:wrap;gap:10px;margin-top:6px}
.sech{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin:0 0 12px}
.sech h2{margin:0;font-family:var(--display);font-weight:400;font-size:24px;text-transform:uppercase;letter-spacing:.02em}
.cgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px}
.ccard{position:relative;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);overflow:hidden;display:flex;flex-direction:column;transition:border-color .15s,transform .15s}
.ccard:hover{border-color:var(--line2);transform:translateY(-2px)}
.ccard .strip{display:grid;grid-template-columns:repeat(4,1fr);gap:2px;background:var(--bg)}
.ccard .strip img,.ccard .strip .noposter{width:100%;aspect-ratio:2/3;object-fit:cover;border-radius:0;display:block;font-size:9px;padding:3px}
.ccard .strip.sq img,.ccard .strip.sq .noposter{aspect-ratio:1/1}
.ccard .body{padding:14px;display:grid;gap:8px;flex:1;align-content:start}
.ccard .type{font:600 11px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--muted);display:flex;gap:8px;align-items:center}
.ccard .type .dot{width:7px;height:7px;border-radius:50%;background:var(--red)}
.ccard.music .type .dot{background:var(--blue)}
.ccard h3{margin:0;font-size:19px;line-height:1.15}
.ccard .meta{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:13px;color:var(--muted)}
.ccard .meta b{color:var(--text);font-family:var(--mono);font-size:12px}
.ccard .acts{display:flex;gap:8px;align-items:center;margin-top:4px;flex-wrap:wrap}
.ccard .acts .btn{flex:1}
.ccard .more{display:flex;gap:14px;padding:0 14px 14px}
.ccard.add{border-style:dashed;display:grid;place-items:center;text-align:center;min-height:240px;color:var(--gold);background:transparent;font-weight:700;gap:6px;padding:20px}
.ccard.add .plus{font-family:var(--display);font-size:44px;line-height:1}
.ccard.add span{color:var(--muted);font-weight:400;font-size:13px;max-width:26ch}

/* ---------- Arène ---------- */
.stage{position:relative;border-radius:20px;overflow:hidden;border:1px solid var(--line);background:var(--panel);padding:clamp(14px,2.5vw,28px)}
.stage-bg{position:absolute;inset:-60px;z-index:0;display:grid;grid-template-columns:1fr 1fr;filter:blur(50px) saturate(1.1);opacity:.18;pointer-events:none;overflow:hidden}
.stage-bg img,.stage-bg div{width:100%;height:100%;object-fit:cover;display:block}
.stage::after{content:"";position:absolute;inset:0;z-index:0;background:linear-gradient(180deg,rgba(21,25,34,.6),rgba(21,25,34,.92));pointer-events:none}
.stage>*:not(.stage-bg){position:relative;z-index:1}
.stagehead{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin-bottom:16px}
.round{font:600 12px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
.round b{color:var(--gold);font-weight:600}
.arena{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);gap:clamp(12px,3vw,40px);align-items:start;max-width:820px;margin:0 auto}
.fighter{display:grid;gap:10px;min-width:0;align-content:start}
.fighter .player{width:100%;max-width:420px;justify-self:center}
.card{position:relative;display:grid;gap:8px;justify-items:center;text-align:center;background:none;border:0;padding:0;border-radius:14px;transition:transform .18s ease}
.card .art{width:min(100%, calc(min(54vh, 500px) * 2 / 3))}
.sq-col .card .art{width:min(100%, min(30vh, 260px))}
.card .cmeta{justify-content:center}
.card .art{position:relative;border-radius:12px;overflow:hidden;box-shadow:0 20px 40px -18px rgba(0,0,0,.8);outline:3px solid transparent;outline-offset:3px;transition:outline-color .15s}
.card.l .art{outline-color:rgba(240,70,76,.0)}
.card:hover{transform:translateY(-4px)}
.card.l:hover .art{outline-color:var(--red)}
.card.r:hover .art{outline-color:var(--blue)}
.card .art .poster,.card .art .noposter{border-radius:0}
.corner{position:absolute;top:10px;left:10px;font:700 11px var(--mono);letter-spacing:.08em;padding:4px 8px;border-radius:6px;color:#fff}
.card.l .corner{background:var(--red)}.card.r .corner{background:var(--blue)}
.rankb{position:absolute;top:10px;right:10px;font:700 11px var(--mono);padding:4px 8px;border-radius:6px;background:rgba(0,0,0,.65);color:var(--text)}
.pick{position:absolute;left:0;right:0;bottom:0;padding:26px 12px 12px;background:linear-gradient(0deg,rgba(0,0,0,.85),transparent);font-weight:800;text-align:center;opacity:0;transition:opacity .15s;letter-spacing:.02em}
.card:hover .pick,.card:focus-visible .pick{opacity:1}
.ctitle{font-weight:700;font-size:18px;line-height:1.2;text-wrap:balance}
.cmeta{color:var(--muted);font-size:13px;display:flex;flex-wrap:wrap;gap:3px 10px}
.badge{font:600 11px var(--mono);color:var(--faint)}
.badge b{color:var(--muted)}
.vs{font-family:var(--display);font-size:clamp(34px,6vw,64px);line-height:1;align-self:center;background:linear-gradient(180deg,var(--red) 0 50%,var(--blue) 50% 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
.card.win{animation:win .38s ease}
@keyframes win{50%{transform:scale(1.04)}}
.card.win .art{outline-color:var(--gold)!important}
.card.ko{opacity:.55;transform:scale(.97)}
.card.ko .poster{filter:grayscale(1) brightness(.55)}
.stamp{position:absolute;inset:0;display:grid;place-items:center;font-family:var(--display);font-size:clamp(38px,7vw,70px);color:var(--red);transform:rotate(-12deg) scale(1.6);opacity:0;pointer-events:none;text-shadow:0 3px 0 #000}
.card.ko .stamp{opacity:1;transform:rotate(-12deg) scale(1);transition:all .2s cubic-bezier(.2,1.6,.4,1)}
.stamp.draw{color:var(--gold)}
.actbar{display:grid;grid-template-columns:1fr auto auto auto 1fr;gap:8px;max-width:820px;margin:18px auto 0;align-items:center}
.actbar .btn{padding:11px 14px}
.actbar .choose.l{justify-self:start;border-color:rgba(240,70,76,.5)}
.actbar .choose.r{justify-self:end;border-color:rgba(63,125,255,.5)}
.actbar .choose.l:hover{background:rgba(240,70,76,.15)}
.actbar .choose.r:hover{background:rgba(63,125,255,.15)}
.below{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px;margin-top:18px}
.feed{display:grid;gap:3px}
.fight{display:grid;grid-template-columns:minmax(0,max-content) auto minmax(0,1fr) auto;gap:10px;align-items:center;font-size:14px;padding:5px 8px;border-radius:8px}
.fight:nth-child(odd){background:var(--bg2)}
.fight .w .nm::before{content:"✓ ";color:var(--green)}
.fight.dr .w .nm::before{content:"= ";color:var(--gold)}
.fight .w{font-weight:600}
.fight .lo{color:var(--muted)}
.fight .lo .th{filter:grayscale(1) brightness(.6)}
.fight .x{font:700 10px var(--mono);color:var(--faint);letter-spacing:.08em}
.fight .tag{font:11px var(--mono);color:var(--faint);white-space:nowrap}

/* lecteurs */
.player{display:grid;gap:6px}
.pbar{display:flex;gap:4px;align-items:center}
.pb{font-weight:700;font-size:12px;color:var(--muted);background:var(--panel2);border:1px solid var(--line);border-radius:999px;padding:4px 10px}
.pb.on{color:#0B0D12;background:var(--text);border-color:var(--text)}
.pout{margin-left:auto;color:var(--muted);text-decoration:none;font-size:13px;padding:2px 6px}
.pout:hover{color:var(--text)}
.pslot{display:grid}
.ytf{width:100%;aspect-ratio:16/9;height:auto;border:0;border-radius:10px;background:#000;display:block}
.spf{width:100%;height:80px;border:0;border-radius:12px;background:var(--panel2);display:block}
.findyt{width:100%}

/* ---------- Tournoi ---------- */
.track{display:flex;flex-wrap:wrap;gap:4px}
.track span{font:600 11px var(--mono);padding:4px 8px;border-radius:999px;border:1px solid var(--line);color:var(--faint)}
.track span.done{color:var(--green);background:rgba(60,195,128,.1);border-color:transparent}
.track span.cur{color:#16120A;background:var(--gold);border-color:var(--gold)}
.modes{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.mode{display:grid;gap:6px;text-align:left;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:18px;transition:border-color .15s,transform .15s}
.mode:hover{border-color:var(--gold);transform:translateY(-2px)}
.mode strong{font-family:var(--display);font-weight:400;font-size:26px;text-transform:uppercase;letter-spacing:.02em;line-height:1.05}
.mode span{color:var(--muted);font-size:13px}
.mode em{font:700 11px var(--mono);font-style:normal;color:var(--gold);letter-spacing:.08em;text-transform:uppercase}
.ptabs{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}
.ptabs button{font-weight:600;font-size:13px;color:var(--muted);background:var(--bg2);border:1px solid var(--line);border-radius:999px;padding:6px 12px}
.ptabs button[aria-selected="true"]{color:var(--text);border-color:var(--line2);background:var(--panel2)}
.ptabs button span{font:11px var(--mono);margin-left:5px;color:var(--faint)}
.grid-mini{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:8px}
.mini{display:grid;grid-template-columns:44px minmax(0,1fr);gap:10px;align-items:center;background:var(--bg2);border-radius:10px;padding:6px}
.mini img,.mini .noposter{width:44px;border-radius:5px;font-size:0;padding:0}
.mini .t{font-weight:600;font-size:13px;line-height:1.2;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.mini .s{color:var(--muted);font-size:11px;line-height:1.25;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.mini.out .t{color:var(--muted)}
.mini.out img{filter:grayscale(1) brightness(.6)}
.champ{display:grid;justify-items:center;gap:10px;text-align:center}
.champ .poster,.champ .noposter{width:220px;box-shadow:0 0 0 3px var(--gold),0 24px 60px -20px color-mix(in srgb,var(--acc) 60.0%,transparent)}
.champ h2{font-family:var(--display);font-weight:400;font-size:clamp(32px,6vw,52px);margin:0;color:var(--gold);text-transform:uppercase;line-height:1.02;text-wrap:balance}
.honors{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-top:18px}
.path{display:grid;gap:3px}
.path div{display:grid;grid-template-columns:140px minmax(0,1fr);gap:10px;font-size:14px;padding:5px 8px;border-radius:8px;align-items:center}
.path div:nth-child(odd){background:var(--bg2)}
.path b{font:700 11px var(--mono);color:var(--gold);letter-spacing:.04em;text-transform:uppercase}

/* ---------- Classement ---------- */
.podium{display:grid;grid-template-columns:1fr 1.15fr 1fr;gap:14px;align-items:end;margin-bottom:18px}
.pod{display:grid;gap:8px;text-align:center;justify-items:center;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:14px}
.pod .poster,.pod .noposter{width:min(140px,100%)}
.pod.p1 .poster,.pod.p1 .noposter{width:min(170px,100%);box-shadow:0 0 0 2px var(--gold)}
.pod .n{font-family:var(--display);font-size:30px;line-height:1}
.pod.p1 .n{color:var(--gold)}.pod.p2 .n{color:#C9CDD4}.pod.p3 .n{color:#C98A5A}
.pod .t{font-weight:700;line-height:1.2}
.pod .s{font:12px var(--mono);color:var(--muted)}
.list{display:grid;gap:2px}
.row{display:grid;grid-template-columns:46px 36px minmax(0,1fr) auto 18px;gap:12px;align-items:center;padding:7px 10px;border-radius:10px;cursor:pointer;background:none;border:0;text-align:left;width:100%}
.row:nth-child(4n+1){background:var(--bg2)}
.row:hover{background:var(--panel2)}
.row .rk{font:600 13px var(--mono);color:var(--muted);text-align:right}
.row img,.row .noposter{width:36px;border-radius:4px;font-size:0;padding:0}
.row .t{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .t small{color:var(--muted);font-weight:400;margin-left:6px}
.row .sc{font:12px var(--mono);color:var(--muted);text-align:right;white-space:nowrap}
.row .sc b{color:var(--text)}
.row .chev{color:var(--faint);transition:transform .15s}
.row[aria-expanded="true"] .chev{transform:rotate(90deg)}
.detail{background:var(--panel2);border-radius:12px;padding:16px;margin:2px 0 8px;display:grid;grid-template-columns:120px minmax(0,1fr);gap:18px}
.detail>.poster,.detail>.noposter{width:120px}
.detail h4{margin:0 0 4px;font-size:19px}
.kv{display:flex;flex-wrap:wrap;gap:6px 18px;font-size:13px;color:var(--muted);margin:8px 0 10px}
.kv b{color:var(--text);font-family:var(--mono)}
.vsl{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;font-size:13px}
.vsl h5{margin:0 0 4px;font:700 11px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.vsl ul{margin:0;padding:0;list-style:none;display:grid;gap:2px}
.links{display:flex;flex-wrap:wrap;gap:14px;margin-top:12px}
.links a{font-size:13px}
.detail .player{margin-top:10px;max-width:480px}
.more{margin:16px auto 0;display:flex}
.surp{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:18px}
.surp ol{margin:0;padding-left:20px;display:grid;gap:4px;font-size:14px}
.surp li small{color:var(--muted);font:11px var(--mono);margin-left:6px}

/* ---------- Comparer ---------- */
.cmphead,.cmpcols{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:14px}
.big{font-family:var(--display);font-size:48px;line-height:1.05;color:var(--gold)}
.cmptop{margin:0;padding-left:24px;display:grid;gap:6px;font-size:14px}
.cmptop li.com .nm{color:var(--gold)}
.crow{display:grid;grid-template-columns:minmax(0,1.3fr) 50px 50px minmax(80px,1fr) 44px;gap:10px;align-items:center;font-size:14px;padding:5px 8px;border-radius:8px}
.crow:nth-child(odd){background:var(--bg2)}
.cr{font:600 12px var(--mono);text-align:right}
.cr.a{color:var(--red)}.cr.b{color:var(--blue)}
.cbar{position:relative;height:8px;background:var(--panel2);border-radius:4px}
.cbar i{position:absolute;top:3px;height:2px;background:var(--muted)}
.cbar b{position:absolute;top:0;width:8px;height:8px;border-radius:50%;transform:translateX(-4px)}
.cbar .da{background:var(--red)}.cbar .db{background:var(--blue)}
.cd{font:600 11px var(--mono);text-align:right}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin:0 4px 0 6px;vertical-align:middle}
.dot.a{background:var(--red)}.dot.b{background:var(--blue)}

/* ---------- Fenêtres ---------- */
.modal{position:fixed;inset:0;z-index:50;background:rgba(5,6,9,.72);backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px);display:grid;place-items:center;padding:16px}
.modal[hidden]{display:none}
.sheet{width:min(640px,100%);max-height:calc(100vh - 32px);overflow:auto;background:var(--panel);border:1px solid var(--line2);border-radius:18px;padding:22px;display:grid;gap:16px;box-shadow:0 30px 80px rgba(0,0,0,.6)}
.sheet h2{margin:0;font-family:var(--display);font-weight:400;font-size:30px;text-transform:uppercase;letter-spacing:.02em}
.sheethead{display:flex;justify-content:space-between;align-items:center;gap:10px}
.x{background:none;border:0;color:var(--muted);font-size:22px;line-height:1;padding:4px 8px;border-radius:8px}
.x:hover{background:var(--panel2);color:var(--text)}
.steps{list-style:none;margin:0;padding:0;display:grid;gap:12px;counter-reset:s}
.steps>li{counter-increment:s;display:grid;grid-template-columns:32px minmax(0,1fr);gap:12px;align-items:start}
.steps>li::before{content:counter(s);width:32px;height:32px;border-radius:50%;display:grid;place-items:center;font-family:var(--display);font-size:17px;background:var(--panel3);color:var(--gold)}
.steps>li.done::before{content:"✓";background:rgba(60,195,128,.18);color:var(--green)}
.steps b{color:var(--text)}
.steps .note{margin-top:4px}
.bm{display:inline-flex;gap:8px;align-items:center;font-weight:800;font-size:14px;color:#16120A;background:var(--gold);padding:9px 16px;border-radius:10px;text-decoration:none;cursor:grab;margin-top:8px;box-shadow:0 6px 18px -6px color-mix(in srgb,var(--acc) 60.0%,transparent)}
.srcs{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.srcs a{font-size:13px;font-weight:600;text-decoration:none;color:var(--text);background:var(--panel2);border:1px solid var(--line2);border-radius:999px;padding:6px 12px}
.srcs a:hover{border-color:var(--gold)}
.pastezone{border:2px dashed var(--line2);border-radius:14px;padding:18px;text-align:center;display:grid;gap:6px;transition:border-color .15s,background .15s}
.pastezone.flash{border-color:var(--green);background:rgba(60,195,128,.08)}
.pastezone strong{font-size:16px}
.result{padding:12px 14px;border-radius:10px;background:rgba(60,195,128,.1);border:1px solid rgba(60,195,128,.35);font-size:14px}
.result.err{background:rgba(240,70,76,.1);border-color:rgba(240,70,76,.35)}
.setgrp{display:grid;gap:8px}
.setgrp .row2{display:flex;flex-wrap:wrap;gap:8px}
.msg{font-size:13px;color:var(--green);min-height:1em}
.confirm{display:flex;flex-wrap:wrap;gap:8px;align-items:center;color:var(--red);font-size:13px}
.seg{display:inline-flex;background:var(--bg2);border:1px solid var(--line);border-radius:10px;padding:3px;gap:3px}
.seg button{background:none;border:0;border-radius:7px;padding:6px 12px;font-weight:700;font-size:13px;color:var(--muted)}
.seg button[aria-pressed="true"]{background:var(--panel3);color:var(--text)}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}

/* ---------- Mobile ---------- */
.bottombar{display:none}
@media (max-width:900px){
  .app{grid-template-columns:minmax(0,1fr)}
  .side{display:none}
  .pickbtn{display:inline-flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--line2);border-radius:10px;padding:7px 12px;font-weight:700;font-size:13px;max-width:100%}
  .top{padding-top:10px}
  #view{padding-bottom:calc(90px + env(safe-area-inset-bottom,0px))}
  .bottombar{display:grid;grid-template-columns:repeat(5,1fr);position:fixed;left:0;right:0;bottom:0;z-index:20;background:rgba(16,19,26,.96);backdrop-filter:blur(12px);border-top:1px solid var(--line);padding:6px 4px calc(6px + env(safe-area-inset-bottom,0px))}
  .bottombar button{background:none;border:0;display:grid;justify-items:center;gap:2px;font-size:11px;font-weight:600;color:var(--muted);padding:4px}
  .bottombar button .i{font-size:18px;line-height:1}
  .bottombar button[aria-current="true"]{color:var(--gold)}
  .top .tabs{display:none}
  .top{padding-bottom:12px}
  .toast{bottom:calc(84px + env(safe-area-inset-bottom,0px))}
  .ttl h1{font-size:26px}
}
@media (max-width:640px){
  .arena{grid-template-columns:1fr 1fr;gap:10px}
  .vs{grid-column:1/-1;order:-1;justify-self:center;font-size:30px}
  .ctitle{font-size:14px}
  .actbar{grid-template-columns:repeat(3,minmax(0,1fr))}
  .actbar .btn{padding:10px 8px;font-size:13px}
  .actbar .choose{display:none}
  .actbar .btn{width:100%}
  .below,.surp,.cmphead,.cmpcols,.vsl{grid-template-columns:minmax(0,1fr)}
  .podium{grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
  .pod{padding:8px}.pod .t{font-size:12px}
  .row{grid-template-columns:34px 30px minmax(0,1fr) auto;gap:8px}
  .row .chev{display:none}
  .row img{width:30px}
  .detail{grid-template-columns:minmax(0,1fr)}
  .fight{grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:2px 10px}
  .fight .x{display:none}.fight .tag{grid-column:1/-1}
  .path div{grid-template-columns:minmax(0,1fr)}
  .crow{grid-template-columns:minmax(0,1fr) 40px 40px 40px}
  .crow .cbar{display:none}
  .hero{min-height:220px}
  .hero-bg{grid-template-columns:repeat(3,1fr)}
  .corner{font-size:9px;top:6px;left:6px}.rankb{font-size:9px;top:6px;right:6px}
  .tab kbd{display:none}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
/* musique : vidéo plus grande */
.arena.sq-col{max-width:1180px;gap:clamp(12px,2vw,28px)}
.sq-col .card .art{width:min(100%, min(22vh, 190px))}
.sq-col .fighter .player{max-width:none;width:100%}
.sq-col .ytf{border-radius:12px;box-shadow:0 20px 40px -18px rgba(0,0,0,.8)}
.actbar.sq-bar{max-width:1180px}
@media (max-width:640px){ .sq-col .fighter .player{grid-column:auto} }
.gprev{display:grid;grid-template-columns:repeat(auto-fill,minmax(92px,1fr));gap:10px;max-height:340px;overflow:auto;padding:2px}
.gi{display:grid;gap:5px;font-size:12px;line-height:1.25;min-width:0}
.gi img,.gi .noimg{width:100%;aspect-ratio:2/3;object-fit:cover;border-radius:8px;background:var(--panel2,#1a1d25)}
.gi img.sq{aspect-ratio:1}
.gi span{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}

/* ===== v7 : bureau ===== */
.keysbtn{display:inline-flex;align-items:center;gap:6px;background:var(--panel);border:1px solid var(--line2);border-radius:10px;padding:7px 10px;font-weight:700;font-size:13px;color:var(--muted)}
.keysbtn:hover{color:var(--text);border-color:var(--gold)}
.keygrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:18px}
.krow{display:flex;align-items:center;gap:6px;padding:5px 0;font-size:14px;border-bottom:1px solid var(--line)}
.krow span:last-child{margin-left:auto;color:var(--muted);text-align:right}
.krow kbd{font-size:12px;padding:2px 7px}
.khint{display:flex;justify-content:center;flex-wrap:wrap;gap:6px 18px;margin-top:14px;font-size:12px;color:var(--faint)}
.khint kbd{margin-right:2px}
.pbar .pk{align-self:center;margin-right:2px;color:var(--gold);border-color:color-mix(in srgb,var(--acc) 35.0%,transparent)}
.player.kflash{animation:kflash .5s ease}
@keyframes kflash{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--acc) 70.0%,transparent)}100%{box-shadow:0 0 0 14px color-mix(in srgb,var(--acc) 0.0%,transparent)}}
/* ambiance */
.stage{--ambL:rgba(240,70,76,.28);--ambR:rgba(63,125,255,.28)}
.stage-bg{opacity:.3;filter:blur(60px) saturate(1.6)}
.stage::before{content:"";position:absolute;inset:0;z-index:0;pointer-events:none;background:radial-gradient(ellipse 55% 70% at 18% 45%,var(--ambL),transparent 70%),radial-gradient(ellipse 55% 70% at 82% 45%,var(--ambR),transparent 70%);transition:background .6s}
.stage::after{content:"";position:absolute;inset:0;z-index:2;pointer-events:none;opacity:0}
.stage.hit-l::after{background:radial-gradient(circle at 25% 45%,rgba(240,70,76,.45),transparent 60%);animation:hit .45s ease-out}
.stage.hit-r::after{background:radial-gradient(circle at 75% 45%,rgba(63,125,255,.45),transparent 60%);animation:hit .45s ease-out}
@keyframes hit{0%{opacity:1}100%{opacity:0}}
/* cartes : 3D + néon */
.card .art{transform:perspective(900px) rotateX(var(--rx,0deg)) rotateY(var(--ry,0deg));transition:transform .15s ease-out,box-shadow .2s,outline-color .15s;will-change:transform}
.card .art::after{content:"";position:absolute;inset:0;pointer-events:none;background:radial-gradient(circle at var(--gx,50%) var(--gy,30%),rgba(255,255,255,.22),transparent 55%);opacity:0;transition:opacity .2s;z-index:2}
.card:hover .art::after{opacity:1}
.card.l:hover .art{box-shadow:0 0 0 2px var(--red),0 0 34px 6px rgba(240,70,76,.55),0 0 90px 10px rgba(240,70,76,.22)}
.card.r:hover .art{box-shadow:0 0 0 2px var(--blue),0 0 34px 6px rgba(63,125,255,.55),0 0 90px 10px rgba(63,125,255,.22)}
.card.win{animation:none}
.card.win .art{animation:impact .42s cubic-bezier(.2,1.4,.4,1)}
.card.l.win .art{box-shadow:0 0 0 3px var(--gold),0 0 60px 14px rgba(240,70,76,.7)}
.card.r.win .art{box-shadow:0 0 0 3px var(--gold),0 0 60px 14px rgba(63,125,255,.7)}
@keyframes impact{0%{transform:perspective(900px) scale(1)}35%{transform:perspective(900px) scale(1.08)}100%{transform:perspective(900px) scale(1.02)}}
.card.ko .art{animation:shake .32s ease}
@keyframes shake{20%{translate:-7px 0}40%{translate:6px 0}60%{translate:-4px 0}80%{translate:2px 0}}
/* filtres */
.fxbtn kbd{margin-left:4px}
.fxpanel{display:flex;flex-wrap:wrap;align-items:end;gap:12px 16px;margin:0 0 14px;padding:12px 14px;background:rgba(0,0,0,.25);border:1px solid var(--line2);border-radius:12px}
.fxpanel label{display:grid;gap:4px;font-size:12px;color:var(--muted);font-weight:600}
.fxpanel select{max-width:260px}
.fxpanel .input{width:96px;flex:none}
.fxn{font-size:13px;color:var(--muted);margin-left:auto;align-self:center}
.fxn b{color:var(--gold)}
/* arbre */
.btools{display:flex;flex-wrap:wrap;align-items:center;gap:10px 16px;margin-bottom:10px}
.bracket{overflow:auto;max-height:72vh;border:1px solid var(--line);border-radius:12px;background:rgba(0,0,0,.2);cursor:grab;user-select:none}
.bracket.drag{cursor:grabbing}
.binner{display:flex;align-items:flex-start;padding:16px 24px 24px;width:max-content}
.bcol{display:grid;gap:8px;width:210px;flex:none}
.bh{font:700 11px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--muted);text-align:center;height:16px}
.bm-list{display:flex;flex-direction:column;justify-content:space-around}
.bmatch{height:58px;display:grid;grid-template-rows:1fr 1fr;background:var(--panel2);border:1px solid var(--line2);border-radius:8px;overflow:hidden}
.bmatch.now{border-color:var(--gold);box-shadow:0 0 18px color-mix(in srgb,var(--acc) 35.0%,transparent)}
.bmatch.champ{display:flex;align-items:center;gap:8px;padding:0 8px;border-color:var(--gold);color:var(--gold);font-weight:700}
.bs{display:flex;align-items:center;gap:7px;padding:0 7px;font-size:12px;min-width:0;border-top:1px solid var(--line)}
.bs:first-child{border-top:0}
.bs .bn,.bmatch .bn{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bs.w{color:var(--text);font-weight:700;background:color-mix(in srgb,var(--acc) 8.0%,transparent)}
.bs.w .bn::after{content:" ✓";color:var(--gold)}
.bs.l{color:var(--faint)}
.bs.l .bn{text-decoration:line-through}
.bs.tbd{color:var(--faint);font-style:italic}
.bth{width:18px;height:24px;border-radius:3px;object-fit:cover;flex:none;background:var(--panel3);font-size:0}
.bth.sq{height:18px}
.bmatch.champ .bth{width:26px;height:36px}
.blink{flex:none;margin-top:24px}
.blink path{fill:none;stroke:var(--line2);stroke-width:1.5}
/* glisser-déposer */
body.dropping::after{content:"Dépose ton export Letterboxd (.zip / .csv) ou n’importe quel CSV";position:fixed;inset:14px;z-index:9999;display:grid;place-items:center;border:3px dashed var(--gold);border-radius:24px;background:rgba(11,13,18,.88);color:var(--gold);font:28px var(--display);text-transform:uppercase;letter-spacing:.03em;pointer-events:none}
/* grand écran */
@media (min-width:1500px){
  .arena{max-width:1000px}
  .card .art{width:min(100%, calc(min(58vh, 560px) * 2 / 3))}
  .arena.sq-col{max-width:1500px}
  .sq-col .card .art{width:min(100%, min(24vh, 230px))}
  .actbar{max-width:1000px}
}
@media (min-width:2200px){
  .arena{max-width:1200px}
  .card .art{width:min(100%, calc(min(62vh, 680px) * 2 / 3))}
}
@media (prefers-reduced-motion:reduce){ .card .art,.card.win .art,.card.ko .art{animation:none!important;transform:none!important} }

/* ===== v8 : jeux ===== */
.gopts{display:flex;flex-wrap:wrap;gap:14px 24px;margin-bottom:16px}
.gopts .note{margin-bottom:4px}
.gmodes .mode em{font-size:26px;font-style:normal}
.gmodes .mode[disabled]{opacity:.45;cursor:not-allowed}
.gst{display:block;margin-top:8px;font:600 11px var(--mono);color:var(--gold)!important;letter-spacing:.04em}
.stage.game{min-height:60vh;overflow:visible}
.gload{display:flex;align-items:center;justify-content:center;gap:12px;padding:90px 0;color:var(--muted)}
.spin{width:22px;height:22px;border:3px solid var(--line2);border-top-color:var(--gold);border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.gsteps{display:flex;justify-content:center;gap:6px;margin:4px auto 18px;max-width:760px}
.gsteps span{flex:1;display:grid;gap:2px;text-align:center;padding:8px 6px;border-radius:10px;background:rgba(255,255,255,.04);border:1px solid var(--line);color:var(--faint)}
.gsteps b{font:700 14px var(--mono)}
.gsteps i{font:600 10px var(--mono);font-style:normal;letter-spacing:.06em;text-transform:uppercase}
.gsteps .past{color:var(--muted);background:rgba(240,70,76,.08);border-color:rgba(240,70,76,.25)}
.gsteps .cur{color:var(--gold);background:color-mix(in srgb,var(--acc) 10.0%,transparent);border-color:var(--gold);box-shadow:0 0 18px color-mix(in srgb,var(--acc) 25.0%,transparent)}
.gboard{display:grid;justify-items:center;gap:18px}
.gboard.done{grid-template-columns:auto minmax(0,1fr);align-items:center;max-width:1100px;margin:0 auto}
.gclue{display:grid;justify-items:center;width:100%}
.gboard.done .gclue{width:auto}
.gcrop{width:min(360px,70vw);aspect-ratio:2/3;border-radius:14px;overflow:hidden;background:var(--panel2);box-shadow:0 30px 60px -20px rgba(0,0,0,.8),0 0 0 1px var(--line2)}
.gcrop.sq{aspect-ratio:1;width:min(380px,70vw)}
.gcrop.mini{width:160px;margin-top:12px}
.gcrop img{width:100%;height:100%;object-fit:cover;display:block;transition:transform .7s cubic-bezier(.2,.8,.2,1)}
.gplot{max-width:760px;background:rgba(0,0,0,.25);border:1px solid var(--line2);border-radius:14px;padding:20px 24px;font-size:17px;line-height:1.6}
.gplot p{margin:0}
.gplot .more{color:var(--faint)}
.gfacts{display:flex;gap:14px;margin-top:12px;color:var(--gold);font-weight:700}
.gclip{position:relative;width:min(720px,100%);aspect-ratio:16/9;border-radius:14px;overflow:hidden;background:#000;box-shadow:0 0 0 1px var(--line2)}
.gclip:not(.vis){aspect-ratio:auto;height:150px}
.gclip iframe{position:absolute;inset:0;width:100%;height:100%;border:0;pointer-events:none}
.gclip:not(.vis) iframe{opacity:.01}
.gmask{position:absolute;inset:0;display:grid;place-items:center;background:radial-gradient(circle,#1C212B,#07080C);color:var(--muted);font-size:20px;font-weight:700;transition:opacity .25s}
.gclip:not(.vis) .gmask span{font-size:40px}
.gclip:not(.vis).playing .gmask span{animation:pulse 1s ease-in-out infinite}
@keyframes pulse{50%{transform:scale(1.25);color:var(--gold)}}
.gclip.vis.playing .gmask{opacity:0}
.gclip.vis::after{content:"";position:absolute;left:0;right:0;top:0;height:18%;background:#000;z-index:2}
.gclip.revealed .gmask{opacity:0}
.gclip.revealed iframe{opacity:1;pointer-events:auto}
.gclip.revealed:not(.vis){aspect-ratio:16/9;height:auto}
.gclip.revealed::after{display:none}
.gprog{position:absolute;left:0;right:0;bottom:0;height:4px;background:rgba(255,255,255,.08);z-index:3}
.gprog i{display:block;height:100%;width:0;background:var(--gold)}
.gctl{display:flex;justify-content:center;flex-wrap:wrap;gap:10px;margin-top:20px}
.gwrong{display:flex;justify-content:center;flex-wrap:wrap;gap:6px;margin-top:12px}
.gwrong span{font-size:13px;color:#ff8a8f;background:rgba(240,70,76,.1);border:1px solid rgba(240,70,76,.3);border-radius:999px;padding:3px 10px}
.gguess{position:relative;max-width:560px;margin:16px auto 0}
.gguess .input{width:100%;font-size:17px;padding:13px 16px;border-color:var(--gold)}
.gsug{position:static;margin-top:6px;display:grid;background:var(--panel);border:1px solid var(--line2);border-radius:12px;overflow:hidden;box-shadow:0 20px 50px rgba(0,0,0,.6)}
.gsug:empty{display:none}
.gsug button{display:flex;align-items:center;gap:10px;padding:7px 12px;background:none;border:0;border-top:1px solid var(--line);text-align:left;color:var(--text)}
.gsug button:first-child{border-top:0}
.gsug button.on,.gsug button:hover{background:var(--panel3)}
.gsug span{display:grid;font-weight:600}
.gsug small{color:var(--muted);font-weight:500}
.gchoices{display:grid;grid-template-columns:1fr 1fr;gap:10px;max-width:760px;margin:16px auto 0}
.gchoices .btn{justify-content:flex-start;text-align:left;padding:12px 14px}
.gchoices .btn[disabled]{opacity:.35;text-decoration:line-through}
.greveal{display:grid;gap:14px;padding:18px;border-radius:16px;background:rgba(0,0,0,.25);border:1px solid var(--line2);animation:rise .35s ease}
.greveal.ok{border-color:rgba(60,195,128,.5);box-shadow:0 0 40px rgba(60,195,128,.15)}
.greveal.ko{border-color:rgba(240,70,76,.45)}
@keyframes rise{from{opacity:0;transform:translateY(10px)}}
.gres{font:30px var(--display);text-transform:uppercase;text-align:center}
.greveal.ok .gres b{color:#3CC380}
.gcard{display:grid;grid-template-columns:120px minmax(0,1fr);gap:16px;align-items:center}
.gcard img,.gcard .noposter{width:120px;border-radius:10px}
.gcard h3{margin:0 0 6px;font-size:22px}
@media (max-width:900px){.gboard.done{grid-template-columns:1fr}.gchoices{grid-template-columns:1fr}}

.gclip.subs:not(.revealed){aspect-ratio:16/3.4;height:auto}
.gclip.subs iframe{opacity:1;top:auto;bottom:0;height:auto;aspect-ratio:16/9}
.gclip.subs.playing .gmask{opacity:0}
.gclip.subs .gmask span{font-size:16px!important}
.gclip.revealed iframe{top:0;bottom:0;height:100%;aspect-ratio:auto}
.gsubnote{font-size:12px;color:var(--muted);text-align:center;margin-top:6px}

/* jeux en plein écran */
.stage.game.full{position:fixed;inset:0;z-index:60;border-radius:0;border:0;min-height:0;overflow-y:auto;overscroll-behavior:contain;padding:22px clamp(16px,4vw,60px) 40px;display:flex;flex-direction:column;background:var(--bg)}
.stage.game.full>*{width:100%;max-width:1100px;margin-left:auto;margin-right:auto}
.stage.game.full .stagehead{max-width:none}
.full .gcrop{width:min(360px,70vw,calc(52vh*2/3))}
.full .gcrop.sq{width:min(380px,70vw,52vh)}
.full .gclip.vis:not(.revealed){width:min(720px,100%,calc(46vh*16/9))}
.gsug{max-height:min(46vh,440px);overflow-y:auto;overscroll-behavior:contain;scrollbar-width:thin}
.gsug button{flex:none}
.gguess{margin-bottom:30px}

.gclip.caps:not(.revealed){height:230px}
.gsubs{position:absolute;left:6%;right:6%;bottom:22px;z-index:3;text-align:center;font-family:var(--display);font-weight:600;font-size:clamp(20px,2.4vw,30px);line-height:1.25;color:var(--text);text-shadow:0 2px 12px rgba(0,0,0,.9);min-height:1.3em;pointer-events:none}
.gclip.caps .gmask{align-items:start;padding-top:34px}
.gclip.revealed .gsubs{display:none}
.sadd{font-size:13px;white-space:nowrap;padding:10px 10px}
/* =====================================================================
   v9 : THÈME « CINÉMA LUXE » — noir velours, champagne, serif élégante
   ===================================================================== */
:root{
  --bg:#07070A; --bg2:#0B0A0E; --panel:#111015; --panel2:#17151C; --panel3:#211E27;
  --line:color-mix(in srgb,var(--acc) 10.0%,transparent); --line2:color-mix(in srgb,var(--acc) 24.0%,transparent);
  --text:#F3EDE2; --muted:#A69E8F; --faint:#6E6759;
  --red:#C8404F; --blue:#5584DD; --gold:#D8B46A; --gold2:#F3DFA8; --gold3:#A87F3C; --green:#79C495;
  --goldgrad:linear-gradient(135deg,#F5E3AE 0%,#D8B46A 45%,#A87F3C 100%);
  --display:"Archivo","Inter","Segoe UI",system-ui,sans-serif;
  --body:"Inter","Segoe UI",system-ui,sans-serif;
  --mono:"Inter","Segoe UI",system-ui,sans-serif;
  --r:16px;
}
html,body{background:var(--bg)}
body{font-size:14.5px;letter-spacing:.005em;background:
  radial-gradient(1100px 520px at 62% -12%,color-mix(in srgb,var(--acc) 9.0%,transparent),transparent 62%),
  radial-gradient(900px 600px at -10% 110%,rgba(200,64,79,.05),transparent 60%),var(--bg)}
body::before{content:"";position:fixed;inset:0;z-index:100;pointer-events:none;opacity:.03;transform:translateZ(0);
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
::selection{background:color-mix(in srgb,var(--acc) 35.0%,transparent);color:#fff}
*{scrollbar-width:thin;scrollbar-color:color-mix(in srgb,var(--acc) 28.0%,transparent) transparent}
:focus-visible{outline:1px solid var(--gold2);outline-offset:3px}
a{color:var(--gold2)}
.lnk{color:var(--gold2);text-decoration-color:color-mix(in srgb,var(--acc) 40.0%,transparent)}

/* libellés en petites capitales espacées */
.slabel,.ttl .kicker,.hero .kicker,.ccard .type,.panel h3,.h3,.round,.bh,.mode em,.gsteps i,.pill,.badge,.fight .x,.corner,.rankb,.track span,kbd,.pod .s,.fight .tag,.ptabs button span{font-family:var(--body)!important}
.slabel,.ttl .kicker,.hero .kicker,.ccard .type,.panel h3,.h3,.round,.bh{font-weight:600;font-size:10.5px;letter-spacing:.28em;text-transform:uppercase}
.ttl .kicker,.hero .kicker,.round b{color:var(--gold)}
.round{color:var(--muted)}
.round b{font-weight:700}

/* titres en serif */
.logo,.ttl h1,.hero h2,.sech h2,.sheet h2,.mode strong,.champ h2,.gres,.pod .n,.big,.vs,.stamp,.ccard.add .plus,.noposter,.steps>li::before{font-family:var(--display)!important;text-transform:none!important;letter-spacing:0!important}
.ttl h1{font-weight:600;font-size:clamp(30px,3.6vw,46px);line-height:1.02}
.hero h2{font-weight:600;font-size:clamp(40px,5.5vw,72px);line-height:.95}
.sech h2{font-weight:600;font-size:32px}
.sheet h2{font-weight:600;font-size:34px}
.mode strong{font-weight:600;font-size:28px}
.champ h2{font-weight:600;font-size:clamp(38px,6vw,64px);font-style:italic;background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.gres{font-weight:600;font-size:36px;font-style:italic}
.noposter{font-style:italic;font-weight:600;font-size:22px;color:var(--faint);background:linear-gradient(160deg,#16141B,#0D0C10);border:1px solid var(--line)}
.noposter.th,.noposter.mini-i{border:0}

/* logo */
.logo{display:grid;gap:4px;padding:2px 10px 6px}
.logo b{font-size:44px;line-height:.9;font-weight:600;font-style:italic;background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.logo i{font:600 10px var(--body);letter-spacing:.5em;text-transform:uppercase;color:var(--muted);padding-left:3px}

/* structure */
.side{background:linear-gradient(180deg,#0D0C10,#08080B);border-right:1px solid var(--line);padding:26px 14px}
.sitem{border-radius:12px}
.sitem:hover{background:color-mix(in srgb,var(--acc) 5.0%,transparent)}
.sitem[aria-current="true"]{background:linear-gradient(90deg,color-mix(in srgb,var(--acc) 13.0%,transparent),color-mix(in srgb,var(--acc) 2.0%,transparent));box-shadow:inset 2px 0 0 var(--gold)}
.sitem .ico{border-radius:6px;box-shadow:0 0 0 1px var(--line)}
.sadd{border:1px solid var(--line2);border-radius:999px;justify-content:center;color:var(--gold2);font-weight:600;letter-spacing:.02em}
.sadd:hover{background:color-mix(in srgb,var(--acc) 8.0%,transparent);border-color:var(--gold)}
.top{background:rgba(7,7,10,.78);border-bottom:1px solid var(--line)}
.tab{font-weight:600;font-size:13px;letter-spacing:.04em;padding:10px 16px 13px;border-bottom:1px solid transparent}
.tab[aria-selected="true"]{color:var(--gold2);border-image:linear-gradient(90deg,transparent,var(--gold),transparent) 1;border-bottom-width:1px}
.pill{font-weight:600;font-size:11.5px;letter-spacing:.04em;background:rgba(255,255,255,.02);border-color:var(--line);font-variant-numeric:tabular-nums}
.pill b{color:var(--gold2)}
kbd{font-weight:700;font-size:9.5px;letter-spacing:.04em;background:rgba(255,255,255,.04);border:1px solid var(--line2);border-bottom-width:1px;border-radius:5px;color:var(--muted)}

/* boutons */
.btn{border-radius:999px;font-weight:600;letter-spacing:.02em;background:rgba(255,255,255,.03);border:1px solid var(--line2);padding:10px 20px;transition:background .2s,border-color .2s,box-shadow .2s,transform .1s}
.btn:hover{background:color-mix(in srgb,var(--acc) 8.0%,transparent);border-color:color-mix(in srgb,var(--acc) 50.0%,transparent)}
.btn.sm{border-radius:999px;padding:7px 14px}
.btn.primary{background:var(--goldgrad);color:#1A1308;border:0;box-shadow:0 6px 24px -8px color-mix(in srgb,var(--acc) 55.0%,transparent),inset 0 1px 0 rgba(255,255,255,.35)}
.btn.primary:hover{filter:brightness(1.07);background:var(--goldgrad);box-shadow:0 10px 30px -8px color-mix(in srgb,var(--acc) 70.0%,transparent),inset 0 1px 0 rgba(255,255,255,.4)}
.btn.primary kbd{background:rgba(0,0,0,.18);border-color:rgba(0,0,0,.2);color:#3A2A0E}
.btn.ghost{background:transparent}
.chip{border-radius:999px;font-weight:600;font-size:12.5px;letter-spacing:.02em;background:rgba(255,255,255,.02);border-color:var(--line)}
.chip:hover{border-color:var(--line2);color:var(--text)}
.chip[aria-pressed="true"]{background:var(--goldgrad);color:#1A1308;border-color:transparent;box-shadow:0 4px 16px -6px color-mix(in srgb,var(--acc) 60.0%,transparent)}
.input,select{background:rgba(255,255,255,.025);border:1px solid var(--line2);border-radius:12px}
.input:focus,select:focus{border-color:var(--gold);outline:none;box-shadow:0 0 0 3px color-mix(in srgb,var(--acc) 12.0%,transparent)}
.bm{background:var(--goldgrad);color:#1A1308;border-radius:999px}

/* panneaux et cartes */
.panel,.ccard,.mode,.pod,.sheet,.hero{background:linear-gradient(180deg,rgba(255,255,255,.028),rgba(255,255,255,.008)),var(--panel);border:1px solid var(--line)}
.panel{border-radius:var(--r)}
.ccard{border-radius:18px}
.ccard:hover,.mode:hover{border-color:var(--line2);box-shadow:0 20px 50px -30px color-mix(in srgb,var(--acc) 35.0%,transparent)}
.ccard .type .dot{background:var(--gold)}
.ccard.music .type .dot{background:var(--gold2)}
.ccard.add{border:1px dashed var(--line2);color:var(--gold2)}
.ccard .meta b{font-family:var(--body);color:var(--gold2)}
.mode em{color:var(--gold);letter-spacing:.2em;font-size:10px}
.sheet{border-color:var(--line2);border-radius:22px;box-shadow:0 40px 100px rgba(0,0,0,.7),inset 0 1px 0 color-mix(in srgb,var(--acc) 12.0%,transparent)}
.modal{background:rgba(3,3,5,.78)}
.toast{background:#15131A;border:1px solid var(--line2);border-radius:999px;box-shadow:0 20px 50px rgba(0,0,0,.6)}
.hero{border-radius:22px}
.hero::after{background:linear-gradient(90deg,rgba(7,7,10,.97) 0%,rgba(7,7,10,.82) 45%,rgba(7,7,10,.25) 100%),linear-gradient(0deg,rgba(7,7,10,.95),transparent 60%)}
.hero-bg{opacity:.6}
.bar{height:3px;background:rgba(255,255,255,.05)}
.bar i{background:var(--goldgrad)}
.fight:nth-child(odd){background:rgba(255,255,255,.018)}
.fight .w .nm::before{color:var(--gold)}
.track span.cur{background:var(--goldgrad);color:#1A1308;border-color:transparent}
.track span.done{color:var(--gold2);background:color-mix(in srgb,var(--acc) 8.0%,transparent)}
.ptabs button{border-radius:999px;background:rgba(255,255,255,.02)}
.ptabs button[aria-selected="true"]{color:var(--gold2);border-color:var(--line2);background:color-mix(in srgb,var(--acc) 8.0%,transparent)}
.pod .n{font-weight:600;font-style:italic;font-size:40px}
.pod.p1 .n{background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.pod.p1 .poster,.pod.p1 .noposter{box-shadow:0 0 0 1px var(--gold),0 20px 40px -12px color-mix(in srgb,var(--acc) 45.0%,transparent)}
.row:hover{background:color-mix(in srgb,var(--acc) 4.0%,transparent)}
.row .rk{font-family:var(--display);font-style:italic;font-weight:600;font-size:22px;color:var(--gold)}
.steps>li::before{font-style:italic;font-weight:600;font-size:20px;background:color-mix(in srgb,var(--acc) 10.0%,transparent);color:var(--gold2);border:1px solid var(--line2)}
.pastezone{border:1px dashed var(--line2);border-radius:18px}

/* scène de duel : salle de cinéma */
.stage{border-radius:24px;border:1px solid var(--line);background:
  radial-gradient(ellipse 70% 55% at 50% -8%,color-mix(in srgb,var(--acc2) 10.0%,transparent),transparent 70%),
  linear-gradient(180deg,#0E0D12,#09080C);box-shadow:inset 0 1px 0 color-mix(in srgb,var(--acc) 12.0%,transparent),0 40px 80px -40px rgba(0,0,0,.8)}
.stage{--ambL:rgba(200,64,79,.20);--ambR:rgba(85,132,221,.20)}
.stage-bg{opacity:.24;filter:blur(40px) saturate(1.3);transform:translateZ(0)}
.vs{font-style:italic;font-weight:600;font-size:clamp(44px,6vw,86px);background:var(--goldgrad)!important;-webkit-background-clip:text!important;background-clip:text!important;color:transparent!important;display:grid;justify-items:center;gap:6px;filter:drop-shadow(0 4px 20px color-mix(in srgb,var(--acc) 25.0%,transparent))}
.vs::before,.vs::after{content:"";width:1px;height:70px;background:linear-gradient(180deg,transparent,color-mix(in srgb,var(--acc) 60.0%,transparent),transparent)}
.card .art{border-radius:10px;box-shadow:0 30px 60px -24px rgba(0,0,0,.95),0 0 0 1px color-mix(in srgb,var(--acc) 12.0%,transparent)}
.card.l:hover .art{box-shadow:0 0 0 1px rgba(200,64,79,.9),0 0 40px 2px rgba(200,64,79,.35),0 30px 60px -24px rgba(0,0,0,.95)}
.card.r:hover .art{box-shadow:0 0 0 1px rgba(85,132,221,.9),0 0 40px 2px rgba(85,132,221,.35),0 30px 60px -24px rgba(0,0,0,.95)}
.card.l.win .art,.card.r.win .art{box-shadow:0 0 0 2px var(--gold),0 0 70px 10px color-mix(in srgb,var(--acc) 45.0%,transparent)}
.card:hover{transform:none}
.corner{font-weight:700;font-size:9.5px;letter-spacing:.2em;border-radius:999px;padding:4px 10px;backdrop-filter:blur(6px)}
.card.l .corner{background:rgba(200,64,79,.85)}.card.r .corner{background:rgba(85,132,221,.85)}
.rankb{font-weight:700;font-size:10px;letter-spacing:.1em;border-radius:999px;background:rgba(7,7,10,.7);border:1px solid var(--line2);color:var(--gold2)}
.pick{font-family:var(--display);font-style:italic;font-weight:600;font-size:24px;letter-spacing:.02em}
.ctitle{font-family:var(--display);font-weight:600;font-size:26px;line-height:1.08}
.badge{font-weight:600;font-size:10.5px;letter-spacing:.08em;color:var(--faint)}
.badge b{color:var(--gold)}
.stamp{font-style:italic;font-weight:700;color:#E0DAD0;text-shadow:0 2px 30px rgba(0,0,0,.9)}
.stamp.draw{color:var(--gold2)}
.btn.choose.l{border-color:rgba(200,64,79,.55)}
.btn.choose.r{border-color:rgba(85,132,221,.55)}
.btn.choose.l:hover{background:rgba(200,64,79,.12)}
.btn.choose.r:hover{background:rgba(85,132,221,.12)}
.khint{color:var(--faint)}
.fxpanel{background:rgba(255,255,255,.02);border-color:var(--line)}
.fxn b{color:var(--gold2)}

/* jeux */
.stage.game.full{background:radial-gradient(ellipse 60% 45% at 50% -5%,color-mix(in srgb,var(--acc2) 10.0%,transparent),transparent 70%),#07070A}
.gsteps span{border-radius:12px;background:rgba(255,255,255,.02)}
.gsteps b{font-family:var(--display);font-style:italic;font-weight:600;font-size:20px}
.gsteps .cur{color:var(--gold2);border-color:var(--gold);background:color-mix(in srgb,var(--acc) 8.0%,transparent);box-shadow:0 0 24px -4px color-mix(in srgb,var(--acc) 35.0%,transparent)}
.gsteps .past{background:rgba(200,64,79,.06);border-color:rgba(200,64,79,.25)}
.gclip,.gcrop,.gplot{border-radius:16px;box-shadow:0 0 0 1px var(--line2),0 30px 70px -30px rgba(0,0,0,.9)}
.gmask{background:radial-gradient(circle,#17151C,#070709)}
.gprog i{background:var(--goldgrad)}
.gplot{font-family:var(--display);font-size:21px;line-height:1.5;font-weight:500}
.gguess .input{border-color:var(--line2);border-radius:999px;padding:14px 22px}
.gguess .input:focus{border-color:var(--gold)}
.gsug{border-radius:18px;border-color:var(--line2);background:#121016}
.gsug button.on,.gsug button:hover{background:color-mix(in srgb,var(--acc) 8.0%,transparent)}
.greveal{border-radius:20px;background:rgba(255,255,255,.02)}
.greveal.ok{border-color:color-mix(in srgb,var(--acc) 55.0%,transparent);box-shadow:0 0 50px -10px color-mix(in srgb,var(--acc) 30.0%,transparent)}
.greveal.ok .gres b{color:var(--gold2)}
.gcard h3{font-family:var(--display);font-weight:600;font-size:28px}
.gst{color:var(--gold)!important}

/* arbre */
.bmatch{background:rgba(255,255,255,.025);border-color:var(--line)}
.bmatch.now,.bmatch.champ{border-color:var(--gold)}
.blink path{stroke:color-mix(in srgb,var(--acc) 28.0%,transparent)}
.bs.w{background:color-mix(in srgb,var(--acc) 7.0%,transparent)}
body.dropping::after{font-style:italic;font-weight:600;border:1px dashed var(--gold);color:var(--gold2)}


/* =====================================================================
   v10 : DISPOSITION « NETFLIX » + TYPO MODERNE GRASSE (Archivo / Inter)
   ===================================================================== */
:root{--padx:clamp(18px,4vw,64px);--navh:68px}
body{font-size:14.5px;letter-spacing:0}
/* plus de barre latérale */
.app{display:block}
.side{display:none!important}
.main{min-height:100vh}
#view{padding:26px var(--padx) 80px}
/* titres : Archivo gras, large */
.logo,.ttl h1,.hero h2,.sech h2,.sheet h2,.mode strong,.champ h2,.gres,.pod .n,.big,.vs,.stamp,.ccard.add .plus,.noposter,.steps>li::before,.ctitle,.gcard h3,.gsteps b,.pick,.row .rk,.gplot{font-family:var(--display)!important;font-style:normal!important}
.ttl h1,.sech h2,.sheet h2,.hero h2,.mode strong,.gres{text-transform:uppercase!important;font-weight:800!important;font-stretch:112%;letter-spacing:-.005em!important}
.ttl h1{font-size:clamp(26px,3vw,40px)!important;line-height:1}
.sech h2{font-size:22px!important}
.sheet h2{font-size:26px!important}
.mode strong{font-size:22px!important}
.gres{font-size:30px!important}
.ctitle{font-weight:800;font-size:22px;line-height:1.1;font-stretch:105%;letter-spacing:-.01em}
.gcard h3{font-weight:800;font-size:24px}
.gplot{font-family:var(--body)!important;font-size:18px;font-weight:500}
.gsteps b{font-weight:800;font-size:17px}
.pick{font-weight:800;font-size:15px;letter-spacing:.14em;text-transform:uppercase}
.row .rk{font-weight:900;font-size:24px;font-stretch:110%}
.noposter{font-weight:800;font-size:18px;text-transform:uppercase;font-stretch:110%}
.champ h2{font-weight:900!important;font-stretch:115%;text-transform:uppercase!important;font-size:clamp(36px,5.5vw,70px)!important}
.pod .n{font-weight:900;font-size:44px}
.stamp{font-weight:900;font-stretch:120%;letter-spacing:.02em}
.vs{font-weight:900!important;font-style:italic!important;font-stretch:120%;font-size:clamp(46px,6vw,92px)!important}
.steps>li::before{font-weight:800;font-size:16px}
.gsubs{font-family:var(--body)}
.slabel,.ttl .kicker,.hero .kicker,.ccard .type,.panel h3,.h3,.round,.bh{letter-spacing:.2em!important;font-size:10.5px!important;font-weight:700!important}

/* ---------- barre du haut ---------- */
.top{position:sticky;top:0;z-index:30;padding:0;border:0;background:linear-gradient(180deg,rgba(7,7,10,.95) 0%,rgba(7,7,10,.7) 70%,rgba(7,7,10,0) 100%);backdrop-filter:none;-webkit-backdrop-filter:none;transition:background .3s}
.top.solid{background:rgba(7,7,10,.92);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);box-shadow:0 1px 0 var(--line)}
.nav{height:var(--navh);display:flex;align-items:center;gap:clamp(14px,2.5vw,36px);padding:0 var(--padx)}
.brand{background:none;border:0;padding:0;font:900 26px var(--display);font-stretch:125%;letter-spacing:.04em;color:transparent;background-image:var(--goldgrad);-webkit-background-clip:text;background-clip:text;display:flex;align-items:baseline;gap:8px;white-space:nowrap}
.brand span{font:700 10px var(--body);letter-spacing:.35em;color:var(--muted);-webkit-text-fill-color:var(--muted);text-transform:uppercase}
.navl{display:flex;gap:2px;overflow-x:auto;scrollbar-width:none;min-width:0}
.navl::-webkit-scrollbar{display:none}
.navl .tab{border:0!important;padding:8px 12px;border-radius:999px;font:600 14px var(--body);letter-spacing:0;color:var(--muted);white-space:nowrap}
.navl .tab:hover{color:var(--text)}
.navl .tab[aria-selected="true"]{color:var(--text);font-weight:800;background:rgba(255,255,255,.06);box-shadow:inset 0 0 0 1px var(--line2)}
.navr{margin-left:auto;display:flex;align-items:center;gap:8px}
.ringsel{display:flex;align-items:center;gap:10px;background:rgba(255,255,255,.04);border:1px solid var(--line2);border-radius:999px;padding:4px 14px 4px 4px;max-width:280px;color:var(--text)}
.ringsel:hover{border-color:var(--gold)}
.rs-ico{width:30px;height:30px;border-radius:50%;overflow:hidden;display:grid;place-items:center;background:var(--panel2);flex:none;font-size:14px}
.rs-ico img{width:100%;height:100%;object-fit:cover}
.rs-t{display:grid;text-align:left;min-width:0;font-weight:700;font-size:13px;line-height:1.15}
.rs-t small{font-size:9.5px;letter-spacing:.2em;text-transform:uppercase;color:var(--gold);font-weight:700}
.rs-t b{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:700}
.ringsel .chev{color:var(--muted);font-size:11px}
.icon-btn{position:relative;width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:rgba(255,255,255,.04);border:1px solid var(--line2);color:var(--text);font-size:16px}
.icon-btn:hover{border-color:var(--gold);color:var(--gold2)}
.icon-btn .conn{position:absolute;right:1px;top:1px;width:9px;height:9px;border:2px solid var(--bg)}
.subbar{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:6px var(--padx) 14px}
.keysbtn,.pickbtn,.tabs{display:none!important}

/* ---------- accueil : billboard + rangées ---------- */
.home{margin:calc(-26px - var(--navh)) calc(-1 * var(--padx)) 0}
.bill{position:relative;min-height:min(78vh,760px);display:flex;align-items:flex-end;overflow:hidden;padding:calc(var(--navh) + 40px) var(--padx) 70px}
.bill-bg{position:absolute;inset:-40px;z-index:0}
.bill-bg img{width:100%;height:100%;object-fit:cover;filter:blur(38px) saturate(1.2) brightness(.55);transform:scale(1.15)}
.bill::after{content:"";position:absolute;inset:0;z-index:1;background:linear-gradient(90deg,rgba(7,7,10,.96) 0%,rgba(7,7,10,.75) 38%,rgba(7,7,10,.15) 75%),linear-gradient(0deg,var(--bg) 0%,rgba(7,7,10,0) 35%),radial-gradient(ellipse 50% 60% at 75% 40%,color-mix(in srgb,var(--acc) 14.0%,transparent),transparent 70%)}
.bill-in{position:relative;z-index:2;width:100%;display:grid;grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);gap:40px;align-items:center}
.bill-txt{display:grid;gap:16px;max-width:640px}
.bill-txt .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.bill-txt h2{margin:0;font:900 clamp(44px,6.5vw,104px)/.9 var(--display);font-stretch:118%;text-transform:uppercase;letter-spacing:-.02em;text-wrap:balance}
.bill-txt p{margin:0;color:#CFC8BB;font-size:16px;max-width:52ch}
.bill-stats{display:flex;gap:26px;flex-wrap:wrap}
.bill-stats div{display:grid}
.bill-stats b{font:900 30px var(--display);font-stretch:110%;color:var(--text)}
.bill-stats span{font:600 10px var(--body);letter-spacing:.2em;text-transform:uppercase;color:var(--muted)}
.bill-txt .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:6px}
.bill-txt .btn{padding:13px 26px;font-size:15px}
.bill-fan{position:relative;height:clamp(300px,42vw,520px);perspective:1400px}
.bill-fan img,.bill-fan .noposter{position:absolute;top:50%;left:50%;width:clamp(150px,17vw,260px);aspect-ratio:2/3;object-fit:cover;border-radius:12px;box-shadow:0 40px 80px -20px rgba(0,0,0,.9),0 0 0 1px rgba(255,255,255,.08);transition:transform .5s cubic-bezier(.2,.8,.2,1)}
.bill-fan .sq{aspect-ratio:1}
.bill-fan .f0{transform:translate(-50%,-50%) translateZ(60px);z-index:5}
.bill-fan .f1{transform:translate(-115%,-47%) rotateY(18deg) scale(.86);z-index:4;filter:brightness(.7)}
.bill-fan .f2{transform:translate(15%,-47%) rotateY(-18deg) scale(.86);z-index:4;filter:brightness(.7)}
.bill-fan .f3{transform:translate(-170%,-44%) rotateY(26deg) scale(.72);z-index:3;filter:brightness(.45)}
.bill-fan .f4{transform:translate(70%,-44%) rotateY(-26deg) scale(.72);z-index:3;filter:brightness(.45)}
.bill-fan:hover .f1{transform:translate(-125%,-47%) rotateY(14deg) scale(.88)}
.bill-fan:hover .f2{transform:translate(25%,-47%) rotateY(-14deg) scale(.88)}
.bill-fan .crown{position:absolute;left:50%;top:calc(50% - clamp(115px,13vw,195px) - 26px);transform:translateX(-50%);z-index:6;font:800 11px var(--body);letter-spacing:.25em;color:#1A1308;background:var(--goldgrad);padding:5px 12px;border-radius:999px;white-space:nowrap}
.rows{display:grid;gap:34px;padding:10px 0 20px;position:relative;z-index:3;margin-top:-30px}
.hrow{display:grid;gap:12px}
.hrow-h{display:flex;align-items:baseline;justify-content:space-between;gap:12px;padding:0 var(--padx)}
.hrow-h h3{margin:0;font:800 20px var(--display);font-stretch:108%;letter-spacing:-.005em}
.hrow-h h3 small{font:600 12px var(--body);color:var(--muted);margin-left:10px;letter-spacing:0}
.hrow-h .lnk{font-size:13px}
.scroller{position:relative}
.strack{display:grid;grid-auto-flow:column;gap:14px;overflow-x:auto;scroll-snap-type:x mandatory;scroll-padding:0 var(--padx);padding:6px var(--padx) 14px;scrollbar-width:none}
.strack::-webkit-scrollbar{display:none}
.strack>*{scroll-snap-align:start}
.sarrow{position:absolute;top:6px;bottom:14px;width:calc(var(--padx) - 4px);min-width:34px;z-index:4;border:0;background:linear-gradient(90deg,rgba(7,7,10,.9),rgba(7,7,10,0));color:var(--text);font-size:30px;opacity:0;transition:opacity .2s}
.sarrow.r{right:0;background:linear-gradient(270deg,rgba(7,7,10,.9),rgba(7,7,10,0))}
.sarrow.l{left:0}
.scroller:hover .sarrow{opacity:1}
.sarrow:hover{color:var(--gold2)}
/* top 10 avec gros chiffres */
.t10{position:relative;display:flex;align-items:flex-end;background:none;border:0;padding:0;width:clamp(190px,17vw,250px);color:var(--text)}
.t10 .num{font:900 clamp(110px,10vw,160px)/.78 var(--display);font-stretch:85%;letter-spacing:-.06em;color:var(--bg);-webkit-text-stroke:2px color-mix(in srgb,var(--acc) 75.0%,transparent);margin-right:-18px;flex:none;z-index:0}
.t10 img,.t10 .noposter{position:relative;z-index:1;width:62%;aspect-ratio:2/3;object-fit:cover;border-radius:8px;box-shadow:0 20px 40px -14px rgba(0,0,0,.9);transition:transform .25s,box-shadow .25s}
.t10 .sq{aspect-ratio:1}
.t10:hover img,.t10:hover .noposter{transform:translateY(-6px) scale(1.03);box-shadow:0 0 0 2px var(--gold),0 26px 50px -14px rgba(0,0,0,.95)}
.t10.first .num{-webkit-text-stroke:0;background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
/* cartes de ring */
.rcard{position:relative;width:clamp(290px,26vw,380px);aspect-ratio:16/10;border-radius:14px;overflow:hidden;border:1px solid var(--line);background:var(--panel);text-align:left;padding:0;color:var(--text);transition:transform .25s,border-color .25s,box-shadow .25s}
.rcard:hover{transform:translateY(-4px);border-color:var(--line2);box-shadow:0 30px 60px -30px color-mix(in srgb,var(--acc) 40.0%,transparent)}
.rcard .rc-art{position:absolute;inset:0;display:grid;grid-template-columns:repeat(4,1fr)}
.rcard .rc-art img,.rcard .rc-art .noposter{width:100%;height:100%;object-fit:cover;border-radius:0;font-size:9px;padding:3px;aspect-ratio:auto}
.rcard::after{content:"";position:absolute;inset:0;background:linear-gradient(0deg,rgba(7,7,10,.97) 0%,rgba(7,7,10,.6) 48%,rgba(7,7,10,.1) 100%)}
.rcard .rc-body{position:absolute;left:0;right:0;bottom:0;z-index:1;padding:16px;display:grid;gap:6px}
.rcard .rc-type{font:700 10px var(--body);letter-spacing:.22em;text-transform:uppercase;color:var(--gold)}
.rcard h4{margin:0;font:800 22px/1.05 var(--display);font-stretch:108%}
.rcard .rc-meta{display:flex;gap:12px;font-size:12.5px;color:var(--muted)}
.rcard .rc-meta b{color:var(--text)}
.rcard .bar{margin-top:4px}
.rcard .rc-acts{position:absolute;top:10px;right:10px;z-index:2;display:flex;gap:6px;opacity:0;transition:opacity .2s}
.rcard:hover .rc-acts,.rcard:focus-within .rc-acts{opacity:1}
.rc-acts span{font:700 11px var(--body);padding:5px 10px;border-radius:999px;background:rgba(7,7,10,.8);border:1px solid var(--line2);color:var(--text)}
.rc-acts span:hover{border-color:var(--gold);color:var(--gold2)}
.rc-acts span.danger{color:#FF8A94}
.rc-tag{position:absolute;top:10px;left:10px;z-index:2;font:800 10px var(--body);letter-spacing:.14em;text-transform:uppercase;padding:5px 10px;border-radius:999px;background:var(--goldgrad);color:#1A1308}
.rcard.add{display:grid;place-items:center;text-align:center;border-style:dashed;border-color:var(--line2);background:rgba(255,255,255,.015)}
.rcard.add::after{display:none}
.rcard.add .plus{font:300 54px/1 var(--display);color:var(--gold)}
.rcard.add b{font:800 18px var(--display);display:block;margin:4px 0}
.rcard.add small{color:var(--muted);font-size:12.5px;display:block;max-width:30ch;margin:0 auto}
.homehint{margin:0 var(--padx)}

/* ---------- duel immersif ---------- */
.stage:not(.game){margin:0 calc(-1 * var(--padx));border-radius:0;border-left:0;border-right:0;padding:26px var(--padx) 30px}
.arena{max-width:1100px}
.actbar{max-width:1100px}
@media (min-width:1500px){ .arena{max-width:1200px} .card .art{width:min(100%, calc(min(60vh, 600px) * 2 / 3))} }
.card .cmeta{font-size:13.5px}
.badge{font-size:11px;letter-spacing:.06em}

/* ---------- divers ---------- */
.btn{font-weight:700;letter-spacing:.01em}
.chip{font-weight:700}
.panel h3{color:var(--muted)}
.hero{display:none}

@media (max-width:1000px){
  .bill-in{grid-template-columns:1fr}
  .bill-fan{display:none}
  .rs-t{display:none}
  .navl .tab{padding:8px 9px;font-size:13px}
}
@media (max-width:720px){
  .navl{display:none}
  .brand span{display:none}
}
.t10.plain{width:clamp(120px,10vw,160px)}
.t10.plain img,.t10.plain .noposter{width:100%}
.rows,.hrow{grid-template-columns:minmax(0,1fr)}
.rows>*,.hrow>*,.scroller{min-width:0}
.home{overflow-x:clip}

/* fluidité */
.card,.card .art{backface-visibility:hidden}
.strack{contain:layout paint}
.list .row{content-visibility:auto;contain-intrinsic-size:auto 62px}
.grid-mini .mini{content-visibility:auto;contain-intrinsic-size:auto 80px}
.card.win .art{animation-duration:.3s}
.card.ko .art{animation-duration:.26s}

/* =====================================================================
   v11 : couleurs d'accent + thème clair + nouvelles vues
   ===================================================================== */
:root{--acc:#D8B46A;--acc2:#F3DFA8;--acc3:#A87F3C}
:root[data-accent="red"]{--acc:#E5484D;--acc2:#FFA3A6;--acc3:#9E2A2F}
:root[data-accent="blue"]{--acc:#4F8BF5;--acc2:#A9C8FF;--acc3:#2A56B8}
:root{--gold:var(--acc);--gold2:var(--acc2);--gold3:var(--acc3);--goldgrad:linear-gradient(135deg,var(--acc2) 0%,var(--acc) 45%,var(--acc3) 100%)}
/* thème clair */
:root[data-theme="light"]{color-scheme:light;
  --bg:#F3EFE7;--bg2:#ECE6DB;--panel:#FFFFFF;--panel2:#F4F0E8;--panel3:#E9E3D7;
  --line:rgba(40,30,10,.10);--line2:rgba(40,30,10,.20);
  --text:#18140D;--muted:#6A6254;--faint:#9B9383;
  --gold:color-mix(in srgb,var(--acc) 80%,#000);--gold2:color-mix(in srgb,var(--acc) 62%,#000)}
:root[data-theme="light"] body{background:radial-gradient(1100px 520px at 62% -12%,color-mix(in srgb,var(--acc) 14%,transparent),transparent 62%),var(--bg)}
:root[data-theme="light"] body::before{opacity:.015}
:root[data-theme="light"] .top{background:linear-gradient(180deg,rgba(243,239,231,.97) 0%,rgba(243,239,231,.8) 70%,rgba(243,239,231,0) 100%)}
:root[data-theme="light"] .top.solid{background:rgba(243,239,231,.94)}
:root[data-theme="light"] .panel,:root[data-theme="light"] .ccard,:root[data-theme="light"] .mode,:root[data-theme="light"] .pod,:root[data-theme="light"] .sheet{background:var(--panel);box-shadow:0 10px 30px -18px rgba(40,30,10,.25)}
:root[data-theme="light"] .stage{background:radial-gradient(ellipse 70% 55% at 50% -8%,color-mix(in srgb,var(--acc) 14%,transparent),transparent 70%),linear-gradient(180deg,#FBF8F2,#EFE9DE);box-shadow:none}
:root[data-theme="light"] .stage.game.full{background:radial-gradient(ellipse 60% 45% at 50% -5%,color-mix(in srgb,var(--acc) 14%,transparent),transparent 70%),var(--bg)}
:root[data-theme="light"] .bill::after{background:linear-gradient(90deg,rgba(243,239,231,.97) 0%,rgba(243,239,231,.8) 40%,rgba(243,239,231,.1) 78%),linear-gradient(0deg,var(--bg) 0%,rgba(243,239,231,0) 35%)}
:root[data-theme="light"] .bill-bg img{filter:blur(38px) saturate(1.1) brightness(1.05)}
:root[data-theme="light"] .bill-txt p{color:var(--muted)}
:root[data-theme="light"] .rcard .rc-body{color:#fff}
:root[data-theme="light"] .rcard .rc-meta{color:#ddd}
:root[data-theme="light"] .rcard .rc-meta b{color:#fff}
:root[data-theme="light"] .sarrow{background:linear-gradient(90deg,rgba(243,239,231,.95),rgba(243,239,231,0));color:var(--text)}
:root[data-theme="light"] .sarrow.r{background:linear-gradient(270deg,rgba(243,239,231,.95),rgba(243,239,231,0))}
:root[data-theme="light"] .t10 .num{color:var(--bg);-webkit-text-stroke-color:var(--gold)}
:root[data-theme="light"] .gmask{background:radial-gradient(circle,#FFFFFF,#E7E0D3);color:var(--muted)}
:root[data-theme="light"] .gsug{background:#fff}
:root[data-theme="light"] .input,:root[data-theme="light"] select{background:#fff}
:root[data-theme="light"] .btn{background:#fff}
:root[data-theme="light"] .btn.primary{background:var(--goldgrad)}
:root[data-theme="light"] .btn.ghost{background:transparent}
:root[data-theme="light"] .chip{background:#fff}
:root[data-theme="light"] .modal{background:rgba(40,30,10,.35)}
:root[data-theme="light"] .toast{background:#fff;color:var(--text)}
:root[data-theme="light"] .rankb{background:rgba(255,255,255,.85);color:var(--gold)}
:root[data-theme="light"] .stamp{color:#fff}
:root[data-theme="light"] .noposter{background:linear-gradient(160deg,#EFE9DE,#E2DACB)}
:root[data-theme="light"] .fight:nth-child(odd){background:rgba(40,30,10,.03)}
:root[data-theme="light"] .icon-btn,:root[data-theme="light"] .ringsel{background:#fff}
:root[data-theme="light"] .bmatch{background:#fff}
.swatch{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:-1px}
.swatch.gold{background:#D8B46A}.swatch.red{background:#E5484D}.swatch.blue{background:#4F8BF5}
.confetti{position:fixed;inset:0;z-index:200;pointer-events:none}

/* historique */
.hist{margin-top:12px;padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:rgba(255,255,255,.02)}
.hist-t{font-size:13px;color:var(--muted);margin-bottom:6px}.hist-t b{color:var(--text)}
.hist-svg{width:100%;height:110px;display:block}
.hist-svg path{fill:none;stroke:var(--gold);stroke-width:2.2;vector-effect:non-scaling-stroke}
.hist-svg circle{fill:var(--gold2)}
.hist-l{display:flex;justify-content:space-between;font-size:11px;color:var(--faint)}

/* tier list */
.tierboard{display:grid;gap:6px;margin-bottom:18px}
.trow{display:grid;grid-template-columns:86px minmax(0,1fr);min-height:112px;border:1px solid var(--line);border-radius:14px;overflow:hidden;background:rgba(255,255,255,.02)}
.tlab{display:grid;place-content:center;text-align:center;background:var(--tc);color:#16120A;font:900 40px var(--display);font-stretch:115%}
.tlab small{font:700 11px var(--body);opacity:.7}
.tzone{display:flex;flex-wrap:wrap;gap:6px;padding:8px;align-content:flex-start;min-height:100px;transition:background .15s}
.tzone.over{background:color-mix(in srgb,var(--acc) 10%,transparent)}
.tzone.pool{min-height:140px}
.tempty{color:var(--faint);font-size:12px;align-self:center;padding:0 8px}
.tt{width:64px;cursor:grab;border-radius:6px;transition:transform .15s}
.tt:hover{transform:translateY(-3px)}
.tt.dragging{opacity:.4}
.tt .tti{width:64px;aspect-ratio:2/3;object-fit:cover;border-radius:6px;display:block;pointer-events:none}
.tt .tti.sq{aspect-ratio:1}
.tt .noposter.tti{font-size:8px;padding:3px}
.tchk{display:flex;align-items:center;gap:6px}
.tpop{position:absolute;z-index:80;display:flex;gap:4px;padding:6px;background:var(--panel);border:1px solid var(--line2);border-radius:12px;box-shadow:0 20px 40px rgba(0,0,0,.5)}
.tpop button{width:38px;height:38px;border-radius:9px;border:0;background:var(--tc,var(--panel3));color:#16120A;font:900 18px var(--display)}
.tpop button:last-child{background:var(--panel3);color:var(--text)}

/* tri rapide */
.swipe{display:grid;grid-template-columns:minmax(0,320px) minmax(0,1fr);gap:26px;align-items:start}
.sw-side{display:grid;gap:14px}
.sw-stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:10px;text-align:center}
.sw-stats b{display:block;font:900 26px var(--display)}.sw-stats span{font-size:11px;color:var(--muted)}
.sw-kept{display:flex;flex-wrap:wrap;gap:4px;margin-bottom:10px}
.sw-kept .th{width:34px}
.sw-acts{display:grid;gap:6px}
.sw-main{display:grid;justify-items:center;gap:14px}
.sw-stack{position:relative;width:min(340px,70vw);aspect-ratio:2/3}
.sw-card{position:absolute;inset:0;border-radius:18px;overflow:hidden;box-shadow:0 40px 80px -30px rgba(0,0,0,.9),0 0 0 1px var(--line2);touch-action:none;cursor:grab;transition:transform .25s;user-select:none;background:var(--panel2)}
.sw-card img,.sw-card .noposter{width:100%;height:100%;object-fit:cover;border-radius:0;pointer-events:none}
.sw-card.back{transform:scale(.93) translateY(14px);filter:brightness(.55);cursor:default}
.sw-lab{position:absolute;top:22px;padding:6px 14px;border:3px solid;border-radius:10px;font:900 26px var(--display);opacity:0;transition:opacity .1s}
.sw-lab.keep{left:18px;color:#7FD99A;border-color:#7FD99A;transform:rotate(-12deg)}
.sw-lab.drop{right:18px;color:#FF7A85;border-color:#FF7A85;transform:rotate(12deg)}
.sw-card.k .sw-lab.keep,.sw-card.d .sw-lab.drop{opacity:1}
.sw-info{text-align:center}.sw-info h2{margin:0 0 4px;font:800 26px var(--display)}
.sw-info .cmeta{justify-content:center}
.sw-player{width:min(520px,100%)}
.sw-btns{display:flex;gap:16px;align-items:center}
.sw-b{width:64px;height:64px;border-radius:50%;border:1px solid var(--line2);background:var(--panel);font-size:26px;color:var(--text);transition:transform .15s,box-shadow .15s}
.sw-b:hover{transform:scale(1.08)}
.sw-b.drop{color:#FF7A85}.sw-b.keep{color:#7FD99A}
.sw-b.drop:hover{box-shadow:0 0 30px rgba(255,90,100,.35)}.sw-b.keep:hover{box-shadow:0 0 30px rgba(120,220,150,.35)}
.sw-b.undo,.sw-b.skip{width:48px;height:48px;font-size:18px}
.sw-done{text-align:center;padding:60px 0}

/* ce soir */
.tn-intro{max-width:720px;margin:20px auto;display:grid;gap:16px;text-align:center;justify-items:center}
.tn-intro h2{margin:0;font:900 clamp(40px,6vw,80px)/.95 var(--display);font-stretch:115%;text-transform:uppercase}
.tn-intro .kicker,.tn-win .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.tn-intro p{margin:0;color:var(--muted)}
.tn-opts{display:flex;gap:18px;flex-wrap:wrap;justify-content:center;align-items:end}
.tn-opts label{display:grid;gap:6px}
.tn-intro .btn.primary{padding:14px 30px;font-size:16px}
.tn-hint{max-width:560px}
.tn-win{position:relative;overflow:hidden;border-radius:24px;margin:0 calc(-1*var(--padx));min-height:70vh;display:grid;place-items:center;padding:40px var(--padx)}
.tn-bg{position:absolute;inset:-40px}.tn-bg img{width:100%;height:100%;object-fit:cover;filter:blur(40px) brightness(.45) saturate(1.3)}
.tn-in{position:relative;display:grid;justify-items:center;gap:12px;text-align:center}
.tn-in .poster{width:min(300px,60vw);border-radius:14px;box-shadow:0 0 0 2px var(--gold),0 40px 90px -20px rgba(0,0,0,.9);animation:rise .5s ease}
.tn-in h2{margin:6px 0 0;font:900 clamp(34px,5vw,64px)/1 var(--display);font-stretch:112%;text-transform:uppercase;color:#fff}
.tn-in .cmeta{color:#ddd}
.tn-in .row{display:flex;gap:10px;flex-wrap:wrap;justify-content:center;margin-top:8px}

/* stats */
.scards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:16px}
.scard{padding:18px;border:1px solid var(--line);border-radius:16px;background:linear-gradient(180deg,rgba(255,255,255,.03),rgba(255,255,255,.01)),var(--panel)}
.scard b{display:block;font:900 34px var(--display);font-stretch:110%}.scard span{font-size:12px;color:var(--muted)}
.sgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:14px}
.srows{display:grid;gap:7px}
.srow{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) auto;gap:10px;align-items:center;font-size:13.5px}
.sname{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.sname b{color:var(--gold)}
.sbar{height:8px;border-radius:4px;background:rgba(255,255,255,.05);overflow:hidden}.sbar i{display:block;height:100%;background:var(--goldgrad);border-radius:4px}
.sval{font-weight:800;text-align:right;min-width:70px}.sval small{display:block;font-weight:500;font-size:11px;color:var(--muted)}
.tag.up{color:#7FD99A}.tag.down{color:#FF7A85}
/* récap */
.recap{display:grid;gap:16px}
.rc-hero{padding:34px;border-radius:22px;border:1px solid var(--line2);background:radial-gradient(ellipse 60% 90% at 80% 0%,color-mix(in srgb,var(--acc) 22%,transparent),transparent 70%),var(--panel);display:grid;gap:14px}
.rc-hero .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.rc-hero h2{margin:0;font:900 clamp(36px,5vw,64px)/1 var(--display);font-stretch:115%;text-transform:uppercase}
.rc-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px}
.rc-t{display:grid;grid-template-columns:64px minmax(0,1fr);gap:12px;align-items:center;margin-bottom:10px}
.rc-t .poster,.rc-t .noposter{width:64px;border-radius:8px}
.rc-t b{display:block;font-weight:800}.rc-t span{font-size:12.5px;color:var(--muted)}
.rc-t.gold .poster{box-shadow:0 0 0 2px var(--gold)}
.rc-vs{display:grid;gap:4px}.rc-vs>span{font:900 italic 18px var(--display);color:var(--gold);padding-left:76px}

/* à deux */
.defi{margin-bottom:16px;border-color:var(--line2)}
.defi .input{flex:1 1 280px}
.dpair{display:grid;grid-template-columns:1fr auto 1fr;gap:14px;align-items:center}
.dcard{display:grid;gap:6px;justify-items:center;text-align:center;background:none;border:1px solid var(--line);border-radius:14px;padding:10px;color:var(--text);transition:border-color .15s,transform .15s}
.dcard:hover{transform:translateY(-3px)}.dcard.l:hover{border-color:var(--red)}.dcard.r:hover{border-color:var(--blue)}
.dcard img,.dcard .noposter{width:100%;max-width:190px;aspect-ratio:2/3;object-fit:cover;border-radius:10px}
.dcard img.sq,.dcard .noposter.sq{aspect-ratio:1}
.dcard b{font-weight:800}.dcard span{font-size:12px;color:var(--muted)}
.dvs{font:900 italic 30px var(--display);color:var(--gold)}
.compat{display:flex;align-items:center;gap:18px}
.cring{--p:0;flex:none;width:130px;height:130px;border-radius:50%;display:grid;place-content:center;text-align:center;background:radial-gradient(closest-side,var(--panel) 78%,transparent 80% 100%),conic-gradient(var(--gold) calc(var(--p)*1%),rgba(255,255,255,.08) 0)}
.cring b{font:900 30px var(--display)}.cring span{font-size:11px;color:var(--muted)}
.compat .kicker{font:700 11px var(--body);letter-spacing:.2em;text-transform:uppercase;color:var(--gold)}

/* jeux en plus */
.gquote{max-width:820px;display:grid;gap:12px}
.gquote blockquote{margin:0;padding:22px 26px;border-radius:16px;border:1px solid var(--line2);background:rgba(255,255,255,.025);font:700 clamp(20px,2.4vw,30px)/1.3 var(--display);letter-spacing:-.005em}
.gquote blockquote.fr{font-weight:600;font-size:clamp(17px,2vw,24px);color:var(--muted);border-style:dashed}
.gquote cite{display:block;margin-top:10px;font:700 10px var(--body);letter-spacing:.25em;text-transform:uppercase;color:var(--gold);font-style:normal}
.gcast{display:grid;gap:10px;min-width:min(520px,100%)}
.gactor{display:flex;align-items:center;gap:14px;padding:14px 18px;border:1px solid var(--line2);border-radius:14px;background:rgba(255,255,255,.025);font:800 22px var(--display);animation:rise .35s ease}
.gactor span{width:30px;height:30px;border-radius:50%;display:grid;place-items:center;background:var(--goldgrad);color:#16120A;font:900 14px var(--body)}
.gyear{display:flex;gap:10px}
.gyear .input{flex:1}
@media (max-width:900px){ .swipe{grid-template-columns:1fr} .sw-side{order:2} .dpair{grid-template-columns:1fr 1fr} .dvs{display:none} }

/* fluidité v12 : pas de backdrop-filter, flous sur images minuscules */
.top,.top.solid,.modal,.corner,.stage.game.full{backdrop-filter:none!important;-webkit-backdrop-filter:none!important}
.top.solid{background:rgba(7,7,10,.97)}
:root[data-theme="light"] .top.solid{background:rgba(243,239,231,.98)}
.modal{background:rgba(3,3,5,.84)}
.stage-bg{filter:blur(14px) saturate(1.3)!important;opacity:.3!important;inset:-20px!important}
.stage-bg img{image-rendering:auto}
.bill-bg img{filter:blur(14px) saturate(1.2) brightness(.55)!important;transform:scale(1.1)}
:root[data-theme="light"] .bill-bg img{filter:blur(14px) saturate(1.1) brightness(1.05)!important}
.hrow{content-visibility:auto;contain-intrinsic-size:auto 320px}
.vs{filter:none!important;text-shadow:none}
.card .art{will-change:auto}
.card:hover .art{will-change:transform}

.gcast{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,210px));justify-content:center;gap:14px;min-width:min(680px,100%)}
.gcast .gfacts{grid-column:1/-1;justify-content:center}
.gactor{display:grid!important;justify-items:center;gap:10px;padding:14px!important;text-align:center}
.gactor img,.gactor .noface{width:140px;height:170px;object-fit:cover;object-position:50% 20%;border-radius:12px;box-shadow:0 14px 30px -12px rgba(0,0,0,.8)}
.gactor .noface{display:grid;place-items:center;background:var(--panel2);font:900 42px var(--display);color:var(--gold);font-style:normal}
.gactor b{font:800 17px/1.2 var(--display)}
.gcast.all .gactor img,.gcast.all .gactor .noface{width:100px;height:122px}
.gactor .noface{background:radial-gradient(circle at 50% 35%,color-mix(in srgb,var(--acc) 30%,var(--panel2)),var(--panel2) 70%);font-size:46px;letter-spacing:.02em}

/* plus ou moins */
.hl-intro,.hl-over{max-width:900px;margin:10px auto;display:grid;gap:14px;text-align:center;justify-items:center}
.hl-intro h2,.hl-over h2{margin:0;font:900 clamp(38px,5.5vw,72px)/.95 var(--display);font-stretch:115%;text-transform:uppercase}
.hl-intro .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.hl-intro p{margin:0;color:var(--muted);max-width:62ch}
.hl-modes{width:100%;text-align:left}
.hl-over .big{font:900 120px/1 var(--display);background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.hl-head{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:14px}
.hl-head .btn{margin-left:auto}
.hl-arena{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);gap:clamp(14px,3vw,40px);align-items:center}
.hl-card{position:relative;overflow:hidden;border-radius:22px;border:1px solid var(--line2);padding:24px;display:grid;justify-items:center;gap:8px;text-align:center;min-height:62vh;align-content:center}
.hl-bg{position:absolute;inset:-20px;z-index:0}.hl-bg img{width:100%;height:100%;object-fit:cover;filter:blur(18px) brightness(.35) saturate(1.3)}
.hl-card>*:not(.hl-bg){position:relative;z-index:1}
.hl-card .poster,.hl-card .noposter{width:min(230px,26vw);border-radius:12px;box-shadow:0 30px 60px -20px rgba(0,0,0,.9)}
.hl-t{font:800 24px/1.1 var(--display);color:#fff;max-width:30ch}
.hl-card .cmeta{justify-content:center;color:#ccc}
.hl-val{font:900 clamp(40px,5vw,64px)/1 var(--display);color:#fff;margin-top:6px;transition:color .3s,transform .3s}
.hl-card.b .hl-val{color:var(--gold2)}
.hl-val.ok{color:#7FD99A!important;transform:scale(1.12)}.hl-val.ko{color:#FF7A85!important;transform:scale(1.12)}
.hl-lab{font:700 10px var(--body);letter-spacing:.25em;text-transform:uppercase;color:#bbb}
.hl-mid{display:grid;gap:12px;justify-items:center;max-width:220px;text-align:center}
.hl-mid .btn{width:100%;padding:14px 18px;font-size:15px}
@media (max-width:900px){.hl-arena{grid-template-columns:1fr}.hl-card{min-height:0}}
/* roulette */
.wheel-wrap{display:grid;justify-items:center;gap:16px}
.wheel{position:relative;width:min(640px,86vw,72vh);aspect-ratio:1}
.wheel canvas{width:100%;height:100%;display:block;filter:drop-shadow(0 30px 60px rgba(0,0,0,.7))}
.wh-pointer{position:absolute;left:50%;top:-6px;transform:translateX(-50%);width:0;height:0;border-left:18px solid transparent;border-right:18px solid transparent;border-top:34px solid var(--gold);z-index:2;filter:drop-shadow(0 4px 8px rgba(0,0,0,.6))}
.wh-center{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:22%;aspect-ratio:1;border-radius:50%;border:4px solid var(--gold);background:radial-gradient(circle,#1C1A22,#0B0A0E);color:var(--gold2);font:900 clamp(13px,1.6vw,18px) var(--display);letter-spacing:.05em;cursor:pointer;box-shadow:0 0 40px color-mix(in srgb,var(--acc) 35%,transparent)}
.wh-center:disabled{opacity:.6}
/* scène */
.gscene{display:grid;gap:10px;justify-items:center;width:min(900px,100%)}
.gs-main img{width:min(880px,100%);aspect-ratio:16/9;object-fit:cover;border-radius:16px;box-shadow:0 0 0 1px var(--line2),0 30px 70px -30px rgba(0,0,0,.9);display:block;animation:rise .35s ease}
.gs-thumbs{display:flex;gap:10px}
.gs-thumbs img{width:180px;aspect-ratio:16/9;object-fit:cover;border-radius:10px;opacity:.85;box-shadow:0 0 0 1px var(--line2)}

/* chrono / connexions */
.ch-arena{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);gap:clamp(14px,3vw,40px);align-items:center;max-width:1000px;margin:0 auto}
.ch-card{display:grid;justify-items:center;gap:8px;text-align:center}
.ch-card .poster,.ch-card .noposter{width:min(230px,26vw,34vh);border-radius:12px;box-shadow:0 30px 60px -20px rgba(0,0,0,.9),0 0 0 1px var(--line2)}
.ch-card b{font:800 20px/1.1 var(--display);max-width:26ch}
.ch-y{font:900 44px/1 var(--display);color:var(--gold2)}
.ch-y.q{color:var(--faint)}.ch-y.ok{color:#7FD99A}.ch-y.ko{color:#FF7A85}
.ch-mid{display:grid;gap:10px;justify-items:center;max-width:220px;text-align:center}
.ch-mid .btn{width:100%;padding:13px 18px}
.ch-over{text-align:center;display:grid;gap:10px;justify-items:center;padding:20px 0}
.ch-over .big{font:900 110px/1 var(--display);background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.ch-over h2{margin:0;font:900 40px var(--display);text-transform:uppercase}
.frise{display:flex;align-items:center;gap:0;overflow-x:auto;padding:10px 4px 14px;scrollbar-width:thin}
.fr-it{flex:none;display:grid;justify-items:center;gap:4px;width:92px;text-align:center;padding:8px 4px;border-radius:10px;border:1px solid var(--line)}
.fr-it .th{width:46px}
.fr-it b{font:900 15px var(--display);color:var(--gold2)}
.fr-it span{font-size:10.5px;color:var(--muted);line-height:1.2;max-height:2.4em;overflow:hidden}
.fr-it.cur{border-color:var(--gold);box-shadow:0 0 18px color-mix(in srgb,var(--acc) 35%,transparent)}
.fr-line{flex:none;width:18px;height:2px;background:var(--line2)}
.cx-link{font-size:44px}
/* intrus */
.in-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px;max-width:1100px;margin:0 auto}
.in-card{position:relative;display:grid;justify-items:center;gap:8px;padding:12px;border-radius:16px;border:1px solid var(--line2);background:rgba(255,255,255,.02);color:var(--text);text-align:center;transition:transform .15s,border-color .15s}
.in-card:hover:not([disabled]){transform:translateY(-4px);border-color:var(--gold)}
.in-card .poster,.in-card .noposter{width:100%;border-radius:10px}
.in-card b{font:800 16px/1.15 var(--display)}
.in-card span{font-size:12px;color:var(--muted);min-height:1.2em}
.in-card kbd{position:absolute;top:18px;left:18px;z-index:2}
.in-card.odd{border-color:#7FD99A;box-shadow:0 0 30px rgba(120,220,150,.3)}
.in-card.same{opacity:.55}
.in-card.wrong{border-color:#FF7A85;opacity:1}
.in-res{text-align:center;margin-top:16px;font-size:16px}.in-res.ok b,.in-res.ko b{color:var(--gold2)}
@media (max-width:900px){.in-grid{grid-template-columns:repeat(2,1fr)}.ch-arena{grid-template-columns:1fr}}
/* battle */
.battle{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:end;width:100%;padding-top:10px;border-top:1px dashed var(--line2)}
.battle label{display:grid;gap:4px;font-size:12px;color:var(--muted);font-weight:600}
.battle select{max-width:240px}
.battle .input{width:110px}
.bvs{font:900 italic 18px var(--display);color:var(--gold);padding-bottom:8px}
/* trophées */
.tr-hero{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:20px;padding:30px;border-radius:22px;border:1px solid var(--line2);background:radial-gradient(ellipse 60% 100% at 90% 0%,color-mix(in srgb,var(--acc) 22%,transparent),transparent 70%),var(--panel);margin-bottom:22px}
.tr-hero .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.tr-hero h2{margin:4px 0;font:900 56px/1 var(--display);font-stretch:112%}
.tr-medals{display:flex;gap:22px}.tr-medals div{display:grid;text-align:center}.tr-medals b{font:900 24px var(--display)}.tr-medals span{font-size:11px;color:var(--muted)}
.tr-sec{margin-bottom:26px}
.tr-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px}
.tr-card{display:grid;grid-template-columns:58px minmax(0,1fr);gap:14px;align-items:center;padding:14px;border-radius:16px;border:1px solid var(--line);background:linear-gradient(180deg,rgba(255,255,255,.025),rgba(255,255,255,.008)),var(--panel)}
.tr-ic{width:58px;height:58px;border-radius:14px;display:grid;place-items:center;font-size:28px;background:var(--panel2);filter:grayscale(1);opacity:.55}
.tr-card.tier0 .tr-ic{filter:none;opacity:1;background:linear-gradient(135deg,#8C5A32,#4A2E18)}
.tr-card.tier1 .tr-ic{filter:none;opacity:1;background:linear-gradient(135deg,#C9CED6,#6E7480)}
.tr-card.tier2 .tr-ic{filter:none;opacity:1;background:var(--goldgrad);box-shadow:0 0 22px color-mix(in srgb,var(--acc) 40%,transparent)}
.tr-card.tier3 .tr-ic{filter:none;opacity:1;background:linear-gradient(135deg,#B9F2FF,#6CA8FF 50%,#B58CFF);box-shadow:0 0 26px rgba(150,190,255,.5)}
.tr-card.tier3{border-color:rgba(150,190,255,.45)}
.tr-body{display:grid;gap:4px;min-width:0}.tr-body b{font:800 16px var(--display)}
.tr-steps{display:flex;gap:4px}.tr-steps i{font-style:normal;font-size:14px;filter:grayscale(1);opacity:.3}.tr-steps i.on{filter:none;opacity:1}
.tr-v{font-size:11.5px;color:var(--muted)}

.nav{gap:clamp(10px,1.6vw,26px)}
.navl .tab{padding:7px 10px;font-size:13.5px}
.ringsel{max-width:220px}
@media (max-width:1680px){ .rs-t{display:none} .ringsel{padding:4px 10px 4px 4px} }
@media (max-width:1300px){ .navl .tab{padding:7px 7px;font-size:12.5px} .brand span{display:none} }
.in-card .poster,.in-card .noposter{width:min(100%,calc(44vh*2/3));justify-self:center}
.in-card .poster.sq,.in-card .noposter.sq{width:min(100%,44vh)}

.tr-rings{display:flex;gap:8px;overflow-x:auto;padding:2px 2px 12px;margin-bottom:10px;scrollbar-width:thin}
.tr-ring{flex:none;display:flex;align-items:center;gap:10px;padding:6px 14px 6px 6px;border-radius:999px;border:1px solid var(--line2);background:rgba(255,255,255,.02);color:var(--text);text-align:left}
.tr-ring b{display:block;font-size:13px;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tr-ring small{font-size:11px;color:var(--muted)}
.tr-ring.on{border-color:var(--gold);background:color-mix(in srgb,var(--acc) 10%,transparent)}

/* roulette verticale */
.rl-wrap{display:grid;justify-items:center;gap:16px}
.rl-reel{position:relative;width:min(300px,80vw);height:min(62vh,640px);overflow:hidden;border-radius:22px;border:1px solid var(--line2);background:linear-gradient(180deg,#0B0A0E,#15131A 50%,#0B0A0E);box-shadow:inset 0 0 60px rgba(0,0,0,.8),0 30px 70px -30px rgba(0,0,0,.9)}
.rl-strip{position:absolute;left:0;right:0;top:0;will-change:transform}
.rl-it{height:214px;display:grid;justify-items:center;align-content:center;gap:6px;padding:8px 0}
.rl-it img,.rl-it .noposter{width:118px;height:177px;object-fit:cover;border-radius:10px;box-shadow:0 10px 24px -8px rgba(0,0,0,.9);font-size:12px}
.rl-it span{font-size:12.5px;font-weight:700;max-width:92%;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text)}
.rl-it.win img,.rl-it.win .noposter{box-shadow:0 0 0 3px var(--gold),0 0 40px color-mix(in srgb,var(--acc) 60%,transparent);transform:scale(1.06);transition:transform .3s}
.rl-mark{position:absolute;left:0;right:0;top:50%;height:214px;transform:translateY(-50%);border-top:2px solid var(--gold);border-bottom:2px solid var(--gold);background:color-mix(in srgb,var(--acc) 7%,transparent);z-index:2;pointer-events:none}
.rl-mark::before,.rl-mark::after{content:"";position:absolute;top:50%;transform:translateY(-50%);border:12px solid transparent}
.rl-mark::before{left:-2px;border-left:16px solid var(--gold)}
.rl-mark::after{right:-2px;border-right:16px solid var(--gold)}
.rl-fade{position:absolute;left:0;right:0;height:26%;z-index:3;pointer-events:none}
.rl-fade.top{top:0;background:linear-gradient(180deg,#0B0A0E,rgba(11,10,14,0))}
.rl-fade.bot{bottom:0;background:linear-gradient(0deg,#0B0A0E,rgba(11,10,14,0))}
.rl-go{padding:14px 34px;font-size:16px}
.rl-edit{display:grid;gap:12px}
.rl-cols{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px}
.rl-res{display:grid;gap:4px;margin-top:10px;max-height:56vh;overflow:auto}
.rl-row{display:grid;grid-template-columns:34px minmax(0,1fr) auto;gap:10px;align-items:center;padding:6px 8px;border-radius:10px;border:1px solid transparent;background:none;color:var(--text);text-align:left}
.rl-row:hover{background:rgba(255,255,255,.04)}
.rl-row img,.rl-row i{width:34px;height:50px;object-fit:cover;border-radius:4px;background:var(--panel2)}
.rl-row b{display:block;font-size:13.5px}.rl-row small{font-size:11.5px;color:var(--muted)}
.rl-row em{font-style:normal;font-weight:800;color:var(--gold)}
.rl-row.in{border-color:var(--gold);background:color-mix(in srgb,var(--acc) 8%,transparent)}
.rl-mine{display:flex;flex-wrap:wrap;gap:8px}
.rl-chip{display:flex;align-items:center;gap:8px;padding:4px 6px 4px 4px;border-radius:999px;border:1px solid var(--line2);background:rgba(255,255,255,.03)}
.rl-chip img{width:26px;height:38px;object-fit:cover;border-radius:4px}
.rl-chip span{font-size:13px;font-weight:700;max-width:180px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rl-chip button{border:0;background:none;color:var(--muted);font-size:14px;cursor:pointer}
@media (max-width:900px){.rl-cols{grid-template-columns:1fr}}
/* v15 : scène culte, musique du film */
.gs-ic{width:min(880px,100%);aspect-ratio:16/9;overflow:hidden;border-radius:16px;box-shadow:0 0 0 1px var(--line2),0 30px 70px -30px rgba(0,0,0,.9);background:var(--panel2)}
.gs-main.gs-ic img{width:100%;height:100%;aspect-ratio:auto;border-radius:0;box-shadow:none;animation:none;transition:transform .6s cubic-bezier(.2,.8,.2,1)}
.gsongline{margin:8px 0 0;font-size:15px;color:var(--acc)}
.gsonghint{margin:10px auto 0;padding:10px 16px;border-radius:12px;background:color-mix(in srgb,var(--acc) 14%,transparent);border:1px solid color-mix(in srgb,var(--acc) 40%,transparent);text-align:center;max-width:520px}
/* v17 : Le Chemin */
.pt-goal{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);gap:18px;align-items:center;max-width:820px;margin:6px auto 18px}
.pt-goal>.pt-node:first-child{justify-self:end}.pt-goal>.pt-node:last-child{justify-self:start}
.pt-goalmid{display:grid;justify-items:center;text-align:center;gap:4px}.pt-goalmid b{font-size:18px}
.pt-node{display:grid;justify-items:center;gap:6px;text-align:center;width:110px}
.pt-node span{font-size:13px;font-weight:700;line-height:1.2;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.pt-node .th,.pt-node .noposter{width:78px;aspect-ratio:2/3;border-radius:8px;object-fit:cover;box-shadow:0 0 0 1px var(--line2)}
.pt-face{width:78px;height:78px;border-radius:50%;object-fit:cover;object-position:50% 20%;box-shadow:0 0 0 2px var(--line2);background:var(--panel2)}
.pt-face.noface{display:grid;place-items:center;font-style:normal;font-weight:800;font-size:22px;color:var(--muted)}
.pt-node.target .th,.pt-node.target .pt-face{box-shadow:0 0 0 3px var(--acc),0 0 30px color-mix(in srgb,var(--acc) 45%,transparent)}
.pt-node.cur .th,.pt-node.cur .pt-face{box-shadow:0 0 0 3px var(--acc2,var(--acc))}
.pt-chain{display:flex;align-items:center;gap:6px;overflow-x:auto;padding:10px 4px 14px;justify-content:safe center;max-width:100%}
.pt-chain .pt-node{flex:0 0 auto;width:92px}.pt-chain .pt-node .th,.pt-chain .pt-face{width:64px}.pt-chain .pt-face{height:64px}
.pt-link{font-style:normal;color:var(--acc);font-weight:800;flex:0 0 auto}
.pt-ask{text-align:center;font-size:18px;margin:6px 0 12px}
.pt-cast{display:grid;grid-template-columns:repeat(auto-fill,minmax(104px,1fr));gap:10px;max-width:980px;margin:0 auto}
.pt-act,.pt-f{display:grid;justify-items:center;gap:6px;padding:10px 6px;border-radius:14px;border:1px solid var(--line2);background:var(--panel);color:inherit;cursor:pointer;font:inherit;font-size:13px;font-weight:600;transition:transform .15s,border-color .15s}
.pt-act:hover,.pt-f:hover{transform:translateY(-2px);border-color:var(--acc)}
.pt-act .pt-face{width:68px;height:68px}
.pt-films{display:flex;flex-wrap:wrap;gap:10px;justify-content:center;margin-top:12px}.pt-f{width:108px}.pt-f .th{width:70px;aspect-ratio:2/3;border-radius:6px;object-fit:cover}
.pt-msg{text-align:center;color:#ff7a7a;margin:8px 0}
.pt-over{text-align:center;margin-top:8px}.pt-over h2{margin:0 0 4px}
#pthint{display:block;width:auto;margin:12px auto 0}
@media (max-width:700px){.pt-goal{grid-template-columns:1fr 1fr}.pt-goalmid{grid-column:1/-1;order:-1}}
/* v18 : carte, toile, soirée quiz, AniList */
.map-wrap,.web-wrap{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:16px;align-items:start}
@media (max-width:1100px){.map-wrap,.web-wrap{grid-template-columns:minmax(0,1fr)}}
.map-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px}.map-head h3{margin:0}
.wmap{width:100%;height:auto;display:block}
.wmap path{fill:color-mix(in srgb,var(--text) 7%,transparent);stroke:var(--bg,#0b0b0f);stroke-width:.5;cursor:pointer;transition:fill .2s}
.wmap path.has{fill:color-mix(in srgb,var(--acc) calc(var(--o) * 100%),color-mix(in srgb,var(--text) 7%,transparent))}
.wmap path:hover{fill:color-mix(in srgb,var(--acc) 55%,#fff 10%)}
.wmap path.sel{stroke:var(--text);stroke-width:1.4}
.map-leg{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--muted);margin-top:8px}
.map-leg i{flex:0 0 160px;height:8px;border-radius:4px;background:linear-gradient(90deg,color-mix(in srgb,var(--acc) 18%,transparent),var(--acc))}
.map-side,.web-side{display:grid;gap:16px}
.map-row{width:100%;background:none;border:0;color:inherit;font:inherit;cursor:pointer;text-align:left;padding:0}
.map-films{display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:10px;max-height:420px;overflow:auto}
.map-f{display:grid;gap:4px;background:none;border:0;color:inherit;font:inherit;font-size:12px;font-weight:600;cursor:pointer;text-align:left;padding:0}
.map-f .th,.map-f .noposter{width:100%;aspect-ratio:2/3;border-radius:8px;object-fit:cover}
.map-f small{display:block;color:var(--muted);font-weight:500}
.map-sug{display:flex;flex-wrap:wrap;gap:6px}
.chip{border:1px solid var(--line2);background:var(--panel2);color:inherit;border-radius:999px;padding:6px 12px;font:inherit;font-size:13px;cursor:pointer}.chip:hover{border-color:var(--acc)}
.webc{width:100%;height:min(62vh,680px);display:block;border-radius:12px;background:radial-gradient(circle at 50% 50%,color-mix(in srgb,var(--acc) 6%,transparent),transparent 70%);cursor:grab;touch-action:none}
.web-who{display:flex;gap:12px;align-items:center;margin-bottom:10px}.web-who h3{margin:0}
.input.sm{padding:7px 12px;font-size:13px}
.partybar{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:10px 16px;margin:0 0 12px;border-radius:14px;background:color-mix(in srgb,var(--acc) 12%,var(--panel));border:1px solid color-mix(in srgb,var(--acc) 40%,transparent)}
.pb-turn{font-size:18px}.pb-turn small{display:block;font-size:12px;color:var(--muted)}
.pb-sc{display:flex;gap:8px;flex-wrap:wrap}.pb-sc span{padding:5px 10px;border-radius:999px;background:var(--panel2);font-size:13px}.pb-sc span.on{outline:2px solid var(--acc)}
.party-setup{max-width:900px;margin:0 auto;display:grid;gap:14px}.party-setup .sech{display:flex;justify-content:space-between;align-items:center}
.party-pl{display:grid;gap:8px;margin-bottom:10px}.pnum{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;background:var(--acc);color:#111;font-weight:800;flex:0 0 auto}
.party-setup .mode.on{outline:2px solid var(--acc)}
.party-end{text-align:center;display:grid;gap:14px;justify-items:center;padding:30px 0}
.party-end .podium{display:flex;gap:12px;flex-wrap:wrap;justify-content:center;align-items:stretch}.party-end .pod{display:grid;gap:4px;min-width:130px;padding:16px;border-radius:16px;background:var(--panel);border:1px solid var(--line2)}.party-end .pod em{font-style:normal;font-size:30px}.party-end .pod.p0{border-color:var(--acc);transform:scale(1.08)}
.alist{margin:14px 0;padding:12px 14px;border-radius:12px;border:1px solid var(--line2);background:var(--panel2)}
#partygo{margin-left:auto}
.party-setup #pgo{justify-self:center;padding-inline:44px}
/* =====================================================================
   v19 : corrections de mise en page + finitions
   ===================================================================== */
/* .row servait à la fois aux lignes du classement et aux rangées de boutons */
.bill-txt .row,.tn-in .row,.hero .row{display:flex;flex-wrap:wrap;gap:10px;grid-template-columns:none;width:auto;padding:0;border-radius:0;background:none!important;cursor:auto;content-visibility:visible}
.bill-txt .row .btn{flex:none}
/* podium du classement */
.podium{max-width:760px;margin-left:auto;margin-right:auto}
.pod{transition:border-color .2s,transform .2s}
.pod.p1{border-color:color-mix(in srgb,var(--acc) 45%,transparent);background:radial-gradient(ellipse 90% 60% at 50% 0%,color-mix(in srgb,var(--acc) 14%,transparent),transparent 70%),var(--panel)}
.pod .t{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;text-wrap:balance}
/* duel : les boutons restent visibles sans défiler */
.card .art{width:min(100%, calc(clamp(240px, 100vh - 440px, 600px) * 2 / 3))}
@media (min-width:1500px){ .card .art{width:min(100%, calc(clamp(240px, 100vh - 430px, 640px) * 2 / 3))} }
.actbar{margin-top:14px}
.card:focus-visible{outline:none}
.card:focus-visible .art{box-shadow:0 0 0 2px var(--gold),0 30px 60px -24px rgba(0,0,0,.95)}
/* notifications : en haut, animées, ne cachent plus les boutons */
.toast{top:calc(var(--navh) + 10px);bottom:auto!important;display:flex;align-items:center;gap:10px;padding:11px 20px;animation:toastin .28s cubic-bezier(.2,1.2,.4,1)}
.toast::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--gold);flex:none;box-shadow:0 0 10px var(--gold)}
@keyframes toastin{from{opacity:0;transform:translate(-50%,-10px) scale(.96)}}
/* barre de navigation : soulignement de l’onglet actif */
.navl .tab{position:relative;transition:color .15s,background .15s}
.navl .tab[aria-selected="true"]::after{content:"";position:absolute;left:30%;right:30%;bottom:-3px;height:2px;border-radius:2px;background:var(--goldgrad)}
/* menu « Plus » (mobile) */
.gmodes .mode.hot{border-color:color-mix(in srgb,var(--acc) 55%,transparent);background:radial-gradient(ellipse 80% 70% at 0% 0%,color-mix(in srgb,var(--acc) 16%,transparent),transparent 70%),var(--panel)}
.gmodes .mode.hot strong::after{content:"Nouveau";margin-left:8px;vertical-align:middle;font:800 9.5px var(--body);letter-spacing:.14em;text-transform:uppercase;padding:3px 8px;border-radius:999px;background:var(--goldgrad);color:#1A1308}
.gsrc{color:var(--gold2);letter-spacing:.12em}
/* vidéos des jeux : on recadre pour cacher le titre YouTube en haut et le logo / la barre en bas */
.gclip.vis iframe{transform:scale(1.3);transform-origin:50% 50%}
.gclip.vis::after{height:9%!important}
.gclip.vis::before{content:"";position:absolute;left:0;right:0;bottom:0;height:11%;background:#000;z-index:2;pointer-events:none}
.gclip.vis.revealed::after{display:block!important}
.gladder{display:inline-flex;gap:3px;vertical-align:middle}
.gladder i{font-style:normal;padding:2px 8px;border-radius:999px;font-weight:800;letter-spacing:.08em;font-size:9.5px;color:var(--faint);border:1px solid var(--line2);opacity:.75}
.gladder i.done{opacity:.45;text-decoration:line-through}
.gladder i.on{opacity:1;color:#111;border-color:transparent;box-shadow:0 0 14px rgba(255,255,255,.12)}
.gladder i.on.d-easy{background:#79C495}.gladder i.on.d-medium{background:#E8C46A}.gladder i.on.d-hard{background:#F08A4B}.gladder i.on.d-expert{background:#E5484D;color:#fff}.gladder i.on.d-impossible{background:#8E5BE8;color:#fff}
.gloop{color:var(--gold2);font-weight:800}
.stagehead .gladder{gap:5px}.stagehead .gladder i{font-size:11.5px;padding:5px 13px;letter-spacing:.1em}
.stagehead .gloop{font-size:12.5px;letter-spacing:.08em}
.gnextlvl{margin:-4px 0 0;text-align:center;font-size:15px;font-weight:600}
.gnextlvl .gdiffb{font-size:12px}
@media (max-width:640px){.gladder i{padding:2px 5px;font-size:8.5px}}
.gdiffb{padding:2px 9px;border-radius:999px;font-weight:800;letter-spacing:.12em;color:#111}
.gdiffb.d-easy{background:#79C495}.gdiffb.d-medium{background:#E8C46A}.gdiffb.d-hard{background:#F08A4B}.gdiffb.d-expert{background:#E5484D;color:#fff}.gdiffb.d-impossible{background:#8E5BE8;color:#fff}
#gdiff button[data-v="easy"][aria-pressed="true"],#mpdiff button[data-v="easy"][aria-pressed="true"]{background:#79C495;color:#111}
#gdiff button[data-v="medium"][aria-pressed="true"],#mpdiff button[data-v="medium"][aria-pressed="true"]{background:#E8C46A;color:#111}
#gdiff button[data-v="hard"][aria-pressed="true"],#mpdiff button[data-v="hard"][aria-pressed="true"]{background:#F08A4B;color:#111}
#gdiff button[data-v="expert"][aria-pressed="true"],#mpdiff button[data-v="expert"][aria-pressed="true"]{background:#E5484D;color:#fff}
#gdiff button[data-v="impossible"][aria-pressed="true"],#mpdiff button[data-v="impossible"][aria-pressed="true"]{background:#8E5BE8;color:#fff}
/* multijoueur */
.mp-menu,.mp-lobby,.mp-end{max-width:900px;margin:0 auto;display:grid;gap:16px}
.mp-menu h2,.mp-end h2{margin:0;font:900 clamp(34px,5vw,60px)/1 var(--display);font-stretch:112%;text-transform:uppercase}
.mp-menu .kicker,.mp-end .kicker{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--gold)}
.mp-end{text-align:center;justify-items:center}
.mp-f{display:grid;gap:6px;max-width:360px}.mp-f span{font-size:12px;color:var(--muted);font-weight:600}
.mp-cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(300px,100%),1fr));gap:14px}
.mp-cols .panel{display:grid;gap:10px;align-content:start}
.mp-code{text-transform:uppercase;letter-spacing:.3em;font-weight:800;text-align:center;max-width:180px}
.mp-codebox{display:grid;justify-items:center;gap:6px;padding:22px;border-radius:22px;border:1px dashed var(--gold);background:color-mix(in srgb,var(--acc) 8%,transparent)}
.mp-codebox span{font:700 11px var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--muted)}
.mp-codebox b{font:900 clamp(44px,8vw,80px)/1 var(--display);letter-spacing:.18em;background:var(--goldgrad);-webkit-background-clip:text;background-clip:text;color:transparent}
.mp-board{display:grid;gap:6px;width:100%;text-align:left}
.mp-board.final{max-width:520px}
.mp-pl{display:grid;grid-template-columns:34px minmax(0,1fr) auto auto;gap:10px;align-items:center;padding:9px 12px;border-radius:12px;background:rgba(255,255,255,.03);border:1px solid var(--line)}
.mp-pl b{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.mp-pl b small{font-size:10px;color:var(--muted);font-weight:600;margin-left:4px}
.mp-pl.me{border-color:var(--gold)}
.mp-pl.ok{background:rgba(121,196,149,.12);border-color:rgba(121,196,149,.5)}
.mp-rk{font:900 18px var(--display);color:var(--gold);text-align:center}
.mp-st{font-size:12px;font-weight:700;color:var(--muted)}.mp-pl.ok .mp-st{color:#7FD99A}
.mp-pl em{font-style:normal;font:900 18px var(--display);font-variant-numeric:tabular-nums}
.mp-board.final .mp-pl{padding:14px 16px;font-size:17px}.mp-board.final .mp-pl:first-child{border-color:var(--gold);box-shadow:0 0 30px color-mix(in srgb,var(--acc) 30%,transparent)}
.mp-game{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:20px;align-items:start;max-width:1200px;margin:0 auto;width:100%}
.mp-main{display:grid;gap:14px;justify-items:center}
.mp-main .gclip{width:min(760px,100%)}
.mp-timer{font:900 34px var(--display);color:var(--gold2);font-variant-numeric:tabular-nums}
.mp-main .gguess{width:min(560px,100%);margin:0}
.mp-main .greveal{width:min(760px,100%)}
@media (max-width:1000px){.mp-game{grid-template-columns:1fr}}
.gboard.done .gclue{width:min(620px,52vw)}
.gboard.done .gclip{width:100%}
@media (max-width:900px){.gboard.done .gclue{width:100%}}
.moregrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
.moreit{display:grid;justify-items:center;gap:6px;padding:16px 6px;border-radius:14px;border:1px solid var(--line2);background:rgba(255,255,255,.025);color:var(--text);font-weight:700;font-size:13px}
.moreit .i{font-size:22px;line-height:1}
.moreit:hover,.moreit[aria-current="true"]{border-color:var(--gold);background:color-mix(in srgb,var(--acc) 9%,transparent)}
:root[data-theme="light"] .moreit{background:#fff}
/* fenêtres : apparition douce */
.modal:not([hidden]) .sheet{animation:sheetin .22s cubic-bezier(.2,1,.4,1)}
@keyframes sheetin{from{opacity:0;transform:translateY(12px) scale(.98)}}
/* listes : lignes plus lisibles */
.list .row{transition:background .12s}
.row .sc b{font-variant-numeric:tabular-nums}
/* mobile */
@media (max-width:900px){
  .bottombar{grid-template-columns:repeat(6,minmax(0,1fr));padding:6px 2px calc(6px + env(safe-area-inset-bottom,0px));background:rgba(9,9,12,.97);box-shadow:0 -10px 30px rgba(0,0,0,.4)}
  .bottombar button{font-size:10.5px;padding:5px 0;border-radius:10px;white-space:nowrap}
  .bottombar button[aria-current="true"]{background:color-mix(in srgb,var(--acc) 10%,transparent)}
  :root[data-theme="light"] .bottombar{background:rgba(243,239,231,.97);box-shadow:0 -6px 20px rgba(40,30,10,.12)}
  .toast{top:calc(var(--navh) + 6px)}
}
@media (max-width:720px){
  #keysbtn2{display:none}
  .nav{gap:10px}
  .bill{min-height:0;padding-bottom:40px}
  .bill-txt h2{font-size:clamp(38px,12vw,56px)}
  .bill-stats{gap:20px}.bill-stats b{font-size:26px}
}
/* grilles : jamais plus larges que l’écran */
.sgrid{grid-template-columns:repeat(auto-fit,minmax(min(360px,100%),1fr))}
.tr-grid{grid-template-columns:repeat(auto-fill,minmax(min(290px,100%),1fr))}
.rc-grid{grid-template-columns:repeat(auto-fit,minmax(min(300px,100%),1fr))}
.honors{grid-template-columns:repeat(auto-fit,minmax(min(260px,100%),1fr))}
.keygrid{grid-template-columns:repeat(auto-fit,minmax(min(250px,100%),1fr))}
.cgrid{grid-template-columns:repeat(auto-fill,minmax(min(250px,100%),1fr))}
@media (max-width:640px){
  .scards{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
  .scard{padding:14px}.scard b{font-size:26px}
  .tr-hero{padding:20px}.tr-hero h2{font-size:40px}
  .vs{display:flex!important;align-items:center;gap:12px;font-size:30px!important;margin:-4px 0}
  .vs::before,.vs::after{width:44px;height:1px;background:linear-gradient(90deg,transparent,color-mix(in srgb,var(--acc) 60%,transparent),transparent)}
  .card .art{width:100%}
  .ctitle{font-size:15px}
  .stage:not(.game){padding:18px var(--padx) 22px}
  .stagehead{margin-bottom:10px}
  .stagehead>.fx{justify-content:flex-start!important;width:100%}
  .khint{display:none}
  .moregrid{grid-template-columns:repeat(2,minmax(0,1fr))}
  .podium{gap:6px}
}
/* =====================================================================
   v20 : INTERFACE ÉPURÉE — surfaces plates, une seule couleur d'accent, typo simple
   ===================================================================== */
:root:not([data-theme="light"]){--bg:#0F1013;--bg2:#131418;--panel:#17181C;--panel2:#1E1F24;--panel3:#26282E;--line:rgba(255,255,255,.07);--line2:rgba(255,255,255,.12);--text:#ECEDEF;--muted:#9A9FA8;--faint:#666B74}
:root{--gold:var(--acc);--gold2:var(--acc);--goldgrad:linear-gradient(var(--acc),var(--acc));--display:"Inter","Segoe UI",system-ui,sans-serif;--r:14px;--navh:60px;--onacc:#16120A}
:root[data-accent="red"],:root[data-accent="blue"]{--onacc:#fff}
:root[data-theme="light"]{--gold:color-mix(in srgb,var(--acc) 82%,#000);--gold2:color-mix(in srgb,var(--acc) 82%,#000)}
html body{background:var(--bg)!important;font-size:14.5px;letter-spacing:0}
body::before{display:none!important}
::selection{background:color-mix(in srgb,var(--acc) 35%,transparent)}
:focus-visible{outline:2px solid var(--acc)!important;outline-offset:2px}

/* typo : fini les majuscules étirées */
body h1,body h2,body h3,body h4,body .ttl h1,body .sech h2,body .sheet h2,body .mode strong,body .gres,body .champ h2,body .hl-intro h2,body .hl-over h2,body .tn-intro h2,body .tn-in h2,body .rc-hero h2,body .tr-hero h2,body .mp-menu h2,body .mp-end h2,body .ch-over h2,body .ctitle,body .pod .n,body .row .rk,body .noposter,body .gcard h3,body .gsteps b,body .stamp,body .big,body .hl-t,body .hl-val,body .ch-y,body .tlab,body .scard b,body .sw-stats b,body .tr-medals b,body .mp-rk,body .mp-pl em,body .mp-timer,body .gquote blockquote,body .gactor b,body .rcard h4,body .dvs,body .bvs,body .cring b{font-family:var(--display)!important;text-transform:none!important;font-stretch:100%!important;font-style:normal!important;letter-spacing:-.015em!important}
body .ttl h1{font-size:24px!important;font-weight:700!important}
body .sech h2,body .sheet h2{font-size:20px!important;font-weight:700!important}
body .mode strong{font-size:16px!important;font-weight:700!important;line-height:1.25}
body .gres{font-size:22px!important;font-weight:700!important}
body .hl-intro h2,body .hl-over h2,body .tn-intro h2,body .mp-menu h2,body .mp-end h2,body .ch-over h2,body .rc-hero h2,body .tr-hero h2{font-size:clamp(26px,3.4vw,36px)!important;font-weight:750!important}
body .champ h2,body .tn-in h2{font-size:clamp(26px,3.6vw,38px)!important;font-weight:750!important;background:none!important;-webkit-text-fill-color:currentColor;color:var(--text)!important}
body .kicker,body .ttl .kicker,body .round,body .slabel,body .panel h3,body .h3,body .bh,body .rc-type,body .ccard .type,body .tn-intro .kicker,body .hl-intro .kicker,body .mp-menu .kicker,body .mp-end .kicker,body .rc-hero .kicker,body .tr-hero .kicker,body .compat .kicker,body .hl-lab,body .gquote cite,body .mp-codebox span{letter-spacing:.01em!important;text-transform:none!important;font-size:12.5px!important;font-weight:600!important;color:var(--muted)!important;font-family:var(--body)!important}
body .round b{color:var(--text)!important}
body .panel h3{font-size:13px!important;color:var(--text)!important;margin-bottom:10px}
body kbd{font:600 10px var(--body);background:var(--panel3);border:1px solid var(--line2);border-radius:4px;color:var(--muted)}
.btn kbd,.chip kbd,.tab kbd,.fxbtn kbd,.khint,.gsubnote{display:none!important}

/* barre du haut */
.top,.top.solid,:root[data-theme="light"] .top,:root[data-theme="light"] .top.solid{background:var(--bg)!important;border-bottom:1px solid var(--line)!important;box-shadow:none!important}
.nav{height:var(--navh);gap:28px}
.brand{font:800 19px var(--display)!important;letter-spacing:-.02em!important;background:none!important;color:var(--text)!important;-webkit-text-fill-color:currentColor!important;font-stretch:100%!important}
.brand span{display:none!important}
.navl{gap:4px}
.navl .tab{font:500 14px var(--body)!important;color:var(--muted)!important;background:none!important;box-shadow:none!important;padding:8px 12px!important;border-radius:8px!important;letter-spacing:0!important}
.navl .tab:hover{color:var(--text)!important;background:var(--panel2)!important}
.navl .tab[aria-selected="true"]{color:var(--text)!important;font-weight:600!important;background:var(--panel2)!important}
.navl .tab[aria-selected="true"]::after{display:none}
.ringsel,.icon-btn{background:transparent!important;border:1px solid var(--line2)!important}
.ringsel{padding:3px 12px 3px 3px;border-radius:10px}.rs-ico{border-radius:7px}
.icon-btn{width:36px;height:36px;border-radius:10px}
.ringsel:hover,.icon-btn:hover{border-color:var(--muted)!important;color:var(--text)!important}
.rs-t small{color:var(--muted)!important;letter-spacing:.02em;text-transform:none;font-weight:500}
.subbar{padding:22px var(--padx) 4px;align-items:flex-end}
.ttl .kicker{display:none}
.pills{gap:16px}
.pill{background:none!important;border:0!important;padding:0!important;font:500 13px var(--body)!important;color:var(--muted)!important;letter-spacing:0!important}
.pill b{color:var(--text)!important;font-weight:650}
#view{padding:22px var(--padx) 80px}

/* boutons, champs, puces */
body .btn{border-radius:10px;background:var(--panel2);border:1px solid var(--line2);box-shadow:none!important;font-weight:600;letter-spacing:0;padding:9px 16px;filter:none;transition:background .15s,border-color .15s}
body .btn:hover{background:var(--panel3);border-color:var(--line2)}
body .btn.sm{padding:6px 12px;border-radius:8px}
body .btn.primary,:root[data-theme="light"] body .btn.primary{background:var(--acc)!important;color:var(--onacc)!important;border-color:transparent!important}
body .btn.primary:hover{filter:brightness(1.08)}
body .btn.ghost,:root[data-theme="light"] body .btn.ghost{background:transparent;border-color:transparent}
body .btn.ghost:hover{background:var(--panel2)}
body .btn.danger{color:#FF7A82}
body .lnk{color:var(--muted);text-decoration:none;font-weight:600}
body .lnk:hover{color:var(--text)}
body .chip,:root[data-theme="light"] body .chip{border-radius:8px;background:transparent;border:1px solid var(--line2);color:var(--muted);font-weight:600;padding:5px 11px;box-shadow:none!important}
body .chip:hover{color:var(--text)}
body .chip[aria-pressed="true"]{background:var(--text)!important;color:var(--bg)!important;border-color:var(--text)!important}
body .seg{background:var(--panel2);border:0;border-radius:10px;padding:3px}
body .seg button{border-radius:7px;font-weight:600;color:var(--muted)}
body .seg button[aria-pressed="true"]{background:var(--panel3);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.3)}
:root[data-theme="light"] body .seg button[aria-pressed="true"]{background:#fff}
body .input,body select{background:var(--panel)!important;border:1px solid var(--line2);border-radius:10px;box-shadow:none}
body .input:focus,body select:focus{border-color:var(--acc);box-shadow:none}
body .ptabs button{border-radius:8px;background:transparent;border:1px solid var(--line2);color:var(--muted)}
body .ptabs button[aria-selected="true"]{background:var(--panel2);color:var(--text);border-color:var(--line2)}

/* surfaces plates */
body .panel,body .ccard,body .mode,body .pod,body .sheet,body .scard,body .tr-card,body .tr-hero,body .rc-hero,body .greveal,body .mp-codebox,body .mp-pl,body .gplot,body .gquote blockquote,body .gactor,body .in-card,body .dcard,body .fxpanel,body .trow,body .hist,body .partybar,body .alist{background:var(--panel)!important;border:1px solid var(--line)!important;box-shadow:none!important;border-radius:14px}
body .mode:hover,body .ccard:hover,body .in-card:hover:not([disabled]){transform:none!important;border-color:var(--line2)!important;box-shadow:none!important}
body .mode em{font-size:12.5px!important;letter-spacing:0!important;text-transform:none!important;font-weight:600!important;color:var(--muted)!important}
body .gmodes .mode em{font-size:20px!important}
body .mode span{font-size:13px;line-height:1.45;color:var(--muted)}
body .gmodes .mode{padding:16px;gap:6px}
body .gmodes .mode.hot{border-color:color-mix(in srgb,var(--acc) 50%,transparent)!important;background:var(--panel)!important}
body .gmodes .mode.hot strong::after{background:var(--acc);color:var(--onacc);letter-spacing:.06em}
body .gst{color:var(--muted)!important;font-weight:600;letter-spacing:0}
body .sheet{border-radius:16px;border-color:var(--line2)!important}
.modal{background:rgba(0,0,0,.6)!important}
.toast{background:var(--panel3)!important;color:var(--text)!important;border:1px solid var(--line2)!important;border-radius:10px!important;box-shadow:0 10px 30px rgba(0,0,0,.35)!important}
.toast::before{display:none}
body .result{border-radius:10px}
body .bar{height:4px}
body .bar i{background:var(--acc)}
.confetti{display:none}

/* duel */
.stage-bg,.stage::before,.stage::after{display:none!important}
.stage:not(.game){background:transparent!important;border:0!important;box-shadow:none!important;padding:6px 0 0!important;margin:0!important;border-radius:0!important}
.stagehead{margin-bottom:18px}
.stagehead select{max-width:220px}
.arena{max-width:900px!important;gap:clamp(16px,4vw,56px)}
.card .art{transform:none!important;border-radius:12px!important;box-shadow:0 10px 30px -14px rgba(0,0,0,.7)!important;transition:box-shadow .15s!important}
.card .art::after,.pick,.corner{display:none!important}
.card:hover .art,.card.l:hover .art,.card.r:hover .art{box-shadow:0 0 0 2px var(--acc),0 10px 30px -14px rgba(0,0,0,.7)!important}
.card.win .art,.card.l.win .art,.card.r.win .art{box-shadow:0 0 0 3px var(--acc)!important;animation:none!important}
.card.ko{opacity:.4}
.card.ko .art{animation:none!important}
.stamp{display:none!important}
.rankb{background:rgba(0,0,0,.6)!important;border:0!important;color:#fff!important;font:600 10.5px var(--body)!important;letter-spacing:0!important;border-radius:6px!important}
.vs{font:600 14px var(--body)!important;color:var(--faint)!important;background:none!important;-webkit-text-fill-color:currentColor!important;-webkit-background-clip:border-box!important;background-clip:border-box!important;text-transform:lowercase;letter-spacing:.04em!important;font-style:normal!important}
.vs::before,.vs::after{display:none!important}
body .ctitle{font-size:16.5px!important;font-weight:650!important;line-height:1.25}
.card .cmeta{font-size:13px;color:var(--muted)}
.badge{color:var(--faint)!important;letter-spacing:0!important;font-weight:500!important}
.badge b{color:var(--muted)!important}
.actbar{display:flex!important;justify-content:center;gap:6px;margin-top:18px}
.actbar .choose{display:none!important}
.actbar .btn{background:transparent;border-color:transparent;color:var(--muted);padding:8px 14px}
.actbar .btn:hover{background:var(--panel2);color:var(--text)}
.below{margin-top:34px}
.fight:nth-child(odd),.row:nth-child(4n+1),.path div:nth-child(odd),.crow:nth-child(odd){background:transparent!important}
.fight{border-bottom:1px solid var(--line);border-radius:0}

/* classement */
.podium{gap:12px}
body .pod{padding:16px}
body .pod.p1{background:var(--panel)!important;border-color:color-mix(in srgb,var(--acc) 45%,transparent)!important}
body .pod .n{font-size:22px!important;font-weight:700!important;background:none!important;-webkit-text-fill-color:currentColor;color:var(--muted)!important}
body .pod.p1 .n{color:var(--acc)!important}
body .pod.p1 .poster,body .pod.p1 .noposter{box-shadow:none!important}
.list{gap:0}
.list .row{border-bottom:1px solid var(--line);border-radius:0;padding:9px 6px}
.list .row:hover{background:var(--panel)!important}
body .row .rk{font-size:15px!important;font-weight:650!important;color:var(--muted)!important}
.detail{background:var(--panel)!important;border:1px solid var(--line)}
.tools{gap:8px;margin-bottom:20px}

/* jeux */
.stage.game.full,:root[data-theme="light"] .stage.game.full{background:var(--bg)!important}
.gsteps span,.gsteps .cur,.gsteps .past{border-radius:10px;box-shadow:none!important;background:var(--panel)!important}
.gsteps .cur{border-color:var(--acc)!important;color:var(--text)!important}
.gsteps .past{opacity:.5}
body .gsteps b{font-size:15px!important;font-weight:700!important}
.gclip,.gcrop,.gplot{box-shadow:0 0 0 1px var(--line2)!important}
.gmask,:root[data-theme="light"] .gmask{background:var(--panel2)!important}
.gprog i{background:var(--acc)!important}
.gguess .input{border-radius:12px!important}
.gsug{border-radius:12px!important;background:var(--panel)!important}
body .greveal.ok{border-color:color-mix(in srgb,var(--acc) 50%,transparent)!important}
body .greveal.ok .gres b{color:var(--acc)!important}
.wh-center{box-shadow:none!important}
.gladder i.on{box-shadow:none}

/* stats, trophées, tier list */
body .scard b{font-size:26px!important;font-weight:750!important}
.sbar i{background:var(--acc)!important}
body .tr-card .tr-ic{border-radius:12px}
body .tr-hero h2{font-size:30px!important}
body .tlab{font-weight:800!important;font-size:28px!important}

/* accueil épuré */
.hm{display:grid;gap:40px;max-width:1200px}
.hm-hero{display:grid;gap:8px;padding:28px 0 4px}
.hm-k{font-size:13px;font-weight:600;color:var(--muted)}
.hm-hero h1{margin:0;font:750 clamp(30px,4.5vw,46px)/1.05 var(--display);letter-spacing:-.025em}
.hm-meta{margin:0;color:var(--muted);font-size:15px}
.hm-acts{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.hm-acts .btn{padding:11px 20px;font-size:14.5px}
.hm-sec{display:grid;gap:14px}
.hm-head{display:flex;align-items:baseline;justify-content:space-between;gap:12px}
.hm-head h2{margin:0;font:700 18px var(--display);letter-spacing:-.01em}
.hm-top{display:grid;grid-auto-flow:column;grid-auto-columns:clamp(110px,11vw,150px);gap:14px;overflow-x:auto;padding-bottom:6px;scrollbar-width:thin}
.hm-t{display:grid;gap:8px;background:none;border:0;padding:0;text-align:left;color:var(--text)}
.hm-t img,.hm-t .noposter{width:100%;aspect-ratio:2/3;object-fit:cover;border-radius:10px;font-size:11px;transition:opacity .15s}
.hm-t img.sq,.hm-t .noposter.sq{aspect-ratio:1}
.hm-t:hover img{opacity:.85}
.hm-t span{font-size:13px;font-weight:600;line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.hm-t em{font-style:normal;color:var(--muted);margin-right:6px}
.hm-rings{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(280px,100%),1fr));gap:10px}
.hc-ring{display:flex;align-items:center;gap:14px;padding:12px;border-radius:14px;border:1px solid var(--line);background:var(--panel);color:var(--text);text-align:left;transition:border-color .15s}
.hc-ring:hover{border-color:var(--line2)}
.hc-ring.cur{border-color:color-mix(in srgb,var(--acc) 50%,transparent)}
.hc-art{display:flex;flex:none}
.hc-art img,.hc-art .noposter{width:36px;aspect-ratio:2/3;object-fit:cover;border-radius:6px;margin-left:-10px;box-shadow:0 0 0 2px var(--panel);font-size:0;padding:0}
.hc-art img:first-child,.hc-art .noposter:first-child{margin-left:0}
.hc-art.sq img,.hc-art.sq .noposter{aspect-ratio:1}
.hc-txt{display:grid;gap:2px;min-width:0}
.hc-txt b{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.hc-txt small{color:var(--muted);font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

/* menu Plus */
body .moreit{background:var(--panel)!important;border:1px solid var(--line)!important;border-radius:12px;font-weight:600}
body .moreit .i{font-size:18px;color:var(--muted)}
body .moreit:hover,body .moreit[aria-current="true"]{border-color:var(--acc)!important;background:var(--panel)!important}

/* mobile */
@media (max-width:900px){
  .bottombar{background:var(--bg)!important;box-shadow:none!important;border-top:1px solid var(--line)}
  .bottombar button[aria-current="true"]{background:none!important;color:var(--text)!important}
  .bottombar button .i{font-size:17px}
}
@media (max-width:720px){
  .subbar{padding-top:14px}
  .hm{gap:30px}.hm-hero{padding-top:10px}
  .stagehead select{max-width:100%;flex:1}
}
@media (max-width:640px){
  .vs{display:none!important}
  .arena{gap:12px!important}
}
/* multijoueur v2 : essais, indices, fil des essais */
.mp-side{display:grid;gap:12px;align-content:start}
.mp-bodyw{display:grid;gap:12px;justify-items:center;width:100%}
.mp-bar{display:flex;align-items:center;gap:14px}
.mp-bar .mp-timer{font-size:28px}
.mp-hints{display:flex;flex-wrap:wrap;justify-content:center;gap:6px;max-width:620px}
.mp-hints span{padding:6px 12px;border-radius:999px;background:color-mix(in srgb,var(--acc) 14%,transparent);border:1px solid color-mix(in srgb,var(--acc) 40%,transparent);font-size:13px;font-weight:600}
.mp-mine{display:grid;justify-items:center;gap:4px}
.mp-mine .gwrong{margin:0}
.mp-feed{display:grid;gap:4px;max-height:280px;overflow:auto}
.mp-feed div{font-size:13px;padding:5px 8px;border-radius:8px;background:var(--panel2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mp-feed div.ok{color:#7FD99A}
.mp-feed div.ko{color:var(--muted)}.mp-feed div.ko b{color:var(--text)}
#mpsug button{align-items:center}
#mpsug .th{width:34px;aspect-ratio:2/3;object-fit:cover;border-radius:4px;flex:none;background:var(--panel2)}
#mpsug .th.sq{aspect-ratio:1}
#mpsug span b{color:var(--acc);font-weight:800}
#mpsug .mp-tt{display:block}
.mp-noth{display:block}
.mp-nores{padding:10px 14px;font-size:13px;color:var(--muted)}
/* chat de partie */
.mp-chat{display:grid;gap:8px}
.mp-chatlist{display:grid;gap:3px;align-content:start;height:min(46vh,420px);overflow-y:auto;padding-right:4px;scrollbar-width:thin}
.mp-lobby .mp-chatlist{height:180px}
.mp-line{font-size:13px;line-height:1.4;padding:4px 8px;border-radius:8px;word-break:break-word}
.mp-line.msg{background:var(--panel2)}
.mp-line.ko .mp-miss{color:#FF8A92}
.mp-line.ok{color:#7FD99A;background:rgba(121,196,149,.08)}
.mp-line.ok em{font-style:normal;font-weight:800;margin-left:4px}
.mp-sep{font-size:11px;font-weight:700;color:var(--faint);text-align:center;margin:6px 0 2px;letter-spacing:.04em}
.mp-empty{font-size:12.5px}
.mp-chatin{display:flex;gap:6px}
.mp-chatin .input{flex:1;min-width:0}
/* multijoueur : jeux à indice image / texte */
.mp-clue{display:grid;justify-items:center;width:100%}
.mp-clue:empty{display:none}
#mpgame{flex-wrap:wrap}
/* son seul : lecteur YouTube en vraie taille, caché derrière le masque (sinon certains navigateurs coupent le son) */
.gclip:not(.vis):not(.revealed) iframe{opacity:1!important;height:auto!important;aspect-ratio:16/9;top:50%!important;bottom:auto!important;transform:translateY(-50%)}
.gclip:not(.vis):not(.revealed) .gmask{z-index:3;opacity:1!important;background:var(--panel2)!important}
.gclip.blocked .gmask{cursor:pointer;color:var(--text)}
.gclip.blocked .gmask span{font-size:15px!important;animation:none!important;padding:0 20px;text-align:center}
.gclip.blocked .gmask:hover{background:var(--panel3)!important}
/* extrait Spotify : juste une bande avec le casque */
.gclip.aud,.gclip.aud.revealed{aspect-ratio:auto!important;height:150px!important}
.gclip.aud .gmask{opacity:1!important}
.gclip.aud.playing .gmask span{animation:pulse 1s ease-in-out infinite}
/* réglage du volume dans les jeux */
.gvol{display:flex;align-items:center;gap:6px;font-size:15px;padding:4px 10px;border-radius:999px;border:1px solid var(--line2);cursor:pointer}
.gvol input{width:110px;accent-color:var(--acc);cursor:pointer}
@media (max-width:640px){.gvol input{width:70px}}
</style>
</head>
<body>
<div class="app">
  <aside class="side" id="side" aria-label="Navigation"></aside>
  <div class="main">
    <header class="top" id="top"></header>
    <main id="view"></main>
  </div>
</div>
<nav class="bottombar" id="bottombar" aria-label="Navigation"></nav>
<div class="modal" id="modal" hidden><div class="sheet" id="sheet" role="dialog" aria-modal="true"></div></div>

<script>
const FILM_DATA = [["The End of Oak Street",2026,"David Robert Mitchell",7,"992962-the-end-of-oak-street"],["The Last House",2026,"Louis Leterrier",4,"1167674-the-last-house-2026"],["Soulm8te",2026,"Kate Dolan",5,"1188518-soulm8te"],["One Night Only",2026,"Will Gluck",5,"1311677-one-night-only-2026"],["Evil Dead Burn",2026,"Sébastien Vaniček",7,"1097022-evil-dead-burn"],["Supergirl",2026,"Craig Gillespie",4,"974286-supergirl-2026"],["The Death of Robin Hood",2026,"Michael Sarnoski",7,"1167858-the-death-of-robin-hood"],["Toy Story 5",2026,"Andrew Stanton",8,"977186-toy-story-5"],["Scary Movie",2026,"Michael Tiddes",5,"1156910-scary-movie-2026"],["Disclosure Day",2026,"Steven Spielberg",7,"1159251-disclosure-day"],["Masters of the Universe",2026,"Travis Knight",5,"386613-masters-of-the-universe-2026"],["Teenage Sex and Death at Camp Miasma",2026,"Jane Schoenbrun",8,"1123867-teenage-sex-and-death-at-camp-miasma"],["Backrooms",2026,"Kane Parsons",7,"976419-backrooms-2026"],["Mortal Kombat II",2026,"Simon McQuoid",4,"836571-mortal-kombat-ii"],["Bagarre",2026,"Julien Royal",5,"1299323-bagarre"],["Michael",2026,"Antoine Fuqua",2,"841103-michael-2026"],["Lee Cronin's The Mummy",2026,"Lee Cronin",7,"1186318-lee-cronins-the-mummy"],["The Super Mario Galaxy Movie",2026,"Aaron Horvath, Michael Jelenic",4,"1110080-the-super-mario-galaxy-movie"],["They Will Kill You",2026,"Kirill Sokolov",6,"1175528-they-will-kill-you"],["The Drama",2026,"Kristoffer Borgli",8,"1205494-the-drama"],["Forbidden Fruits",2026,"Meredith Alloway",3,"1327775-forbidden-fruits-2026"],["Hokum",2026,"Damian McCarthy",6,"1308587-hokum"],["Ready or Not 2: Here I Come",2026,"Matt Bettinelli-Olpin, Tyler Gillett",4,"1150113-ready-or-not-2-here-i-come"],["Project Hail Mary",2026,"Phil Lord, Christopher Miller",8,"611288-project-hail-mary"],["Scream 7",2026,"Kevin Williamson",2,"1045381-scream-7"],["Hoppers",2026,"Daniel Chong",6,"1207557-hoppers"],["How to Make a Killing",2026,"John Patton Ford",5,"399504-how-to-make-a-killing-2026"],["Wuthering Heights",2026,"Emerald Fennell",5,"1196911-wuthering-heights-2026"],["The Invite",2026,"Olivia Wilde",6,"854831-the-invite-2026"],["I Want Your Sex",2026,"Gregg Araki",7,"1170954-i-want-your-sex"],["Alter Ego",2026,"Nicolas Charlet, Bruno Lavaine",8,"1150727-alter-ego-2026"],["Send Help",2026,"Sam Raimi",7,"1084117-send-help"],["28 Years Later: The Bone Temple",2026,"Nia DaCosta",7,"1156409-28-years-later-the-bone-temple"],["The Rip",2026,"Joe Carnahan",6,"1187446-the-rip-2026"],["The Housemaid",2025,"Paul Feig",2,"1255319-the-housemaid-2025"],["Avatar: Fire and Ash",2025,"James Cameron",8,"70007-avatar-fire-and-ash"],["Zootopia 2",2025,"Jared Bush, Byron Howard",7,"977342-zootopia-2"],["Keeper",2025,"Osgood Perkins",4,"1171017-keeper-2025"],["The Running Man",2025,"Edgar Wright",4,"716178-the-running-man-2025"],["Now You See Me: Now You Don't",2025,"Ruben Fleischer",2,"358757-now-you-see-me-now-you-dont-2025"],["Marty Supreme",2025,"Josh Safdie",8,"1197499-marty-supreme"],["Whistle",2025,"Corin Hardy",5,"1078889-whistle-2025-1"],["Good Luck, Have Fun, Don't Die",2025,"Gore Verbinski",6,"1009237-good-luck-have-fun-dont-die"],["Primate",2025,"Johannes Roberts",3,"1196086-primate-2025"],["HIM",2025,"Justin Tipping",3,"887956-him-2025"],["McWalter",2025,"Simon Astier",5,"1183016-mcwalter"],["One Battle After Another",2025,"Paul Thomas Anderson",9,"951277-one-battle-after-another"],["The Long Walk",2025,"Francis Lawrence",5,"531316-the-long-walk-2025"],["The Furious",2025,"Kenji Tanigaki",7,"1164154-the-furious"],["Nuremberg",2025,"James Vanderbilt",4,"1098782-nuremberg-2025"],["Obsession",2025,"Curry Barker",7,"1234472-obsession-2025-2"],["Wake Up Dead Man",2025,"Rian Johnson",6,"729113-wake-up-dead-man"],["Roofman",2025,"Derek Cianfrance",5,"1125033-roofman"],["Good Fortune",2025,"Aziz Ansari",4,"1005018-good-fortune-2025"],["Fuze",2025,"David Mackenzie",7,"1125032-fuze"],["The Voice of Hind Rajab",2025,"Kaouther Ben Hania",0,"1357402-the-voice-of-hind-rajab"],["A House of Dynamite",2025,"Kathryn Bigelow",7,"1172787-a-house-of-dynamite"],["The Smashing Machine",2025,"Benny Safdie",6,"680739-the-smashing-machine-2025"],["Frankenstein",2025,"Guillermo del Toro",7,"958100-frankenstein-2025"],["Hamnet",2025,"Chloé Zhao",7,"772232-hamnet"],["Unknown Number: The High School Catfish",2025,"Skye Borgman",0,"1393775-unknown-number-the-high-school-catfish"],["Bugonia",2025,"Yorgos Lanthimos",7,"625400-bugonia"],["Eenie Meanie",2025,"Shawn Simmons",4,"1037580-eenie-meanie"],["Caught Stealing",2025,"Darren Aronofsky",6,"1129199-caught-stealing"],["Weapons",2025,"Zach Cregger",7,"972109-weapons-2025"],["undertone",2025,"Ian Tuason",5,"1357408-undertone-2025-1"],["The Naked Gun",2025,"Akiva Schaffer",6,"933381-the-naked-gun"],["The Fantastic 4: First Steps",2025,"Matt Shakman",5,"543967-the-fantastic-four-first-steps"],["M3GAN 2.0",2025,"Gerard Johnstone",2,"965885-m3gan-20"],["KPop Demon Hunters",2025,"Chris Appelhans, Maggie Kang",6,"720953-kpop-demon-hunters"],["Superman",2025,"James Gunn",6,"957050-superman-2025"],["28 Years Later",2025,"Danny Boyle",6,"992786-28-years-later"],["F1",2025,"Joseph Kosinski",5,"817977-f1-the-movie"],["Elio",2025,"Madeline Sharafian, Domee Shi, Adrian Molina",8,"921575-elio"],["Materialists",2025,"Celine Song",3,"1024562-materialists"],["K.O.",2025,"Antoine Blossier",4,"1327912-ko-2025-1"],["Honey Don't!",2025,"Ethan Coen",5,"1036511-honey-dont"],["Ballerina",2025,"Len Wiseman",5,"470671-ballerina-2025"],["Sentimental Value",2025,"Joachim Trier",8,"1013357-sentimental-value-2025"],["Little Amélie or the Character of Rain",2025,"Maïlys Vallade, Liane-cho Han",6,"606298-little-amelie-or-the-character-of-rain"],["It Was Just an Accident",2025,"Jafar Panahi",7,"1333498-it-was-just-an-accident"],["Eleanor the Great",2025,"Scarlett Johansson",7,"1096218-eleanor-the-great"],["Untamable",2025,"Thomas Ngijol",6,"1338613-untamable"],["The Party's Over!",2025,"Antony Cordier",6,"1194498-the-partys-over-2025"],["Splitsville",2025,"Michael Angelo Covino",7,"1231801-splitsville"],["Highest 2 Lowest",2025,"Spike Lee",4,"1125031-highest-2-lowest"],["Alpha",2025,"Julia Ducournau",5,"1167808-alpha-2025-1"],["Exit 8",2025,"Genki Kawamura",5,"1290718-exit-8"],["The Secret Agent",2025,"Kleber Mendonça Filho",8,"1104348-the-secret-agent-2025"],["The Phoenician Scheme",2025,"Wes Anderson",7,"1025047-the-phoenician-scheme"],["Nouvelle Vague",2025,"Richard Linklater",4,"1138505-nouvelle-vague-2025"],["Die My Love",2025,"Lynne Ramsay",4,"931480-die-my-love"],["Dangerous Animals",2025,"Sean Byrne",7,"1169284-dangerous-animals"],["Arco",2025,"Ugo Bienvenu",7,"721566-arco"],["Eddington",2025,"Ari Aster",7,"574595-eddington"],["Case 137",2025,"Dominik Moll",8,"1177370-case-137-2025"],["Bring Her Back",2025,"Michael Philippou, Danny Philippou",8,"1037627-bring-her-back"],["Adam's Sake",2025,"Laura Wandel",7,"1176715-adams-sake"],["Leave One Day",2025,"Amélie Bonnin",7,"1161696-leave-one-day"],["Mission: Impossible – The Final Reckoning",2025,"Christopher McQuarrie",6,"503403-mission-impossible-the-final-reckoning"],["Havoc",2025,"Gareth Evans",5,"593280-havoc-1"],["Until Dawn",2025,"David F. Sandberg",5,"1115597-until-dawn-2025"],["Thunderbolts*",2025,"Jake Schreier",5,"887653-thunderbolts"],["Sinners",2025,"Ryan Coogler",6,"1116600-sinners-2025"],["Banger",2025,"So-Me",2,"1149662-banger-2025"],["A Minecraft Movie",2025,"Jared Hess",2,"854691-a-minecraft-movie"],["Locked",2025,"David Yarovesky",6,"977247-locked-2025"],["Warfare",2025,"Ray Mendoza, Alex Garland",6,"1124701-warfare"],["Drop",2025,"Christopher Landon",3,"1133530-drop-2025"],["Holland",2025,"Mimi Cave",4,"180876-holland-2025"],["Black Bag",2025,"Steven Soderbergh",7,"1116755-black-bag-2025"],["Good Boy",2025,"Ben Leonberg",5,"1301581-good-boy-2025"],["Death of a Unicorn",2025,"Alex Scharfman",4,"1039736-death-of-a-unicorn"],["Novocaine",2025,"Dan Berk, Robert Olsen",5,"1081017-novocaine-2025"],["Blue Moon",2025,"Richard Linklater",6,"1181463-blue-moon-2025"],["Mickey 17",2025,"Bong Joon Ho",7,"620281-mickey-17"],["The Monkey",2025,"Osgood Perkins",4,"1013393-the-monkey-2025"],["Sorry, Baby",2025,"Eva Victor",8,"1090464-sorry-baby-2025"],["Opus",2025,"Mark Anthony Green",5,"1087000-opus-2025"],["Train Dreams",2025,"Clint Bentley",6,"1125383-train-dreams"],["Together",2025,"Michael Shanks",6,"1125397-together-2025"],["The Perfect Neighbor",2025,"Geeta Gandbhir",0,"1284157-the-perfect-neighbor-2025"],["The Ugly Stepsister",2025,"Emilie Blichfeldt",8,"1167657-the-ugly-stepsister"],["Companion",2025,"Drew Hancock",6,"977172-companion-2025"],["One of Them Days",2025,"Lawrence Lamont",3,"1164440-one-of-them-days"],["Nosferatu",2024,"Robert Eggers",8,"359505-nosferatu-2024"],["Here",2024,"Robert Zemeckis",7,"844991-here-2024"],["Smile 2",2024,"Parker Finn",5,"992360-smile-2-2024"],["Kaizen",2024,"Basile Monnot",0,"1236131-kaizen"],["The Wild Robot",2024,"Chris Sanders",7,"1071196-the-wild-robot"],["The Life of Chuck",2024,"Mike Flanagan",7,"757612-the-life-of-chuck"],["We Live in Time",2024,"John Crowley",5,"991786-we-live-in-time"],["Joker: Folie à Deux",2024,"Todd Phillips",5,"800858-joker-folie-a-deux"],["Speak No Evil",2024,"James Watkins",5,"1004531-speak-no-evil"],["Queer",2024,"Luca Guadagnino",7,"955184-queer-2024"],["The Brutalist",2024,"Brady Corbet",7,"478428-the-brutalist"],["Wolfs",2024,"Jon Watts",5,"789010-wolfs"],["And Their Children After Them",2024,"Ludovic Boukherma, Zoran Boukherma",7,"995290-and-their-children-after-them"],["Babygirl",2024,"Halina Reijn",4,"989125-babygirl-2024"],["Beetlejuice Beetlejuice",2024,"Tim Burton",4,"823648-beetlejuice-beetlejuice"],["Ride Away",2024,"Mathias Mlekuz",7,"1202136-ride-away-2024"],["Meet the Barbarians",2024,"Julie Delpy",6,"902433-meet-the-barbarians"],["Rebel Ridge",2024,"Jeremy Saulnier",5,"571791-rebel-ridge"],["Incoming",2024,"Dave Chernin, John Chernin",2,"908689-incoming"],["The Union",2024,"Julian Farino",3,"627583-the-union"],["Alien: Romulus",2024,"Fede Álvarez",6,"850459-alien-romulus"],["Milk & Serial",2024,"Curry Barker",6,"1073624-milk-serial"],["Blink Twice",2024,"Zoë Kravitz",6,"756042-blink-twice"],["Borderlands",2024,"Eli Roth",2,"301123-borderlands"],["Deadpool & Wolverine",2024,"Shawn Levy",4,"462870-deadpool-wolverine"],["Trap",2024,"M. Night Shyamalan",6,"931164-trap"],["Longlegs",2024,"Osgood Perkins",6,"1110059-longlegs"],["Twisters",2024,"Lee Isaac Chung",5,"641608-twisters"],["A Family Affair",2024,"Richard LaGravenese",2,"889178-a-family-affair"],["A Quiet Place: Day One",2024,"Michael Sarnoski",7,"682535-a-quiet-place-day-one"],["Night Call",2024,"Michiel Blanchart",7,"902035-night-call-2024"],["Inside Out 2",2024,"Kelsey Mann",6,"921578-inside-out-2"],["The Watchers",2024,"Ishana Night Shyamalan",4,"979783-the-watchers"],["Beating Hearts",2024,"Gilles Lellouche",6,"863617-beating-hearts-2024"],["Plastic Guns",2024,"Jean-Christophe Meurisse",6,"901703-plastic-guns"],["Flow",2024,"Gints Zilbalodis",7,"739451-flow-2024"],["The Count of Monte Cristo",2024,"Alexandre de La Patellière, Matthieu Delaporte",7,"977835-the-count-of-monte-cristo-2024"],["Anora",2024,"Sean Baker",8,"959540-anora"],["The Apprentice",2024,"Ali Abbasi",6,"/sm/upload/yj/8m/d9/4r/apprentice_xxlg"],["Souleymane's Story",2024,"Boris Lojkine",8,"1045156-souleymanes-story"],["The Substance",2024,"Coralie Fargeat",8,"838140-the-substance"],["Emilia Pérez",2024,"Jacques Audiard",7,"877608-emilia-perez"],["The Second Act",2024,"Quentin Dupieux",4,"1047164-the-second-act"],["IF",2024,"John Krasinski",5,"565655-if"],["Furiosa: A Mad Max Saga",2024,"George Miller",8,"705221-furiosa-a-mad-max-saga"],["A Little Something Extra",2024,"Artus",6,"1038542-un-p-tit-truc-en-plus"],["The Ministry of Ungentlemanly Warfare",2024,"Guy Ritchie",4,"717126-the-ministry-of-ungentlemanly-warfare"],["Challengers",2024,"Luca Guadagnino",9,"842301-challengers"],["The Idea of You",2024,"Michael Showalter",5,"758397-the-idea-of-you"],["The Greatest Hits",2024,"Ned Benson",6,"910918-the-greatest-hits"],["Civil War",2024,"Alex Garland",7,"834656-civil-war"],["The Fall Guy",2024,"David Leitch",6,"667550-the-fall-guy"],["Immaculate",2024,"Michael Mohan",5,"938894-immaculate"],["Monkey Man",2024,"Dev Patel",7,"488751-monkey-man"],["Azrael",2024,"E.L. Katz",6,"927624-azrael"],["Road House",2024,"Doug Liman",5,"291213-road-house"],["Drive-Away Dolls",2024,"Ethan Coen",5,"861250-drive-away-dolls"],["Ricky Stanicky",2024,"Peter Farrelly",5,"921527-ricky-stanicky"],["Spaceman",2024,"Johan Renck",6,"562774-spaceman"],["The Empire",2024,"Bruno Dumont",1,"835293-the-empire-2024"],["Madame Web",2024,"SJ Clarkson",3,"560697-madame-web"],["Dune: Part Two",2024,"Denis Villeneuve",8,"617443-dune-part-two"],["Orion and the Dark",2024,"Sean Charmatz",6,"1025926-orion-and-the-dark"],["Argylle",2024,"Matthew Vaughn",3,"763160-argylle"],["A Real Pain",2024,"Jesse Eisenberg",7,"913258-a-real-pain"],["Game Changers",2024,"Jérémie Sein",5,"1005111-l-esprit-coubertin"],["Love Lies Bleeding",2024,"Rose Glass",8,"853011-love-lies-bleeding"],["Presence",2024,"Steven Soderbergh",6,"1027937-presence-2024"],["I Saw the TV Glow",2024,"Jane Schoenbrun",6,"772230-i-saw-the-tv-glow"],["Lucky Winners",2024,"Maxime Govare, Romain Choay",5,"1100522-heureux-gagnants"],["Meet the Leroys",2024,"Florent Bernard",7,"868402-nous-les-leroy"],["Lift",2024,"F. Gary Gray",3,"860077-lift"],["Five Years From Now",2024,"Léa Rouaud",0,"1109268-five-years-from-now"],["Anyone But You",2023,"Will Gluck",5,"966990-anyone-but-you"],["Leave the World Behind",2023,"Sam Esmail",7,"648869-leave-the-world-behind"],["Warnings",2023,"Curry Barker",0,"1076224-warnings"],["Freelance",2023,"Pierre Morel",3,"807679-freelance"],["The Rat Catcher",2023,"Wes Anderson",5,"1059457-the-rat-catcher"],["The Swan",2023,"Wes Anderson",5,"1059456-the-swan"],["Les Indésirables",2023,"Ladj Ly",5,"880513-les-indesirables"],["Infested",2023,"Sébastien Vaniček",7,"959593-infested"],["American Fiction",2023,"Cord Jefferson",7,"952812-american-fiction"],["Daaaaaalí!",2023,"Quentin Dupieux",3,"943257-daaaaaali-"],["Hit Man",2023,"Richard Linklater",7,"877046-hit-man"],["Humanist Vampire Seeking Consenting Suicidal Person",2023,"Ariane Louis-Seize",8,"890105-humanist-vampire-seeking-consenting-suicidal-person"],["The Killer",2023,"David Fincher",7,"717654-the-killer"],["Poor Things",2023,"Yorgos Lanthimos",8,"710352-poor-things"],["The Bikeriders",2023,"Jeff Nichols",6,"908327-the-bikeriders"],["Saltburn",2023,"Emerald Fennell",8,"835774-saltburn"],["The Holdovers",2023,"Alexander Payne",8,"755564-the-holdovers"],["The Equalizer 3",2023,"Antoine Fuqua",6,"831873-the-equalizer-3"],["Sentinelle",2023,"David Caviglioli, Hugo Benamozig",3,"900973-sentinelle"],["Iris and the Men",2023,"Caroline Vignal",3,"901841-it-s-raining-men"],["Teenage Mutant Ninja Turtles: Mutant Mayhem",2023,"Jeff Rowe",6,"542005-teenage-mutant-ninja-turtles-mutant-mayhem"],["Gran Turismo",2023,"Neill Blomkamp",6,"882718-gran-turismo"],["Oppenheimer",2023,"Christopher Nolan",7,"784328-oppenheimer"],["Yannick",2023,"Quentin Dupieux",7,"1001836-yannick"],["Barbie",2023,"Greta Gerwig",6,"277064-barbie"],["Enigma",2023,"Curry Barker",0,"1076238-enigma"],["Mission: Impossible – Dead Reckoning",2023,"Christopher McQuarrie",7,"503402-mission-impossible-dead-reckoning-part-one"],["No Hard Feelings",2023,"Gene Stupnitsky",5,"795897-no-hard-feelings"],["The Spider Within: A Spider-Verse Story",2023,"Jarelle Dampier",0,"997562-the-spider-within-a-spider-verse-story"],["The Flash",2023,"Andy Muschietti",3,"225845-the-flash"],["Spider-Man: Across the Spider-Verse",2023,"Justin K. Thompson, Kemp Powers, Joaquim Dos Santos",9,"497631-spider-man-across-the-spider-verse"],["Elemental",2023,"Peter Sohn",7,"878854-elemental"],["Asteroid City",2023,"Wes Anderson",6,"668555-asteroid-city"],["The Book of Solutions",2023,"Michel Gondry",7,"799188-the-book-of-solutions"],["Mars Express",2023,"Jérémie Périn",8,"514672-mars-express"],["Anatomy of a Fall",2023,"Justine Triet",8,"822093-anatomy-of-a-fall"],["Killers of the Flower Moon",2023,"Martin Scorsese",8,"398009-killers-of-the-flower-moon"],["The Zone of Interest",2023,"Jonathan Glazer",9,"398800-the-zone-of-interest"],["The King of Algiers",2023,"Elias Belkeddar",6,"896914-the-king-of-algiers"],["The Nature of Love",2023,"Monia Chokri",8,"818811-the-nature-of-love"],["The Animal Kingdom",2023,"Thomas Cailley",7,"847883-the-animal-kingdom"],["Fast X",2023,"Louis Leterrier",4,"320481-fast-x"],["Guardians of the Galaxy Vol. 3",2023,"James Gunn",7,"379711-guardians-of-the-galaxy-volume-3"],["Ghosted",2023,"Dexter Fletcher",4,"780724-ghosted"],["To Catch a Killer",2023,"Damián Szifron",7,"533065-to-catch-a-killer"],["Beau Is Afraid",2023,"Ari Aster",6,"715856-beau-is-afraid"],["The Super Mario Bros. Movie",2023,"Aaron Horvath, Michael Jelenic",6,"432302-the-super-mario-bros-movie"],["All Your Faces",2023,"Jeanne Herry",8,"901350-all-your-faces"],["Evil Dead Rise",2023,"Lee Cronin",6,"636761-evil-dead-rise"],["Bottoms",2023,"Emma Seligman",4,"731222-bottoms"],["John Wick: Chapter 4",2023,"Chad Stahelski",7,"530882-john-wick-chapter-4"],["Scream VI",2023,"Matt Bettinelli-Olpin, Tyler Gillett",5,"839244-scream-vi"],["Cocaine Bear",2023,"Elizabeth Banks",5,"721333-cocaine-bear"],["Knock at the Cabin",2023,"M. Night Shyamalan",6,"558056-knock-at-the-cabin"],["Past Lives",2023,"Celine Song",7,"591053-past-lives"],["You People",2023,"Kenya Barris",3,"780321-you-people"],["The Hatchet Wielding Hitchhiker",2023,"Colette Camden",0,"956954-the-hatchet-wielding-hitchhiker"],["Babylon",2022,"Damien Chazelle",8,"542773-babylon"],["M3GAN",2022,"Gerard Johnstone",6,"465649-m3gan"],["Avatar: The Way of Water",2022,"James Cameron",8,"63058-avatar-the-way-of-water"],["Puss in Boots: The Last Wish",2022,"Joel Crawford",6,"242285-puss-in-boots-the-last-wish"],["Upon Entry",2022,"Alejandro Rojas, Juan Sebastián Vásquez",7,"948247-upon-entry"],["Heavy Eyes",2022,"Curry Barker",0,"1074053-heavy-eyes"],["The New Toy",2022,"James Huth",2,"779691-the-new-toy"],["Smile",2022,"Parker Finn",5,"793883-smile"],["The Menu",2022,"Mark Mylod",5,"521323-the-menu"],["The Fabelmans",2022,"Steven Spielberg",9,"721288-the-fabelmans"],["Glass Onion",2022,"Rian Johnson",6,"586723-glass-onion"],["I Like Movies",2022,"Chandler Levack",7,"883153-i-like-movies"],["Ticket to Paradise",2022,"Ol Parker",4,"718296-ticket-to-paradise"],["Pearl",2022,"Ti West",8,"853822-pearl"],["Athena",2022,"Romain Gavras",6,"766607-athena"],["Jack Mimoun & the Secrets of Val Verde",2022,"Ludovic Colbeau-Justin, Malik Bentalha",4,"804301-jack-mimoun-the-secrets-of-val-verde"],["Honor Society",2022,"Oran Zegman",4,"834765-honor-society"],["Bullet Train",2022,"David Leitch",6,"641961-bullet-train"],["The Gray Man",2022,"Joe Russo, Anthony Russo",4,"647760-the-gray-man"],["Natural Born Liar",2022,"Olivier Baroux",2,"745088-natural-born-liar"],["Thor: Love and Thunder",2022,"Taika Waititi",5,"543002-thor-love-and-thunder"],["Hustle",2022,"Jeremiah Zagar",3,"629376-hustle"],["Smoking Causes Coughing",2022,"Quentin Dupieux",5,"784691-smoking-causes-coughing"],["The Night of the 12th",2022,"Dominik Moll",7,"830457-the-night-of-the-12th"],["A Perfect Pairing",2022,"Stuart McDonald",3,"839735-a-perfect-pairing"],["The Valet",2022,"Richard Wong",3,"727035-the-valet"],["Tenor",2022,"Claude Zidi Jr.",3,"840916-tenor"],["X",2022,"Ti West",7,"680358-x"],["The Chair",2022,"Curry Barker",0,"1007985-the-chair-2022-1"],["The Lost City",2022,"Aaron Nee, Adam Nee",6,"673474-the-lost-city"],["Everything Everywhere All at Once",2022,"Daniel Scheinert, Daniel Kwan",8,"474474-everything-everywhere-all-at-once"],["The Batman",2022,"Matt Reeves",7,"348914-the-batman"],["Dog",2022,"Reid Carolin, Channing Tatum",4,"553181-dog"],["Incredible But True",2022,"Quentin Dupieux",6,"657892-incredible-but-true"],["Love Tactics",2022,"Emre Kabakuşak",2,"833383-love-tactics"],["Uncharted",2022,"Ruben Fleischer",5,"264328-uncharted"],["Speak No Evil",2022,"Christian Tafdrup",8,"748943-speak-no-evil"],["Two Of A Kind",2022,"Olivier Ducray, Wilfried Méance",3,"833504-two-of-a-kind"],["Sex Appeal",2022,"Talia Osteen",1,"720518-sex-appeal"],["Gold",2022,"Anthony Hayes",5,"681347-gold"],["Scream",2022,"Tyler Gillett, Matt Bettinelli-Olpin",5,"572119-scream"],["The Wannabes",2022,"Jonathan Barré",6,"662441-the-wannabes"],["Jujutsu Kaisen 0",2021,"Sunghoo Park",6,"727160-jujutsu-kaisen-0"],["Spider-Man: No Way Home",2021,"Jon Watts",4,"560787-spider-man-no-way-home"],["The Hating Game",2021,"Peter Hutchings",2,"530972-the-hating-game"],["Licorice Pizza",2021,"Paul Thomas Anderson",8,"641086-licorice-pizza"],["Red Notice",2021,"Rawson Marshall Thurber",3,"441858-red-notice"],["Venom: Let There Be Carnage",2021,"Andy Serkis",3,"508638-venom-let-there-be-carnage"],["Some Like It Rare",2021,"Fabrice Eboué",4,"653180-some-like-it-rare"],["Last Night in Soho",2021,"Edgar Wright",8,"505000-last-night-in-soho"],["Bye Bye",2021,"Amélie Bonnin",7,"759649-bye-bye"],["Dune",2021,"Denis Villeneuve",8,"/sm/upload/nx/8b/vs/gc/cDbNAY0KM84cxXhmj8f0dLWza3t"],["Malignant",2021,"James Wan",6,"546348-malignant"],["He's All That",2021,"Mark Waters",1,"277993-he-s-all-that"],["Sweet Girl",2021,"Brian Andrew Mendoza",4,"546051-sweet-girl"],["The Stronghold",2021,"Cédric Jimenez",6,"563414-the-stronghold"],["Free Guy",2021,"Shawn Levy",5,"479814-free-guy"],["The Suicide Squad",2021,"James Gunn",7,"369835-the-suicide-squad"],["Titane",2021,"Julia Ducournau",6,"556553-titane"],["The Worst Person in the World",2021,"Joachim Trier",9,"585258-the-worst-person-in-the-world"],["Fear Street: 1978",2021,"Leigh Janiak",5,"518788-fear-street-1978"],["Space Jam: A New Legacy",2021,"Malcolm D. Lee",3,"314883-space-jam-a-new-legacy"],["Fear Street: 1994",2021,"Leigh Janiak",5,"518787-fear-street-part-one-1994"],["Hitman's Wife's Bodyguard",2021,"Patrick Hughes",4,"452522-hitman-s-wife-s-bodyguard"],["Stay",2021,"Sébastien Vaniček",0,"1109875-pas-bouger"],["Plan B",2021,"Natalie Morales",4,"665313-plan-b"],["F9",2021,"Justin Lin",3,"320000-f9"],["Wrath of Man",2021,"Guy Ritchie",5,"563643-wrath-of-man"],["Mortal Kombat",2021,"Simon McQuoid",3,"392290-mortal-kombat"],["Billie Eilish: The World's a Little Blurry",2021,"R. J. Cutler",0,"580204-billie-eilish-the-world-s-a-little-blurry"],["Two Distant Strangers",2020,"Travon Free, Martin Desmond Roe",7,"705560-two-distant-strangers"],["Holidate",2020,"John Whitesell",2,"542464-holidate"],["Soul",2020,"Pete Docter",8,"438511-soul"],["American Pie Presents: Girls' Rules",2020,"Mike Elliott",3,"585969-american-pie-presents-girls-rules"],["Tenet",2020,"Christopher Nolan",7,"/sm/upload/pq/9f/sr/vt/aCIFMriQh8rvhxpN1IWGgvH0Tlg"],["Simply Black",2020,"Jean-Pascal Zadi, John Wax",5,"604495-simply-black"],["The King of Staten Island",2020,"Judd Apatow",7,"507592-the-king-of-staten-island"],["A Quiet Place Part II",2020,"John Krasinski",6,"450337-a-quiet-place-part-ii"],["Spenser Confidential",2020,"Peter Berg",3,"509814-spenser-confidential"],["Palm Springs",2020,"Max Barbakow",8,"515467-palm-springs"],["Birds of Prey (and the Fantabulous Emancipation of One Harley Quinn)",2020,"Cathy Yan",5,"426131-birds-of-prey-and-the-fantabulous-emancipation-of-one-har"],["6 Underground",2019,"Michael Bay",3,"439717-6-underground"],["Jumanji: The Next Level",2019,"Jake Kasdan",4,"441862-jumanji-the-next-level"],["Blue Story",2019,"Rapman",3,"547814-blue-story"],["Let It Snow",2019,"Luke Snellin",3,"222470-let-it-snow"],["Street Flow",2019,"Alix Mathurin, Leïla Sy",3,"541512-street-flow"],["Miracle in Cell No. 7",2019,"Mehmet Ada Öztekin",6,"564087-miracle-in-cell-no-7"],["El Camino: A Breaking Bad Movie",2019,"Vince Gilligan",6,"488575-el-camino-a-breaking-bad-movie"],["Knives Out",2019,"Rian Johnson",6,"475370-knives-out"],["A Very Bad Friend",2019,"Varante Soudjian",2,"517759-a-very-bad-friend"],["Joker",2019,"Todd Phillips",7,"406775-joker"],["Uncut Gems",2019,"Josh Safdie, Benny Safdie",8,"404266-uncut-gems"],["Sextuplets",2019,"Michael Tiddes",3,"510640-sextuplets"],["Nimic",2019,"Yorgos Lanthimos",0,"548544-nimic"],["Ready or Not",2019,"Matt Bettinelli-Olpin, Tyler Gillett",7,"495969-ready-or-not"],["Secret Obsession",2019,"Peter Sullivan",1,"/sm/upload/2c/oy/5k/oc/r9hRGmNsKxfeu9UH7lKvYEkIJgv"],["Fast & Furious Presents: Hobbs & Shaw",2019,"David Leitch",4,"318913-fast-furious-presents-hobbs-shaw"],["Lying and Stealing",2019,"Matt Aselton",3,"439758-lying-and-stealing"],["The Lion King",2019,"Jon Favreau",4,"354539-the-lion-king"],["Spider-Man: Far From Home",2019,"Jon Watts",5,"362977-spider-man-far-from-home"],["Beats",2019,"Chris Robinson",2,"530722-beats"],["Midsommar",2019,"Ari Aster",9,"459564-midsommar"],["Shaft",2019,"Tim Story",4,"416624-shaft"],["Toy Story 4",2019,"Josh Cooley",7,"228628-toy-story-4"],["Wandering Stars",2019,"Syrine Boulanouar, Nekfeu",0,"536858-wandering-stars"],["Murder Mystery",2019,"Kyle Newacheck",5,"444598-murder-mystery"],["School Life",2019,"Mehdi Idir, Grand Corps Malade",5,"515161-school-life"],["Parasite",2019,"Bong Joon Ho",9,"426406-parasite"],["Once Upon a Time... in Hollywood",2019,"Quentin Tarantino",8,"397859-once-upon-a-time-in-hollywood"],["Portrait of a Lady on Fire",2019,"Céline Sciamma",9,"460830-portrait-of-a-lady-on-fire"],["Les Misérables",2019,"Ladj Ly",7,"514647-les-miserables"],["John Wick: Chapter 3 – Parabellum",2019,"Chad Stahelski",7,"390039-john-wick-chapter-3-parabellum"],["Pokémon Detective Pikachu",2019,"Rob Letterman",6,"379626-pokemon-detective-pikachu"],["Avengers: Endgame",2019,"Anthony Russo, Joe Russo",6,"226660-avengers-endgame"],["Long Shot",2019,"Jonathan Levine",6,"391964-long-shot"],["Us",2019,"Jordan Peele",6,"390520-us"],["Triple Frontier",2019,"J.C. Chandor",7,"333627-triple-frontier"],["Captain Marvel",2019,"Ryan Fleck, Anna Boden",4,"226750-captain-marvel"],["New Biz in the Hood",2019,"Mohamed Hamidi",2,"476291-new-biz-in-the-hood"],["Paradise Beach",2019,"Xavier Durringer",2,"500048-paradise-beach"],["Serial (Bad) Weddings 2",2019,"Philippe de Chauveron",2,"435317-serial-bad-weddings-2"],["Polar",2019,"Jonas Åkerlund",4,"414763-polar"],["How to Train Your Dragon: The Hidden World",2019,"Dean DeBlois",7,"123067-how-to-train-your-dragon-the-hidden-world"],["Spider-Man: Into the Spider-Verse",2018,"Bob Persichetti, Peter Ramsey, Rodney Rothman",9,"251943-spider-man-into-the-spider-verse"],["Creed II",2018,"Steven Caple Jr.",6,"411439-creed-ii"],["Venom",2018,"Ruben Fleischer",4,"265438-venom"],["Night School",2018,"Malcolm D. Lee",2,"386154-night-school"],["Nothing to Hide",2018,"Fred Cavayé",6,"418191-nothing-to-hide-2018"],["Suspiria",2018,"Luca Guadagnino",8,"293066-suspiria"],["A Star Is Born",2018,"Bradley Cooper",8,"261108-a-star-is-born"],["The Equalizer 2",2018,"Antoine Fuqua",6,"276253-the-equalizer-2"],["Mission: Impossible – Fallout",2018,"Christopher McQuarrie",7,"283273-mission-impossible-fallout"],["The First Purge",2018,"Gerard McMurray",4,"374885-the-first-purge"],["Budapest",2018,"Xavier Gens",4,"399293-budapest"],["Uncle Drew",2018,"Charles Stone III",4,"405541-uncle-drew"],["Ant-Man and the Wasp",2018,"Peyton Reed",3,"296341-ant-man-and-the-wasp"],["Looking for Teddy",2018,"Philippe Mechelen, Julien Hervé",1,"417054-looking-for-teddy"],["Incredibles 2",2018,"Brad Bird",6,"184061-incredibles-2"],["Ocean's Eight",2018,"Gary Ross",5,"337567-ocean-s-8"],["Tag",2018,"Jeff Tomsic",6,"387909-tag-2018"],["Shéhérazade",2018,"Jean-Bernard Marlin",5,"448090-sheherazade"],["Deadpool 2",2018,"David Leitch",5,"318195-deadpool-2"],["BlacKkKlansman",2018,"Spike Lee",7,"418135-blackkklansman"],["Sink or Swim",2018,"Gilles Lellouche",7,"415318-sink-or-swim"],["Avengers: Infinity War",2018,"Anthony Russo, Joe Russo",7,"226661-avengers-infinity-war"],["Love Addict",2018,"Frank Bellocq",2,"393922-love-addict-2018"],["Blockers",2018,"Kay Cannon",3,"370431-blockers"],["A Quiet Place",2018,"John Krasinski",7,"379687-a-quiet-place"],["Game Night",2018,"John Francis Daley, Jonathan Goldstein",7,"378048-game-night"],["Thugocratie",2018,"FGKO",2,"148708-voyoucratie"],["Black Panther",2018,"Ryan Coogler",6,"209383-black-panther"],["Hereditary",2018,"Ari Aster",9,"424348-hereditary"],["The Guilty",2018,"Gustav Möller",8,"417516-the-guilty"],["American Animals",2018,"Bart Layton",7,"420563-american-animals"],["Taxi 5",2018,"Franck Gastambide",3,"367378-taxi-5"],["Den of Thieves",2018,"Christian Gudegast",4,"381754-den-of-thieves"],["Bright",2017,"David Ayer",4,"334311-bright"],["Jumanji: Welcome to the Jungle",2017,"Jake Kasdan",5,"/sm/upload/j1/1c/as/56/bUzOyCgsb6FLXco6mxaNufY0joi"],["Justice League",2017,"Zack Snyder",3,"107670-justice-league"],["Marry Me, Dude",2017,"Tarek Boudali",4,"365692-marry-me-dude"],["Coco",2017,"Lee Unkrich",10,"/sm/upload/3p/mh/wq/v9/6Ryitt95xrO8KXuqRGm1fUuNwqF"],["Blade Runner 2049",2017,"Denis Villeneuve",8,"265439-blade-runner-2049"],["Thor: Ragnarok",2017,"Taika Waititi",6,"209382-thor-ragnarok"],["Kingsman: The Golden Circle",2017,"Matthew Vaughn",5,"/sm/upload/3h/o6/gc/iy/yOGf8Or1k78Y6OLdYmTTSGHW1dP"],["The Upside",2017,"Neil Burger",4,"373189-the-upside"],["Three Billboards Outside Ebbing, Missouri",2017,"Martin McDonagh",7,"291610-three-billboards-outside-ebbing-missouri"],["The Hitman's Bodyguard",2017,"Patrick Hughes",5,"/sm/upload/cs/4h/d7/ej/5CGjlz2vyBhW5xHW4eNOZIdgzYq"],["Logan Lucky",2017,"Steven Soderbergh",7,"/sm/upload/oh/pn/ri/gu/mQrhrBaaHvRfBQq0Px3HtVbH9iE"],["Spider-Man: Homecoming",2017,"Jon Watts",6,"242710-spider-man-homecoming"],["The Mansion",2017,"Tony T. Datis",1,"370606-the-mansion"],["All Eyez on Me",2017,"Benny Boom",4,"337159-all-eyez-on-me"],["Cars 3",2017,"Brian Fee",5,"184062-cars-3"],["Baywatch",2017,"Seth Gordon",3,"/sm/upload/0y/1p/zz/j6/rxQynWvwl41VbJGb0FEyYtuRwS2"],["Alien: Covenant",2017,"Ridley Scott",4,"99144-alien-covenant"],["Guardians of the Galaxy Vol. 2",2017,"James Gunn",5,"/sm/upload/1g/4f/6e/5b/prvWMj8cBFgVn5MLlsjlvH2hiIh"],["The Fate of the Furious",2017,"F. Gary Gray",4,"266628-the-fate-of-the-furious"],["Going in Style",2017,"Zach Braff",5,"283209-going-in-style"],["Gangsterdam",2017,"Romain Lévy",2,"345812-gangsterdam"],["CHiPs",2017,"Dax Shepard",4,"351534-chips"],["Atomic Blonde",2017,"David Leitch",4,"270477-atomic-blonde"],["Baby Driver",2017,"Edgar Wright",6,"268950-baby-driver"],["Logan",2017,"James Mangold",8,"/sm/upload/f3/ub/fq/f5/gGBu0hKw9BGddG8RkRAMX7B6NDB"],["Fist Fight",2017,"Richie Keen",3,"276277-fist-fight"],["John Wick: Chapter 2",2017,"Chad Stahelski",7,"/sm/upload/wb/rc/zd/o6/fWz9LMfdES80BsJKucgzI5ZJhnB"],["Get Out",2017,"Jordan Peele",9,"353117-get-out"],["Alibi.com",2017,"Philippe Lacheau",4,"333165-alibi-com"],["The Climb",2017,"Ludovic Bernard",5,"355163-the-climb"],["xXx: Return of Xander Cage",2017,"D.J. Caruso",4,"/sm/upload/ko/um/0w/04/yNsdyNbQqaKN0TQxkHMws2KLTJ6"],["Why Him?",2016,"John Hamburg",4,"287509-why-him-"],["Assassin's Creed",2016,"Justin Kurzel",2,"/sm/upload/r9/9y/rj/rt/tIKFBxBZhSXpIITiiB5Ws8VGXjt"],["R.A.I.D. Special Unit",2016,"Dany Boon",3,"317566-r-a-i-d-special-unit"],["Collateral Beauty",2016,"David Frankel",5,"276275-collateral-beauty"],["Office Christmas Party",2016,"Josh Gordon, Will Speck",3,"/sm/upload/pu/54/l8/x8/cW85VlHPm3pz0anupAXHL9eTh5b"],["Full Speed",2016,"Nicolas Benamou",2,"317567-full-speed"],["Fantastic Beasts and Where to Find Them",2016,"David Yates",5,"182910-fantastic-beasts-and-where-to-find-them"],["Doctor Strange",2016,"Scott Derrickson",6,"209381-doctor-strange"],["Keeping Up with the Joneses",2016,"Greg Mottola",4,"259120-keeping-up-with-the-joneses"],["Jack Reacher: Never Go Back",2016,"Edward Zwick",4,"/sm/upload/54/yn/th/hy/IfB9hy4JH1eH6HEfIgIGORXi5h"],["La Pièce - Les derniers seront les premiers",2016,"Lamine Diakite",1,"347709-la-piece-les-derniers-seront-les-premiers"],["Penny Pincher!",2016,"Fred Cavayé",4,"317512-penny-pincher-"],["Split",2016,"M. Night Shyamalan",6,"/sm/upload/5e/pw/vs/km/8CHJcVc5IGXS1sC5DyjeMwTDEQH"],["La La Land",2016,"Damien Chazelle",9,"240344-la-la-land"],["Mechanic: Resurrection",2016,"Dennis Gansel",3,"203081-mechanic-resurrection"],["C'est la Vie",2016,"Ari Aster",0,"451976-c-est-la-vie"],["Suicide Squad",2016,"David Ayer",2,"/sm/upload/t0/3y/yr/rs/n3rm3gxguxzFDlygpROV7RHbELe"],["Last Call for Nowhere",2016,"Philippe de Chauveron",4,"317518-last-call-for-nowhere"],["The Infiltrator",2016,"Brad Furman",5,"253072-the-infiltrator"],["Mike and Dave Need Wedding Dates",2016,"Jake Szymanski",4,"/sm/upload/0f/hb/kn/x0/3DwSh0AsBxPUxQ9x4yDuRNoYOW7"],["The Purge: Election Year",2016,"James DeMonaco",6,"243745-the-purge-election-year"],["Camping 3",2016,"Fabien Onteniente",2,"311245-camping-3"],["Central Intelligence",2016,"Rawson Marshall Thurber",4,"229745-central-intelligence"],["Lights Out",2016,"David F. Sandberg",4,"276267-lights-out"],["Now You See Me 2",2016,"Jon M. Chu",4,"218051-now-you-see-me-2"],["Popstar: Never Stop Never Stopping",2016,"Akiva Schaffer, Jorma Taccone",6,"270476-popstar-never-stop-never-stopping"],["Chouf",2016,"Karim Dridi",4,"328677-chouf"],["Raw",2016,"Julia Ducournau",8,"327974-raw"],["The Handmaiden",2016,"Park Chan-wook",10,"/sm/upload/pc/n6/pz/mi/wvzfK5QR6dGLwND8MCzWjsQWG4Q"],["The Conjuring 2",2016,"James Wan",6,"183255-the-conjuring-2"],["The Nice Guys",2016,"Shane Black",8,"216301-the-nice-guys"],["Neighbors 2: Sorority Rising",2016,"Nicholas Stoller",5,"/sm/upload/0j/b6/38/hd/bWUeJHbKIyT306WtJFRHoSzX9nk"],["Barbershop: The Next Cut",2016,"Malcolm D. Lee",4,"253767-barbershop-the-next-cut"],["Captain America: Civil War",2016,"Joe Russo, Anthony Russo",7,"194402-captain-america-civil-war"],["Five",2016,"Igor Gotesman",7,"316387-five"],["A Mighty Team",2016,"Thomas Sorriaux",3,"316383-a-mighty-team"],["Get a Job",2016,"Dylan Kidd",4,"/sm/upload/nl/2j/tw/nq/ud9YiLyAdLDSQhJSVVTv2Pb6h56"],["Sausage Party",2016,"Conrad Vernon, Greg Tiernan",2,"/sm/upload/h4/fy/g1/ks/jDeDRLEa8JqB3xmKVy6q3bkmDt6"],["Keanu",2016,"Peter Atencio",3,"/sm/upload/b7/u5/wl/xy/46RdI1XNmNm4me25oIvXf6Zizy5"],["Good Guys Go to Heaven, Bad Guys Go to Pattaya",2016,"Franck Gastambide",2,"201938-good-guys-go-to-heaven-bad-guys-go-to-pattaya"],["Deadpool",2016,"Tim Miller",7,"220575-deadpool"],["Zootopia",2016,"Byron Howard, Rich Moore",8,"192410-zootopia"],["Zoolander 2",2016,"Ben Stiller",2,"/sm/upload/5n/ry/t4/nr/u2s2WOskiEH71WbGCZehZ0shduO"],["The Tuche Family: The American Dream",2016,"Olivier Baroux",4,"305581-the-tuche-family-the-american-dream"],["Blue Mountain State: The Rise of Thadland",2016,"Lev L. Spiro",3,"213939-blue-mountain-state-the-rise-of-thadland"],["Captain Fantastic",2016,"Matt Ross",8,"/sm/upload/5d/hg/f9/my/fnaGmGCWgGOQjCpM0TqKPZJ5x85"],["One Man and his Cow",2016,"Mohamed Hamidi",3,"313186-one-man-and-his-cow"],["Ride Along 2",2016,"Tim Story",6,"250814-ride-along-2-next-level-miami"],["Friend Request",2016,"Simon Verhoeven",4,"/sm/upload/mi/ml/d6/xo/s91SGUDBoa0eXgWoqK5Q1uvtpYr"],["The Revenant",2015,"Alejandro G. Iñárritu",8,"207224-the-revenant"],["Comment c'est loin",2015,"Christophe Offenstein, Orelsan",7,"302633-comment-c-est-loin"],["The Hateful Eight",2015,"Quentin Tarantino",8,"197012-the-hateful-eight"],["Point Break",2015,"Ericson Core",4,"180873-point-break"],["Creed",2015,"Ryan Coogler",7,"239260-creed"],["The Big Short",2015,"Adam McKay",8,"246013-the-big-short"],["Babysitting 2",2015,"Nicolas Benamou, Philippe Lacheau",4,"259673-babysitting-2"],["High-Rise",2015,"Ben Wheatley",4,"/sm/upload/ao/dm/ne/5x/oc00vvVYatTUvvcNC7ZyPlMmNCe"],["Dab6e: The Return",2015,"Hasan Karacadağ",2,"328268-dbbe-6-the-return"],["Black",2015,"Adil El Arbi, Bilall Fallah",2,"287380-black"],["The Visit",2015,"M. Night Shyamalan",6,"225437-the-visit"],["Legend",2015,"Brian Helgeland",4,"/sm/upload/8f/af/l2/9b/nXXI1MCJ0ugMetJ5Qn7ofDXANxf"],["The New Adventures of Aladdin",2015,"Arthur Benzaquen",1,"274472-the-new-adventures-of-aladdin"],["The Transporter Refueled",2015,"Camille Delamarre",4,"213191-the-transporter-refueled"],["Sinister 2",2015,"Ciarán Foy",4,"208761-sinister-2"],["Straight Outta Compton",2015,"F. Gary Gray",7,"201340-straight-outta-compton"],["Mission: Impossible – Rogue Nation",2015,"Christopher McQuarrie",7,"/sm/upload/lk/jb/17/6y/oUDKymEL932AeHyl4A4ee8zuBLF"],["Pixels",2015,"Chris Columbus",1,"181118-pixels"],["Serial Teachers 2",2015,"Pierre-François Martin-Laval",2,"253099-serial-teachers-2"],["Ant-Man",2015,"Peyton Reed",5,"83557-ant-man"],["Ted 2",2015,"Seth MacFarlane",5,"152464-ted-2"],["A Love You",2015,"Paul Lefèvre",4,"268629-a-love-you"],["Southpaw",2015,"Antoine Fuqua",6,"234208-southpaw"],["Insidious: Chapter 3",2015,"Leigh Whannell",4,"205014-insidious-chapter-3"],["San Andreas",2015,"Brad Peyton",4,"177941-san-andreas"],["Inside Out",2015,"Pete Docter",8,"113284-inside-out"],["Mad Max: Fury Road",2015,"George Miller",10,"62780-mad-max-fury-road"],["Spy",2015,"Paul Feig",4,"167502-spy"],["Avengers: Age of Ultron",2015,"Joss Whedon",5,"81605-avengers-age-of-ultron"],["Animal Kingdom: Let's Go Ape",2015,"Jamel Debbouze",2,"205408-why-i-did-not-eat-my-father"],["Get Hard",2015,"Etan Cohen",4,"180874-get-hard"],["Furious 7",2015,"James Wan",7,"124133-furious-7"],["Trainwreck",2015,"Judd Apatow",5,"194975-trainwreck"],["Bis",2015,"Dominique Farrugia",2,"250040-bis"],["Focus",2015,"Glenn Ficarra, John Requa",5,"180414-focus-2015"],["Fifty Shades of Grey",2015,"Sam Taylor-Johnson",2,"/sm/upload/fb/qp/f7/re/v8OHt1ZG1K7c5KvDCGpX2zvlWzA"],["The SpongeBob Movie: Sponge Out of Water",2015,"Paul Tibbitt, Mike Mitchell",4,"160505-the-spongebob-movie-sponge-out-of-water"],["Sleeping with Other People",2015,"Leslye Headland",5,"/sm/upload/wg/4y/18/x1/sT7WJ14n2tfU7ek9O1c0n2rVMbJ"],["The Witch",2015,"Robert Eggers",7,"/sm/upload/y2/i8/9s/h1/tNr2KYytArZNSh0K8PUcHU3JnX4"],["Reality+",2014,"Coralie Fargeat",0,"303159-reality-2014-1"],["Taken 3",2014,"Olivier Megaton",3,"183907-taken-3"],["Kingsman: The Secret Service",2014,"Matthew Vaughn",6,"148200-kingsman-the-secret-service"],["Dumb and Dumber To",2014,"Bobby Farrelly, Peter Farrelly",4,"81811-dumb-and-dumber-to"],["Horrible Bosses 2",2014,"Sean Anders",4,"159889-horrible-bosses-2"],["The Bélier Family",2014,"Éric Lartigau",5,"231398-the-belier-family"],["Interstellar",2014,"Christopher Nolan",8,"117621-interstellar"],["Love, Rosie",2014,"Christian Ditter",5,"/sm/upload/pp/av/st/c7/fOSxpfWiNCDXgYLDdZ6hifrshrh"],["Annabelle",2014,"John R. Leonetti",6,"/sm/upload/h1/9m/2u/4k/annabelle"],["Gone Girl",2014,"David Fincher",9,"149857-gone-girl"],["Two Night Stand",2014,"Max Nichols",5,"211827-two-night-stand"],["Playing It Cool",2014,"Justin Reardon",4,"201659-playing-it-cool"],["John Wick",2014,"Chad Stahelski",8,"172076-john-wick"],["The Equalizer",2014,"Antoine Fuqua",6,"116825-the-equalizer"],["Nightcrawler",2014,"Dan Gilroy",8,"/sm/upload/g7/2e/vi/vy/A9ANrAWlmIovxzjAIiOgseSLNc9"],["Before We Go",2014,"Chris Evans",5,"208675-before-we-go"],["Birdman or (The Unexpected Virtue of Ignorance)",2014,"Alejandro G. Iñárritu",8,"139795-birdman"],["Guardians of the Galaxy",2014,"James Gunn",7,"93676-guardians-of-the-galaxy"],["Sex Tape",2014,"Jake Kasdan",4,"/sm/upload/21/5x/j0/51/2BMmIPGu5ZbTrwXwomdSUuTB2Ul"],["The Purge: Anarchy",2014,"James DeMonaco",5,"167433-the-purge-anarchy"],["Fastlife",2014,"Thomas Ngijol",5,"205833-fastlife"],["Think Like a Man Too",2014,"Tim Story",3,"133279-think-like-a-man-too"],["22 Jump Street",2014,"Phil Lord, Christopher Miller",7,"/sm/upload/qq/wx/vh/dy/tPnw9oqIvIMoYjVozkDkxm3xR8r"],["It Follows",2014,"David Robert Mitchell",8,"/sm/upload/zr/lv/9v/wy/4MrwJZr0R9LbyOgZqwLNmtzzxbu"],["How to Train Your Dragon 2",2014,"Dean DeBlois",8,"69142-how-to-train-your-dragon-2"],["Serial (Bad) Weddings",2014,"Philippe de Chauveron",3,"185864-qu-est-ce-qu-on-a-fait-au-bon-dieu"],["Babysitting",2014,"Philippe Lacheau, Nicolas Benamou",5,"186015-babysitting"],["Captain America: The Winter Soldier",2014,"Joe Russo, Anthony Russo",5,"/sm/upload/he/p6/cc/lg/zt6b493XEL2OQ1bCSKccZ7V0iRY"],["Junior",2014,"Pascal Bourdiaux",2,"176470-junior"],["Neighbors",2014,"Nicholas Stoller",5,"140512-neighbors"],["Need for Speed",2014,"Scott Waugh",3,"104997-need-for-speed"],["Superchondriac",2014,"Dany Boon",2,"173632-superchondriac"],["Basically",2014,"Ari Aster",0,"262955-basically"],["Le Crocodile du Botswanga",2014,"Fabrice Eboué, Lionel Steketee",5,"173535-le-crocodile-du-botswanga"],["The Grand Budapest Hotel",2014,"Wes Anderson",8,"95113-the-grand-budapest-hotel"],["The Wedding Pact",2014,"Matt Berman",2,"177871-the-wedding-pact"],["That Awkward Moment",2014,"Tom Gormican",4,"/sm/upload/yh/f8/m4/6w/that-awkward-moment"],["What We Do in the Shadows",2014,"Jemaine Clement, Taika Waititi",6,"172537-what-we-do-in-the-shadows"],["Whiplash",2014,"Damien Chazelle",10,"/sm/upload/cl/dn/kr/f1/4C9LHDxMsoYI0S3iMPZdm3Oevwo"],["Ride Along",2014,"Tim Story",5,"/sm/upload/y6/w7/bu/89/fLXPcxZ1fJjxqUg94FFb8wwM9YN"],["Lights Out",2013,"David F. Sandberg",0,"183322-lights-out"],["The Wolf of Wall Street",2013,"Martin Scorsese",9,"86114-the-wolf-of-wall-street"],["The Hunger Games: Catching Fire",2013,"Francis Lawrence",6,"/sm/upload/0a/6m/bl/rt/esWEsDI83IYqUBGSN69hb4A1Vfu"],["Thor: The Dark World",2013,"Alan Taylor",4,"/sm/upload/pc/xw/7h/17/bnX5PqAdQZRXSw3aX3DutDcdso5"],["Munchausen",2013,"Ari Aster",0,"431952-munchausen"],["Insidious: Chapter 2",2013,"James Wan",6,"76658-insidious-chapter-2"],["Jodorowsky's Dune",2013,"Frank Pavich",0,"/sm/upload/t0/wb/a6/pm/c8zcrYHsAg9R9oEbfdRhwslDwnp"],["Prisoners",2013,"Denis Villeneuve",8,"/sm/upload/iw/eg/4g/nm/3w79tTsv6tmlT8Jww6snyPrgVok"],["Under the Skin",2013,"Jonathan Glazer",7,"80198-under-the-skin"],["We're the Millers",2013,"Rawson Marshall Thurber",6,"/sm/upload/gy/z2/o8/vq/pyrv46Lr3rOIcSg1PkkCwktCC3G"],["The To Do List",2013,"Maggie Carey",3,"/sm/upload/id/11/rq/x3/kcFuRIq7vVNkjcPcvNcdsT2Bgf9"],["Escape Plan",2013,"Mikael Håfström",3,"86856-escape-plan"],["Grown Ups 2",2013,"Dennis Dugan",6,"/sm/upload/5j/17/k1/d2/xVfzcl1fcTDA4T76enoHF80MR4n"],["Despicable Me 2",2013,"Chris Renaud, Pierre Coffin",6,"/sm/upload/dz/ec/y7/pf/ek09KXB8ytg9nUb3hDUpJn7APdT"],["Man of Steel",2013,"Zack Snyder",4,"/sm/upload/wx/hm/hf/14/uKnhbfNt1ZR2TdoZpdn7vSNZlhX"],["The Conjuring",2013,"James Wan",7,"106262-the-conjuring"],["This Is the End",2013,"Evan Goldberg, Seth Rogen",4,"/sm/upload/jc/9p/19/zx/oie_1512543TJ3vNUDP"],["The Purge",2013,"James DeMonaco",6,"118110-the-purge"],["Only God Forgives",2013,"Nicolas Winding Refn",5,"64427-only-god-forgives"],["Now You See Me",2013,"Louis Leterrier",5,"/sm/upload/10/vk/qc/6e/1NybAlflbmRXMIr9WoYxtlt1b6m"],["The Hangover Part III",2013,"Todd Phillips",4,"87953-the-hangover-part-iii"],["Fast & Furious 6",2013,"Justin Lin",4,"69453-fast-furious-6"],["Iron Man 3",2013,"Shane Black",6,"/sm/upload/5r/0i/96/db/7XiGqZE8meUv7L4720L0tIDd7gO"],["Serial Teachers",2013,"Pierre-François Martin-Laval",2,"132222-serial-teachers"],["Pain & Gain",2013,"Michael Bay",7,"103559-pain-gain"],["Evil Dead",2013,"Fede Álvarez",6,"/sm/upload/he/wz/f9/h1/6gtHgAxgemVd3pIQlbg4YoniqEY"],["It Boy",2013,"David Moreau",5,"126980-it-boy"],["The Real Life of Teachers",2013,"Albert Pereira-Lazaro, Emmanuel Klotz",3,"124615-the-real-life-of-teachers"],["The Croods",2013,"Chris Sanders, Kirk DeMicco",4,"16093-the-croods"],["Identity Thief",2013,"Seth Gordon",3,"/sm/upload/2f/87/ui/j0/lOF4rI6SxgRsVLW8odsauqnhB9Z"],["This Is 40",2012,"Judd Apatow",6,"75322-this-is-40"],["Django Unchained",2012,"Quentin Tarantino",8,"52516-django-unchained"],["Jack Reacher",2012,"Christopher McQuarrie",6,"/sm/upload/ir/bx/ah/ew/3VoVKGVmU7S0a9yMVJo4H5siVw7"],["Asphalt Playground",2012,"Julien Abraham",4,"131123-asphalt-playground"],["Wreck-It Ralph",2012,"Rich Moore",4,"69154-wreck-it-ralph"],["The First Time",2012,"Jonathan Kasdan",4,"70642-the-first-time"],["Taken 2",2012,"Olivier Megaton",4,"69169-taken-2"],["The Dream Team",2012,"Olivier Dahan",6,"103066-the-dream-team"],["Frankenweenie",2012,"Tim Burton",6,"/sm/upload/w7/w9/ex/7w/zMFJ0Uy9y0Oy3KPbgtRic6IYzRk"],["Hotel Transylvania",2012,"Genndy Tartakovsky",5,"/sm/upload/f8/kq/gh/fa/9qugesYpAWHUpdrw2w8URSGkAPt"],["Silver Linings Playbook",2012,"David O. Russell",7,"69151-silver-linings-playbook"],["The Place Beyond the Pines",2012,"Derek Cianfrance",8,"80200-the-place-beyond-the-pines"],["Spring Breakers",2012,"Harmony Korine",4,"96109-spring-breakers"],["The Dark Knight Rises",2012,"Christopher Nolan",6,"16550-the-dark-knight-rises"],["Porn in the Hood",2012,"Franck Gastambide",4,"96834-porn-in-the-hood"],["Brave",2012,"Mark Andrews, Brenda Chapman",6,"/sm/upload/ct/de/cg/m1/tZhun7eLdyGv9nMJS9YTyOXeOCb"],["Ted",2012,"Seth MacFarlane",6,"57376-ted"],["Madagascar 3: Europe's Most Wanted",2012,"Eric Darnell, Tom McGrath, Conrad Vernon",6,"/sm/upload/ra/ee/np/jf/5aNEbL2EpKk47V3wDXVenLx2ksS"],["The Dictator",2012,"Larry Charles",5,"62911-the-dictator"],["What's in a Name",2012,"Alexandre de La Patellière, Matthieu Delaporte",7,"89700-what-s-in-a-name"],["Prometheus",2012,"Ridley Scott",6,"/sm/upload/39/zq/9r/ye/qsYQflQhOuhDpQ0W2aOcwqgDAeI"],["The Avengers",2012,"Joss Whedon",6,"36778-the-avengers-2012"],["American Reunion",2012,"Jon Hurwitz, Hayden Schlossberg",4,"57927-american-reunion"],["The Hunger Games",2012,"Gary Ross",7,"/sm/upload/x3/tw/wu/z4/vAkjFEm76Lu5hSevquxPgQ91OtI"],["21 Jump Street",2012,"Phil Lord, Christopher Miller",7,"279-21-jump-street"],["Sinister",2012,"Scott Derrickson",7,"/sm/upload/e2/ry/mu/yc/hrRYY7FcRc46Ue7h9jcKiW1xqJ3"],["Project X",2012,"Nima Nourizadeh",4,"/sm/upload/h7/gc/y5/05/cWXkRLmzKfYutvWeJXaednoGKdF"],["The Players",2012,"Jean Dujardin, Alexandre Courtes, Éric Lartigau, Fred Cavayé, Michel Hazanavicius, Emmanuelle Bercot, Gilles Lellouche",4,"75492-the-players"],["Think Like a Man",2012,"Tim Story",5,"/sm/upload/3q/i1/wf/hx/4tK8k1YbF58nEMW76bnm76jWpnZ"],["Chronicle",2012,"Josh Trank",5,"/sm/upload/85/vy/rs/s4/dMULLYV1wxEdG6P3uziGqdo6uFl"],["Journey 2: The Mysterious Island",2012,"Brad Peyton",4,"/sm/upload/w6/w1/s7/ma/xErNH2c27M07BE31z4JXmNtdL5M"],["Hollywoo",2011,"Frédéric Berthe, Pascal Serieis",3,"66475-hollywoo"],["Mission: Impossible – Ghost Protocol",2011,"Brad Bird",7,"/sm/upload/mi/dr/zr/6r/e3SnEE5ug02TsH86H6EF30laHjO"],["Tower Heist",2011,"Brett Ratner",4,"/sm/upload/5n/50/82/yc/tower-heist"],["Puss in Boots",2011,"Chris Miller",6,"/sm/upload/li/68/db/nc/7r57xOw0zSCW59pys29KyPrDS3t"],["Beur sur la ville",2011,"Djamel Bensalah",5,"63916-beur-sur-la-ville"],["What's Your Number?",2011,"Mark Mylod",2,"/sm/upload/lq/kx/kg/ub/yugpF7km9nEE5GLpSWMSkGKHGNd"],["The Intouchables",2011,"Olivier Nakache, Éric Toledano",8,"/sm/upload/6d/b1/v2/4j/intouchables"],["Warrior",2011,"Gavin O'Connor",8,"6942-warrior"],["Captain America: The First Avenger",2011,"Joe Johnston",5,"50809-captain-america-the-first-avenger"],["Friends with Benefits",2011,"Will Gluck",5,"/sm/upload/gx/n5/br/ke/nKhhDFCdzxeJ3GUunQ570LDpUkz"],["Crazy, Stupid, Love.",2011,"Glenn Ficarra, John Requa",7,"15051-crazy-stupid-love-"],["Les Mythos",2011,"Denis Thybaud",3,"718-les-mythos"],["Harry Potter and the Deathly Hallows: Part 2",2011,"David Yates",6,"44580-harry-potter-and-the-deathly-hallows-part-2"],["Case départ",2011,"Lionel Steketee, Thomas Ngijol, Fabrice Eboué",6,"728-case-depart"],["Horrible Bosses",2011,"Seth Gordon",4,"/sm/upload/zl/qm/x7/ds/2yrbGFgrzYFtkYoVzUQSf6tforZ"],["The Tuche Family",2011,"Olivier Baroux",4,"717-the-tuche-family"],["Colombiana",2011,"Olivier Megaton",4,"3980-colombiana"],["Cars 2",2011,"John Lasseter",4,"16560-cars-2"],["Drive",2011,"Nicolas Winding Refn",8,"/sm/upload/6d/6l/r3/e9/nu7XIa67cXc2t7frXCE5voXUJcN.jpg"],["The Hangover Part II",2011,"Todd Phillips",5,"/sm/upload/14/sk/45/1c/hFUsdnUoQDQ02EVlKTyhDTdehEr"],["Bad Teacher",2011,"Jake Kasdan",2,"13439-bad-teacher"],["Polisse",2011,"Maïwenn",7,"/sm/upload/5n/94/1m/fc/gJK2GdkcZNbhY2VqnsZ8Q3X9Of7.jpg"],["Beau",2011,"Ari Aster",0,"432043-beau"],["Thor",2011,"Kenneth Branagh",5,"46456-thor"],["Fast Five",2011,"Justin Lin",7,"/sm/upload/xr/1t/wx/2n/cA81CI8odKv5KHRUUzJbj83yN7c"],["Lemonade Mouth",2011,"Patricia Riggen",3,"1610-lemonade-mouth"],["Scream 4",2011,"Wes Craven",4,"/sm/upload/xw/xb/gx/5p/xEl8QQunHWUtf0dlKEbMXlfKSdr"],["Rio",2011,"Carlos Saldanha",6,"19122-rio"],["Limitless",2011,"Neil Burger",4,"13972-limitless"],["Halal State Security",2011,"Rachid Dhibou",3,"8780-halal-state-security"],["Paul",2011,"Greg Mottola",4,"/sm/upload/kv/bj/t4/ly/297N75COL0NsJJY5k5U8VTJ1DCe"],["Rango",2011,"Gore Verbinski",6,"/sm/upload/kg/9s/vs/0n/tB6RZA2pEFnolOKOAHR2GBu25aT"],["The Strange Thing About the Johnsons",2011,"Ari Aster",8,"121618-the-strange-thing-about-the-johnsons"],["No Strings Attached",2011,"Ivan Reitman",4,"/sm/upload/uz/u6/by/g9/no-strings-attached-original"],["The Fighter",2010,"David O. Russell",7,"/sm/upload/am/i6/d4/hr/f81GIoNQJQX92YCaTs8wjbT0h7b"],["Fracture",2010,"Alain Tasma",2,"172370-fracture-2010-1"],["Tangled",2010,"Byron Howard, Nathan Greno",8,"25859-tangled-2010"],["Faster",2010,"George Tillman Jr.",4,"23737-faster"],["Love & Other Drugs",2010,"Edward Zwick",6,"21801-love-other-drugs"],["Harry Potter and the Deathly Hallows: Part 1",2010,"David Yates",6,"/sm/upload/u8/tj/88/3v/harry-potter-and-the-deathly-hallows-part-i-original"],["Megamind",2010,"Tom McGrath",5,"26476-megamind"],["The Social Network",2010,"David Fincher",8,"/sm/upload/nw/cm/pa/ai/sGQv3ZMZBDBnl3z42Q0mEQ5uiDe"],["Insidious",2010,"James Wan",7,"/sm/upload/te/ew/lb/gd/urAaOffVaxQzRJ8X5Z0oDqOWAjl"],["The Town",2010,"Ben Affleck",6,"/sm/upload/am/yz/8g/am/c7zMl6igI6LMBuuov0tEz7fN2EH"],["127 Hours",2010,"Danny Boyle",6,"21050-127-hours"],["Takers",2010,"John Luessenhop",3,"37633-takers"],["Arthur 3: The War of the Two Worlds",2010,"Luc Besson",4,"22170-arthur-3-the-war-of-the-two-worlds"],["Inception",2010,"Christopher Nolan",8,"/sm/upload/sv/95/s9/4j/inception"],["Grown Ups",2010,"Dennis Dugan",6,"26196-grown-ups"],["Toy Story 3",2010,"Lee Unkrich",10,"46458-toy-story-3"],["Fatal",2010,"Michaël Youn",5,"19718-fatal"],["The Karate Kid",2010,"Harald Zwart",7,"26025-the-karate-kid"],["Despicable Me",2010,"Chris Renaud, Pierre Coffin",6,"39067-despicable-me"],["Marmaduke",2010,"Tom Dey",2,"26021-marmaduke"],["Shrek Forever After",2010,"Mike Mitchell",5,"/sm/upload/el/uo/sb/5o/enqVwbUu6OX5LHq0fuk7sLT35zy"],["Iron Man 2",2010,"Jon Favreau",5,"46511-iron-man-2"],["Camping 2",2010,"Fabien Onteniente",2,"26280-camping-2"],["Undisputed III: Redemption",2010,"Isaac Florentine",3,"26317-undisputed-iii-redemption"],["How to Train Your Dragon",2010,"Dean DeBlois, Chris Sanders",9,"/sm/upload/0r/r7/c6/7e/hIXX3IRFy0InUOmYeWjvhCAgQNj"],["She's Out of My League",2010,"Jim Field Smith",4,"29416-she-s-out-of-my-league"],["The Pimp",2010,"Pascal Bourdiaux",4,"28806-the-pimp"],["Shutter Island",2010,"Martin Scorsese",8,"45409-shutter-island"],["Four Lions",2010,"Chris Morris",6,"/sm/upload/ms/43/2p/3u/xp500JNCanNW2F2Flw6jLp56M5g"],["Avatar",2009,"James Cameron",10,"/sm/upload/1p/mh/li/l2/b7nR3eKeTOwHPKmDLUWunIGasKo"],["Arthur and the Revenge of Maltazard",2009,"Luc Besson",4,"35270-arthur-and-the-revenge-of-maltazard"],["The Twilight Saga: New Moon",2009,"Chris Weitz",4,"40480-the-twilight-saga-new-moon"],["American Pie Presents: The Book of Love",2009,"John Putch",4,"35567-american-pie-presents-the-book-of-love"],["Zombieland",2009,"Ruben Fleischer",6,"39352-zombieland"],["The Invention of Lying",2009,"Ricky Gervais, Matthew Robinson",5,"/sm/upload/67/gf/vo/k9/x2CsqtcSqGcrkpMIQCUum5JDiHg"],["Neuilly Yo Mama!",2009,"Gabriel Julien-Laferrière",3,"35120-neuilly-yo-mama-"],["The Ugly Truth",2009,"Robert Luketic",4,"38696-the-ugly-truth"],["Harry Potter and the Half-Blood Prince",2009,"David Yates",6,"51385-harry-potter-and-the-half-blood-prince"],["Exam",2009,"Stuart Hazeldine",4,"32433-exam"],["The French Kissers",2009,"Riad Sattouf",6,"40019-the-french-kissers"],["The Proposal",2009,"Anne Fletcher",4,"40479-the-proposal"],["The Hangover",2009,"Todd Phillips",7,"40100-the-hangover"],["Inglourious Basterds",2009,"Quentin Tarantino",8,"41352-inglourious-basterds"],["A Prophet",2009,"Jacques Audiard",9,"/sm/upload/1e/n7/st/bb/eQpVD55Kqhx0l4HGvZasYWEMXXJ"],["Up",2009,"Pete Docter",8,"43302-up"],["Fast & Furious",2009,"Justin Lin",4,"43582-fast-furious"],["Monsters vs Aliens",2009,"Rob Letterman, Conrad Vernon",4,"42315-monsters-vs-aliens"],["17 Again",2009,"Burr Steers",4,"41276-17-again"],["District 13: Ultimatum",2009,"Patrick Alessandrin",3,"42437-district-13-ultimatum"],["(500) Days of Summer",2009,"Marc Webb",7,"39350--500-days-of-summer"],["Gran Torino",2008,"Clint Eastwood",8,"/sm/upload/il/wm/1v/to/9ip2LgCyVMdovhJqY4mttTWfyo6"],["Extreme Movie",2008,"Adam Jay Epstein, Andrew Jacobson",1,"42292-extreme-movie"],["Transporter 3",2008,"Olivier Megaton",6,"43931-transporter-3"],["Twilight",2008,"Catherine Hardwicke",4,"47469-twilight"],["Bolt",2008,"Chris Williams, Byron Howard",4,"/sm/upload/5q/da/f1/rt/6pTNDqXPPZmN6I5buVeTEnwbjn0"],["Madagascar: Escape 2 Africa",2008,"Eric Darnell, Tom McGrath",6,"46145-madagascar-escape-2-africa"],["Zack and Miri Make a Porno",2008,"Kevin Smith",5,"46306-zack-and-miri-make-a-porno"],["The Wrestler",2008,"Darren Aronofsky",8,"/sm/upload/ud/52/sl/57/huooRmB7yksJyVVSkqOgitxlCec"],["Slumdog Millionaire",2008,"Danny Boyle",8,"44613-slumdog-millionaire"],["Eden Lake",2008,"James Watkins",6,"/sm/upload/hq/28/2l/x4/tn5ldUSjZJFkmnnLdCikGjMgiGj"],["Step Brothers",2008,"Adam McKay",8,"44768-step-brothers"],["The Dark Knight",2008,"Christopher Nolan",10,"/sm/upload/78/y5/zg/ej/oefdD26aey8GPdx7Rm45PNncJdU"],["WALL·E",2008,"Andrew Stanton",9,"45994-walle"],["Camp Rock",2008,"Matthew Diamond",3,"/sm/upload/2o/jj/dd/os/2WdEnrjqB4ItGWDYrve7YuDW7On"],["Hancock",2008,"Peter Berg",6,"47474-hancock"],["The Incredible Hulk",2008,"Louis Leterrier",4,"50827-the-incredible-hulk"],["You Don't Mess with the Zohan",2008,"Dennis Dugan",4,"/sm/upload/su/vd/x1/p2/dont-mess-with-the-zohan"],["Kung Fu Panda",2008,"Mark Osborne, John Stevenson",6,"/sm/upload/wn/0t/9w/2v/mk3UyyaLyXhgIhmLji25OUPXvGR"],["Made of Honor",2008,"Paul Weiland",4,"/sm/upload/wz/uz/2g/15/b7w9BOieXq3qzwtOoXRUCNWc1Hz"],["Iron Man",2008,"Jon Favreau",7,"50825-iron-man"],["Forgetting Sarah Marshall",2008,"Nicholas Stoller",5,"46763-forgetting-sarah-marshall"],["Taken",2008,"Pierre Morel",6,"47648-taken"],["Step Up 2: The Streets",2008,"Jon M. Chu",5,"47804-step-up-2"],["The Hottie & The Nottie",2008,"Tom Putnam",1,"3515-the-hottie-the-nottie"],["Welcome to the Sticks",2008,"Dany Boon",5,"47841-welcome-to-the-sticks"],["American Pie Presents: Beta House",2007,"Andrew Waller",4,"/sm/upload/i0/yk/qh/gv/kIJKegtMoJLVvx2iSIQY6u2zfPS"],["I Am Legend",2007,"Francis Lawrence",6,"48296-i-am-legend"],["[REC]",2007,"Jaume Balagueró, Paco Plaza",5,"/sm/upload/wc/8v/37/hl/cOW5Oc3vnjD2QgK68BUvm6GGLZ4"],["Superbad",2007,"Greg Mottola",8,"47776-superbad"],["The Simpsons Movie",2007,"David Silverman",6,"2684-the-simpsons-movie"],["Harry Potter and the Order of the Phoenix",2007,"David Yates",6,"/sm/upload/wd/w4/n0/yj/g6n8G0xPnBVUIKKK41sNmbZB5h4"],["Ratatouille",2007,"Brad Bird",9,"/sm/upload/n8/rl/pc/se/jEiEU8viSb8CIIHcfprVr2V6XDz"],["Ocean's Thirteen",2007,"Steven Soderbergh",5,"51761-ocean-s-thirteen"],["Death Proof",2007,"Quentin Tarantino",7,"50621-death-proof"],["No Country for Old Men",2007,"Joel Coen, Ethan Coen",10,"/sm/upload/dr/hr/pz/ez/ehLb2SQ3djlA1FrQKbP2WO3VH09"],["Shrek the Third",2007,"Chris Miller",5,"/sm/upload/qn/3n/0d/bn/lA17Mlz8hXVZsW5Y3WuUa8KPilQ"],["28 Weeks Later",2007,"Juan Carlos Fresnadillo",6,"50972-28-weeks-later"],["Spider-Man 3",2007,"Sam Raimi",6,"/sm/upload/gi/zi/fp/69/uC2pAMjb32NIgQ1GdC1Bl6LZJc2"],["Knocked Up",2007,"Judd Apatow",5,"/sm/upload/76/de/te/sq/z4jvDMQwjc42p6zfZysYjBX7EHZ"],["Zodiac",2007,"David Fincher",9,"/sm/upload/58/tf/z6/gw/qKQIjErYaN149hZRP5Vgf8RoC7S"],["Hot Fuzz",2007,"Edgar Wright",6,"/sm/upload/xe/2y/e6/gy/4XLSKzQcE4lIgJgd71Y8UhAhxqQ"],["Taxi 4",2007,"Gérard Krawczyk",4,"50319-taxi-4"],["Bridge to Terabithia",2007,"Gábor Csupó",6,"51117-bridge-to-terabithia"],["Freedom Writers",2007,"Richard LaGravenese",6,"50896-freedom-writers"],["Rocky Balboa",2006,"Sylvester Stallone",6,"51134-rocky-balboa"],["The Pursuit of Happyness",2006,"Gabriele Muccino",7,"51061-the-pursuit-of-happyness"],["Arthur and the Invisibles",2006,"Luc Besson",4,"46649-arthur-and-the-invisibles"],["American Pie Presents: The Naked Mile",2006,"Joe Nussbaum",4,"47831-american-pie-presents-the-naked-mile"],["The Holiday",2006,"Nancy Meyers",7,"50953-the-holiday"],["Flushed Away",2006,"David Bowers, Sam Fell",4,"45132-flushed-away"],["The Prestige",2006,"Christopher Nolan",8,"51147-the-prestige"],["Idiocracy",2006,"Mike Judge",3,"48000-idiocracy"],["Little Man",2006,"Keenen Ivory Wayans",3,"47372-little-man"],["Step Up",2006,"Anne Fletcher",4,"46848-step-up"],["Click",2006,"Frank Coraci",4,"47255-click"],["Dikkenek",2006,"Olivier Van Hoofstadt",4,"47632-dikkenek"],["The Devil Wears Prada",2006,"David Frankel",6,"51712-the-devil-wears-prada"],["The Fast and the Furious: Tokyo Drift",2006,"Justin Lin",6,"46986-the-fast-and-the-furious-tokyo-drift"],["Beur Blanc Rouge",2006,"Mahmoud Zemmouri",3,"22190-beur-blanc-rouge"],["Over the Hedge",2006,"Karey Kirkpatrick, Tim Johnson",4,"47994-over-the-hedge"],["Camping",2006,"Fabien Onteniente",4,"44197-camping"],["Mission: Impossible III",2006,"J.J. Abrams",6,"51204-mission-impossible-iii"],["Scary Movie 4",2006,"David Zucker",3,"49433-scary-movie-4"],["Undisputed II: Last Man Standing",2006,"Isaac Florentine",3,"42501-undisputed-ii-last-man-standing"],["Jean-Philippe",2006,"Laurent Tuel",2,"43654-jean-philippe"],["Inside Man",2006,"Spike Lee",5,"/sm/upload/dn/nz/ds/9v/l1kkUKGrI07kOzxznPpF4WJUrJw"],["Cars",2006,"John Lasseter",9,"/sm/upload/de/kp/63/hd/dWg33ektXuHmxjSjEulwDPTWbC2"],["The Hills Have Eyes",2006,"Alexandre Aja",5,"46820-the-hills-have-eyes"],["High School Musical",2006,"Kenny Ortega",5,"45747-high-school-musical"],["Just Friends",2005,"Roger Kumble",3,"/sm/upload/lg/b2/3t/em/n7gZuqiRSjgIkyqDIiLZ20qRgoi"],["Get Rich or Die Tryin'",2005,"Jim Sheridan",5,"46586-get-rich-or-die-tryin-"],["Harry Potter and the Goblet of Fire",2005,"Mike Newell",7,"51450-harry-potter-and-the-goblet-of-fire"],["American Pie Presents: Band Camp",2005,"Steve Rash",4,"/sm/upload/gd/06/pe/ye/o0F588TQazo1gYMEAaK7vN9iB6V"],["Once Upon a Time in the Oued",2005,"Djamel Bensalah",3,"4086-once-upon-a-time-in-the-oued"],["Goal!",2005,"Danny Cannon",3,"46847-goal-the-dream-begins"],["The 40 Year Old Virgin",2005,"Judd Apatow",7,"48160-the-40-year-old-virgin"],["Transporter 2",2005,"Louis Leterrier",5,"47259-transporter-2"],["Charlie and the Chocolate Factory",2005,"Tim Burton",6,"51932-charlie-and-the-chocolate-factory"],["Camping à la ferme",2005,"Jean-Pierre Sinapi",3,"25472-camping-a-la-ferme"],["Mr. & Mrs. Smith",2005,"Doug Liman",5,"51365-mr-mrs-smith"],["Batman Begins",2005,"Christopher Nolan",7,"51784-batman-begins"],["Havoc",2005,"Barbara Kopple",5,"42885-havoc"],["The Longest Yard",2005,"Peter Segal",4,"47301-the-longest-yard"],["Madagascar",2005,"Eric Darnell, Tom McGrath",6,"/sm/upload/4g/qd/0m/h2/80MP1QuE4D8TQ0EBygGbWiWadrd"],["A Lot Like Love",2005,"Nigel Cole",5,"47460-a-lot-like-love"],["Green Street Hooligans",2005,"Lexi Alexander",3,"47505-green-street-hooligans"],["The Descent",2005,"Neil Marshall",8,"47204-the-descent"],["The Pacifier",2005,"Adam Shankman",3,"46620-the-pacifier"],["Son of the Mask",2005,"Lawrence Guterman",2,"/sm/upload/v1/cf/h2/zx/x0vfTsgoSM96YCouqsOXgP6klX9"],["Hitch",2005,"Andy Tennant",5,"47699-hitch"],["Chaos",2005,"Tony Giglio",4,"48872-chaos"],["Coach Carter",2005,"Thomas Carter",8,"48101-coach-carter"],["Ocean's Twelve",2004,"Steven Soderbergh",6,"51888-oceans-twelve"],["Million Dollar Baby",2004,"Clint Eastwood",8,"51979-million-dollar-baby"],["District B13",2004,"Pierre Morel",5,"46599-district-13"],["The Incredibles",2004,"Brad Bird",7,"46806-the-incredibles"],["Anchorman: The Legend of Ron Burgundy",2004,"Adam McKay",5,"47637-anchorman-the-legend-of-ron-burgundy"],["Spider-Man 2",2004,"Sam Raimi",9,"/sm/upload/pq/mi/kb/ck/7JtMVM58MnzxWeyubzLpXBiVnDC"],["Harry Potter and the Prisoner of Azkaban",2004,"Alfonso Cuarón",8,"/sm/upload/a3/0q/kf/h8/jUFjMoLh8T2CWzHUSjKCojI5SHu"],["Shrek 2",2004,"Andrew Adamson, Kelly Asbury, Conrad Vernon",8,"/sm/upload/g4/4m/0c/6s/rD8SvOTCCJ2VIpIV7GUwUKD1Kzc"],["Troy",2004,"Wolfgang Petersen",4,"/sm/upload/s4/d9/77/ed/edMlij7nw2NMla32xskDnzMCFBM"],["Mean Girls",2004,"Mark Waters",6,"46049-mean-girls"],["Man on Fire",2004,"Tony Scott",7,"/sm/upload/vy/z4/mq/qc/qAbRLPe8T7ehKzr1Tgo78T7ASrS"],["Kill Bill: Vol. 2",2004,"Quentin Tarantino",9,"/sm/upload/ka/7q/dh/8m/bxbX4sHZHcy81dnNs4VAVs7HXDL"],["Scooby-Doo 2: Monsters Unleashed",2004,"Raja Gosnell",3,"45679-scooby-doo-2-monsters-unleashed"],["The Chorus",2004,"Christophe Barratier",7,"/sm/upload/ag/g7/6e/ka/8nxYEvYYRYNF9JY32eDLgJlZdpl"],["Eternal Sunshine of the Spotless Mind",2004,"Michel Gondry",9,"/sm/upload/ay/bp/kl/1y/uBfQ7IGpi0jXSP3GPCzp9Pzm10v"],["The Girl Next Door",2004,"Luke Greenfield",2,"46081-the-girl-next-door-2004"],["The 11 Commandments",2004,"François Desagnat, Thomas Sorriaux",5,"40754-the-11-commandments"],["RRRrrrr!!!",2004,"Alain Chabat",6,"38203-rrrrrrr-"],["Barbershop 2: Back in Business",2004,"Kevin Rodney Sullivan",4,"38488-barbershop-2-back-in-business"],["Saw",2004,"James Wan",6,"/sm/upload/qd/18/jq/1b/oFl8U5Mzohs6z8mL8KT4Gjoiirm"],["The Lord of the Rings: The Return of the King",2003,"Peter Jackson",10,"/sm/upload/zs/nt/u4/uz/xieWkPAgQrrk5wOyncayPd65hrp"],["Ruby & Quentin",2003,"Francis Veber",3,"48092-ruby-quentin"],["Scary Movie 3",2003,"David Zucker",4,"49434-scary-movie-3"],["Kill Bill: Vol. 1",2003,"Quentin Tarantino",9,"/sm/upload/sw/w2/ep/v4/9O50TVszkz0dcP5g6Ej33UhR7vw"],["Love Actually",2003,"Richard Curtis",5,"51602-love-actually"],["Lost in Translation",2003,"Sofia Coppola",8,"/sm/upload/th/b5/6c/gl/5T8VvuFTdaawKLJk34i69Utaw7o"],["Stitch! The Movie",2003,"Bobs Gannaway, Tony Craig",4,"42274-stitch-the-movie"],["American Wedding",2003,"Jesse Dylan",4,"47833-american-wedding"],["Bad Boys II",2003,"Michael Bay",4,"47473-bad-boys-ii"],["2 Fast 2 Furious",2003,"John Singleton",5,"51536-2-fast-2-furious"],["The Italian Job",2003,"F. Gary Gray",6,"46947-the-italian-job"],["Finding Nemo",2003,"Andrew Stanton",8,"2705-finding-nemo"],["Bruce Almighty",2003,"Tom Shadyac",6,"51749-bruce-almighty"],["Memories of Murder",2003,"Bong Joon Ho",10,"/sm/upload/84/xt/e8/mw/gawnVe9cFowdoDLo9Pok12NTw39"],["I, Cesar",2003,"Richard Berry",4,"6543-i-cesar"],["Taxi 3",2003,"Gérard Krawczyk",4,"50320-taxi-3"],["The Lord of the Rings: The Two Towers",2002,"Peter Jackson",10,"51929-the-lord-of-the-rings-the-two-towers"],["Catch Me If You Can",2002,"Steven Spielberg",8,"51484-catch-me-if-you-can"],["Half Past Dead",2002,"Don Michael Paul",2,"46482-half-past-dead"],["Harry Potter and the Chamber of Secrets",2002,"Chris Columbus",7,"/sm/upload/rj/yc/zl/ex/g8IQhqYYLERU0UxjVaySP46PFEZ"],["Jackass: The Movie",2002,"Jeff Tremaine",4,"/sm/upload/of/ey/nb/95/iCB8mLrRoMp6sFta1qgZyZgmu9W"],["28 Days Later",2002,"Danny Boyle",8,"/sm/upload/qr/28/nz/3f/xaYdxi1PBEAYvqknvAmMPK5Eff3"],["The Transporter",2002,"Corey Yuen, Louis Leterrier",5,"49510-the-transporter"],["Phone Booth",2002,"Joel Schumacher",5,"/sm/upload/ma/ho/yr/w8/xIaUpPok8WFnr79EAvgtGsIaJzV"],["8 Mile",2002,"Curtis Hanson",7,"/sm/upload/sx/ew/do/rx/dXzTrKwpbLpCqn8O70FUUhNbYQT"],["Paid in Full",2002,"Charles Stone III",5,"44147-paid-in-full"],["xXx",2002,"Rob Cohen",5,"48025-xxx"],["Undisputed",2002,"Walter Hill",5,"42620-undisputed"],["Lilo & Stitch",2002,"Chris Sanders, Dean DeBlois",5,"45204-lilo-stitch"],["Scooby-Doo",2002,"Raja Gosnell",4,"/sm/upload/35/mj/25/xd/yn1dLaEcvUHIgxmAu6NY5ho6CnJ"],["Punch-Drunk Love",2002,"Paul Thomas Anderson",8,"47914-punch-drunk-love"],["City of God",2002,"Fernando Meirelles",8,"51523-city-of-god"],["Spider-Man",2002,"Sam Raimi",8,"51561-spider-man"],["Shooting Stars",2002,"Fabien Onteniente",2,"40366-shooting-stars-2002"],["Barbershop",2002,"Tim Story",4,"46063-barbershop"],["The Race",2002,"Djamel Bensalah",2,"18637-the-race"],["Panic Room",2002,"David Fincher",7,"/sm/upload/f2/vz/w1/kw/cLwfIWHGjXXrtVgaww33RbIR4Dh"],["Ice Age",2002,"Chris Wedge",7,"51670-ice-age"],["Asterix & Obelix: Mission Cleopatra",2002,"Alain Chabat",7,"50024-asterix-obelix-mission-cleopatra"],["How High",2001,"Jesse Dylan",4,"47761-how-high"],["A Beautiful Mind",2001,"Ron Howard",7,"51648-a-beautiful-mind"],["The Three Kings",2001,"Didier Bourdon, Bernard Campan",5,"40442-the-three-kings"],["The Lord of the Rings: The Fellowship of the Ring",2001,"Peter Jackson",10,"/sm/upload/3t/vq/0u/m6/1tX9ZlgVvWjAQhMs1vAfsYpi7VK"],["Not Another Teen Movie",2001,"Joel Gallen",5,"45337-not-another-teen-movie"],["Ocean's Eleven",2001,"Steven Soderbergh",7,"51890-oceans-eleven-2001"],["Harry Potter and the Philosopher's Stone",2001,"Chris Columbus",7,"/sm/upload/5t/cj/6w/6e/harrypotter2"],["Monsters, Inc.",2001,"Pete Docter",9,"/sm/upload/r0/m8/t4/gs/7m1wKo1rM9QL5DMJCAs66bDQVYC"],["Training Day",2001,"Antoine Fuqua",7,"50580-training-day"],["American Pie 2",2001,"J.B. Rogers",5,"50101-american-pie-2"],["Scary Movie 2",2001,"Keenen Ivory Wayans",4,"49442-scary-movie-2"],["Baby Boy",2001,"John Singleton",6,"41781-baby-boy"],["The Fast and the Furious",2001,"Rob Cohen",6,"46813-the-fast-and-the-furious"],["Mulholland Drive",2001,"David Lynch",10,"/sm/upload/kv/7n/p8/tv/fMC8JBWx2VjsJ53JopAcFjqmlYv"],["Amélie",2001,"Jean-Pierre Jeunet",9,"/sm/upload/ly/0v/ey/u7/pM20xF4WFyX7G3ie0YBXFp75aEC"],["Shrek",2001,"Andrew Adamson, Vicky Jenson",8,"51344-shrek"],["Yamakasi",2001,"Julien Seri, Ariel Zeitoun",3,"48171-yamakasi"],["Donnie Darko",2001,"Richard Kelly",8,"/sm/upload/ye/jq/f3/22/nmb4QhCRmdfNP6rgb81yUFgI83l"],["The Family Man",2000,"Brett Ratner",7,"48522-the-family-man"],["Dude, Where's My Car?",2000,"Danny Leiner",2,"47562-dude-where-s-my-car-"],["How the Grinch Stole Christmas",2000,"Ron Howard",6,"47553-the-grinch"],["Meet the Parents",2000,"Jay Roach",5,"50937-meet-the-parents"],["Snatch",2000,"Guy Ritchie",8,"/sm/upload/6p/tf/oh/ao/on9JlbGEccLsYkjeEph2Whm1DIp"],["Loser",2000,"Amy Heckerling",3,"46032-loser"],["Scary Movie",2000,"Keenen Ivory Wayans",6,"49443-scary-movie"],["Shaft",2000,"John Singleton",4,"51627-shaft"],["Big Momma's House",2000,"Raja Gosnell",4,"/sm/upload/v0/q8/y0/fn/bse0uwxF6daKzDbxZki1SYRNZkI"],["Mission: Impossible II",2000,"John Woo",5,"/sm/upload/67/p1/1d/1m/MnK1Kn8cFcORYT8pIIexPUwLfW"],["Requiem for a Dream",2000,"Darren Aronofsky",7,"/sm/upload/lv/4b/f2/zj/muym4jTjdLx7E6as09d1wlC3sOB"],["Taxi 2",2000,"Gérard Krawczyk",4,"50322-taxi-2"],["Scream 3",2000,"Wes Craven",3,"49453-scream-3"],["American Psycho",2000,"Mary Harron",8,"/sm/upload/5b/u9/av/il/ecoY7zJL6Ub3URP1oPhPfGflEjV"],["Magnolia",1999,"Paul Thomas Anderson",9,"51728-magnolia"],["Toy Story 2",1999,"John Lasseter",8,"51289-toy-story-2"],["Fight Club",1999,"David Fincher",8,"51568-fight-club"],["The Sixth Sense",1999,"M. Night Shyamalan",8,"51407-the-sixth-sense"],["Eyes Wide Shut",1999,"Stanley Kubrick",9,"51717-eyes-wide-shut"],["American Pie",1999,"Paul Weitz",6,"50521-american-pie"],["Notting Hill",1999,"Roger Michell",5,"/sm/upload/pa/ej/k3/ft/notting-hill"],["10 Things I Hate About You",1999,"Gil Junger",6,"49047-10-things-i-hate-about-you"],["The Matrix",1999,"Lana Wachowski, Lilly Wachowski",10,"51518-the-matrix"],["She's All That",1999,"Robert Iscove",4,"46345-she-s-all-that"],["The Blair Witch Project",1999,"Daniel Myrick, Eduardo Sánchez",3,"50159-the-blair-witch-project"],["There's Something About Mary",1998,"Peter Farrelly, Bobby Farrelly",6,"51573-theres-something-about-mary"],["Mulan",1998,"Tony Bancroft, Barry Cook",8,"/sm/upload/yz/dm/zk/5z/5vG3XyQNxOkl2Qd7D8MzMoY6sm2"],["The Truman Show",1998,"Peter Weir",8,"/sm/upload/xx/io/jp/45/the-truman-show"],["The Dinner Game",1998,"Francis Veber",8,"47176-the-dinner-game"],["Taxi",1998,"Gérard Pirès",6,"50324-taxi"],["Ring",1998,"Hideo Nakata",5,"50155-ring-1998"],["The Big Lebowski",1998,"Joel Coen",8,"51935-the-big-lebowski"],["Scream 2",1997,"Wes Craven",6,"/sm/upload/ju/sr/4r/t3/c5AyWNWooMGkJXlqLwmPQCjUwHt"],["Good Will Hunting",1997,"Gus Van Sant",7,"51621-good-will-hunting"],["I Know What You Did Last Summer",1997,"Jim Gillespie",5,"49638-i-know-what-you-did-last-summer"],["Perfect Blue",1997,"Satoshi Kon",8,"46175-perfect-blue"],["Crack 6T",1997,"Jean-François Richet",1,"19893-crack-6t"],["Men in Black",1997,"Barry Sonnenfeld",6,"51514-men-in-black"],["The Fifth Element",1997,"Luc Besson",5,"2699-the-fifth-element"],["Liar Liar",1997,"Tom Shadyac",6,"/sm/upload/fq/hq/vj/re/qd8VcWKrE4cNfInl9Osb8o8h9KP"],["Scream",1996,"Wes Craven",9,"49455-scream"],["The Best Job in the World",1996,"Gérard Lauzier",4,"24795-le-plus-beau-metier-du-monde"],["Should Not!...",1996,"Gérard Jugnot",4,"24340-should-not"],["Jingle All the Way",1996,"Brian Levant",5,"47313-jingle-all-the-way"],["Space Jam",1996,"Joe Pytka",5,"/sm/upload/2r/nv/5b/ef/bJhVLribUKCrKv1h1WFqv4QmRWM"],["Escape from L.A.",1996,"John Carpenter",6,"46585-escape-from-l-a-"],["The Cable Guy",1996,"Ben Stiller",4,"/sm/upload/sf/si/bk/p8/ttHmmQwMixZHxME6nEz34AOS5Ek"],["Mission: Impossible",1996,"Brian De Palma",8,"51206-mission-impossible"],["Fargo",1996,"Joel Coen",8,"51781-fargo"],["Don't Be a Menace to South Central While Drinking Your Juice in the Hood",1996,"Paris Barclay",4,"46067-don-t-be-a-menace-to-south-central-while-drinking-your-jui"],["The Three Brothers",1995,"Bernard Campan, Didier Bourdon",7,"26844-the-three-brothers"],["Toy Story",1995,"John Lasseter",9,"51290-toy-story"],["Se7en",1995,"David Fincher",10,"51345-se7en"],["Rai",1995,"Thomas Gilou",3,"24081-rai"],["La Haine",1995,"Mathieu Kassovitz",8,"51684-la-haine"],["Die Hard With a Vengeance",1995,"John McTiernan",8,"50962-die-hard-with-a-vengeance"],["Friday",1995,"F. Gary Gray",6,"46040-friday"],["Bad Boys",1995,"Michael Bay",6,"46870-bad-boys"],["The Usual Suspects",1995,"Bryan Singer",8,"51495-the-usual-suspects"],["Little Indian, Big City",1994,"Hervé Palud",4,"45265-little-indian-big-city"],["Dumb and Dumber",1994,"Peter Farrelly",6,"/sm/upload/72/oe/b4/no/st4P2TtPrAfNwu8HLXoPsPPii42"],["Léon: The Professional",1994,"Luc Besson",6,"/sm/upload/6x/vq/25/fy/gE8S02QUOhVnAmYu4tcrBlMTujz"],["The Shawshank Redemption",1994,"Frank Darabont",8,"/sm/upload/7l/hn/46/uz/zGINvGjdlO6TJRu9wESQvWlOKVT"],["The Mask",1994,"Chuck Russell",6,"51298-the-mask"],["Forrest Gump",1994,"Robert Zemeckis",9,"2704-forrest-gump"],["The Lion King",1994,"Roger Allers, Rob Minkoff",9,"47677-the-lion-king"],["Pulp Fiction",1994,"Quentin Tarantino",8,"51444-pulp-fiction"],["Above the Rim",1994,"Jeff Pollack",2,"39871-above-the-rim"],["Ace Ventura: Pet Detective",1994,"Tom Shadyac",6,"49922-ace-ventura-pet-detective"],["Cool Runnings",1993,"Jon Turteltaub",5,"51288-cool-runnings"],["Jurassic Park",1993,"Steven Spielberg",9,"/sm/upload/1g/zz/ez/d8/yyCKYaW908ZbpexpnBJ3p8o87HA"],["Menace II Society",1993,"Allen Hughes, Albert Hughes",7,"47084-menace-ii-society"],["Groundhog Day",1993,"Harold Ramis",8,"51914-groundhog-day"],["Home Alone 2: Lost in New York",1992,"Chris Columbus",4,"/sm/upload/i5/04/e8/7t/home%20alone%202"],["Aladdin",1992,"John Musker, Ron Clements",6,"/sm/upload/n3/26/lb/e2/trm94WPjW5ApKulhFvuRm5cT8KQ"],["Army of Darkness",1992,"Sam Raimi",5,"/sm/upload/a7/6d/2x/pn/z7jxLTbnDx4tmLprfClKoUvOPmF"],["Alien³",1992,"David Fincher",6,"47888-alien"],["Wayne's World",1992,"Penelope Spheeris",6,"47552-wayne-s-world"],["Reservoir Dogs",1992,"Quentin Tarantino",8,"/sm/upload/u0/4o/op/yx/g7spS2Y4SZoQoC6Hn7zoqEqdYqR"],["Juice",1992,"Ernest R. Dickerson",5,"41801-juice"],["Point Break",1991,"Kathryn Bigelow",6,"51157-point-break"],["Terminator 2: Judgment Day",1991,"James Cameron",10,"51776-terminator-2-judgment-day"],["Une époque formidable",1991,"Gérard Jugnot",5,"15437-une-epoque-formidable"],["Thelma & Louise",1991,"Ridley Scott",9,"/sm/upload/wt/r4/hc/iz/pnzuLoE52EiTfjfqRex2uTkH7LB"],["Boyz n the Hood",1991,"John Singleton",7,"51474-boyz-n-the-hood"],["The Professional Secrets of Dr. Apfelgluck",1991,"Stéphane Clavier, Mathias Ledoux, Thierry Lhermitte, Hervé Palud, Alessandro Capone",3,"58928-the-professional-secrets-of-dr-apfelgluck"],["The Silence of the Lambs",1991,"Jonathan Demme",10,"51782-the-silence-of-the-lambs"],["New Jack City",1991,"Mario Van Peebles",5,"45742-new-jack-city"],["Rocky V",1990,"John G. Avildsen",6,"51081-rocky-v"],["Home Alone",1990,"Chris Columbus",6,"/sm/upload/e6/mn/oi/ky/8IWPBT1rkAaI8Kpk5V3WfQRklJ7"],["GoodFellas",1990,"Martin Scorsese",10,"51383-goodfellas"],["Die Hard 2",1990,"Renny Harlin",6,"/sm/upload/f1/gp/j4/xi/zSgL998DXaljsCmwQuwDM8Ak4rV"],["Days of Thunder",1990,"Tony Scott",5,"/sm/upload/x4/g7/aj/wl/6L71vd5WDVIe5rGTxi9mYgGFKZj"],["Back to the Future Part III",1990,"Robert Zemeckis",6,"51856-back-to-the-future-part-iii"],["Back to the Future Part II",1989,"Robert Zemeckis",8,"51886-back-to-the-future-part-ii"],["A Grand Day Out",1989,"Nick Park",7,"51587-a-grand-day-out"],["Kickboxer",1989,"David Worth, Mark DiSalle",5,"46429-kickboxer"],["sex, lies, and videotape",1989,"Steven Soderbergh",7,"51052-sex-lies-and-videotape"],["The Naked Gun: From the Files of Police Squad!",1988,"David Zucker",6,"27284-the-naked-gun"],["Akira",1988,"Katsuhiro Otomo",8,"/sm/upload/xk/25/lu/0m/mi2Axov7Hy20wieoGfrbqDWLjSr"],["Die Hard",1988,"John McTiernan",8,"51556-die-hard"],["Coming to America",1988,"John Landis",6,"46999-coming-to-america"],["Who Framed Roger Rabbit",1988,"Robert Zemeckis",7,"51296-who-framed-roger-rabbit"],["Beetlejuice",1988,"Tim Burton",7,"/sm/upload/rs/wk/3i/nt/gWnW7vxm8yr01TVLQhL4aI02orp"],["Life Is a Long Quiet River",1988,"Étienne Chatiliez",4,"49423-life-is-a-long-quiet-river"],["Evil Dead II",1987,"Sam Raimi",8,"/sm/upload/p9/tg/s4/ca/dxbIRmIo0rN5R6WGvxnJuUJPh3t"],["Aliens",1986,"James Cameron",8,"51445-aliens"],["Ferris Bueller's Day Off",1986,"John Hughes",7,"47219-ferris-bueller-s-day-off"],["Rocky IV",1985,"Sylvester Stallone",6,"51082-rocky-iv"],["After Hours",1985,"Martin Scorsese",8,"/sm/upload/2z/7c/vx/lo/qpr5tRmvyx4rbv1gKMKbW1v5JUC"],["Back to the Future",1985,"Robert Zemeckis",10,"51945-back-to-the-future"],["The Breakfast Club",1985,"John Hughes",8,"50518-the-breakfast-club"],["Beverly Hills Cop",1984,"Martin Brest",6,"/sm/upload/7h/a5/tr/ae/s7n0rS2Ff85SuSpqYG3ndkmdQf4"],["A Nightmare on Elm Street",1984,"Wes Craven",7,"51708-a-nightmare-on-elm-street"],["The Terminator",1984,"James Cameron",8,"/sm/upload/g2/2g/f0/6b/the-terminator-original"],["Gremlins",1984,"Joe Dante",6,"51226-gremlins"],["Indiana Jones and the Temple of Doom",1984,"Steven Spielberg",7,"51963-indiana-jones-and-the-temple-of-doom"],["Scarface",1983,"Brian De Palma",8,"51939-scarface"],["Return of the Jedi",1983,"Richard Marquand",6,"/sm/upload/88/lu/ak/8v/5wDrNqePjb5SOucrWQwiFu340vv"],["Santa Claus Is a Stinker",1982,"Jean-Marie Poiré",6,"42924-santa-claus-is-a-stinker"],["Fast Times at Ridgemont High",1982,"Amy Heckerling",4,"/sm/upload/ou/6a/j4/uh/lvEenO2CikD4Zo3rFK1flAU99Pr"],["Blade Runner",1982,"Ridley Scott",9,"/sm/upload/85/io/38/dz/vfzE3pjE5G7G7kcZWrA3fnbZo7V"],["The Thing",1982,"John Carpenter",9,"/sm/upload/t3/qn/vs/p5/s5fH3GqFcHbi2F0NSBSh4KRNTc0"],["Rocky III",1982,"Sylvester Stallone",6,"/sm/upload/bo/kj/30/pg/eX2RbfTV5figCysWEmC6ubmXIgm"],["The School Teacher",1981,"Claude Berri",5,"12753-le-maitre-decole"],["The Evil Dead",1981,"Sam Raimi",7,"/sm/upload/c7/4g/ae/zn/7cpSdCrBY7UhiygkcP57dpixXsW"],["Raiders of the Lost Ark",1981,"Steven Spielberg",8,"51965-raiders-of-the-lost-ark"],["Escape from New York",1981,"John Carpenter",7,"/sm/upload/ft/7g/e0/y0/50aa3ZKcDF0c3r6nqY5I4jP1xnp"],["Thief",1981,"Michael Mann",8,"45224-thief"],["The Elephant Man",1980,"David Lynch",8,"50653-the-elephant-man"],["Airplane!",1980,"Jerry Zucker, David Zucker, Jim Abrahams",7,"51339-airplane-"],["The Shining",1980,"Stanley Kubrick",9,"/sm/upload/7s/m2/bw/d0/caoYMcjUamGoBVy65i1AHJBvdzw"],["The Empire Strikes Back",1980,"Irvin Kershner",9,"/sm/upload/mp/pz/lf/2i/7BuH8itoSrLExs2YZSsM01Qk2no"],["The Under-Gifted",1980,"Claude Zidi",6,"6405-the-under-gifted"],["Rocky II",1979,"Sylvester Stallone",6,"51089-rocky-ii"],["Alien",1979,"Ridley Scott",10,"/sm/upload/8v/f1/qw/aa/bg7K6VtUG7Ew70gQj6SSroD5d4R"],["Halloween",1978,"John Carpenter",9,"60298-halloween"],["Saturday Night Fever",1977,"John Badham",4,"/sm/upload/40/f2/pd/ql/12Ol9OqHzpXzIp5MKfw8dDkm8kf"],["Star Wars",1977,"George Lucas",8,"2706-star-wars"],["Suspiria",1977,"Dario Argento",9,"44900-suspiria"],["Rocky",1976,"John G. Avildsen",8,"51090-rocky"],["Carrie",1976,"Brian De Palma",5,"/sm/upload/2c/5d/69/bc/uc3OvgmbnYaS5Y0BOjSmC1EmSz1"],["Taxi Driver",1976,"Martin Scorsese",10,"51947-taxi-driver"],["Jaws",1975,"Steven Spielberg",9,"51542-jaws"],["Going Places",1974,"Bertrand Blier",5,"49525-going-places"],["2001: A Space Odyssey",1968,"Stanley Kubrick",8,"51987-2001-a-space-odyssey"],["Psycho",1960,"Alfred Hitchcock",10,"51578-psycho"],["Breathless",1960,"Jean-Luc Godard",5,"51787-breathless"],["12 Angry Men",1957,"Sidney Lumet",10,"51700-12-angry-men"],["Rear Window",1954,"Alfred Hitchcock",9,"51552-rear-window"],["Rope",1948,"Alfred Hitchcock",7,"50954-rope"]];   // [titre, année, réalisateur, note (0-10), affiche]
const MUSIC_DATA = [["I Mean It (feat. Remo)","G-Eazy, Remo the Hitmaker","6jmTHeoWvBaSrwWttr8Xvu","bdfe4efd674482cf5ac88c99","CxnaPa8ohmM"],["Sucker for Pain (with Wiz Khalifa, Imagine Dragons, Logic & Ty Dolla $ign feat. X Ambassadors)","Lil Wayne, Wiz Khalifa, Imagine Dragons, X Ambassadors, Logic, Ty Dolla $ign","7qUJQSNX9QNf46CC6FgH66","cb4ec52c48a6b071ed2ab6bc","-59jGD4WrmE"],["The Hills","The Weeknd","7fBv7CLKzipRk6EC6TWHOB","7fcead687e99583072cc217b","yzTuBuRdAyA"],["23","Mike WiLL Made-It, Miley Cyrus, Wiz Khalifa, Juicy J","20FZrLl9zSbO9b3DhaqO6M","44b72761419fcedcf38998b7","bbEoRnaOIbs"],["Come & Get It","Selena Gomez","6LoQHIo74tOzQ8EsLEkhgF","0e36690135fa1a30d048e604","n-D1EB74Ckg"],["Good For You","Selena Gomez, A$AP Rocky","5xdVqHtFS0eLuNp4Z8Wbpa","6bc7473df6c9d1fd90972e84","1TsVjvEkc4s"],["Just Dance","Lady Gaga, Colby O'Donis","2x7MyWybabEz6Y6wvHuwGE","613aaa3ae566d9f36008aed0","2Abk1jAONjw"],["Poker Face","Lady Gaga","5R8dQOPq8haW94K7mgERlO","613aaa3ae566d9f36008aed0","bESGLojNYSo"],["Bad Romance","Lady Gaga","0SiywuOBRcynK0uKGWdCnn","5c9890c0456a3719eeecd8aa","qrO4YZeyl0I"],["Telephone","Lady Gaga, Beyoncé","4TCL0qqKyqsMZml0G3M9IM","5c9890c0456a3719eeecd8aa","EVBsypHzF3U"],["Bloody Mary","Lady Gaga","53jnnqFSRGMDB9ADrNriCA","a5d31644260279be8d0c46c0","VFwmKL5OL-Q"],["Applause","Lady Gaga","5ka2ajep9OAvU5Sgduhiex","7da123c944790bfab54b2522","pco91kroVgQ"],["Black Eyes","Bradley Cooper","4HUqrGAZ5f0gHRor7z9BFc","e2d156fdc691f57900134342","DqlUt0Ff70Q"],["Shallow","Lady Gaga, Bradley Cooper","2VxeLyX666F8uXCJ0dZF8B","e2d156fdc691f57900134342","bo_efYhYU2A"],["I'll Never Love Again - Film Version","Lady Gaga, Bradley Cooper","4A7EkKijzA4ryEoCRWJzdG","e2d156fdc691f57900134342","52nfjRzIaj8"],["I Kissed A Girl","Katy Perry","14iN3o8ptQ8cFVZTEmyQRV","3f97d4244eff5852477d9ee0","tAp9BKosZXs"],["Teenage Dream","Katy Perry","5xxRe0IrwEE7JgksMnebIy","5a12c445148279c139fc49f9","98WtmW-lfeE"],["Last Friday Night (T.G.I.F.)","Katy Perry","0U0xVhqSrYKHT9sBds6z8s","5a12c445148279c139fc49f9","KlyXNRrsk4A"],["California Gurls","Katy Perry, Snoop Dogg","21itC2Lu9P9FSxcToyeNGt","5a12c445148279c139fc49f9","F57P9C4SAW4"],["Firework","Katy Perry","5F4uYbI6GOazvkqVWTFpxx","5a12c445148279c139fc49f9","QGJuMBdaqIw"],["Roar","Katy Perry","27tNWlhdAryQY04Gb2ZhUI","1e9a057052d59004caf47e22","CevxZvSJLk8"],["Birthday","Katy Perry","1NOZvdCovG42qQV7ftVD5d","1e9a057052d59004caf47e22","jqYxyd1iSNk"],["Dark Horse","Katy Perry, Juicy J","4jbmgIyjGoXjY01XxatOx6","1e9a057052d59004caf47e22","0KSOMA3QBU0"],["Starships","Nicki Minaj","2EBCVPNAG46nbgs6jXPGvv","ef9ad61e2a4f15606fd4ab15","SeIJmciN8mo"],["Only","Nicki Minaj, Drake, Lil Wayne, Chris Brown","6AD3gisKJrvj1STmAIRzHg","6fc944ef0967cf846c7539d6","zXtsGAkyeIo"],["Chun-Li","Nicki Minaj","0kCakXs4r2adpGE43JXsFg","d0c7233f8b6511bf7e09de2b","Wpm07-BGJnE"],["Bang Bang","Jessie J, Ariana Grande, Nicki Minaj","0puf9yIluy9W0vpMEUoAnN","930f686fe89425c7b6bf9a7d","0HDdjwpPM3Y"],["Price Tag","Jessie J, B.o.B","2fTsFCKRFQ5M0igJgabnLA","7805aebd5a39023d553ada3a","qMxX-QOV9tI"],["Domino","Jessie J","2fQxE0jVrjNMT9oJAXtSJR","7805aebd5a39023d553ada3a","UJtB55MaoD0"],["Tusa","KAROL G, Nicki Minaj","0dKg2vGC1hFqcK5LGTaKzX","ae28c8f2748587cc2a33d6c2","tbneQDc2H3I"],["Trap Queen","Fetty Wap","0TzxcB6dK46vgXZT2P8qeR","02928b251e41844f5186920e","i_kF4zLNKio"],["679 (feat. Monty)","Fetty Wap, Monty","1mCA6ZasOlv1MOD16f0VhL","02928b251e41844f5186920e","Pzz4Z-O7710"],["My Way (feat. Monty)","Fetty Wap, Monty","0UHlD4tIdUSDAyM1AAfMBA","02928b251e41844f5186920e","YS-5oD2Y4Wk"],["Can't Stay (feat. T.I.)","Ty Dolla $ign, T.I.","2Fqe6xZSDyIwTXs3VIbmYN","b2a0b92286afeb896d63dad0","p5hlAWC7ChA"],["Wavy (feat. Joe Moses)","Ty Dolla $ign, Joe Moses","6oECOh5nAYmxz4EiYhjsPi","bf5e5daa0d56045c1bff8778","Uc-apOIYbFM"],["Westside","Ty Dolla $ign","2hkBrU5mjoielqu0SFW3DX","bf5e5daa0d56045c1bff8778","BIdOgqrUAaA"],["Spicy (feat. Post Malone)","Ty Dolla $ign, Post Malone","5IUtvfNvOyVYZUa6AJFrnP","0c2d3dcb6d1f8c0ffbe2cabd","meDRHqG2djI"],["Or Nah (feat. The Weeknd, Wiz Khalifa & DJ Mustard) - Remix","Ty Dolla $ign, The Weeknd, Wiz Khalifa, Mustard","7t2bFihaDvhIrd2gn2CWJO","1c04efd2804b16cf689de7f0","TUj0otkJEBo"],["Nights Like This (feat. Ty Dolla $ign)","Kehlani, Ty Dolla $ign","6ZRuF2n1CQxyxxAAWsKJOy","f882c60f16e308b5e51fbccf","I99qCuWx1mI"],["Talk Dirty (feat. 2 Chainz)","Jason Derulo, 2 Chainz","31JwK4iHCf75rnQWoMPU5t","64d58f6e7672baecc8972806","RbtPXFlZlHg"],["Trumpets","Jason Derulo","1QdpGjYp035BXJB7qPAzl9","64d58f6e7672baecc8972806","oOAfz0H4f00"],["Wiggle (feat. Snoop Dogg)","Jason Derulo, Snoop Dogg","4B4zDmbHdkXZ1wUJv1yKFy","64d58f6e7672baecc8972806","hiP14ED28CA"],["Bubblegum (feat. Tyga)","Jason Derulo, Tyga","1EujTZPE2yBYbbwu2vWXvr","64d58f6e7672baecc8972806","Ekw4OAEO7Sg"],["Kama Sutra (feat. Kid Ink)","Jason Derulo, Kid Ink","6776Z2AyGoYRpMdkYIcLOU","64d58f6e7672baecc8972806","Jxkh1SxBV10"],["Whatcha Say","Jason Derulo","7xkQdy0cy5ymoWT7nedvLz","293e8055dd8814fcdf4742f7","pBI3lc18k8Q"],["Swalla (feat. Nicki Minaj & Ty Dolla $ign)","Jason Derulo, Nicki Minaj, Ty Dolla $ign","6kex4EBAj0WHXDKZMEJaaF","b98e54a5bf5bc17964c93c7e","NGLxoKOvzu4"],["Rack City","Tyga","21nFIDqoD1L7ELsprVSzOR","b0e97e7b9e4d143743612dd2","AE3yia1AJeQ"],["Ayo","Chris Brown, Tyga","0k6DnZMLoEUH8NGD5zh2SE","aee727756d5fec0de96dc6d9","zKCrSN9oXgQ"],["Bitches N Marijuana (feat. ScHoolboy Q)","Chris Brown, Tyga, ScHoolboy Q","3PiLfzEXHrvT1oJKR8PAJt","aee727756d5fec0de96dc6d9","n9RIWKIwb-8"],["Legendary (feat. Gunna)","Tyga, Gunna","4yn0ftNHQSwsWE81h33y4K","d38a9c6e4fcfeb128f111f6b","c1g_3NOI8CI"],["Taste (feat. Offset)","Tyga, Offset","5IaHrVsrferBYDm0bDyABy","a4d73b32e40487605c73cffe","LjxulQ1bEWg"],["Ice Cream Man","Tyga","6ZA3Q8Dj5BrnmOsT300DCh","b39f0914ef5920d743c6f35f","TYSM8GAFR5I"],["Loco Contigo (feat. J. Balvin & Tyga)","DJ Snake, J Balvin, Tyga","6osaMSJh9NguagEDQcZaKx","caf82abb2338880577e472be","zNl00mOSnJI"],["Let Me Love You","DJ Snake, Justin Bieber","0lYBSQXN6rCTvUZvg9S0lU","212d776c31027c511f0ee3bc","euCqAq6BRa4"],["What Do You Mean?","Justin Bieber","4B0JvthVoAAuygILe3n4Bs","f46b9d202509a8f7384b90de","DK_0jXPuIr0"],["Sorry","Justin Bieber","09CtPGIpYB4BrO8qb1RGsF","f46b9d202509a8f7384b90de","fRh_vgS2dFE"],["Where Are Ü Now","Skrillex, Diplo, Justin Bieber","0n8ob8S72lvznoVfiwz4qL","f46b9d202509a8f7384b90de","nntGTK2Fhb0"],["STAY (with Justin Bieber)","The Kid LAROI, Justin Bieber","5PjdY0CKGZdEuoNab3yDmX","8e6551a2944764bc8e33a960","kTJczUoc26U"],["Bad Intentions","Niykee Heaton, Migos, OG Parker","5W3UniuRMkHHIpaiQo1hAW","4217e3cb1cc0a8166902b86f","5uUApCWptYE"],["Misery","Maroon 5","0RZyUsKfiC7MtiGKatCtGc","9585ff55fff75c5c07a619cb","6g6g2mvItp4"],["Moves Like Jagger - Studio Recording From \"The Voice\" Performance","Maroon 5, Christina Aguilera","7pYfyrMNPn3wtoCyqcTVoI","9585ff55fff75c5c07a619cb","iEPTlhBmwRg"],["One More Night","Maroon 5","5sSjntBXVmtJLCcMlJP5Qb","855cda68658945a764dfb01d","fwK7ggA3-bU"],["Payphone","Maroon 5, Wiz Khalifa","1XGmzt0PVuFgQYYnV2It7A","fc8633e22a7dba6aab817bff","KRaWnd3LJfs"],["Animals","Maroon 5","2bL2gyO6kBdLkNSkxXNh6x","442b53773d50e1b5369bb16c","qpgTC9MDx1o"],["Sugar","Maroon 5","2iuZJX9X9P0GKaE93xcPjk","442b53773d50e1b5369bb16c","09R8_2nJtjg"],["Maps","Maroon 5","4gbVRS8gloEluzf0GzDOFc","442b53773d50e1b5369bb16c","NmugSMBh_iI"],["Dynamite","Taio Cruz","2CEgGE6aESpnmtfiZwYlbV","66c3eb32692a0ae487079cf1","VUjdiDeJ0xg"],["Hangover","Taio Cruz, Flo Rida","5pmL3RzOy3IvGFaSDi4hZL","27656009177a4273a62c758a","dLhFDYQHDQY"],["Higher","Taio Cruz, Kylie Minogue","6AxCr5G75R5rqyNCYWVpTo","c434f98f315c12a0f4d049a0","KRBS5WZMdik"],["Break Your Heart","Taio Cruz","7ElF5zxOwYP4qVSWVvse3W","66c3eb32692a0ae487079cf1","y_SI2EDM6Lo"],["Bumpy Ride","Mohombi","71R6zJsrF3ffc3TBFHfivX","3cfcf82ef4d0685f4e4e95a5","G2RCCDSBEGk"],["Where Have You Been","Rihanna","3tyPOhuVnt5zd5kGfxbCyL","1c5eacf6965d328c2c795cef","HBxt_v0WF6Y"],["Turn Me On (feat. Nicki Minaj)","David Guetta, Nicki Minaj","6T27IN7Ai94BeDv6PPCmoC","63bf1cd36632031eb3081cb0","YVw7eJ0vGfM"],["Whistle","Flo Rida","3bC1ahPIYt1btJzSSEyyrF","15785fa4f22f8c50902b3a42","cSnkWzZ7ZAA"],["Bangarang (feat. Sirah)","Skrillex, Sirah","6VRhkROS2SZHGlp0pxndbJ","6081278cb62df2757d55633b","YJVmu6yttiw"],["Boyfriend","Justin Bieber","2L7rZWg9RLxIwnysmxm4xk","6c20c4638a558132ba95bc39","4GuqB1BQVr4"],["Don't Wake Me Up","Chris Brown","18VfHIPaCo0s6FTi1Fnp6T","781583ade2f00c2966a35965","QOowQeKyNkQ"],["Latch","Disclosure, Sam Smith","51ODNNDZm21HU7wI7cccRr","786201dca187d2b0c956c24b","93ASUImTedo"],["Sexy And I Know It","LMFAO","70Vdd1gx5tn84jkAU31ASv","1db908d5f66645cb158837ca","wyx6JDQCslE"],["Die Young","Kesha","7EQGXaVSyEDsCWKmUcfpLk","edcab0fe7cf29d17751dad18","NOubzHCUt48"],["Part Of Me","Katy Perry","1nZzRJbFvCEct3uzu04ZoL","937af329667311f4b2831616","uuwfgXD8qV8"],["Titanium (feat. Sia)","David Guetta, Sia","0TDLuuLlV54CkRRUOahJb4","63bf1cd36632031eb3081cb0","JRfuAukYTKg"],["Too Close","Alex Clare","4VySpxhRGy32u5zPCprzDn","e11a503d7be9336b72a53899","zP50Ewh31E4"],["Paradise","Coldplay","6nek1Nin9q48AVZcWs9e9D","de0cd11d7b31c3bd1fd5983d","1G4isv_Fylg"],["I Love It (feat. Charli XCX)","Icona Pop, Charli xcx","2U8NXPTXZWG2O0ye2sYRiH","51b4a23b47059a9aef703df6","UxxajLWwzqY"],["I Knew You Were Trouble.","Taylor Swift","3lKZf71jeNi14udIFPJ29V","254c8a09649551438b20f4c0","vNoKguSdy4Y"],["TiK ToK","Kesha","0HPD5WQqrq7wPWR7P7Dw1i","97c7b770b28ffeed164f4d0e","iP6XpLQM2Cs"],["Deuces (feat. Tyga & Kevin McCall)","Chris Brown, Tyga, Kevin McCall","6wN4nT2qy3MQc098yL3Eu9","0a1d20ec09cab4bb17a36aab","rhBwt9mw7Sk"],["Look At Me Now (feat. Lil' Wayne & Busta Rhymes)","Chris Brown, Lil Wayne, Busta Rhymes","3hsmbFKT5Cujb5GQjqEU39","0a1d20ec09cab4bb17a36aab","8gyLR4NfMiI"],["Right Above It","Lil Wayne, Drake","1kMuU3TNQvHbqvXCWBodmP","229411bccce65156241b6190","b0wbCtrGjXA"],["Pass Out","Tinie Tempah","2I7s0b5PubDX17fR7brcL4","1e2ab4ff97e279411d70696b","QzvGKas5RsU"],["All I Do Is Win (feat. T-Pain, Ludacris, Snoop Dogg & Rick Ross)","DJ Khaled","75FT1IPlCYCs5DAYbR9mjE","446930205d880005f1cc4511","WRc4lH6_bEU"],["Like A G6","Far East Movement, The Cataracs, DEV","5AyL2kgLtTWEu3qO3B9SqK","fc7cbacf9d506c92aa7d7720","w4s6H4ku6ZY"],["Danza Kuduro","Don Omar, Lucenzo","6DXLO8LndZMVOHM0wNbpzg","d4c273fe23a0950d7ac9fce2","71sqkgaUncI"],["Replay","Iyaz","4E5P1XyAFtrjpiIxkydly4","ae7012fce99c2b2345b54f30","ZoG5jJ3E8rg"],["One (Your Name) - Radio Edit","Swedish House Mafia, Pharrell Williams","1qZMPmpD1jDcOA7gZ6TCde","8dfae070d8dd3fee23689a59","PkQ5rEJaTmk"],["Sun Is Up","INNA","1TtteYFQeZfSU8AmfIAOvu","464f14f7c511222dc6c95b97","VNfFTuIk-dQ"],["Dick (feat. Doja Cat)","StarBoi3, Doja Cat","3nY8AqaMNNHHLYV4380ol0","1535551028fa53fd473ab7d3",""],["Down The Road","C2C","1x5MjCffpcdHLf65eR9r3T","32d6aa9f9b1810e7fb8aaca5","gpc3cCxWNkU"],["Truffle Butter","Nicki Minaj, Drake, Lil Wayne","3keUgTGEoZJt0QkzTB6kHg","fa8ef63d8bf819b3463528e9","EUS_ONfxRnQ"],["Up All Night","Drake, Nicki Minaj","55YHftnlehUQQJoTSLKCxj","72babba16ea5e3afe690b4f1","BfCJ_Az698g"],["Make Me Proud","Drake, Nicki Minaj","7yfg0Eer6UZZt5tZ1XdsWz","c7ea04a9b455e3f68ef82550","wWL6ZzkiQKg"],["Where Them Girls At (feat. Nicki Minaj & Flo Rida)","David Guetta, Flo Rida, Nicki Minaj","7yO48FWUkqsrdxrwkGcnwl","41e645fc5764b517912fb720","p4kVWCSzfK4"],["Say So (feat. Nicki Minaj) - Original Version","Doja Cat, Nicki Minaj","1KNh3GCalI00xnSGQZNmiZ","648990ef5afed6108cc42ab3","pok8H_KF1FA"],["Make That Cake (feat. Doja Cat)","LunchMoney Lewis, Doja Cat","3H46DLWgIFfEoP4mOXEIzq","5ca7bd31ddca321f8ad5dc5e","UI2XVGDEMEk"],["We Dem Boyz","Wiz Khalifa","1ULa3GfdMKs0MfRpm6xVlu","27ed4f26fa2bfbd714dba7dd","UX6K7waag5Q"],["Space Cadet (feat. Gunna)","Metro Boomin, Gunna","1fewSx2d5KIZ04wsooEBOz","2887f8c05b5a9f1cb105be29","qBWhc4qbsjo"],["Trance (with Travis Scott & Young Thug)","Metro Boomin, Travis Scott, Young Thug","5wG3HvLhF6Y5KTGlK0IW3J","c4fee55d7b51479627c31f89","TxUdlC0057s"],["The Way I Are","Timbaland, Keri Hilson, D.O.E.","2bLqfJjuC5syrsgDsZfGmn","4ed674ab91bdc566534f9285","U5rLz5AZBIA"],["Hussle in the House","Nipsey Hussle","1bMLie2mM5foKAiaZz3Xo1","151e9d688694d3beda350d5b","JXOF8yXuS90"],["Hung Up","Madonna","70VjMtwhm3Q2HBQeJnPfmh","6b44fa8f5415cc4c945117be","EDwb9jOVRtU"],["SexyBack (feat. Timbaland)","Justin Timberlake, Timbaland","0O45fw2L5vsWpdsOdXwNAR","c6ba98fd3f3b396a6c6f7091","3gOHvDP_vCs"],["Praise The Lord (Da Shine) (feat. Skepta)","A$AP Rocky, Skepta","7ycWLEP1GsNjVvcjawXz3z","bfcb8d00cee4f8257a6b7fe1","Kbj2Zss-5GY"],["Main Chick (feat. Chris Brown)","Kid Ink, Chris Brown","2asIUjALYhUbH8hvLUhDWo","f8d9263f7af76538827b7afd","tfRW88oBbbE"],["Show Me (feat. Chris Brown)","Kid Ink, Chris Brown","4q6dqyGM25sKFU8nYAGRe4","f8d9263f7af76538827b7afd","xKkb13IU_DE"],["Break Ya Neck","Busta Rhymes","0svl7cK07gK1ia5ainczU5","117fafcd2354258771914e63","W7FfCJb8JZQ"],["SWISH","Tyga","55GiOwtxNajXVbpjjIzMnD","87ca061535e5b10a8fc49794","ScdQQfAjFTk"],["Love Me","Lil Wayne, Drake, Future","2XHzzp1j4IfTNp1FTn7YFg","80c64a084164867806ea617a","KY44zvhWhp4"],["Mirror","Lil Wayne, Bruno Mars","5hUYsaOyMY32yjRXeuQwGj","e80b258c7e0b318202870953","OZLUa8JUR18"],["You & Me - Flume Remix","Disclosure, Eliza Doolittle, Flume","3W2ZcrRsInZbjWylOi6KhZ","786201dca187d2b0c956c24b","8x-M7AkTvrQ"],["Lollipop","Lil Wayne, Static Major","5jnxxpX2834SB6LJ0S73Uz","aa739a5e844220bb44a64adc","2IH8tNQAzSs"],["Birthday Sex","Jeremih","16XNk3bVCSHXN1rlwbXtHb","3ef4572e653cc08326c9551a","vYMxOzxKYYo"],["Down On Me","Jeremih, 50 Cent","0x3TibRgnSqzkcwrqBd4iX","ee6271e9d8488289b6a4aa63","AaXaig_43lU"],["Don't Tell 'Em","Jeremih, YG","0Dc7J9VPV4eOInoxUiZrsL","262c8e955ad5c60b1d0abf53","MqyCoAgiGnI"],["Planez","Jeremih, J. Cole","08zJpaUQVi9FrKv2e32Bah","262c8e955ad5c60b1d0abf53","--5u48IaR4M"],["Psycho (feat. Ty Dolla $ign)","Post Malone, Ty Dolla $ign","3swc6WTsr7rl9DqQKQA55C","b1c4b76e23414c9f20242268","au2n7VVGv_c"],["rockstar (feat. 21 Savage)","Post Malone, 21 Savage","0e7ipj03S05BNilyu5bRzt","b1c4b76e23414c9f20242268","UceaB4D0jpo"],["Chosen (feat. Ty Dolla $ign)","Blxst, Tyga, Ty Dolla $ign","1dIWPXMX4kRHj6Dt2DStUQ","4dd2991fe759c7205f31eabb","kUhHdASVjGs"],["BELIEVE IT","PARTYNEXTDOOR, Rihanna","6WHZvtFnceMMv08gUCHR0y","45beaf5f98f27b2b5c10ec11","gejbbL1AaJk"],["Streets","Doja Cat","60ynsPSSKe6O3sfwRnIBRf","d0bbfea6226b5c3707de92ed","jJdlgKzVsnI"],["Juicy","Doja Cat, Tyga","7f5trao56t7sB7f14QDTmp","d0bbfea6226b5c3707de92ed","YIALlhlyqO4"],["Woman","Doja Cat","6Uj1ctrBOjOas8xZXGqKk4","14b7b2a920a41166d53ddd49","yxW5yuzVi8w"],["Be Real (feat. DeJ Loaf)","Kid Ink, DeJ Loaf","2npJP0YTkykkqjezhA1g8f","24aaa74351e83d0515f8c106","7TvfG6IzBa0"],["2 On (feat. ScHoolboy Q)","Tinashe, ScHoolboy Q","3jVtllWS5CFFWLQng8sKsr","c77c076843e1f7d3ad715337","-s7TCuCpB5c"],["Body Language (feat. Usher & Tinashe)","Kid Ink, USHER, Tinashe","7F51q96XofOD2lntm7hzvQ","24aaa74351e83d0515f8c106","_Ht6gSClAzo"],["I Like It","Cardi B, Bad Bunny, J Balvin","58q2HKrzhC3ozto2nDdN4z","a0caffda54afd0a65995bbab","xTlNMmZKwpA"],["I Love It (& Lil Pump)","Kanye West, Lil Pump","4S8d14HvHb70ImctNgVzQQ","b6d544387b04e1d1a5f7926c","cwQgjq0mCdE"],["Family Affair","Mary J. Blige","3aw9iWUQ3VrPQltgwvN9Xu","096a7fc9668305db9d3175fc","znlFu_lemsU"],["The Man","Aloe Blacc","4e6ZN0EcEqYx74BTC5xQzy","4de16370db3ca53c8e29e72f","HGy9i8vvCxk"],["I Need A Dollar","Aloe Blacc","3oUphdZVPyrsprZ8FgbmQS","da3cc2c4204afde1c08431d5","nFZP8zQ5kzk"],["I'm the One (feat. Justin Bieber, Quavo, Chance the Rapper & Lil Wayne)","DJ Khaled, Justin Bieber, Quavo, Chance the Rapper, Lil Wayne","3DXncPQOG4VBw3QHh3S817","f2b55cfff049e03f92834b50","weeI1G46q0o"],["Wild Thoughts (feat. Rihanna & Bryson Tiller)","DJ Khaled, Rihanna, Bryson Tiller","1OAh8uOEOvTDqkKFsKksCi","f2b55cfff049e03f92834b50","fyaI4-5849w"],["GREECE (feat. Drake)","DJ Khaled, Drake","3gruCKVuhCsRjs3a3dG8CA","dcd4d70294f17175991ba1bb","NMlBB2pK5qo"],["Promiscuous","Nelly Furtado, Timbaland","2gam98EZKrF9XuOkU13ApN","a6f439c8957170652f9410e2","0J3vgcE5i2o"],["Give It To Me","Timbaland, Justin Timberlake, Nelly Furtado","0wbDgMuAoy7O7pL3a69uZx","755a9f1e89ad8e8cf91d4956","RgoiSJ23cSc"],["Suga Suga","Baby Bash, Frankie J","6Nq5lE0CeOAAAqN4qhkbZU","07acb67d4e71275637cd0a1b","6rgStv12dwA"],["Sugar (feat. Wynter)","Flo Rida, Wynter Gordon","4shgvM4ClrZeDiflNJwlGd","7eb51e495a5d31e24e0847cf","S4WS_Q5Mq2s"],["Mercy","Kanye West, Big Sean, Pusha T, 2 Chainz","4qikXelSRKvoCqFcHLB2H2","2127d038204bc32c416d55e2","7Dqgr0wNyPo"],["Live Your Life","T.I., Rihanna","6jKeXDUCImQkNdwKJviCPw","0dd170d60a89c5cbb8cb8bb3","koVHN6eO4Xg"],["Born This Way","Lady Gaga","30XU4suKzCeoCK9YFzdufg","a5d31644260279be8d0c46c0","wV1FrqwZyKw"],["Low (feat. T-Pain)","Flo Rida, T-Pain","0CAfXk7DXMnon4gLudAp7J","49ebebcf0bd7042e5ef931be","U2waT9TxPU0"],["Wild Ones (feat. Sia)","Flo Rida, Sia","1NpW5kyvO4XrNJ3rnfcNy3","15785fa4f22f8c50902b3a42","bpOR_HuHRNs"],["Good Feeling","Flo Rida","2LEF1A8DOZ9wRYikWgVlZ8","15785fa4f22f8c50902b3a42","3OnnDqH6Wj8"],["Club Can't Handle Me (feat. David Guetta)","Flo Rida, David Guetta","6ebkx7Q5tTxrCxKq4GYj0Y","1dec5cdebb0ea9b3df5fd0ca","SgM3r8xKfGE"],["My House","Flo Rida","6Knv6wdA0luoMUuuoYi2i1","6ba3d11e51c7df825292307f","uo35R9zQsAI"],["Right Round","Flo Rida, Kesha","3GpbwCm3YxiWDvy29Uo3vP","7eb51e495a5d31e24e0847cf","CcCw1ggftuQ"],["I Don't Like It, I Love It (feat. Robin Thicke & Verdine White)","Flo Rida, Robin Thicke, Verdine White","2S5LNtRVRPbXk01yRQ14sZ","6ba3d11e51c7df825292307f","Tw8mpgccugc"],["DJ Got Us Fallin' In Love (feat. Pitbull)","USHER, Pitbull","4356Typ82hUiFAynbLYbPn","86b0c9728ad3ed338eaeea79","C-dvTjK_07c"],["Disturbia","Rihanna","2VOomzT6VavJOGBeySqaMc","f9f27162ab1ed45b8d7a7e98","E1mU6h4Xdxc"],["Stay Schemin","Rick Ross, French Montana, Drake","0nq6sfr8z1R5KJ4XUk396e","5352ff7a09fd78a78ed4e9ba","JWT_wzIG4gY"],["B.M.F. (Blowin' Money Fast)","Rick Ross, Styles P","35QGdv6aFbIaLM0Ozr3rHt","0fbb5046ac2211a4aab5ecfa","n2MVzP4MaJ0"],["Goodies (feat. Petey Pablo)","Ciara, Petey Pablo","3dFwpxh2yH7C7p9BGEKLVB","c1e3659212de0f437bbf395e","YtC92pzp5vw"],["Let Me Blow Ya Mind","Eve, Gwen Stefani","3RmKpob8xzv1pzHEQrMJah","0a825fea8b9095572e5130ef","Wt88GMJmVk0"],["Im a Boss","Meek Mill","7wSunRBfZJAT9dKZ2MdYs2","55ca7a7b47cc80c2b21d5231","V1cxP2nCBdU"],["Mr. Saxobeat - Radio Edit","Alexandra Stan","3LWDPEXEaLBRGNLbdcbwBR","b787b5b057751c4d5bb5de54","nwsewSMWIas"],["Forgot About Dre","Dr. Dre, Eminem","7iXF2W9vKmDoGAhlHdpyIa","9b19c107109de740bad72df5","QFcv5Ma8u8k"],["Still D.R.E.","Dr. Dre, Snoop Dogg","503OTo2dSqe7qk76rgsbep","9b19c107109de740bad72df5","_CL6n0FJZpk"],["What's The Difference","Dr. Dre, Eminem, Xzibit","1SWVDBtw6h3tm9OehOkDhv","9b19c107109de740bad72df5","-Ubyt7iWJ8Q"],["The Next Episode","Dr. Dre, Snoop Dogg","4LwU4Vp6od3Sb08CsP99GC","9b19c107109de740bad72df5","QZXc39hT8t4"],["Danger (with Migos & Marshmello)","Migos, Marshmello","0nhVrTiCGiGRCoZOJiWzm1","4e6c9afd981f4615718507a5","ntLtNTUCuII"],["We Own It (Fast & Furious)","2 Chainz, Wiz Khalifa","2OQJKTtrH482waGFmOfJni","b4366694590f7164fad21fc7","tYQ1Okyi3g4"],["Ali Bomaye","The Game, 2 Chainz, Rick Ross","0LFcFGLYTX6UmeIdO7NVd7","a65779c8c92dff73f8189800","eU4ZvfkmOck"],["How We Do","The Game, 50 Cent","4PmMVdIFpJTB9WQbmILf4p","b1d860ab1ba847e778b2796d","PH34kMOjmQk"],["Pray For Me","The Weeknd, Kendrick Lamar","6huNf4dutXRjJyGn7f5BPS","12a76d1b13ef07188f7dfbc9","XR7Ev14vUh8"],["Crack A Bottle","Eminem, Dr. Dre, 50 Cent","360TPORPNBas8DeQueJe67","63d5aec8186b37f4404b1d1d","_wN3wl473M0"],["POPSTAR (feat. Drake)","DJ Khaled, Drake","6EDO9iiTtwNv6waLwa1UUq","efaecb4b9cbae7c120d14617","3CxtK7-XtE0"],["Human","Rag'n'Bone Man","58zsLZPvfflaiIbNWoA22O","f5c397bd6cdac2a6c287b5bd","L3wKzyIN1yk"],["War","Drake","1I55Ea0zVoSKs6MqW7DQ3i","bba7cfaf7c59ff0898acba1f","lIlMtVGI5Pg"],["Work from Home (feat. Ty Dolla $ign)","Fifth Harmony, Ty Dolla $ign","4tCtwWceOPWzenK2HAIJSb","82db43e5091301205076d6ab","5GL9JoH4Sws"],["Worth It (feat. Kid Ink)","Fifth Harmony, Kid Ink","41Fflg7qHiVOD6dEPvsCzO","42d324c29b1f8d408c08f86b","YBHQbu5rbdQ"],["Havana (feat. Young Thug)","Camila Cabello, Young Thug","1rfofaqEpACxVEHIZBJe6W","652c9f55dfbf3cfe1800daea","BQ0mxQXmLsk"],["All I Do Is Win (feat. T-Pain, Ludacris, Snoop Dogg & Rick Ross)","DJ Khaled","12PNcnMsjsZ3eHm62t8hiy","5de048eb9ca94916178afb20","WRc4lH6_bEU"],["Get Along Better","Drake, Ty Dolla $ign","5ScbulRnixQ2XAdvrPMFjz","cd945b4e3de57edd28481a3f","84y-jaEiFZU"],["Life Is Good (feat. Drake)","Future, Drake","5yY9lUy8nbvjM1Uyo1Uqoc","8a01c7b77a34378a62f46402","l0U7SxXHkPY"],["Laugh Now Cry Later (feat. Lil Durk)","Drake, Lil Durk","2SAqBLGA283SUiwJ3xOUVI","52c75ed37313b889447011ef","JFm7YDVlqnI"],["Loyal (feat. Lil Wayne & Tyga)","Chris Brown, Lil Wayne, Tyga","5BrTUo0xP1wKXLJWUaGFtk","b37e6176a034d4470304d706","JXRN_LkCa_o"],["Promise (feat. Fetty Wap)","Kid Ink, Fetty Wap","5IZc3KIVFhjzJ0L2kiXzUl","08e8765aad76229c1054c673","DE1NciB_gEU"],["Amazing","INNA","1dHG7nq5iazWKugHealVEk","3d6413c7dc24318bdbd5b366","gKHe12T6GMY"],["Day 'N' Nite (Nightmare)","Kid Cudi","60PAzFNW3vAiAiVK6DRJfB","713f297a7bdc1d48971062b2","a7ZcDNys3ZU"],["Drop It Like It's Hot","Snoop Dogg, Pharrell Williams","2NBQmPrOEEjA8VbeWOQGxO","e803716268c173c3f9a0c057","GtUVQei3nX4"],["Where The Hood At","DMX","6RUpJeXT6U4SPEafnr9Wr7","b6afa5d2bfa63cb0eaa386b1","6CqXgs-7ico"],["All The Way Up (feat. Infared)","Fat Joe, Remy Ma, French Montana, InfaRed","7Ezwtgfw7khBrpvaNPtMoT","fb0a799a6441249426c15eed","y2ak_oBeC-I"],["Search & Rescue","Drake","7aRCf5cLOFN1U7kvtChY1G","cace8a4b2ff924c9e12e3a96","ntp9_iznQ-0"],["My Nigga","YG, Jeezy, Rich Homie Quan","19OHDib8Jrqi3o2nm5lzdA","d5e1093f3b6f0a59114a4905","MSrTnWDTdwI"],["My Nigga - Remix","YG, Lil Wayne, Rich Homie Quan, Meek Mill, Nicki Minaj","6qaGOYPk0tmPmPDIrRiBPM","49fbbf5b483d1bbdd2c025c4","MSrTnWDTdwI"],["We Can't Stop","Miley Cyrus","2y4lAQpi5VTNLu2ldeTdUH","c19a3bef3b59347c8070770b","LrUvu1mlWco"],["Shook Ones, Pt. II","Mobb Deep","33ZXjLCpiINn8eQIDYEPTD","3789f564b75140c1fd2228cc","yoYZf-lBF_U"],["Survival of the Fittest","Mobb Deep","7N1Vjtzr1lmmCW9iasQ8YO","3789f564b75140c1fd2228cc","Dz5VzLz67WA"],["Hell on Earth (Front Lines)","Mobb Deep","1RjU7UhRICmdFPKxCucLgq","aaade0aecd37f7c8311e11c7","-lonWMzBKdU"],["Gangsta's Paradise","Coolio, L.V.","1DIXPcTDzTj8ZMHt3PDt8p","7438996f6fe67c59d75d4e43","fPO76Jlnz6c"],["Stuntin' Like My Daddy - Street","Birdman, Lil Wayne","3rMyMv8EjKXoPnaRo2hdJN","8da932399ce7f587525587b6","_hDPUoUi6_s"],["Money To Blow - Street Version","Birdman, Lil Wayne, Drake","4gaz3uvhKgO078XcdzyPsl","f4b27b2c8c9e3fd7e6796dd3","NjNBC4mC5y4"],["Believe Me","Lil Wayne, Drake","6t2eIONH4Sax3R21QWiKNp","a097c007351b6dc514af10fc","JSOo4ULWYOA"],["The Motto","Drake, Lil Wayne","4Kz4RdRCceaA9VgTqBhBfa","c7ea04a9b455e3f68ef82550","BYDKK95cpfM"],["LA Leakers Freestyle","Central Cee","5gpyyqA9WZyWu24ESUzrkk","0840fd3ea11d6848d192d8d0","3ZCKZnJmhx0"],["The Hillbillies","Baby Keem, Kendrick Lamar","1h6w4POXM2LfG4ZD4xUfZQ","dc35f5b5b51d56f5d88ed6b9","Yhivl6fln3s"],["March Madness","Future","3WcC6NH9J77xPEvj1SOL7z","dc014d6cf51f0ff8bdd76764","pJ-c5NsKjXo"],["Airplanes (feat. Hayley Williams of Paramore)","B.o.B, Hayley Williams","6lV2MSQmRIkycDScNtrBXO","caa23612279c2d059a0d3a82","kn6-c223DUU"],["She Will","Lil Wayne, Drake","78O33U6jbQtNiNfbkZudpd","e521b35f461062a93d1a8d1a","Fw3H8R5hHEY"],["Under The Influence","Chris Brown","5IgjP7X4th6nMNDh4akUHb","48f69a441c575fa5926a0831","pfxyk1glEq4"],["Scream & Shout","will.i.am, Britney Spears","2iJuuzV8P9Yz0VSurttIV5","e6082141bd7c86ae9f11ea26","kYtGl1dX5qI"],["Beautiful Liar","Beyoncé, Shakira","2HWWNoWEEEECwZhAiLg7ib","026e88f624dfb96f2e1ef10b","QrOe2h9RtWI"],["Ridin'","Chamillionaire, Krayzie Bone","3kZoay4ANo86ehb6s4RwS9","abeffe927a62a584cf7c2708","CtwJvgPJ9xw"],["Loca (feat. El Cata)","Shakira, El Cata","42k1KeBehAd83lrGt1okiC","4214ddc9e33e76de6a8ee888","KewfYKJy8YU"],["Grinding All My Life","Nipsey Hussle","3R9j8urSPiBbapNbyuSYkE","ac271e5d670e92c42bf99237","AVrNHI4RdPM"],["Who Do You Love?","YG, Drake","7ngdkrVQPgP3AoIxUrTpHT","d5e1093f3b6f0a59114a4905","xTlWz_kZuWU"],["Hypnotize - 2014 Remaster","The Notorious B.I.G.","7KwZNVEaqikRSBSpyhXK2j","fde79b88e2a659c394c5ae30","glEiPXAYE-U"],["Big Poppa - 2005 Remaster","The Notorious B.I.G.","2g8HN35AnVGIk7B8yMucww","0f51e29700232d57fe8a0830","Zs8nbZAVRrY"],["Juicy - 2005 Remaster","The Notorious B.I.G.","5ByAIlEEnxYdvpnezg7HTX","0f51e29700232d57fe8a0830","_JZom_gVfuw"],["Vato","Snoop Dogg, B-Real","2TgPHDU8zPgAvkSLXkHKXR","5a62c25459ad69981d5d09ef","UXWFqxKU2qA"],["Sensual Seduction","Snoop Dogg","1wva1IlWLDNLgwipUWcmjy","57823d09cb2efe1a926f1623","Y1PVmANeyAg"],["Sweat - Snoop Dogg vs David Guetta Remix","Snoop Dogg, David Guetta","0R7YVi7w41Dr9jU5vblAok","9fa2954cdefd83d439a1e7ac","KnEXrbAQyIo"],["Who's That Chick? (feat. Rihanna)","David Guetta, Rihanna","64r1Dcco8Vj0inAZgEK05a","909ed9cd12fa1b5fc75ae674","EAc4zHEDd7o"],["Little Bad Girl (feat. Taio Cruz & Ludacris)","David Guetta, Ludacris, Taio Cruz","55VzNhbcf0Gxf6qRCUAV01","63bf1cd36632031eb3081cb0","9ha5ujHnYXg"],["Disco Inferno","50 Cent","69bHJ9qs5FrUJbKP8xU8uZ","91f7222996c531b981e7bb3d","GNqYWkiBHHw"],["No Lie","Sean Paul, Dua Lipa","48QmG1dfvMuYLxMPt7KSRA","2d564195ed3dd7b70d64862c","GzU8KqOY8YA"],["Womanizer","Britney Spears","4fixebDZAVToLbUCuEloa2","1abb421ac1fbbe52c127015e","rMqayQ-U74s"],["Get Ur Freak On","Missy Elliott","6zsk6uF3MxfIeHPlubKBvR","2e3969990abe1229c0879a7b","FPoKiGQzbSQ"],["A Milli","Lil Wayne","3uqinR4FCjLv28bkrTdNX5","aa739a5e844220bb44a64adc","1Vf4mMCpNY0"],["Hate Bein' Sober","Chief Keef, 50 Cent, Wiz Khalifa","2oHM9KAdFdFvDCaE4V6RST","a76616abf60ce17491e95891","ISj_j2h9UjA"],["Coming Home","Diddy - Dirty Money, Skylar Grey","6Iocm6VMu6bVNYwiDoyQFW","0b1cfc3df4d9d5d4cbce9208","FOXfbTx_P7c"],["Lemonade (feat. Gunna, Don Toliver & NAV)","Internet Money, Gunna, Don Toliver, NAV","7hxHWCCAIIxFLCzvDgnQHX","9ca0c952f130e28025209cf0","0opZqh_TprM"],["No Idea","Don Toliver","7AzlLxHn24DxjgQX73F9fU","9d04d25e732c593fb94e7193","_r-nPqWGG6c"],["No Guidance (feat. Drake)","Chris Brown, Drake","6XHVuErjQ4XNm6nDPVCxVX","0bf1b932009c0bff47b8cb86","oOni4BMeMp0"],["You're Mines Still (feat. Drake)","Yung Bleu, Drake","6tiKwZppNjrls8RsPQwK6r","5af60d7ec22b1b70933ac381","_bptrMV3zHE"],["STAYING ALIVE (feat. Drake & Lil Baby)","DJ Khaled, Drake, Lil Baby","0g2Bbgy7P41pFjMWJuzsf4","d6321b45fcd0e207087a5a93","PM2f835zx88"],["Hussle & Motivate","Nipsey Hussle","2hVtGnJeHOo0EqjzYXNFg5","ac271e5d670e92c42bf99237","nhcDl3S5sXQ"],["Now & Forever","Drake","4zLOwx1yRJXWkHKt1XzF1p","2090f4f6cc406e6d3c306733","vZmNlvfrL4U"],["Symphony (feat. Zara Larsson)","Clean Bandit, Zara Larsson","72gv4zhNvRVdQA0eOenCal","5c66e925d8fe4c92ebfb49ed","aatr_2MstrI"],["Rockabye (feat. Sean Paul & Anne-Marie)","Clean Bandit, Anne-Marie, Sean Paul","2hrUO4drrO63i7FYbCLBl2","5c66e925d8fe4c92ebfb49ed","papuvlVeZg8"],["Rather Be (feat. Jess Glynne)","Clean Bandit, Jess Glynne","61dCUoMCg28qEBzrW6htYM","5ef315d54fd701725176292e","m-M1AtrxztU"],["American Boy","Estelle, Kanye West","6etwirSInfuJrSOlogS6Sh","98dc3e242a818007dd67b7c5","Ic5vxw3eijY"],["The Motion","Drake","3t8pnImpBpOwxdtYBpKvA9","adfb5909ec66db5fbb4d06c8","BZy1f0Tl7OM"],["Gimme More","Britney Spears","6ic8OlLUNEATToEFU3xmaH","d0a8bfe18f25429d76886b1e","elueA2rofoo"],["Toxic","Britney Spears","6I9VzXrHxO9rA9A5euc8Ak","efc6988972cb04105f002cd4","LOZuxwVk7TU"],["...Baby One More Time","Britney Spears","3MjUtNVVq3C8Fn0MP3zhXa","36cf58e3e7cf36a145b1da18","C-u5WLJ9Yk4"],["Oops!...I Did It Again","Britney Spears","6naxalmIoLFWR0siv8dnQQ","c50b7d96737041f4bfd844d6","CduA0TULnow"],["TAlk tO Me (with Rich The Kid)","Tory Lanez, Rich The Kid","2QihWAl9xAwGPm5vGoO7uM","e425ce7f784550e60e6045fe","v-KX9i3EB3g"],["The Sweet Escape","Gwen Stefani, Akon","07K4GcCDSTiXUF5ssyTRUM","ed29b3ed6596d0bb0df132e1","O0lf_fE3HwA"],["Hollaback Girl","Gwen Stefani","0eqH0ALoDQevq59YcQ53KE","f049fc9322f0c93646cdcc77","Kgjkth6BRRY"],["Girlfriend","Avril Lavigne","45hOioMDJktr86iKDHC8gr","476cdf5837ae39eee951cc15","Bg59q4puhmg"],["What's Luv? (feat. Ja-Rule & Ashanti)","Fat Joe, Ja Rule, Ashanti","2mKouqwAIdQnMP43zxR89r","!7bb3a0b50c9c42572efd9772628c14140f70980a","VpvyG2NrS1Y"],["I'm On One","DJ Khaled, Drake, Rick Ross, Lil Wayne","608a1wIsSd5KzMEqm1O7w3","dd87a2f68949c8fcbbec91be","Z09lYqdxqzo"],["Drifting (feat. Chris Brown & Tory Lanez)","G-Eazy, Chris Brown, Tory Lanez","5sv4LTz8qayQYnXlzaxg2x","bf34660a2cc3f4d83966b1e7","gE1Gbwn-LU0"],["Smack That","Akon, Eminem","2kQuhkFX7uSVepCD3h29g5","d9bcf5565005950b353bc9cf","bKDdT_nyP54"],["Over","Drake","1EoHEkVcysf4WVDx6r9WzQ","72babba16ea5e3afe690b4f1","2lTB1pIg1y0"],["Hold On, We're Going Home","Drake, Majid Jordan","6jdOi5U5LBzQrc4c1VT983","adfb5909ec66db5fbb4d06c8","GxgqpCdOKak"],["The Color Violet","Tory Lanez","3azJifCSqg9fRij2yKIbWz","0c5f23cbf0b1ab7e37d0dc67","GfAPEko4rbU"],["Obsessed","Mariah Carey","5EGPf0nqO7vEIwsOX6Er98","6ff3f8fd7540eb7447dae564","H1Yt0xJKDY8"],["Niagara Falls (Foot or 2) [with Travis Scott & 21 Savage]","Metro Boomin, Travis Scott, 21 Savage","4WuOWVnAqvEQxgSRrspBgt","c4fee55d7b51479627c31f89","Z8vDU6vUTj4"],["Going Bad (feat. Drake)","Meek Mill, Drake","2IRZnDFmlqMuOrYOLnZZyc","cd63c5962050729d260077d6","S1gp0m4B5p8"],["F**kin' Problems (feat. Drake, 2 Chainz & Kendrick Lamar)","A$AP Rocky, Drake, 2 Chainz, Kendrick Lamar","4X5f3vT8MRuXF68pfjNte5","2ae92030b51fb8135d694af9","liZm1im2erU"],["0 To 100 / The Catch Up","Drake","4jtyUzZm9WLc2AdaJ1dso7","2b83df1b3ca78269f49fa89f","s0PZYWA4LoM"],["Am I Dreaming (Metro Boomin & A$AP Rocky, Roisee)","Metro Boomin, A$AP Rocky, Roisee","6Ec5LeRzkisa5KJtwLfOoW","6ed9aef791159496b286179f","7aUZtDaxS60"],["Worst Behavior","Drake","3X37NtwadSS0RM20dh2IgP","adfb5909ec66db5fbb4d06c8","CccnAvfLPvE"],["XO Tour Llif3","Lil Uzi Vert","7GX5flRQZVHRAGd6B4TmDO","f23aee9d3be9fcbca1bc6352","WrsFXgQk5UI"],["UnFazed (feat. The Weeknd)","Lil Uzi Vert, The Weeknd","5O8x1YlmLQopQHErxtDfi9","f23aee9d3be9fcbca1bc6352","fFWYTGtRmEE"],["Aston Martin Music","Rick Ross, Drake, Chrisette Michele","5W7xC99N2Zzfh69r7I7zWK","0fbb5046ac2211a4aab5ecfa","a35rNEBNiO4"],["Buried Alive Interlude","Drake, Kendrick Lamar","1ZyudLFv35SRvY5SvTZqJx","c7ea04a9b455e3f68ef82550","kGO6a0T7f8w"],["L.A.LOVE (la la) (feat. YG)","Fergie, YG","746BlfyY0hVG65EtfaNvwo","3ed4bc4e5d579d8ef102110c","GLyP0B2Q-R4"],["Want to Want Me","Jason Derulo","7oGZAicScQt96OAW4AruYy","519241bcfc352fc3eaaac5db","rClUOdS5Zyw"],["Clout (feat. Cardi B)","Offset, Cardi B","59ywHNwwchG4nZJMLyxSzd","7028679269dc6a5a29ce8f36","mt2zvsvkKKo"],["Father Stretch My Hands Pt. 1","Kanye West","4KW1lqgSr8TKrvBII0Brf8","2a7db835b912dc5014bd37f4","wuO4_P_8p-Q"],["The Box","Roddy Ricch","0nbXyq5TXYPCO7pr3N8S4I","820b43679aab8d3b47001f9c","UNZqm3dxd2w"],["Ballin' (with Roddy Ricch)","Mustard, Roddy Ricch","3QzAOrNlsabgbMwlZt7TAY","93b1e96fad758869d0974162","YS0h2-hy9rw"],["Pure Water (with Migos)","Mustard, Migos","3j84U36KvLeXNDPv4t5pI8","93b1e96fad758869d0974162","9hJ8lLNWrM4"],["Die Young","Roddy Ricch","3wLtYwtqvKK2ewelSVPeDK","434f4eeb4231f6f4862cafd4","FctI8l2KKw8"],["International Love (feat. Chris Brown)","Pitbull, Chris Brown","62zFEHfAYl5kdHYOivj4BC","1dc7483a9fcfce54822a2f19","CdXesX6mYUE"],["Strange Clouds (feat. Lil Wayne)","B.o.B, Lil Wayne","0yQw3d0iQDjMrxaVHFv77J","a191830c8b300bc71c2faac7","9g1CgvXhCo4"],["Say It Right","Nelly Furtado","2aI21FnmY7TJVKeMaoQZ0t","a6f439c8957170652f9410e2","6JnGBs88sL0"],["Me & U","Cassie","7k6IzwMGpxnRghE7YosnXT","f4c4ee507c2558262869f415","zVJ5gsLeCSM"],["Glamorous","Fergie, Ludacris","6vVfNqiMSku4FrqsqhurBK","4c62f163f672735dda3357e2","q0SyUgw98tE"],["I Wanna Fuck You","Snoop Dogg, Akon","1G93i9ga7ZPEOqpiNhM1mq","5a62c25459ad69981d5d09ef","GJzF7H2e3Tw"],["Buy U a Drank (Shawty Snappin') (feat. Yung Joc)","T-Pain, Yung Joc","1tkMs9wDPknQ3ZHcKDw1ES","baf2f329d4feeb19761eddf4","dBrRBZy8OTs"],["Bartender (feat. Akon)","T-Pain, Akon","1RGIjMFMgJxkZHMDXVYzOJ","baf2f329d4feeb19761eddf4","Lt2wjJlP2N4"],["I'm Sprung","T-Pain","0DLOyyQvwPTSDKuhpzMMwA","dbaa4ff0c40e19d9c19ed760","rxRvDpF2FDA"],["Up Down (Do This All Day) (feat. B.o.B)","T-Pain, B.o.B","6lbhWl34Il0WXm5pX1fM9E","3d537424bb92aa2283f62595","45Q4Zk3CN8k"],["One Last Time","Ariana Grande","50rGbTr2wrWnlIelPQxi87","9e730d8fbd256885242f1e96","BPgEgaPk62M"],["Jump","Tyla, Gunna, Skillibeng","6XpEm7VJ7TZxZTawH8BCSW","3b4e7b8d3e6d063692406021","n3s6lDf8Nq0"],["Daylight","David Kushner","1odExI7RdWc4BT515LTAwj","95ca6a9b4083a86c149934ae","MoN9ql6Yymw"],["Starboy","The Weeknd, Daft Punk","7MXVkk9YMctZqd1Srtv4MB","4718e2b124f79258be7bc452","34Na4j8AVgA"],["Diet Mountain Dew","Lana Del Rey","48SdtsEKujibZPrd6UMfAr","6b850da1e1301dba85b08681","sEetXo3R-aM"],["Renegade","JAŸ-Z, Eminem","0eK5y1c7WDyWwx6k9SFjbT","1b3f6f34954118500ed3e7a7","3JTLkJVDDE4"],["Nightcrawler (feat. Swae Lee & Chief Keef)","Travis Scott, Swae Lee, Chief Keef","3xby7fOyqmeON8jsnom0AT","d3b5affd8824b4ed301b7137","NnOH3_NAw34"],["Crazy In Love (feat. JAŸ-Z)","Beyoncé, JAŸ-Z","0TwBtDAWpkpM3srywFVOV5","a9fd4a0405945cd51e8de130","ViwtNLUqkMY"],["Dirt Off Your Shoulder","JAŸ-Z","3IrkbGQCoEPAkzJ0Tkv8nm","c528802c308a1e0e4d9945dd","Oz_-VaTHpc8"],["Bitch I'm Madonna","Madonna, Nicki Minaj","2bZMOs3RjmhhGca6MEzjyl","ce3289d289ff7fc3c245af34","7hPMmzKs62w"],["Popular (with Playboi Carti & Madonna) - From The Idol Vol. 1 (Music from the HBO Original Series)","The Weeknd, Playboi Carti, Madonna","6WzRpISELf3YglGAh7TXcG","4c8f092adc59b4bf4212389d","vt0i6nuqNEo"],["Lovers on the Sun (feat. Sam Martin)","David Guetta, Sam Martin","2rgtCOVK2tpfao2VjURn84","720d368aa9ea6335ca40a6f8","BPiW0tkWfeg"],["Long Way 2 Go","Cassie","4v5kAh2wWyCSuKuhMJK8u6","f4c4ee507c2558262869f415","agNvdSIIkXA"],["Die For You","The Weeknd","2LBqCSwhJGcFQeTHMVGwy3","a048415db06a5b6fa7ec4e1a","uPD0QOGTmMI"],["When Love Takes Over (feat. Kelly Rowland)","David Guetta, Kelly Rowland","0GWGZA5mxo9nHuSyrj70uo","1813115ff10c5f5ae028321d","zudbz4hOcbc"],["I Knew You Were Trouble.","Taylor Swift","6FB3v4YcR57y4tXFcdxI1E","1c248e90c3e569f90aef9dec","vNoKguSdy4Y"],["Memories (feat. Kid Cudi)","David Guetta, Kid Cudi","7fLzbEOBOae9lUnOwr7Tse","1813115ff10c5f5ae028321d","NUVCQXMUVnI"],["Marvins Room","Drake","047fCsbO4NdmwCBn8pcUXl","c7ea04a9b455e3f68ef82550","JDb3ZZD4bA0"],["Treacherous Twins","Drake, 21 Savage","4Flfb4fGscN9kXPOduQLrv","02854a7060fccc1a66a4b5ad","jCtsnNpCDo0"],["BROTHER STONE (FEAT. KODAK BLACK)","Don Toliver, Kodak Black","0l3raueiJ78IsmZGwo6CRm","72459b3a459c7ef48b2e9624","L_BpiSsIBFM"],["Diamonds From Sierra Leone - Remix","Kanye West, JAŸ-Z","34KUIBsIUiPV7oCIzSdDAU","428d2255141c2119409a31b2","92FCRmggNqQ"],["Never Let Me Down","Kanye West, JAŸ-Z, J. Ivy","34j4OxJxKznBs88cjSL2j9","25b055377757b3cdd6f26b78","p4NvOKy7GOU"],["Heard 'Em Say","Kanye West, Adam Levine","6yIjtVtnOBeC8SwdVHzAuF","428d2255141c2119409a31b2","elVF7oG0pQs"],["Save Your Tears","The Weeknd","5QO79kh1waicV47BqGRL3g","8863bc11d2aa12b54f5aeb36","XXYlFuWEuKI"],["Count Me Out","Kendrick Lamar","6BU1RZexmvJcBjgagVVt3M","2e02117d76426a08ac7c174f","5GhhVHpPR_M"],["Dangerous","Kardinal Offishall, Akon","4NOZ35Dhucr6UlVyLOtktd","cedc24abc2e757d13b386d1e","Ro7yHf_pU14"],["Flex (Ooh, Ooh, Ooh)","Rich Homie Quan","4T0ScSPdQKmGvruK7pavNP","c62a27893c8a67923c852ab1","bWMw4vE3J8s"],["Ride Out","Kid Ink, Tyga, Wale, YG, Rich Homie Quan","5geGLxg6YpZjE3ZQg7PQi2","5d60909c267e1a3ab096583b","X7rdg_tKzKQ"],["If U Seek Amy","Britney Spears","0f0lWRAs9kdAFZu8mAI9K2","f3a189e0db490e1e0a7ebfa3","0aEnnH6t8Ts"],["#thatPOWER","will.i.am, Justin Bieber","01TuObJVd7owWchVRuQbQw","642efc0b3f045f34316d2cf3","DGIgXP9SvB8"],["NO","Meghan Trainor","0l0CvurVUrr2w3Jj1hOVFc","62edffdb4d8b52cf89f39db6","cMTAUr3Nm6I"],["Day 'N' Nite (nightmare)","Kid Cudi","5FEXPoPnzueFJQCPRIrC3c","aab2c3c3f1f3207137d915c9","a7ZcDNys3ZU"],["La La La","Naughty Boy, Sam Smith","3wPPWcVuinAU7dXcJXtCID","fafb4022c8ca1c4498e10b19","qBnvXXpdFF8"],["Magic (feat. Rivers Cuomo)","B.o.B, Rivers Cuomo","5uHYcK0nbEYgRaFTY5BqnP","caa23612279c2d059a0d3a82","Cq-NShfefks"],["Fuck You","CeeLo Green","3ydfhgIZIc2j39NLIhpJpq","1c44d79c994c1a26aa387617","pc0mxOXbWIU"],["Love You Like A Love Song","Selena Gomez & The Scene","0laYHRpNTS6i8FXdupHkJ4","1c8193de8d62b2ffa49a09db","EgT_us6AsDg"],["Without You (feat. Usher)","David Guetta, USHER","3UN6cIn3VIyg0z1LCuFSum","63bf1cd36632031eb3081cb0","jUe8uoKdHao"],["Call Me Maybe","Carly Rae Jepsen","20I6sIOMTCkB6w7ryavxtO","d3ee4bf67c2ac2154006ad72","fWNaR-rxAic"],["Radioactive","Imagine Dragons","62yJjFtgkhUrXktIoSjgP2","407bd04707c463bbb3410737","ktvTqknDobU"],["I Wanna Go","Britney Spears","5cCAZS9VhLGEDV4NCfieeg","3613a80185a11b15987d2885","T-sxSd1uwoU"],["Till the World Ends","Britney Spears","38iU2jg98IZZEIJPrP7aWD","3613a80185a11b15987d2885","qzU9OrZlKb8"],["Burn","Ellie Goulding","2GgxS8bUT5G25QJTsfSv0R","60a98c3be4daffefe9014c7e","CGyEd0aKWZE"],["What the Hell","Avril Lavigne","2z4U9d5OAA4YLNXoCgioxo","72c9f7a7c75eba39726106a6","tQmEd_UeeIk"],["Sk8er Boi","Avril Lavigne","00Mb3DuaIH1kjrwOku9CGU","f7ec724fbf97a30869d06240","TIy3n2b7V9k"],["Sweater Weather","The Neighbourhood","2QjOHCTQ1Jl3zawyYOpxh6","8265a736a1eb838ad5a0b921","GCdwKhTtNNw"],["Love Me Again","John Newman","5TbzAWWc5eJaANpA9kfGCd","b38d10a0f9eabec693d8f96e","CfihYWRWRTQ"],["Counting Stars","OneRepublic","2tpWsVSb9UEmDRxAl1zhX1","9e2f95ae77cf436017ada9cb","hT_nvWreIhg"],["Stereo Hearts (feat. Adam Levine)","Gym Class Heroes, Adam Levine","0qOnSQQF0yzuPWsXrQ9paz","18b8088fe0c3dbf78398b55a","T3E9Wjbq44E"],["No Hands (feat. Roscoe Dash & Wale)","Waka Flocka Flame, Roscoe Dash, Wale","03tqyYWC9Um2ZqU0ZN849H","!e1a8219245606496e48210744bd243badba484f1","skhxizRYxps"],["Demons","Imagine Dragons","5qaEfEh1AtSdrdrByCP7qR","407bd04707c463bbb3410737","mWRsgZuwf_8"],["As Long As You Love Me","Justin Bieber, Big Sean","0pwYLVXVknPSGUQb39cePC","6c20c4638a558132ba95bc39","R4em3LKQCAQ"],["Thrift Shop (feat. Wanz)","Macklemore & Ryan Lewis, Macklemore, Ryan Lewis, Wanz","6CjtS2JZH9RkDz5UVInsa9","2a6b364528b128a4a17d100d","QK8mJJJvaes"],["Can't Hold Us (feat. Ray Dalton)","Macklemore, Ryan Lewis, Macklemore & Ryan Lewis, Ray Dalton","22skzmqfdWrjJylampe0kt","2a6b364528b128a4a17d100d","2zNSgSzhBfM"],["Ain't No Love In Oklahoma (From Twisters: The Album)","Luke Combs","6GG4yyk3UATdBfTHVgI8PB","6f555ba312f3317dcbaa2cb9","J6YlaeACE4E"],["Drugs You Should Try It","Travis Scott","4b7vk8SRcYgnxpk0JOIS7r","a2a7386de6494fc9275e1abb","sS8ELauHmGM"],["Low Life (feat. The Weeknd)","Future, The Weeknd","7EiZI6JVHllARrX9PUvAdX","2f62a05cc754995b544ec1f6","K_9tX4eHztY"],["Miss The Rage","Trippie Redd, Playboi Carti","5n4FTCMefvyKUjeWumdaWv","1c0aacb7cb42f20914d319f4","2ow-9oyca40"],["Open Letter","Lil Wayne","2DnH4XlEkghUdE8ymdVom5","bb1138165ad4ec2306f4e886","LttD17tPT8w"],["Type of Way","Rich Homie Quan","6nu35hLc8zsA9bwBpcuf5L","bab85cd83daa0c9de9b440a8","-KKbdErJkiY"],["Just What I Am","Kid Cudi, King Chip","20bJBbPapGQ4bqs0YcA9xY","b9ab5cc935d2327a7d2bc629","hGbP_kTM4CA"],["Practice","Drake","0jF2AdhsalO1L7KkhK4LE5","c7ea04a9b455e3f68ef82550","JUrDOWj9RUw"],["Summertime Sadness","Lana Del Rey","1FEiijYPJtyswChfcpv3p0","959280fee07d485cb5b56fe7","TdrL3QxjyVw"],["One More Night","Maroon 5","6cpk00i5TxCqSeqNi2HuIe","fc8633e22a7dba6aab817bff","fwK7ggA3-bU"],["Rolling in the Deep","Adele","4OSBTYWVwsQhGLF9NHvIbR","e63ac9f24aab9acc90f81960","rYEDA3JcQqw"],["Talk That Talk","Rihanna, JAŸ-Z","57mKcbEq7nMqtJ4gqJvWcp","1c5eacf6965d328c2c795cef","Z8FarCnm1mE"],["Lean On","Major Lazer, MØ, DJ Snake","4UKJUbcuStnnxLeJmVJsSc","2236ac983588045e42fef5ed","YqeW9_5kURI"],["Skyfall","Adele","6VObnIkLVruX4UVyxWhlqm","b479bb2aed275bb1b13d83da","DeumyOzKqgI"],["Love Don't Let Me Go","David Guetta","5lgS45xqkTk2HVm7Jph9ya","5030123389057f42fed52f8c","_WA9NXXAntc"],["Gasolina","Daddy Yankee","228BxWXUYQPJrJYHDLOHkj","6bdcdf82ecce36bff808a40c","CCF1_jI8Prk"],["Best Friend","Young Thug","33JcUj9qQDayKswunZP9ar","bd29e861f5f985a1bbe50ff9","Tz6OUIjtM6E"],["Earned It (Fifty Shades Of Grey)","The Weeknd","2uv4moS862MAZcntQfurpz","8cab2b4eec5f4c5da4778c9c","waU75jdUnYw"],["I Got 5 On It","Luniz, Michael Marshall","4IYKjN1DrYzxKXt0umJqsG","c1ea4aac1ad07a38c59dd30c","me3CPl_i4C4"],["Boyfriend","Justin Bieber","3UGIZ8qcrMTwzLbx6Kttqt","f1d02a6cec967f8b6b78f76e","4GuqB1BQVr4"],["Unwritten","Natasha Bedingfield","3U5JVgI2x4rDyHGObzJfNf","b337e1ca6629a53c66a3b0d4","b7k0a5hYnSI"],["FE!N (feat. Playboi Carti)","Travis Scott, Playboi Carti","42VsgItocQwOQC3XWZ8JNA","04481c826dd292e5e4983b3f","B9synWjqBn8"],["THANK GOD","Travis Scott","1PH2MDbcBAU094DlgTIND1","04481c826dd292e5e4983b3f","UVtTc4zqbxQ"],["DELRESTO (ECHOES) (feat. Beyoncé)","Travis Scott, Beyoncé","0OEe83mMZ5kaNw5uZQ7ilG","04481c826dd292e5e4983b3f","8WkzlNcU9sg"],["Consideration","Rihanna, SZA","6t90Z9XkdsHD8xMxro6KRP","6be9bac15995f089579074de","WSSShAOKYfo"],["Killer (feat. Drake)","Nipsey Hussle, Drake","2uw8vslyCoFLQsoPcIhen5","3a53255308ec6b400daeaae7","vR4RO3zfcwc"],["Wake Up in the Sky","Gucci Mane, Bruno Mars, Kodak Black","2G1tXoGBaEMJ7FKGnkf6ud","6e4366b5308fd1c5462eb3ab","U68MJz9DrI4"],["overseas","Ken Carson","722NAIXkI6WRNvu9O7JkdH","3b494c1b464d41ef641de442","80M6sAU9DY4"],["Still Be Friends (feat. Tory Lanez & Tyga)","G-Eazy, Tory Lanez, Tyga","0JjM9bKm4wrwohMslcm892","0a70f97365dec77a1a86b785","o0MjKgb1Lp4"],["Like That","Future, Metro Boomin, Kendrick Lamar","2tudvzsrR56uom6smgOcSf","cec3fc072352b5f4f637d9fa","N9bKBAA22Go"],["Ric Flair Drip (with Metro Boomin)","Offset, Metro Boomin","7sO5G9EABYOXQKNPNiE9NR","0db43130a9aaa7bae56967ed","LPTlvQ1Zet0"],["MALA (feat. Anuel AA)","6ix9ine, Anuel AA","5tYCl2bT9bDjMuTyn6OVb0","0a4da3f1a72e4ecaabb76370","bEIH0jLkBnM"],["Monster","Kanye West, JAŸ-Z, Rick Ross, Nicki Minaj, Bon Iver","1ZHYJ2Wwgxes4m8Ba88PeK","d9194aa18fa4c9362b47464f","pS6HRKZQLFA"],["Look Back at It","A Boogie Wit da Hoodie","3Ol2xnObFdKV9pmRD2t9x8","a5c7151899ae5da4f4382d54","RWDXD8tAkPo"],["Hate It Or Love It","The Game, 50 Cent","2wGSgTmgSF3xjRrHkTc25R","b1d860ab1ba847e778b2796d","BuMBmK5uksg"],["Say It","Tory Lanez","2Gyc6e2cLxA5hoX1NOvYnU","9f7ce2227875fd3d645fb5d6","xUq1rZ7mmns"],["Hurts Me","Tory Lanez, Trippie Redd, Yoko Gold","0RBw4ODUQPO4cuAOZtBGga","1dba361996f5b70c1df2b4ee","tp01-2vKT68"],["Shameless","Camila Cabello","2ogKhhoMClkFXek7ZgxAhN","f8fc9e1b46c32dff21cede72","Fp_P_e1cPOE"],["Move (feat. Camila Cabello & Malachiii)","Stryv, Camila Cabello, Malachiii, Adam Port, Keinemusik, Orso","0scd3nh27AYTNXo0KHRmsG","cc522cf4d627dc1323bfda62","si6Ox8IuZeU"],["Never Be the Same","Camila Cabello","4eWQlBRaTjPPUlzacqEeoQ","652c9f55dfbf3cfe1800daea","Ph54wQG8ynk"],["Release","Saleka","5wkICeD0rmFiQQxccrJu9s","c2955b1245ea9e6523304e1c","pyutJEr2SWI"],["Nightcall","Kavinsky","0U0ldCRmgCqhVvD6ksG63j","d6d8c2eaa1f9031b62f7a3f7","MV_3Dpw-BRY"],["Nightcall","Kavinsky, Angèle, Phoenix","2KejCKgm7l3uefW9cFt8cH","82e856e42426e69b8bb43461","MV_3Dpw-BRY"],["Odd Look","Kavinsky, The Weeknd","3Q6mwJseOFYBJ10d5CXp4o","8cc5da5394cb8ccd3646179a","qT0iQRjHbW4"],["If We Being Rëal","Yeat","0YThXX1dqUpYBLyJNAsF9N","03e3ce4b238512cfb42dbc95","1xcvWmN0Pe4"],["You Be Killin Em","Fabolous","5I6YA7oHtraxwWQzzCugDt","a420aca7ee3e9048450ddf1b","z8Nmip4sPHM"],["Fear","Drake","5WfBl43XUcWng7OnB8LKNW","2992fb1eb1114a7a86361ca3","pRnrujxbEhc"],["Praise God","Kanye West","0WSEq9Ko4kFPt8yo3ICd6T","cad190f1a73c024e5a40dddd","9sJZOGxRxwM"],["Heart Of The City (Ain't No Love)","JAŸ-Z","6gpZSI0xEMTzleBc5ykOVA","1b3f6f34954118500ed3e7a7","n3GfToH_l4g"],["Nuthin' But A \"G\" Thang","Dr. Dre, Snoop Dogg","5Tbpp3OLLClPJF8t1DmrFD","9710731c9d7baec635f1bab1","8GliyDgAGQI"],["Bugatti","Ace Hood, Future, Rick Ross","08ljt6NCNAgewQaMya1URa","55dd656375f7cf3782de0cf5","djE-BLrdDDc"],["Turn Me On","Kevin Lyttle","0BBOLOV5JntPL3341swIre","73b8d34fa1ece5bb3cbf6bfb","GP3Exc5tCtc"],["Blinding Lights","The Weeknd","0VjIjW4GlUZAMYd2vXMi3b","8863bc11d2aa12b54f5aeb36","4NRXx6U8ABQ"],["One Of The Girls (with JENNIE, Lily Rose Depp)","The Weeknd, JENNIE, Lily-Rose Depp","7CyPwkp0oE8Ro9Dd5CUDjW","b0dd6a5cd1dec96c4119c262","Mx92lTYxrJQ"],["7 Years","Lukas Graham","0VQjTLPG8l3egUHmIxe265","77029eb01ff27c5f4a25c3f3","LHCob76kigA"],["King Of The Fall","The Weeknd","7o3Mcis1uKcYDuuJD1W0Rm","f60419f5fa7a022ddece0809","ZXBcwyMUrcU"],["Lady Killers II","G-Eazy","068AyhyvE67qMRsMXLqAnd","9009d02501524d8a11839819","i9L_Ew4t1xg"],["No Child Left Behind","Kanye West","3hd6zLhnTlbJ8PupYt3cAI","cad190f1a73c024e5a40dddd","sDJBhQv85K0"],["Faith","The Weeknd","3orEOtd8CPL8GFlpRpKuoE","8863bc11d2aa12b54f5aeb36","RcS_8-a-sMg"],["man at the garden","Kendrick Lamar","5ho7VSXSmI2KM2nDjcnLyz","e2a0a166493a2bde5480a420","wiALRpD0Ztg"],["Sky","Playboi Carti","29TPjc8wxfz4XMn21O7VsZ","98ea0e689c91f8fea726d9bb","KnumAWWWgUE"],["No Role Modelz","J. Cole","68Dni7IE4VyPkTOH9mRWHr","c6e0948bbb0681ff29cdbae8","8HBcV0MtAQg"],["Fresh","Kool & The Gang","1mMYaXpT65iZDtvfRA9EkE","0afe71cef9e2f4db5ebfcc82","sTJ1XwGDcA4"],["Falling Down - Bonus Track","Lil Peep, XXXTENTACION","4jvjzW7Hm0yK4LvvE0Paz9","55e36b0dc5b0ef008fc85319","-jRKsiAOAA8"],["GOD DID (feat. Rick Ross, Lil Wayne, JAY-Z, John Legend & Fridayy)","DJ Khaled, Rick Ross, Lil Wayne, JAŸ-Z, John Legend, Fridayy","2sOj9vyd6yiss9W1IK6chU","82ad88cae25c4b9a55ad6043","QugLZCp74GE"],["Kant rëlax","Yeat","48x1ElzLnuwi72ZpEbbt7L","ddbc8eccc4c64cce7f032019","k5jZP7NY0Ro"],["Memories","Maroon 5","4cktbXiXOapiLBMprHFErI","86a8ab515de4b7aef28cd631","SlPhMPnQ58k"],["Keep Their Heads Ringin'","Dr. Dre","1rylJ0VXvhOzLGNm401iaI","9330b3ab457779ed4137493b","Gg5KfL-4asE"],["Circadian Rhythm","Drake","1eroCliWpJrEu1V7VSObcO","e955f0f0a0471ace604ecdf6","_zq1Squ-Uqs"],["LA FAMA","ROSALÍA, The Weeknd","6Y46tOTRhkBamosyuWa6YX","ac8367a27c0eb7195dc3a58d","e-CEd6xrRQc"],["BESO","ROSALÍA, Rauw Alejandro","609E1JCInJncactoMmkDon","4d6cf0d0d5e32ca4fa3a59e1","QXQQAsIhHMw"],["For The Night (feat. Lil Baby & DaBaby)","Pop Smoke, Lil Baby, DaBaby","0PvFJmanyNQMseIFrU708S","77ada0863603903f57b34369","Q9pjm4cNsfc"],["Dior","Pop Smoke","79s5XnCN4TJKTVMSmOx8Ep","8fe5d04b06aff90f9fe796f5","oorVWW9ywG0"],["What You Know Bout Love","Pop Smoke","1tkg4EHVoqnhR6iFEXb60y","77ada0863603903f57b34369","uuodbSVO3z0"],["Invincible","Pop Smoke","792HwhrdO3ErRKL5yRe4Ge","62a57823eced1cb4fd93b2c1","8_oOES_uKPI"],["Espresso","Sabrina Carpenter","2HRqTpkrJO5ggZyyK6NPWz","fd8d7a8d96871e791cb1f626","eVli-tstM5E"],["Break Ya Neck","Busta Rhymes","7gKgd0P3dAAePiSQQBqrlf","075418a1fafdfd7a455941dd","W7FfCJb8JZQ"],["Purple Lamborghini (with Rick Ross)","Skrillex, Rick Ross","6JyuJFedEvPmdWQW0PkbGJ","602b6507f5289db71603c2f4","ZkqyIoYAXV8"],["Cooler Than Me - Single Mix","Mike Posner, Gigamesh","2V4bv1fNWfTcyRJKmej6Sj","d6165c0d6eba7e5bf3fca16d","mqWq_48LxWQ"],["Again","Fetty Wap","7GCwYL9fowR6Y33OBLCJEO","02928b251e41844f5186920e","77suwtdWzpk"],["What's Up Danger (with Black Caviar)","Blackway, Black Caviar","5zsHmE2gO3RefVsPyw2e3T","e2e352d89826aef6dbd5ff8f","nZFNut0RGlQ"],["Beauty And A Beat","Justin Bieber, Nicki Minaj","190jyVPHYjAqEaOGmMzdyk","6c20c4638a558132ba95bc39","Ys7-6_t7OEQ"],["Unforgettable","French Montana, Swae Lee","3B54sVLJ402zGa6Xm4YGNe","8a31195a371b2233456f6c07","CTFtOOh47oo"],["Scared of the Dark (feat. XXXTENTACION)","Lil Wayne, Ty Dolla $ign, XXXTENTACION","3vWzyGTu6Ovo1GdrcJqH6e","e2e352d89826aef6dbd5ff8f","zVlFkFmk_NM"],["Lose Yourself","Eminem","7MJQ9Nfxzh8LPZ9e9u68Fq","3f66b5b49ccea004a5ef0db2","xFYQQPAOz7Y"],["greedy","Tate McRae","3rUGC1vUpkDG9CZFHMur1t","5f677b5d3b81f08badd0775b","To4SWGZkEPk"],["Abracadabra","Lady Gaga","2LHNTC9QZxsL3nWpt8iaSR","b0860cf0a98e09663c82290c","vBynw9Isr28"],["Sports car","Tate McRae","5UJbgR4XF4y1DvbkxEqe8S","6c691022744f42565f6b546e","7InTkBxPtK4"],["TORE UP","Don Toliver","1jKXjxMWlq4BhH6f9GtZbu","b5050e0d58c704da6bb519e1","PvtQwxZJmL8"],["Easier to Run","Linkin Park","32fEW4jygJjjnZh2iBa5IR","8b5b6fa1326d996181e71dd7","U5zdmjVeQzE"],["Ignite the World","Vybz Kartel","4y4C4B2g9S7Ui2QT8aFIj6","c071632caabf56625063f578","HJ6cffVy-bo"],["Telephone","Lady Gaga, Beyoncé","3MzuXxZE0yAT3ypwNVfmBJ","2e0830bb20df176018c18391","EVBsypHzF3U"],["Got 2 Luv U - feat. Alexis Jordan","Sean Paul","77sFlmQh56N5VSBMKX7e63","162f99980b0244ebb843e256","tDq3fNew1rU"],["Too Many Nights (feat. Don Toliver & with Future)","Metro Boomin, Future, Don Toliver","2Hh3ETdQKrmSI3QS0hme7g","c4fee55d7b51479627c31f89","NyTkaQHdySM"],["Lemonade (feat. NAV)","Internet Money, Gunna, Don Toliver, NAV","1p0rEzrK7YtdRZVtiyV7RN","c4adc981dc6656e52c916088","0opZqh_TprM"],["Around Me (feat. Don Toliver)","Metro Boomin, Don Toliver","221qmpQeBNV87sUjQeUTVH","c4fee55d7b51479627c31f89","IjnCoWA9u9M"],["Hey Baby (Drop It to the Floor) (feat. T-Pain)","Pitbull, T-Pain","3rfhI32Il2hVRKDkuGeeen","1dc7483a9fcfce54822a2f19","LefQdEMJP1I"],["Everyday","Logic, Marshmello","4EAV2cKiqKP5UPZmY6dejk","e19b1b51cdd35051e17cf6dc","_qQsPw4CqUI"],["No Church In The Wild","JAŸ-Z, Kanye West, Frank Ocean, THE-DREAM","7r6PigmGzlB3YPB7wvBBbi","52e61456aa4995ba48d94e30","FJt7gNi3Nr4"],["Otis","JAŸ-Z, Kanye West, Otis Redding","14I61w6cyYUHiV2n28IYdP","52e61456aa4995ba48d94e30","BoEKWtgJQAU"],["Rock That Body","Black Eyed Peas","2WQ09wqQBIOor7Q0VpIDBK","0bd44f5ff9ecc99f7770acc5","nmnjL26OBcY"],["What's My Name?","Rihanna, Drake","6DkXLzBQT7cwXmTyzAB1DJ","31548865f7c729290b96c794","U0CGsw6h60k"],["Boys Don’t Cry","Lil Tecca","6aCzWpIVNoaT8OTeQ3w8If","86c8cd0e15776fa1e18715ec","VCsgTKE5taQ"],["It’s My Birthday","will.i.am, Cody Wise","1pNcUexH7BdMFWFaxV3ltq","4b8bfb5fc950bcf83741b65e","JuM7hObGjWI"],["My Love (feat. Drake)","Majid Jordan, Drake","5fgTKJ5PTbRLzem1tkfFjx","99b1ec1e1412e7d5ee6926c1","eqJ-Shv3kEw"],["I Don't Fuck With You","Big Sean, E-40","7FYH5AW3bVfZHJIQpq3UOA","50192d5f728fea13fb3af203","cZaJYDPY-YQ"],["Lose My Mind (feat. Doja Cat) [From F1® The Movie]","Don Toliver, Doja Cat, F1 The Album","02BcXEH1zJYbXSabPtNlKf","d4c0243b55cdf7394323e710","WWEs82u37Mw"],["True Love","Kanye West, XXXTENTACION","06JvOZ39sK8D8SqiqfaxDU","53edd144e063daae819190e5","k7H2C5L8X7I"],["The Recipe - Bonus Track","Kendrick Lamar, Dr. Dre","5jHilrZDaP1vJMZfdN1He3","78de8b28de36a74afc0348b5","YpugK0RpEaU"],["Man Of The Year","ScHoolboy Q","5SsR3wtCOafDmZgvIdRhSm","36977e237a8f70ec6c990636","rEMsjeq43_U"],["Victory Lap","Fred again.., Skepta, PlaqueBoyMax","1lbNgoJ5iMrMluCyhI4OQP","bf705b821b031cefe91d7b90","08C987fQEKU"],["Cry for You","September","1mvZErZBp7WZT3HfGBykao","e1a050d8545416935386e73a","si0VFSOH0wQ"],["Love Don't Let Me Go","David Guetta","0mIAWTIXUP9Os5RBXKclO6","f807d069bb722aced899e54f","_WA9NXXAntc"],["Chains & Whips","Clipse, Kendrick Lamar, Pharrell Williams, Pusha T, Malice","3znSvEwBq09We4cxxmwlZM","ef854fe1d04279372a96f3d6","ecIH-4RbbOk"],["Where Ya At (feat. Drake)","Future, Drake","5nN8BwAQDJDguq7Dpd3JQQ","b2592bea12d840fd096ef965","lw3Or6eqIpI"],["In the End","Linkin Park","60a0Rd6pjrkxjPbaKzXjfq","e2f039481babe23658fc719a","eVTXPUF4Oz4"],["I Know","Big Sean, Jhené Aiko","6rje9f1wRFJDO2iTORw0lH","50192d5f728fea13fb3af203","YWpTQM-CCTM"],["the ends","Travis Scott","33zbOXJSwW7uf4VXXWow2O","8752a7355996e64709247c53","hF1sqWiqppE"],["3500 (feat. Future & 2 Chainz)","Travis Scott, Future, 2 Chainz","1SGt65i9AnXYdDQt1AtDRH","d3b5affd8824b4ed301b7137","3qNaoLgHU94"],["Beware","Big Sean, Lil Wayne, Jhené Aiko","3Byz6Mk9WCNYeGthiDVti2","73077b16706dbd3dca4b6948","L-rQZ6IGhCM"],["Party In The U.S.A.","Miley Cyrus","3E7dfMvvCLUddWissuqMwr","4ea6653890e297d53e93e3e0","M11SvDtPBhA"],["Wrecking Ball","Miley Cyrus","2vwlzO0Qp8kfEtzTsCXfyE","c19a3bef3b59347c8070770b","My2FRPA3Gf8"],["CHAMPAIN & VACAY","Travis Scott, Don Toliver","5wNIHa6wvCCKP6fWgo3UAh","5d0f8a4c3623e02a79928288","K3crzpqVcQQ"],["Can't Remember to Forget You (feat. Rihanna)","Shakira, Rihanna","7o1Pm9jpH0wFpN5g793Lnq","0da1a7e7f3e9ef163e1c1dbf","o3mP3mJDL2k"],["X Gon' Give It To Ya - Int'l Bonus track","DMX","66orjI5vOkyxOZLHWrPklh","f83cbf5c904d383623b23211","fGx6K90TmCI"],["Stressed Out","Twenty One Pilots","3CRDbSIZ4r5MsZ0YwxuEkn","2df0d98a423025032d0db1f7","pXRviuL6vMY"],["The Line (from the series Arcane League of Legends)","Arcane, Twenty One Pilots","1QJbDTZAO8rpGOMG4UahFM","4aaf2413384c1efcc38353c6","E2Rj2gQAyPA"],["Last Time That I Checc'd (feat. YG)","Nipsey Hussle, YG","39xWBHPM4E9MwzEy5gbM7p","ac271e5d670e92c42bf99237","QM9xgHibvzM"],["New Slaves","Kanye West","4cAgkb0ifwn0FSHGXnr4F6","1dacfbc31cc873d132958af9","vQ0u09mFodw"],["Sex, Drugs, Etc.","Beach Weather","7MlDNspYwfqnHxORufupwq","511b07369101734098b14b0d","FgS1b2nU8AQ"],["Trouble on My Mind","Pusha T, Tyler, The Creator","3DzlR0kXE6shimFVhSwI4A","2749e1b9049f703e43ece068","2GKL_ZoJQjc"],["Take Me In Your Arms","Lil Suzy","51k2LB1iizPL9grpAkQrco","272e3f262dbe89971e0b8351","u4dtixas8xo"],["Kream (feat. Tyga)","Iggy Azalea, Tyga","5mu1uv8RmzDkF8foePK5qa","2fe64d6b4d019a38af3dcdc4","t7lM7Bn16Zg"],["Heathens","Twenty One Pilots","6i0V12jOa3mr6uu4WYhUBr","2ca3ba8f334ca5a5f0312efb","UprcpdwuwCg"],["Lush Life","Zara Larsson","1rIKgCH4H52lrvDcz50hS8","401bf6103d4b7f5230a21582","tD4HCZe-tew"],["(When You Gonna) Give It Up to Me - Radio Version","Sean Paul, Keyshia Cole","5nEdwtSv0qqeE0l4o1lR4q","a539563b3d77bd3ba17d016e","bMoNV9oWs2E"],["Photographs","Rihanna, will.i.am","4iywo4hJoh7MxFdMLFqYhN","ab647295c0c97446c1f1a3b5","Ey5jKdjBwj0"],["Shower","Becky G","3DmW6y7wTEYHJZlLo1r6XJ","f7f5503cfc6a54d31e65b112","50-_oTkmF5I"],["Hello","Martin Solveig, Dragonette","2Hy89WQAxszEUQAvpja0nx","699ca1acc6307dbcfb021a0a","LnET4RKXx5k"],["Stateside + Zara Larsson","PinkPantheress, Zara Larsson","1DwscornXpj8fmOmYVlqZt","684ecc5bc1b724d0106ad694","lIxQe1R5hs0"],["Midnight Sun","Zara Larsson","1qRV1dKLOfH1s00b9J2LUQ","7657f9028ea8bb2c18dca99f","uvY8fdgezLQ"],["My Moment (feat. 2 Chainz, Meek Mill and Jeremih)","DJ Drama, Jeremih, 2 Chainz, Meek Mill","3Gva0j7oBU6MdvUMQyDRTJ","94af37bf31370e0d738a7a24","oA526TjFRjY"],["Timeless (feat Playboi Carti)","The Weeknd, Playboi Carti","0FIDCNYYjNvPVimz5icugS","de79f330bc297af3fae736da","5EpyN_6dqyk"]];  // [titre, artistes, id Spotify, pochette, id YouTube]
const K = 32, MY_LB = 'msnss', MY_PL = '5RdEh4rZWnPZgvuz22h8zf';
const ONLINE = /^https?:$/.test(location.protocol);

/* ---------- Outils ---------- */
function keyHash(s){ s = String(s).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]/g,''); let x = 5381; for (let i=0;i<s.length;i++) x = ((x*33) ^ s.charCodeAt(i)) >>> 0; return x.toString(36); }
const posterUrl = p => !p ? '' : /^https?:/.test(p) ? p : p[0]==='/' ? `https://a.ltrbxd.com/resized${p}-0-300-0-450-crop.jpg` : `https://a.ltrbxd.com/resized/film-poster/${p.split('-')[0].split('').join('/')}/${p}-0-300-0-450-crop.jpg`;
const coverUrl = c => !c ? '' : /^https?:/.test(c) ? c : c[0]==='!' ? `https://i.scdn.co/image/${c.slice(1)}` : `https://i.scdn.co/image/ab67616d00001e02${c}`;
window.noPoster = el => { const d=document.createElement('div'); d.className='noposter '+el.className.replace(/\bposter\b/,''); d.textContent=el.alt.replace(/^Image de /,''); el.replaceWith(d); };
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmt = n => n.toLocaleString('fr-FR');
const $ = id => document.getElementById(id);
const view = $('view');
const starStr = r => r ? '★'.repeat(Math.floor(r/2)) + (r%2 ? '½' : '') : '';
/* Stockage : cache en mémoire + IndexedDB (pas de limite de 5 Mo comme localStorage) */
const MEM = new Map(); let IDB = null, LSVER = 0;
function idbOpen(){ return new Promise(res => { try { const r = indexedDB.open('ring', 1); r.onupgradeneeded = () => r.result.createObjectStore('kv'); r.onsuccess = () => res(r.result); r.onerror = () => res(null); r.onblocked = () => res(null); setTimeout(() => res(null), 4000); } catch(e){ res(null); } }); }
let idbWarned = false;
function idbTx(fn){ if (!IDB) return false; try { const tx = IDB.transaction('kv', 'readwrite'); tx.onabort = tx.onerror = () => { if (!idbWarned) { idbWarned = true; try { toast('Stockage plein : exporte ta sauvegarde (Réglages) puis supprime un ring.'); } catch(e){} } }; fn(tx.objectStore('kv')); return true; } catch(e){ return false; } }
function lsKeys(){ const out = []; try { for (let i=0;i<localStorage.length;i++){ const k = localStorage.key(i); if (k && k.startsWith('ringcine-')) out.push(k); } } catch(e){} return out; }
async function idbLoad(){
  IDB = await idbOpen();
  if (IDB) {
    await new Promise(res => { try { const rq = IDB.transaction('kv').objectStore('kv').openCursor(); rq.onsuccess = () => { const c = rq.result; if (c) { MEM.set(c.key, c.value); c.continue(); } else res(); }; rq.onerror = () => res(); } catch(e){ res(); } });
    if (!MEM.size) { const ks = lsKeys(); ks.forEach(k => MEM.set(k, localStorage.getItem(k))); if (ks.length) idbTx(st => ks.forEach(k => st.put(MEM.get(k), k))); }
  } else lsKeys().forEach(k => MEM.set(k, localStorage.getItem(k)));
}
const ls = {
  get(k, d){ const v = MEM.get(k); if (v == null) return d; try { return JSON.parse(v); } catch(e){ return d; } },
  set(k, v){ const s = JSON.stringify(v), ts = String(Date.now()); LSVER++; MEM.set(k, s); MEM.set('ringcine-ts', ts); if (!idbTx(st => { st.put(s, k); st.put(ts, 'ringcine-ts'); })) { try { localStorage.setItem(k, s); } catch(e){ return false; } } schedulePush(); return true; },
  del(k){ LSVER++; MEM.delete(k); if (!idbTx(st => st.delete(k))) { try { localStorage.removeItem(k); } catch(e){} } schedulePush(); }
};
function toast(t){ document.querySelectorAll('.toast').forEach(x=>x.remove()); const el=document.createElement('div'); el.className='toast'; el.textContent=t; document.body.appendChild(el); setTimeout(()=>el.remove(), 2600); }
async function copyText(t){ try { await navigator.clipboard.writeText(t); return true; } catch(e){ return false; } }

/* ---------- Collections ---------- */
const TYPES = {
  films: {one:'film', many:'films', brand:'Ciné', sq:false, seed: it => 1500 + ((it.r || 6) - 6) * 40},
  music: {one:'son', many:'sons', brand:'Son', sq:true, seed: () => 1500},
  items: {one:'élément', many:'éléments', brand:'Mix', sq:false, seed: () => 1500},
};
const KINDS = {series:{one:'série', many:'séries', brand:'Séries'}, anime:{one:'animé', many:'animés', brand:'Animés'}, manga:{one:'manga', many:'mangas', brand:'Mangas'}, games:{one:'jeu', many:'jeux', brand:'Jeux'}};
const BUILTIN = [
  {id:'films', type:'films', label:'Mes films', user:MY_LB, key:'ringcine-v1', builtin:true},
  {id:'music', type:'music', label:'Ma playlist 🇺🇸', pl:MY_PL, key:'ringcine-music-v1', builtin:true},
];
const customCols = () => ls.get('ringcine-cols', []);
const allCols = () => BUILTIN.concat(customCols());
const colById = id => allCols().find(c => c.id === id);
const stateKey = col => col.key || 'ringcine-st-' + col.id;
function colRows(col){
  if (col.id === 'films') { const ov = ls.get('ringcine-ratings', {}); return FILM_DATA.concat(ls.get('ringcine-extra-films', [])).map(r => { const k = keyHash(`${r[0]} (${r[1]})`); return ov[k] !== undefined ? [r[0], r[1], r[2], ov[k], r[4]] : r; }); }
  if (col.id === 'music') return MUSIC_DATA.concat(ls.get('ringcine-extra-music', []));
  return ls.get('ringcine-data-' + col.id, []);
}
function colType(col){ let t = TYPES[col.type] || TYPES.items; if (col.kind && KINDS[col.kind]) t = Object.assign({}, t, KINDS[col.kind]); return col.shape ? Object.assign({}, t, {sq: col.shape === 'sq'}) : t; }
const isSp = i => /^[A-Za-z0-9]{22}$/.test(F[i].id || '');
const safeUrl = u => { u = String(u || ''); return /^https?:\/\/[^\s"'<>]+$/i.test(u) ? u : ''; };
const safeYt = v => /^[\w-]{11}$/.test(v || '') ? v : '';
const safeId = v => { v = String(v || ''); return /^[\w:.\-]{1,80}$/.test(v) ? v : 'x:' + keyHash(v); };
function buildItems(col){ const OT = col.type === 'films' ? ls.get('ringcine-ot', {}) : null, FRT = col.type === 'films' ? ls.get('ringcine-fr', {}) : null; return buildItemsRaw(col).map(it => { if (OT) { it.en = it.t; const o = OT[it.key]; if (o) it.t = o; const f = FRT[it.key]; if (f && norm(f) !== norm(it.t) && norm(f) !== norm(it.en)) it.fr = f; } it.img = safeUrl(it.img); if ('yt' in it) it.yt = safeYt(it.yt); if ('link' in it) it.link = safeUrl(it.link); if ('y' in it) it.y = +it.y || 0; if ('r' in it) it.r = +it.r || 0; if ('id' in it) it.id = safeId(it.id); return it; }); }
function buildItemsRaw(col){
  const rows = colRows(col);
  if (col.type === 'items') return rows.map(([t,sub,im,link,key]) => ({t, sub, img:im||'', link, key: key || keyHash(link || t), first:''}));
  if (col.type === 'films') return rows.map(([t,y,d,r,p]) => ({t, y, sub:d, r, p, img: posterUrl(p), key: keyHash(`${t} (${y})`)}));
  const ym = ls.get('ringcine-yt', {}); if (!window.__byt) { window.__byt = {}; MUSIC_DATA.forEach(r => { if (r[4]) window.__byt[r[2]] = r[4]; }); }
  return rows.map(([t,a,id,c,yt]) => ({t, sub:a, id, c, img: coverUrl(c), key:id, first:(a||'').split(', ')[0], yt: yt || ym[id] || window.__byt[id] || ''}));
}
let C, TY, F, N, S;
const zeros = () => new Array(N).fill(0);
function fresh(){ return {elo:F.map(it=>TY.seed(it)), w:zeros(), l:zeros(), d:zeros(), total:0, log:[], tour:null, view:'duel', filter:'all'}; }
function loadCol(id){
  if (typeof EXT === 'object') { EXT.on = false; EXT.saved = null; }
  C = colById(id) || BUILTIN[0]; TY = colType(C); fxOpen = false; pair = null; nextPair = null; if (typeof G === 'object' && G) { G.tok++; G.id = null; G.cur = null; } F = buildItems(C); N = F.length;
  S = ls.get(stateKey(C), null);
  if (!S || !S.elo) S = fresh();
  migrate();
  ls.set('ringcine-col', C.id);
  if (typeof otRun === 'function' && otReady) { setTimeout(otRun, 800); setTimeout(prefetchRun, 20000); }
}
function migrate(){
  if (!S.log) S.log = (S.hist||[]).map(h => ({w:h.win, l:h.lose, dl:h.d, m:h.mode}));
  delete S.hist;
  S.d ||= new Array(S.elo.length).fill(0); S.filter ||= 'all';
  for (let i=S.elo.length; i<N; i++){ S.elo.push(TY.seed(F[i])); S.w.push(0); S.l.push(0); S.d.push(0); }
  const t = S.tour;
  if (t) {
    if (!t.ent) t.ent = [...Array(S.elo.length).keys()];
    if (!t.first) { let p=1; while(p*2<=t.ent.length) p*=2; t.first=p; }
    if (t.hasPre === undefined) t.hasPre = t.prelim || t.log.some(m=>m.prelim);
    if (!t.label) t.label = 'Le grand tournoi';
  }
}
const save = () => { if (!ls.set(stateKey(C), S)) toast('Stockage plein : exporte ta sauvegarde puis supprime une collection.'); if (typeof trophyTick === 'function') trophyTick(); };

/* ---------- Moteur Elo ---------- */
function play(win, lose, mode, draw){
  const ew = 1/(1+10**((S.elo[lose]-S.elo[win])/400));
  const dl = K*((draw?0.5:1)-ew);
  S.elo[win]+=dl; S.elo[lose]-=dl;
  if (draw){ S.d[win]++; S.d[lose]++; } else { S.w[win]++; S.l[lose]++; }
  S.total++;
  const t = Date.now(); S.log.push(draw ? {w:win,l:lose,dl,m:mode,dr:1,t} : {w:win,l:lose,dl,m:mode,t});
}
function unplayAt(idx){
  const h = S.log[idx]; if (!h) return null;
  S.log.splice(idx,1);
  S.elo[h.w]-=h.dl; S.elo[h.l]+=h.dl;
  if (h.dr){ S.d[h.w]--; S.d[h.l]--; } else { S.w[h.w]--; S.l[h.l]--; }
  S.total--; return h;
}
function lastIdx(mode){ for (let k=S.log.length-1;k>=0;k--) if (S.log[k].m===mode) return k; return -1; }
function rankOf(elo, n){
  const order = [...Array(n).keys()].sort((a,b)=>elo[b]-elo[a]);
  const rank = new Int32Array(n); order.forEach((id,k)=>rank[id]=k+1);
  return {order, rank};
}
const ranking = () => rankOf(S.elo, N);
const games = i => S.w[i]+S.l[i]+S.d[i];

/* ---------- Lecteurs (YouTube / Spotify) ---------- */
let playerPref = ls.get('ringcine-player', 'yt');
const ytSearch = i => `https://www.youtube.com/results?search_query=${encodeURIComponent((F[i].first||F[i].sub||'')+' '+F[i].t)}`;
const ytEmbed = v => `<iframe class="ytf" src="https://www.youtube.com/embed/${v}?rel=0&amp;playsinline=1&amp;enablejsapi=1${ONLINE ? '&amp;origin=' + encodeURIComponent(location.origin) : ''}" onload="ytListen(this)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin" loading="lazy" title="Vidéo YouTube"></iframe>`;
const spEmbed = i => `<iframe class="spf" src="https://open.spotify.com/embed/track/${F[i].id}?utm_source=generator&amp;theme=0" loading="lazy" allow="autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture" title="Lecteur Spotify"></iframe>`;
/* Un seul lecteur à la fois : quand une vidéo démarre, les autres se mettent en pause */
window.ytListen = f => { const hi = () => { try { f.contentWindow.postMessage(JSON.stringify({event:'listening', id:'ring', channel:'widget'}), '*'); } catch(e){} }; hi(); setTimeout(hi, 800); setTimeout(hi, 2500); };
const playState = new Map();
function pauseFrame(f){
  try {
    if (f.classList.contains('ytf')) f.contentWindow.postMessage(JSON.stringify({event:'command', func:'pauseVideo', args:[]}), '*');
    else f.contentWindow.postMessage({command:'pause'}, '*');
  } catch(e){}
}
window.addEventListener('message', e => {
  let d = e.data;
  if (typeof d === 'string') { try { d = JSON.parse(d); } catch(err) { return; } }
  if (!d || typeof d !== 'object') return;
  let playing;
  if (/youtube/.test(e.origin)) {
    if (d.event === 'onStateChange') playing = d.info === 1;
    else if (d.event === 'infoDelivery' && d.info && typeof d.info.playerState === 'number') playing = d.info.playerState === 1;
  } else if (/spotify/.test(e.origin)) {
    if (d.type === 'playback_update' && d.payload && typeof d.payload.isPaused === 'boolean') playing = !d.payload.isPaused;
  }
  if (playing === undefined) return;
  const was = playState.get(e.source);
  playState.set(e.source, playing);
  if (playing && !was) document.querySelectorAll('iframe.ytf, iframe.spf').forEach(f => { if (f.contentWindow !== e.source) { pauseFrame(f); playState.set(f.contentWindow, false); } });
});
function slotHtml(i){
  if (playerPref === 'sp' && isSp(i)) return spEmbed(i);
  if (F[i].yt) return ytEmbed(F[i].yt);
  return `<button class="btn findyt" data-i="${i}">Trouver la vidéo YouTube</button>`;
}
function playerHtml(i, side){
  return `<div class="player" data-i="${i}"${side!=null?` data-side="${side}"`:''}><div class="pbar">${side!=null?`<kbd class="pk" title="Lecture / pause au clavier">${side?'E':'A'} ▶</kbd>`:''}<button class="pb${playerPref==='yt'?' on':''}" data-p="yt">YouTube</button>${isSp(i) ? `<button class="pb${playerPref==='sp'?' on':''}" data-p="sp">Spotify</button>` : ''}<a class="pout" href="${playerPref==='sp' && isSp(i) ? 'https://open.spotify.com/track/'+F[i].id : F[i].yt ? 'https://www.youtube.com/watch?v='+F[i].yt : ytSearch(i)}" target="_blank" rel="noopener" title="Ouvrir dans un nouvel onglet">↗</a></div><div class="pslot">${slotHtml(i)}</div></div>`;
}
function refreshPlayers(){ view.querySelectorAll('.player').forEach(p => { p.outerHTML = playerHtml(+p.dataset.i, p.dataset.side!=null ? +p.dataset.side : null); }); }
view.addEventListener('click', async e => {
  const pb = e.target.closest('.pb');
  if (pb){ playerPref = pb.dataset.p; ls.set('ringcine-player', playerPref); refreshPlayers(); return; }
  const fy = e.target.closest('.findyt');
  if (fy){
    const i = +fy.dataset.i;
    if (!ONLINE){ window.open(ytSearch(i), '_blank'); return; }
    fy.textContent = 'Recherche…'; fy.disabled = true;
    try { const j = await (await fetch('/yt?q=' + encodeURIComponent((F[i].first||'') + ' ' + F[i].t))).json();
      if (j.id){ F[i].yt = j.id; const m = ls.get('ringcine-yt', {}); m[F[i].id] = j.id; ls.set('ringcine-yt', m); refreshPlayers(); return; } } catch(err){}
    window.open(ytSearch(i), '_blank'); fy.textContent = 'Trouver la vidéo YouTube'; fy.disabled = false;
  }
});

/* ---------- Rendu commun ---------- */
const T = i => esc(F[i].t);
/* Images en haute qualité (affiches Letterboxd 1000×1500, pochettes Spotify 640×640…) */
/* taille "écran" (600×900) : nette et 2,5× plus légère que 1000×1500 ; hiRes(u, true) pour les images PNG / zoom */
function hiRes(u, huge){
  if (!u) return u;
  return u.replace(/-0-\d+-0-\d+-crop\.jpg/, huge ? '-0-1000-0-1500-crop.jpg' : '-0-600-0-900-crop.jpg')
    .replace(/\/image\/ab67616d0000(1e02|4851)/, '/image/ab67616d0000b273')
    .replace(/(dzcdn\.net\/images\/[^/]+\/[^/]+\/)\d+x\d+/, '$11000x1000')
    .replace(/(mzstatic\.com\/.+\/)\d+x\d+(bb|cc)?\.(jpg|png|webp)$/, '$11000x1000bb.jpg');
}
const tinyRes = u => !u ? u : u.replace(/-0-\d+-0-\d+-crop\.jpg/, '-0-70-0-105-crop.jpg').replace(/\/image\/ab67616d0000(1e02|b273)/, '/image/ab67616d00004851');
function img(i, cls='poster', items=F, sq=TY.sq, hi=false){
  const it = items[i], c = cls + (sq ? ' sq' : '');
  if (!it.img) return `<div class="noposter ${c}">${esc(it.t)}</div>`;
  const h = hi ? hiRes(it.img) : it.img;
  return `<img class="${c}" src="${h}" ${h !== it.img ? `data-lo="${it.img}" ` : ''}alt="Image de ${esc(it.t)}" loading="lazy" decoding="async" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}else noPoster(this)">`;
}
const imgHi = (i, cls='poster') => img(i, cls, F, TY.sq, true);
const thumb = i => img(i, 'th');
function metaLine(i){
  const it = F[i];
  if (C.type==='music') return `<span>${esc(it.sub)}</span>`;
  return `<span>${it.y||''}</span>${it.sub?`<span>${esc(it.sub)}</span>`:''}${it.r?`<span class="stars" title="Note Letterboxd">${starStr(it.r)}</span>`:''}`;
}
function curStats(){
  let played=0, solid=0; for (let i=0;i<N;i++){ const g=games(i); if(g) played++; if(g>=3) solid++; }
  return {played, pct: N ? Math.round(solid/N*100) : 0};
}
function stats(){ renderTop(); }
function srcLabel(col){ if (col.host) return esc(col.host); return col.type==='films' ? `Letterboxd${col.user ? ' · ' + esc(col.user) : ''}` : col.type==='music' ? 'Spotify' : 'Liste'; }
const typeName = t => ({films:'Films', music:'Musique', items:'Autre'})[t] || 'Autre';
function renderTop(){
  const top = $('top'), home = curView === 'home';
  const nav = [['home','Accueil','H'],['duel','Duels','D'],['rank','Classement','C'],['tour','Tournoi','T'],['game','Jeux','J']], more = ['tier','swipe','tonight','stats','trophy'].includes(curView);
  const st = C ? curStats() : null, t = S && S.tour;
  top.innerHTML = `<div class="nav">
      <button class="brand" id="logo" aria-label="Accueil">RING<span>${C ? esc(TY.brand) : ''}</span></button>
      <nav class="navl" role="tablist">${nav.map(([v, l, k]) => `<button class="tab" role="tab" data-v="${v}" aria-selected="${curView === v}" title="${l} (touche ${k})">${l}</button>`).join('')}<button class="tab" id="navmore" aria-selected="${more}">${more ? {tier:'Tier list',swipe:'Plus ou moins',tonight:'Ce soir',stats:'Stats',trophy:'Trophées'}[curView] : 'Plus'} ▾</button></nav>
      <div class="navr">
        ${C ? `<button class="ringsel" id="pickbtn" title="Changer de ring (G)"><span class="rs-ico">${colIcon(C)}</span><span class="rs-t"><small>${typeName(C.type)}</small><b>${esc(C.label)}</b></span><span class="chev">▾</span></button>` : ''}
        <button class="icon-btn" id="topadd" title="Ajouter / mettre à jour un ring (S)">＋</button>
        <button class="icon-btn" id="setbtn" title="Réglages et sauvegarde">⚙<span class="conn ${SERVER ? 'ok' : 'off'}" id="conn"></span></button>
      </div>
    </div>
    ${home || !C ? '' : `<div class="subbar"><div class="ttl"><span class="kicker">${typeName(C.type)} · ${srcLabel(C)}</span><h1>${esc(C.label)}</h1></div>
      <div class="pills"><span class="pill"><b>${fmt(N)}</b> ${TY.many}</span><span class="pill"><b>${fmt(S.total)}</b> duels</span>${t && !t.done ? `<span class="pill">Tournoi <b>${fmt(t.log.length)}/${fmt(t.ent.length - 1)}</b></span>` : ''}</div></div>`}`;
  top.querySelectorAll('.tab[data-v]').forEach(b => b.onclick = () => go(b.dataset.v));
  $('logo').onclick = () => go('home');
  if ($('pickbtn')) $('pickbtn').onclick = openPicker;
  $('topadd').onclick = () => openSync();
  $('navmore').onclick = openMore;
  $('setbtn').onclick = openSettings;
}
window.addEventListener('scroll', () => { const t = $('top'); if (t) t.classList.toggle('solid', scrollY > 30); }, {passive:true});
function card(i, side, rank){
  const g = games(i);
  return `<div class="fighter"><button class="card ${side}" data-i="${i}" aria-label="Choisir ${T(i)}">
    <span class="art">${imgHi(i)}<span class="corner">${side==='l'?'← ROUGE':'BLEU →'}</span><span class="rankb">#${rank[i]}</span><span class="pick">Choisir</span><span class="stamp">K.O.</span></span>
    <span class="ctitle">${T(i)}</span>
    <span class="cmeta">${metaLine(i)}</span>
    <span class="badge"><b>${Math.round(S.elo[i])} pts</b> · ${g ? `${S.w[i]}V ${S.l[i]}D${S.d[i]?` ${S.d[i]}N`:''}` : 'premier combat'}</span>
  </button>${C.type==='music' ? playerHtml(i, side==='l'?0:1) : ''}</div>`;
}
const stageBg = (a, b) => `<div class="stage-bg">${[a,b].map(i => F[i].img ? `<img src="${esc(tinyRes(F[i].img))}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : '<div></div>').join('')}</div>`;
function fightRow(h, tag){
  return `<div class="fight${h.dr?' dr':''}"><span class="fx w">${thumb(h.w)}<span class="nm">${T(h.w)}</span></span><span class="x">${h.dr?'ÉGALITÉ':'BAT'}</span><span class="fx lo">${thumb(h.l)}<span class="nm">${T(h.l)}</span></span><span class="tag">${tag}</span></div>`;
}
function animate(win, lose, draw, then){
  const cw = view.querySelector(`.card[data-i="${win}"]`), cl = view.querySelector(`.card[data-i="${lose}"]`);
  if (draw){ [cw,cl].forEach(c=>{ if(c){ const s=c.querySelector('.stamp'); s.textContent='NUL'; s.classList.add('draw'); c.classList.add('ko'); } }); }
  else {
    if (cw) cw.classList.add('win'); if (cl) cl.classList.add('ko');
    const st = view.querySelector('.stage'); if (st && cw) { st.classList.remove('hit-l','hit-r'); void st.offsetWidth; st.classList.add(cw.classList.contains('l') ? 'hit-l' : 'hit-r'); }
  }
  view.querySelectorAll('.card, .actbar .btn').forEach(c=>c.disabled=true);
  setTimeout(then, 190);
}
function bindPickButtons(){
  view.querySelectorAll('[data-pick]').forEach(b => b.onclick = () => { const c = view.querySelectorAll('.card')[+b.dataset.pick]; if (c && !c.disabled) c.click(); });
}
const videoHint = () => C.type==='music' && playerPref==='yt' && !SERVER ? `<div class="filehint">Si les vidéos YouTube affichent une erreur, ouvre Ring avec <b>Ring.bat</b> (dans tes Téléchargements) : YouTube refuse souvent de se lancer dans un fichier ouvert directement.</div>` : '';

/* ---------- Duels ---------- */
function filterList(){ const L = filterListRaw(); if (keptSet().size >= 2) L.splice(1, 0, ['keep','Mes gardés ♥']); return L; }
function filterListRaw(){
  if (C.type==='items') return [['all','Tout'],['top100','Le top 100 actuel'],['new','Jamais combattus']];
  if (C.type==='films') return [['all','Toutes les époques'],['2020','Années 2020'],['2010','Années 2010'],['2000','Années 2000'],['1990','Années 90'],['old','Avant 1990'],['fav','Notés ★★★★ et +'],['top100','Le top 100 actuel'],['new','Jamais combattus']];
  const cnt = new Map(); F.forEach(it => cnt.set(it.first, (cnt.get(it.first)||0)+1));
  const arts = [...cnt].filter(([a,n])=>a && n>=3).sort((a,b)=>b[1]-a[1]).map(([a,n])=>['a:'+a, `${a} (${n})`]);
  return [['all','Toute la playlist'],['top100','Le top 100 actuel'],['new','Jamais combattus'], ...arts];
}
function matches(i, f, top){
  const it = F[i];
  if (f==='all') return true;
  if (f==='top100') return top ? top.has(i) : true;
  if (f==='new') return !games(i);
  if (f==='keep') return keptSet().has(F[i].key);
  if (f.startsWith('a:')) return it.first===f.slice(2);
  if (f==='old') return it.y<1990;
  if (f==='fav') return it.r>=8;
  if (/^\d+$/.test(f)) return it.y>=+f && it.y<+f+10;
  return true;
}
function pool(){
  const f = S.filter, top = f==='top100' ? new Set(ranking().order.slice(0,100)) : null;
  const out = []; for (let i=0;i<N;i++) if (matches(i,f,top) && fxMatch(i)) out.push(i);
  return out.length >= 2 ? out : [...Array(N).keys()];
}
let pair = null;
function pickPair(){
  const bs = typeof battleSides === 'function' ? battleSides() : null;
  if (bs) { const [A, B] = bs; let mg = Infinity; A.forEach(i => { mg = Math.min(mg, games(i)); }); const a = pick1(A.filter(i => games(i) <= mg + 1)); let best = B[0], bd = Infinity; for (let t = 0; t < 40; t++) { const b = pick1(B), d = Math.abs(S.elo[a] - S.elo[b]) + Math.random() * 80; if (d < bd) { bd = d; best = b; } } return Math.random() < .5 ? [a, best] : [best, a]; }
  const P = pool();
  const recent = new Set(S.log.slice(-400).map(h => h.w<h.l ? h.w+'-'+h.l : h.l+'-'+h.w));
  let minG = Infinity; for (const i of P){ const g=games(i); if(g<minG) minG=g; }
  const cand = P.filter(i => games(i) <= minG+1);
  const a = cand[Math.floor(Math.random()*cand.length)];
  let best=-1, bd=Infinity;
  for (let t=0;t<60;t++){
    const b=P[Math.floor(Math.random()*P.length)]; if(b===a) continue;
    const seen = recent.has(a<b ? a+'-'+b : b+'-'+a);
    const dd=Math.abs(S.elo[a]-S.elo[b])+Math.random()*60 + (seen?100000:0);
    if(dd<bd){bd=dd;best=b;}
  }
  if (best<0) best = P.find(x=>x!==a);
  return Math.random()<.5 ? [a,best] : [best,a];
}
function renderDuel(){
  if (N < 2){ view.innerHTML = '<div class="empty">Pas assez d’éléments dans cette collection.</div>'; return; }
  if (!pair || pair[0]>=N || pair[1]>=N) pair = pickPair();
  const [a,b] = pair, {rank, order} = ranking();
  const recent = S.log.filter(h=>h.m==='duel').slice(-8).reverse();
  const opts = filterList();
  if (!opts.some(o=>o[0]===S.filter)) S.filter = 'all';
  const main = opts.filter(o => !o[0].startsWith('a:')), arts = opts.filter(o => o[0].startsWith('a:'));
  view.innerHTML = `${videoHint()}
  <section class="stage">
    ${stageBg(a,b)}
    <div class="stagehead">
      <div class="round">Duel <b>n° ${fmt(S.total+1)}</b> · ${C.type==='music'?'lequel tu préfères ?':'lequel est le meilleur ?'}</div>
      <div class="fx" style="gap:8px;flex-wrap:wrap;justify-content:flex-end">
        <select id="fsel" aria-label="Quels éléments faire combattre">${main.map(([k,v])=>`<option value="${esc(k)}" ${S.filter===k?'selected':''}>${esc(v)}</option>`).join('')}</select>
        ${arts.length ? `<select id="artsel" aria-label="Filtrer par artiste"><option value="">Artiste…</option>${arts.map(([k,v])=>`<option value="${esc(k)}" ${S.filter===k?'selected':''}>${esc(v)}</option>`).join('')}</select>` : ''}
        <button class="btn sm ghost fxbtn" id="fxbtn" aria-pressed="${fxOpen || fxActive()}">Plus de filtres${fxActive() ? ' •' : ''}</button>
      </div>
    </div>
    ${fxOpen ? fxPanel() : ''}
    <div class="arena${TY.sq ? ' sq-col' : ''}">${card(a,'l',rank)}<div class="vs">VS</div>${card(b,'r',rank)}</div>
    <div class="actbar${TY.sq ? ' sq-bar' : ''}">
      <button class="btn choose l" data-pick="0"><kbd>←</kbd> Rouge</button>
      <button class="btn" id="draw"><kbd>↑</kbd> Égalité</button>
      <button class="btn" id="skip"><kbd>↓</kbd> Passer</button>
      <button class="btn ghost" id="undo" title="Annuler le dernier choix (touche Retour)" ${lastIdx('duel')>=0?'':'disabled'}>↶ Annuler</button>
      <button class="btn choose r" data-pick="1">Bleu <kbd>→</kbd></button>
    </div>
    <div class="khint">${C.type==='music' ? '<span><kbd>A</kbd> <kbd>E</kbd> écouter</span>' : ''}<span><kbd>F</kbd> filtres</span><span><kbd>/</kbd> chercher</span><span><kbd>P</kbd> image</span><span><kbd>?</kbd> tous les raccourcis</span></div>
  </section>
  <div class="below">
    <div class="panel"><h3>Derniers combats</h3><div class="feed">${recent.length ? recent.map(h=>fightRow(h, h.dr?'':`+${Math.round(h.dl)} pts`)).join('') : '<div class="empty">Clique sur l’affiche que tu préfères, ou utilise les flèches du clavier.</div>'}</div></div>
    <div class="panel"><h3>Top 5 actuel</h3><div class="feed">${order.slice(0,5).map((i,k)=>`<div class="fight" style="grid-template-columns:24px minmax(0,1fr) auto"><span class="x" style="font-size:12px;color:var(--gold)">${k+1}</span><span class="fx">${thumb(i)}<span class="nm">${T(i)}</span></span><span class="tag">${Math.round(S.elo[i])} pts</span></div>`).join('')}</div>
      <p style="margin:10px 0 0"><button class="lnk" id="seerank">Voir tout le classement</button></p></div>
  </div>`;
  view.querySelectorAll('.card').forEach(c => c.onclick = () => chooseDuel(+c.dataset.i));
  bindPickButtons();
  $('fsel').onchange = e => { S.filter = e.target.value; save(); pair = null; nextPair = null; renderDuel(); };
  if ($('artsel')) $('artsel').onchange = e => { S.filter = e.target.value || 'all'; save(); pair = null; nextPair = null; renderDuel(); };
  $('skip').onclick = () => { pair = null; nextPair = null; renderDuel(); };
  $('draw').onclick = () => chooseDuel(pair[0], true);
  $('undo').onclick = undoDuel;
  $('seerank').onclick = () => go('rank');
  $('fxbtn').onclick = () => { fxOpen = !fxOpen; renderDuel(); };
  (window.requestIdleCallback || setTimeout)(preloadNext);
  if (fxOpen) bindFx();
  (window.requestIdleCallback || setTimeout)(() => ambience(a, b));
}

function chooseDuel(win, draw){
  if (!pair || !pair.includes(win)) return;
  const [a,b] = pair; const lose = win===a?b:a;
  play(win, lose, 'duel', draw); save(); sfx('ko');
  pair = null;
  pair = nextPair && !nextPair.includes(win) && !nextPair.includes(lose) ? nextPair : null; nextPair = null;
  animate(win, lose, draw, ()=>{ renderDuel(); stats(); });
}
let nextPair = null;
function preloadNext(){
  try { if (N < 4) return; const cur = pair; let np = null; for (let t = 0; t < 5 && !np; t++) { const c = pickPair(); if (!cur || (!cur.includes(c[0]) && !cur.includes(c[1]))) np = c; }
    nextPair = np; if (np) np.forEach(i => { if (F[i].img) { const im = new Image(); im.decoding = 'async'; im.referrerPolicy = 'no-referrer'; im.src = hiRes(F[i].img); if (im.decode) im.decode().catch(() => {}); const sm = new Image(); sm.src = tinyRes(F[i].img); } }); } catch(e){}
}
function undoDuel(){
  const k = lastIdx('duel'); if (k<0) return;
  const h = unplayAt(k); pair = Math.random()<.5?[h.w,h.l]:[h.l,h.w];
  save(); renderDuel(); stats(); toast('Dernier choix annulé');
}

/* ---------- Tournoi ---------- */
function shuffle(a){ for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];} return a; }
function seedOrder(n){ let o=[1]; while(o.length<n){ const m=o.length*2; o=o.flatMap(s=>[s,m+1-s]); } return o; }
const sizeName = sz => ({2:'Finale',4:'Demi-finales',8:'Quarts de finale',16:'Huitièmes de finale'})[sz] || `Tour de ${sz}`;
function modes(){
  const m = [{id:'all', name:'Le grand tournoi', n:N, desc:`Tes ${fmt(N)} ${TY.many} tirés au sort. Un seul survivant.`}];
  if (N>=300) m.push({id:'top', name:'Top 256', n:256, desc:`Les 256 meilleurs du classement actuel, avec têtes de série.`});
  if (N>=100) m.push({id:'top', name:'Top 64', n:64, desc:'Le n°1 affronte le n°64 au premier tour.'});
  if (N>=16) m.push({id:'top', name:'Top 16', n:16, desc:'Une session rapide entre les favoris.'});
  const kp = keptIdx(); if (kp.length >= 4) m.unshift({id:'keep', name:'Tournoi des gardés', n:kp.length, ids:kp, desc:`Tes ${fmt(kp.length)} ${TY.many} gardés dans le tri rapide ♥.`});
  const fp = (S.filter!=='all' || fxActive()) ? pool().length : 0;
  if (fp >= 4 && fp < N) m.unshift({id:'filt', name:'Tournoi filtré', n:fp, desc:`Seulement les ${fmt(fp)} ${TY.many} de tes filtres actuels (onglet Duels).`});
  const r = N>=200 ? 64 : 32;
  if (N>r) m.push({id:'rand', name:`${r} au hasard`, n:r, desc:`${r} ${TY.many} pris au hasard dans toute la liste.`});
  return m;
}
function newTour(m){
  let ids, first, hasPre = false, prelims = [];
  if (m.id==='filt' || m.ids){ ids = shuffle(m.ids ? m.ids.slice() : pool()); first = 1; while(first*2 <= ids.length) first*=2; const extra = ids.length - first; if (extra > 0){ hasPre = true; prelims = ids.slice(0, extra*2); ids = ids.slice(extra*2); } }
  else if (m.id==='top'){ const {order} = ranking(); const top = order.slice(0,m.n); ids = seedOrder(m.n).map(s=>top[s-1]); first = m.n; }
  else {
    ids = m.id==='rand' ? shuffle([...Array(N).keys()]).slice(0,m.n) : shuffle([...Array(N).keys()]);
    first = 1; while(first*2 <= ids.length) first*=2;
    const extra = ids.length - first;
    if (extra > 0){ hasPre = true; prelims = ids.slice(0, extra*2); ids = ids.slice(extra*2); }
  }
  const ent = m.id==='top' ? ids.slice() : prelims.concat(ids);
  S.tour = {label:m.name, ent, first, hasPre, alive: hasPre ? ids : [], queue: hasPre ? prelims : ids, next:[], round: hasPre?0:1, prelim: hasPre, done:false, champ:null, log:[]};
  save();
}
function roundLabel(t){ return t.prelim ? 'Barrages' : sizeName(t.first >> (t.round-1)); }
function entryLabel(t, m){ return m.prelim ? 'Barrages' : sizeName(t.first >> (m.round-1)); }
let tpanel = 'feed', tq = '', tshown = 120;
function trackHtml(t){
  const steps = [];
  if (t.hasPre) steps.push({label:'Barrages', key:0});
  for (let s=t.first, r=1; s>=2; s/=2, r++) steps.push({label: s===2?'Finale':s===4?'Demi':s===8?'Quarts':s===16?'8es':String(s), key:r});
  const cur = t.done ? 99 : (t.prelim ? 0 : t.round);
  return `<div class="track">${steps.map(s=>`<span class="${s.key<cur?'done':s.key===cur?'cur':''}">${s.label}</span>`).join('')}${t.done?'<span class="cur">Champion</span>':''}</div>`;
}
function tourData(t){
  const outBy = new Map();
  t.log.forEach(m => { const lo = m.win===m.a?m.b:m.a; outBy.set(lo, m); });
  return {outBy, alive: t.ent.filter(i => !outBy.has(i))};
}
function tourPanel(t){
  const {outBy, alive} = tourData(t);
  const q = tq.trim().toLowerCase();
  const match = i => !q || (F[i].t+' '+F[i].sub).toLowerCase().includes(q);
  let body = '';
  if (tpanel==='tree') body = bracketHtml(t);
  else if (tpanel==='feed'){
    const rec = t.log.slice(-15).reverse();
    body = rec.length ? `<div class="feed">${rec.map(m=>fightRow({w:m.win,l:m.win===m.a?m.b:m.a}, entryLabel(t,m))).join('')}</div>` : '<div class="empty">Les résultats apparaîtront ici.</div>';
  } else {
    const {rank} = ranking();
    const list = tpanel==='out' ? [...outBy.keys()].reverse().filter(match) : alive.filter(match);
    body = `<div class="tools"><input class="input" id="tq" type="search" placeholder="Chercher…" value="${esc(tq)}"></div>` +
      (list.length ? `<div class="grid-mini">${list.slice(0,tshown).map(i => {
        const m = outBy.get(i);
        return `<div class="mini${m?' out':''}">${img(i)}<div><div class="t">${T(i)}</div><div class="s">${m ? `${entryLabel(t,m)} · battu par ${T(m.win)}` : `${C.type==='music'?esc(F[i].first):(F[i].y||'')} · #${rank[i]}`}</div></div></div>`;
      }).join('')}</div>${list.length>tshown?`<button class="btn more" id="tmore">Afficher plus (${fmt(list.length-tshown)})</button>`:''}` : `<div class="empty">${tpanel==='out'?'Aucun éliminé pour l’instant.':'Aucun résultat.'}</div>`);
  }
  return `<div class="panel" id="tpanel"><div class="ptabs" role="tablist">
    <button data-p="feed" aria-selected="${tpanel==='feed'}">Derniers combats</button>
    <button data-p="alive" aria-selected="${tpanel==='alive'}">Encore en lice<span>${fmt(alive.length)}</span></button>
    <button data-p="out" aria-selected="${tpanel==='out'}">Éliminés<span>${fmt(outBy.size)}</span></button>
    <button data-p="tree" aria-selected="${tpanel==='tree'}">🌳 Arbre</button>
  </div>${body}</div>`;
}
function bindPanel(){
  document.querySelectorAll('#tpanel .ptabs button').forEach(b => b.onclick = () => { tpanel=b.dataset.p; tshown=120; rerenderPanel(); });
  const qi = $('tq'); if (qi) qi.oninput = () => { tq = qi.value; tshown=120; rerenderPanel(); const n=$('tq'); n.focus(); n.setSelectionRange(n.value.length,n.value.length); };
  if ($('tmore')) $('tmore').onclick = () => { tshown += 240; rerenderPanel(); };
  if (tpanel==='tree') bindBracket();
}
function rerenderPanel(){ const p=$('tpanel'); if(!p) return; p.outerHTML = tourPanel(S.tour); bindPanel(); }
function renderTour(){
  if (N < 2){ view.innerHTML = '<div class="empty">Pas assez d’éléments pour un tournoi (il en faut au moins 2).</div>'; return; }
  const t = S.tour;
  if (!t){
    const M = modes();
    view.innerHTML = `<div class="sech"><h2>Nouveau tournoi</h2></div>
    <p class="note" style="margin:-4px 0 14px">Élimination directe : chaque duel élimine un ${TY.one}. Tu peux arrêter et reprendre quand tu veux.</p>
    <div class="modes">${M.map((m,k)=>`<button class="mode" data-k="${k}"><em>${fmt(m.n-1)} duels</em><strong>${m.name}</strong><span>${m.desc}</span></button>`).join('')}</div>`;
    view.querySelectorAll('.mode').forEach(b => b.onclick = () => { newTour(M[+b.dataset.k]); tpanel='feed'; tq=''; renderTour(); stats(); });
    return;
  }
  if (t.done){ renderChamp(t); return; }
  const a = t.queue[0], b = t.queue[1], {rank} = ranking();
  const played = t.log.length, total = t.ent.length-1;
  const inRound = t.queue.length/2, doneRound = t.next.length;
  view.innerHTML = `${videoHint()}<section class="stage">
    ${stageBg(a,b)}
    <div class="stagehead"><div class="round"><b>${roundLabel(t)}</b> · match ${doneRound+1} sur ${doneRound+inRound}</div>${trackHtml(t)}</div>
    <div class="arena${TY.sq ? ' sq-col' : ''}">${card(a,'l',rank)}<div class="vs">VS</div>${card(b,'r',rank)}</div>
    <div class="actbar" style="grid-template-columns:1fr auto auto 1fr">
      <button class="btn choose l" data-pick="0"><kbd>←</kbd> Rouge</button>
      <button class="btn ghost" id="tundo" title="Annuler (touche Retour)" ${played?'':'disabled'}>↶ Annuler</button>
      <button class="btn ghost danger" id="tquit">Abandonner</button>
      <button class="btn choose r" data-pick="1">Bleu <kbd>→</kbd></button>
    </div>
    <div id="tconf" style="display:flex;justify-content:center"></div>
    <div style="max-width:820px;margin:16px auto 0;display:grid;gap:6px"><div class="round" style="display:flex;justify-content:space-between;gap:10px"><span>${esc(t.label)}</span><span>${fmt(played)} / ${fmt(total)} duels</span></div><div class="bar"><i style="width:${(played/total*100).toFixed(2)}%"></i></div></div>
  </section>
  <div style="margin-top:18px">${tourPanel(t)}</div>`;
  view.querySelectorAll('.card').forEach(c => c.onclick = () => chooseTour(+c.dataset.i));
  (window.requestIdleCallback || setTimeout)(() => ambience(a, b));
  bindPickButtons();
  $('tundo').onclick = undoTour;
  $('tquit').onclick = () => {
    $('tconf').innerHTML = `<div class="confirm">Abandonner ce tournoi ? Sa progression sera perdue (le classement garde tes choix). <button class="btn sm danger" id="yq">Oui, abandonner</button><button class="btn sm" id="nq">Non</button></div>`;
    $('yq').onclick = () => { S.tour=null; save(); renderTour(); stats(); };
    $('nq').onclick = () => $('tconf').innerHTML='';
  };
  bindPanel();
}
function chooseTour(win){
  const t = S.tour; if (!t || t.done) return;
  const a=t.queue[0], b=t.queue[1]; const lose = win===a?b:a;
  play(win, lose, 'tour');
  const entry = {a, b, win, prelim:t.prelim, round:t.round};
  t.queue.splice(0,2); t.next.push(win);
  let msg = '';
  if (!t.queue.length){
    entry.trans = {alive:t.alive.slice(), next:t.next.slice(), prelim:t.prelim, round:t.round};
    const was = roundLabel(t);
    if (t.prelim){ t.queue = t.alive.concat(t.next); t.alive=[]; t.next=[]; t.prelim=false; t.round=1; }
    else if (t.next.length===1){ t.done=true; t.champ=t.next[0]; (S.champs ||= []).push({k:F[t.champ].key, label:t.label, t:Date.now()}); }
    else { t.queue = t.next; t.next=[]; t.round++; }
    if (!t.done) msg = `${was} : fini  →  ${roundLabel(t)}`;
  }
  t.log.push(entry);
  save();
  sfx('ko');
  animate(win, lose, false, ()=>{ renderTour(); stats(); if (msg) toast(msg); if (t.done) { sfx('bell'); confetti(); } });
}
function undoTour(){
  const t = S.tour; if (!t || !t.log.length) return;
  const m = t.log[t.log.length-1];
  if (m.trans && t.done && S.champs && S.champs.length) S.champs.pop();
  if (m.trans){ t.alive=m.trans.alive; t.next=m.trans.next; t.prelim=m.trans.prelim; t.round=m.trans.round; t.queue=[]; t.done=false; t.champ=null; }
  else if (!t.next.length){ toast('Impossible d’annuler au-delà du début de ce tour.'); return; }
  t.log.pop(); t.next.pop(); t.queue.unshift(m.a, m.b);
  for (let k=S.log.length-1;k>=0;k--){ const h=S.log[k]; if (h.m==='tour' && h.w===m.win && (h.l===m.a||h.l===m.b)){ unplayAt(k); break; } }
  save(); renderTour(); stats(); toast('Dernier choix annulé');
}
function renderChamp(t){
  const c = t.champ;
  const path = t.log.filter(m=>m.win===c).map(m=>({lab:entryLabel(t,m), op:m.a===c?m.b:m.a}));
  const lostIn = sz => t.log.filter(m=>!m.prelim && (t.first>>(m.round-1))===sz).map(m=>m.win===m.a?m.b:m.a);
  const mini = (i, s) => `<div class="mini">${img(i)}<div><div class="t">${T(i)}</div><div class="s">${s}</div></div></div>`;
  view.innerHTML = `<section class="stage">${stageBg(c,c)}<div class="stagehead"><div class="round"><b>${esc(t.label)}</b> · terminé</div>${trackHtml(t)}</div><div class="champ"><div class="round">🏆 Champion</div>${imgHi(c)}<h2>${T(c)}</h2><div class="cmeta">${metaLine(c)}</div>
  ${C.type==='music' ? `<div style="width:min(480px,100%)">${playerHtml(c)}</div>` : ''}
  <div class="fx" style="gap:8px;margin-top:6px"><button class="btn primary" id="again">Nouveau tournoi</button><button class="btn" id="seer">Voir le classement</button><button class="btn" id="champpng">🖼 Image du parcours <kbd>P</kbd></button></div></div></section>
  <div class="honors">
    <div class="panel" style="margin:0"><h3>Son parcours</h3><div class="path">${path.map(p=>`<div><b>${p.lab}</b><span class="fx">${thumb(p.op)}<span class="nm">bat ${T(p.op)}</span></span></div>`).join('')}</div></div>
    <div class="panel" style="margin:0"><h3>Le podium</h3><div class="feed" style="gap:8px">${lostIn(2).map(i=>mini(i,'Finaliste')).join('')}${lostIn(4).map(i=>mini(i,'Demi-finaliste')).join('')}${lostIn(8).map(i=>mini(i,'Quart de finale')).join('')}</div></div>
  </div>
  ${tourPanel(t)}`;
  $('again').onclick = () => { S.tour=null; save(); renderTour(); stats(); };
  $('seer').onclick = () => go('rank');
  $('champpng').onclick = pngChamp;
  bindPanel();
}

/* ---------- Classement ---------- */
let shown = 100, query = '', grp = 'all', sortBy = 'score', open = -1, qT = null;
function starRanks(){
  const ids = [...Array(N).keys()].filter(i=>F[i].r).sort((a,b)=>F[b].r-F[a].r);
  const r = new Map(); let k=0;
  while (k<ids.length){ let j=k; while(j<ids.length && F[ids[j]].r===F[ids[k]].r) j++; const avg=(k+1+j)/2; for(let x=k;x<j;x++) r.set(ids[x], avg); k=j; }
  return r;
}
function surprises(rank){
  const sr = starRanks(), c = [];
  for (let i=0;i<N;i++) if (games(i)>=4 && sr.has(i)) c.push([i, sr.get(i)-rank[i]]);
  c.sort((a,b)=>b[1]-a[1]);
  const li = ([i,g]) => `<li>${T(i)}<small>#${rank[i]} · ${starStr(F[i].r)} · <span class="${g>0?'up':'down'}">${g>0?'▲':'▼'} ${Math.round(Math.abs(g))} places</span></small></li>`;
  const up = c.filter(x=>x[1]>50).slice(0,5), down = c.filter(x=>x[1]<-50).slice(-5).reverse();
  if (!up.length && !down.length) return '';
  return `<div class="surp"><div class="panel"><h3>Meilleur que la note</h3><ol>${up.map(li).join('')||'<li class="empty">Rien pour l’instant.</li>'}</ol></div>
  <div class="panel"><h3>Moins bien que la note</h3><ol>${down.map(li).join('')||'<li class="empty">Rien pour l’instant.</li>'}</ol></div></div>`;
}
function detail(i, rank){
  const beat = [], lost = [];
  for (let k=S.log.length-1;k>=0;k--){ const h=S.log[k]; if (h.dr) continue; if (h.w===i && !beat.includes(h.l)) beat.push(h.l); else if (h.l===i && !lost.includes(h.w)) lost.push(h.w); }
  const g = games(i), pct = g ? Math.round((S.w[i]+S.d[i]/2)/g*100) : 0, it = F[i];
  const ul = a => a.length ? `<ul>${a.slice(0,10).map(x=>`<li>${T(x)} <span style="color:var(--muted)">#${rank[x]}</span></li>`).join('')}${a.length>10?`<li style="color:var(--muted)">et ${a.length-10} autres</li>`:''}</ul>` : '<div class="empty" style="padding:0">Personne pour l’instant.</div>';
  const links = C.type==='films'
    ? it.link ? `<a href="${esc(it.link)}" target="_blank" rel="noopener">Ouvrir la page ↗</a>` : `<a href="https://letterboxd.com/search/films/${encodeURIComponent(it.t+' '+(it.y||''))}/" target="_blank" rel="noopener">Voir sur Letterboxd ↗</a>`
    : C.type==='items' ? (it.link ? `<a href="${esc(it.link)}" target="_blank" rel="noopener">Ouvrir la page ↗</a>` : '')
    : `${isSp(i) ? `<a href="https://open.spotify.com/track/${it.id}" target="_blank" rel="noopener">Ouvrir dans Spotify ↗</a>` : ''}<a href="${it.yt?'https://www.youtube.com/watch?v='+it.yt:ytSearch(i)}" target="_blank" rel="noopener">Ouvrir sur YouTube ↗</a>`;
  return `<div class="detail">${imgHi(i)}<div><h4>${T(i)}</h4><div class="cmeta">${metaLine(i)}</div>
  <div class="kv"><span>Rang <b>#${rank[i]}</b></span><span>Score <b>${Math.round(S.elo[i])}</b></span><span>Bilan <b>${S.w[i]}V ${S.l[i]}D${S.d[i]?` ${S.d[i]}N`:''}</b></span>${g?`<span>Victoires <b>${pct} %</b></span>`:''}${C.type==='films'?`<span>Note <b class="stars">${starStr(it.r)||'—'}</b></span>`:''}</div>
  ${C.type==='music' ? playerHtml(i) : ''}
  ${histSvg(i)}
  <div class="vsl" style="margin-top:10px"><div><h5>A battu</h5>${ul(beat)}</div><div><h5>A perdu contre</h5>${ul(lost)}</div></div>
  <div class="links">${links}</div></div></div>`;
}
function groupOpts(){
  if (C.type==='items') return [['all','Tout']];
  if (C.type==='films') return [['all','Toutes les années'],['2020','2020s'],['2010','2010s'],['2000','2000s'],['1990','1990s'],['old','Avant 1990']];
  return filterList().filter(o=>o[0]==='all'||o[0].startsWith('a:')).map(o=>o[0]==='all'?['all','Tous les artistes']:o);
}
function renderRank(){
  const {order, rank} = ranking();
  const q = query.trim().toLowerCase();
  if (!groupOpts().some(o=>o[0]===grp)) grp='all';
  let list = order.filter(i => (!q || (F[i].t+' '+(F[i].sub||'')).toLowerCase().includes(q)) && matches(i, grp, null));
  if (sortBy==='pct') list.sort((a,b)=>{ const ga=games(a), gb=games(b); return (gb>=3)-(ga>=3) || (gb?(S.w[b]+S.d[b]/2)/gb:0)-(ga?(S.w[a]+S.d[a]/2)/ga:0); });
  if (sortBy==='games') list.sort((a,b)=>games(b)-games(a));
  if (sortBy==='least') list.sort((a,b)=>games(a)-games(b));
  const plain = !q && grp==='all' && sortBy==='score';
  const top3 = order.slice(0,3);
  const pod = plain && top3.length === 3 ? `<div class="podium">${[1,0,2].map(k=>{ const i = top3[k]; return `<div class="pod p${k+1}">${imgHi(i)}<div class="n">${k+1}</div><div class="t">${T(i)}</div><div class="s">${C.type==='music'?esc(F[i].first):(F[i].y||'')} · ${Math.round(S.elo[i])} pts</div></div>`; }).join('')}</div>` : '';
  const sel = (id, v, opts) => `<select id="${id}">${opts.map(([k,l])=>`<option value="${esc(k)}" ${v===k?'selected':''}>${esc(l)}</option>`).join('')}</select>`;
  view.innerHTML = `<div class="tools"><input class="input" id="q" type="search" placeholder="${C.type==='music'?'Chercher un son ou un artiste…':'Chercher un film ou un réalisateur…'}" value="${esc(query)}">
    ${sel('grp', grp, groupOpts())}
    ${sel('sort', sortBy, [['score','Trier par score'],['pct','Trier par % de victoires'],['games','Les plus combattus'],['least','Les moins combattus']])}
    <button class="btn sm" id="top10">Copier le top 10</button><button class="btn sm primary" id="png10">🖼 Image Top 10 <kbd>P</kbd></button></div>
  ${S.total ? '' : `<p class="note" style="margin:0 0 14px">${C.type==='films'?'Aucun duel encore : ce classement de départ vient des notes Letterboxd.':'Aucun duel encore : tous les sons partent à égalité.'} Il bougera à chaque choix.</p>`}
  ${plain && C.type==='films' && S.total>=100 ? surprises(rank) : ''}
  ${pod}
  <div class="list">${list.slice(0,shown).map(i=>`<button class="row" data-i="${i}" aria-expanded="${open===i}"><span class="rk">${rank[i]}</span>${img(i)}<span class="t">${T(i)}<small>${C.type==='music'?esc(F[i].sub):(F[i].y||'')}</small></span><span class="sc"><b>${Math.round(S.elo[i])}</b> · ${S.w[i]}V ${S.l[i]}D</span><span class="chev">›</span></button>${open===i?detail(i,rank):''}`).join('')}</div>
  ${list.length>shown?`<button class="btn more" id="more">Afficher plus (${fmt(list.length-shown)} restants)</button>`:''}
  ${!list.length?'<div class="empty">Rien ne correspond.</div>':''}`;
  const qi = $('q'); qi.oninput = () => { query = qi.value; clearTimeout(qT); qT = setTimeout(() => { shown = 100; renderRank(); const n=$('q'); n.focus(); n.setSelectionRange(n.value.length,n.value.length); }, 140); };
  $('grp').onchange = e => { grp=e.target.value; shown=100; renderRank(); };
  $('sort').onchange = e => { sortBy=e.target.value; shown=100; renderRank(); };
  $('png10').onclick = pngTop10;
  $('top10').onclick = async () => {
    const txt = `Top 10 — ${C.label} (Ring ${TY.brand}) :\n` + order.slice(0,10).map((i,k)=>`${k+1}. ${F[i].t}${C.type==='music'?' — '+F[i].sub:F[i].y?' ('+F[i].y+')':''}`).join('\n');
    toast(await copyText(txt) ? 'Top 10 copié' : 'Copie impossible dans ce navigateur');
  };
  view.querySelectorAll('.row').forEach(r => r.onclick = e => { if (e.target.closest('.player')) return; const i=+r.dataset.i; open = open===i ? -1 : i; const y=window.scrollY; renderRank(); window.scrollTo(0,y); });
  if ($('more')) $('more').onclick = () => { shown += 200; renderRank(); };
}

/* ---------- Comparer ---------- */
let cmpWith = null, cmpShown = 60;
const snapCache = new Map();
function colSnapshot(col){
  const hit = snapCache.get(col.id); if (hit && hit.v === LSVER && hit.col === col) return hit.snap;
  const snap = colSnapshotRaw(col); snapCache.set(col.id, {v: LSVER, col, snap}); return snap;
}
function colSnapshotRaw(col){
  const items = buildItems(col), st = ls.get(stateKey(col), null);
  const elo = items.map((it,i) => st && st.elo && st.elo[i] !== undefined ? st.elo[i] : colType(col).seed(it));
  const {rank, order} = rankOf(elo, items.length);
  return {col, items, rank, order, n: items.length, total: st ? st.total || 0 : 0};
}
function spearman(a, b){
  const n = a.length; if (n < 3) return null;
  const rk = v => { const o = v.map((x,i)=>[x,i]).sort((p,q)=>p[0]-q[0]); const r = new Array(n); o.forEach((p,k)=>r[p[1]]=k); return r; };
  const ra = rk(a), rb = rk(b); let d = 0; for (let i=0;i<n;i++) d += (ra[i]-rb[i])**2;
  return 1 - 6*d/(n*(n*n-1));
}
function renderCmp(){
  const others = allCols().filter(c => c.type === C.type && c.id !== C.id);
  if (!others.length){
    view.innerHTML = defiPanel() + `<div class="panel"><h3>Comparer deux classements</h3><p class="note" style="margin:0">Il faut au moins deux collections de ${TY.many} pour comparer. Ajoute le profil Letterboxd ou la playlist Spotify d'un pote avec <b>Ring Sync</b> (en bas de la page), ou colle le code de collection qu'il t'a envoyé dans <b>Sauvegarde et partage</b>.</p></div>`;
    bindDefi(); return;
  }
  if (!others.some(c => c.id === cmpWith)) cmpWith = others[0].id;
  const A = colSnapshot(C), B = colSnapshot(colById(cmpWith));
  const idxB = new Map(B.items.map((it,i) => [it.key, i]));
  const common = [];
  A.items.forEach((it,i) => { const j = idxB.get(it.key); if (j !== undefined) common.push({i, j, pa: (A.rank[i]-1)/Math.max(1,A.n-1), pb: (B.rank[j]-1)/Math.max(1,B.n-1)}); });
  const rho = spearman(common.map(c=>A.rank[c.i]), common.map(c=>B.rank[c.j]));
  const agree = rho === null ? null : Math.round((rho+1)/2*100);
  const both = common.filter(c => c.pa <= .25 && c.pb <= .25).sort((x,y)=>(x.pa+x.pb)-(y.pa+y.pb)).slice(0,10);
  const dis = common.slice().sort((x,y)=>Math.abs(y.pa-y.pb)-Math.abs(x.pa-x.pb)).slice(0,10);
  const aImg = (snap, i) => img(i, 'th', snap.items, colType(snap.col).sq);
  const topList = snap => `<ol class="cmptop">${snap.order.slice(0,10).map(i => `<li class="${idxB.has(snap.items[i].key) && snap===A || (snap===B && A.items.some(x=>x.key===snap.items[i].key)) ? 'com' : ''}"><span class="fx">${aImg(snap,i)}<span class="nm">${esc(snap.items[i].t)}</span></span></li>`).join('')}</ol>`;
  const row = c => { const it = A.items[c.i]; const diff = Math.round((c.pb - c.pa)*100);
    return `<div class="crow"><span class="fx">${aImg(A,c.i)}<span class="nm">${esc(it.t)}</span></span><span class="cr a">#${A.rank[c.i]}</span><span class="cr b">#${B.rank[c.j]}</span><span class="cbar"><i style="left:${Math.min(c.pa,c.pb)*100}%;width:${Math.max(1,Math.abs(c.pa-c.pb)*100)}%"></i><b class="da" style="left:${c.pa*100}%"></b><b class="db" style="left:${c.pb*100}%"></b></span><span class="cd ${diff>0?'up':diff<0?'down':''}">${diff>0?'▲':diff<0?'▼':'='}${Math.abs(diff)}</span></div>`; };
  const sorted = common.slice().sort((x,y)=>(x.pa+x.pb)-(y.pa+y.pb));
  view.innerHTML = defiPanel() + `<div class="tools"><span class="note" style="margin:0">Comparer <b>${esc(C.label)}</b> avec</span><select id="cmpsel">${others.map(c=>`<option value="${esc(c.id)}" ${c.id===cmpWith?'selected':''}>${esc(c.label)}</option>`).join('')}</select><button class="btn sm primary" id="cpng">🖼 Image de compatibilité</button></div>
  <div class="cmphead">
    <div class="panel"><h3>En commun</h3><div class="big">${fmt(common.length)}</div><div class="note">${TY.many} dans les deux collections (${A.n?Math.round(common.length/A.n*100):0} % de ${esc(C.label)})</div></div>
    <div class="panel"><h3>Compatibilité</h3><div class="compat"><div class="cring" style="--p:${agree||0}"><b>${agree===null?'—':agree+' %'}</b><span>d’accord</span></div><div><div class="note">${agree===null?'Pas assez d’éléments en commun.':agree>=75?'Vous avez des goûts très proches.':agree>=60?'Plutôt d’accord.':agree>=45?'Des goûts assez différents.':'Presque opposés !'}${(A.total<30||B.total<30)?' Fais plus de duels des deux côtés pour un résultat fiable.':''}</div></div></div></div>
  </div>
  <div class="cmpcols">
    <div class="panel"><h3><span class="dot a"></span>Top 10 · ${esc(C.label)}</h3>${topList(A)}</div>
    <div class="panel"><h3><span class="dot b"></span>Top 10 · ${esc(B.col.label)}</h3>${topList(B)}</div>
  </div>
  <div class="cmpcols">
    <div class="panel"><h3>Vous êtes d'accord</h3>${both.length?`<div class="feed">${both.map(row).join('')}</div>`:'<div class="empty">Aucun élément commun dans vos deux quarts supérieurs.</div>'}</div>
    <div class="panel"><h3>Gros désaccords</h3>${dis.length?`<div class="feed">${dis.map(row).join('')}</div>`:'<div class="empty">Rien à signaler.</div>'}</div>
  </div>
  <div class="panel"><h3>Tous les ${TY.many} en commun <span class="note">— <span class="dot a"></span>${esc(C.label)} <span class="dot b"></span>${esc(B.col.label)} (à gauche = mieux classé)</span></h3>
  ${sorted.length?`<div class="feed">${sorted.slice(0,cmpShown).map(row).join('')}</div>${sorted.length>cmpShown?`<button class="btn more" id="cmore">Afficher plus (${fmt(sorted.length-cmpShown)})</button>`:''}`:'<div class="empty">Aucun élément en commun.</div>'}</div>`;
  $('cmpsel').onchange = e => { cmpWith = e.target.value; cmpShown = 60; renderCmp(); };
  $('cpng').onclick = () => pngCompat(A, B, agree, both, dis);
  bindDefi();
  if ($('cmore')) $('cmore').onclick = () => { cmpShown += 200; renderCmp(); };
}

/* ---------- Serveur local : sauvegarde automatique ---------- */
let SERVER = false, pushT = null, SERVER_OK = true;
function schedulePush(){ if (!SERVER) return; clearTimeout(pushT); pushT = setTimeout(pushStore, 1200); }
function dumpKeys(){ const keys = {}; MEM.forEach((v, k) => { if (k.startsWith('ringcine-')) keys[k] = v; }); return keys; }
async function pushStore(){
  try { const r = await fetch('/api/store', {method:'POST', body: JSON.stringify({ts: +(MEM.get('ringcine-ts') || Date.now()), keys: dumpKeys()})}); setConn(r.ok); if (!r.ok) throw 0; }
  catch(e){ setConn(false); clearTimeout(pushT); pushT = setTimeout(pushStore, 8000); }
}
function flushStore(){ if (!SERVER || !pushT) return; clearTimeout(pushT); pushT = null; try { navigator.sendBeacon('/api/store', new Blob([JSON.stringify({ts: +(MEM.get('ringcine-ts') || Date.now()), keys: dumpKeys()})], {type:'text/plain'})); } catch(e){} }
document.addEventListener('visibilitychange', () => { if (document.hidden) flushStore(); });
window.addEventListener('pagehide', flushStore);
function setConn(ok){ SERVER_OK = ok; const el=$('conn'); if (el){ el.className = 'conn ' + (ok?'ok':'off'); el.title = ok ? 'Sauvegarde automatique active' : 'Ring.bat est fermé : les changements restent dans le navigateur'; } }
/* Le navigateur a une copie plus récente que Ring-sauvegarde.json : on fusionne au lieu d'écraser.
   Les clés absentes d'un côté sont gardées, et pour l'état d'un ring on garde celui qui a le plus de duels. */
function stateLen(v){ try { const o = JSON.parse(v); return o && Array.isArray(o.elo) && Array.isArray(o.log) ? o.log.length : -1; } catch(e){ return -1; } }
function mergeKeys(srv, loc){
  const out = Object.assign({}, srv);
  Object.entries(loc).forEach(([k, v]) => { if (!(k in srv)) { out[k] = v; return; } const a = stateLen(srv[k]), b = stateLen(v); out[k] = a >= 0 && b >= 0 && a > b ? srv[k] : v; });
  out['ringcine-ts'] = String(Date.now());
  return out;
}
function writeKeys(keys){
  LSVER++;
  Object.keys(dumpKeys()).forEach(k => MEM.delete(k)); Object.entries(keys).forEach(([k,v]) => MEM.set(k, v));
  if (!idbTx(st => { st.clear(); MEM.forEach((v, k) => st.put(v, k)); })) { try { lsKeys().forEach(k => localStorage.removeItem(k)); MEM.forEach((v, k) => localStorage.setItem(k, v)); } catch(e){} }
}
async function initStore(){
  await idbLoad();
  playerPref = ls.get('ringcine-player', 'yt');
  if (!ONLINE) return;
  let legacy = null;
  if (location.hash.startsWith('#legacy=')) {
    try { legacy = JSON.parse(decodeURIComponent(escape(atob(decodeURIComponent(location.hash.slice(8)))))); } catch(e){}
    history.replaceState(null, '', location.pathname);
  }
  let st = null;
  for (let k = 0; k < 3 && !st; k++) { try { const r = await fetch('/api/store', {cache:'no-store'}); if (r.ok) { st = await r.json(); SERVER = true; } } catch(e){} if (!st) await new Promise(res => setTimeout(res, 700)); }
  const localTs = +(MEM.get('ringcine-ts') || 0), srvTs = st ? +(st.ts || 0) : 0;
  if (st && st.keys && Object.keys(st.keys).length && (!localTs || srvTs >= localTs - 2000)) writeKeys(st.keys);
  else if (st && st.keys && Object.keys(st.keys).length) writeKeys(mergeKeys(st.keys, dumpKeys()));
  else if (legacy && legacy.keys && Object.keys(legacy.keys).length) { writeKeys(legacy.keys); setTimeout(() => toast('Tes anciens duels ont été récupérés'), 800); }
  if (SERVER) pushStore();
}

/* ---------- Ring Sync ---------- */
function allFilmMap(){
  const m = new Map();
  allCols().filter(c=>c.type==='films').forEach(c => colRows(c).forEach(r => { const k = keyHash(`${r[0]} (${r[1]})`); if (!m.has(k)) m.set(k, r); }));
  return m;
}
function allTrackMap(){
  const m = new Map();
  allCols().filter(c=>c.type==='music').forEach(c => colRows(c).forEach(r => { if (r[2] && !m.has(r[2])) m.set(r[2], r); }));
  return m;
}
function addCustomCol(meta, rows){
  const cols = customCols().filter(c => c.id !== meta.id); cols.push(meta); ls.set('ringcine-cols', cols);
  return ls.set('ringcine-data-' + meta.id, rows);
}
function ringSync(KNOWN, BDKS){
  const H = s => { s = String(s).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]/g,''); let x = 5381; for (let i=0;i<s.length;i++) x = ((x*33) ^ s.charCodeAt(i)) >>> 0; return x.toString(36); };
  const known = new Set(KNOWN.split(','));
  const old = document.getElementById('ringsync'); if (old) old.remove();
  const box = document.createElement('div'); box.id = 'ringsync';
  box.style.cssText = 'position:fixed;z-index:2147483647;right:16px;bottom:16px;width:min(440px,calc(100vw - 32px));background:#181B21;color:#ECEAE6;border:1px solid #E8B84A;border-radius:12px;padding:14px;font:14px/1.4 system-ui,sans-serif;box-shadow:0 20px 60px rgba(0,0,0,.5)';
  box.innerHTML = '<div style="display:flex;justify-content:space-between;gap:8px;align-items:center"><b style="color:#E8B84A">Ring Sync</b><button id="rs-x" style="background:none;border:0;color:#8C919B;font-size:18px;cursor:pointer">✕</button></div><div id="rs-msg" style="margin:8px 0">Démarrage…</div><textarea id="rs-out" readonly style="display:none;width:100%;height:90px;background:#101216;color:#ECEAE6;border:1px solid #2B303A;border-radius:8px;font:11px monospace;padding:6px"></textarea><button id="rs-copy" style="display:none;margin-top:8px;background:#E8B84A;color:#101216;border:0;border-radius:8px;padding:8px 14px;font-weight:700;cursor:pointer">Copier</button>';
  document.body.appendChild(box);
  const msg = t => { box.querySelector('#rs-msg').textContent = t; };
  box.querySelector('#rs-x').onclick = () => box.remove();
  const done = (data, text) => {
    const out = box.querySelector('#rs-out'), btn = box.querySelector('#rs-copy');
    out.value = JSON.stringify(data); out.style.display = 'block'; btn.style.display = 'inline-block'; msg(text);
    btn.onclick = async () => { try { await navigator.clipboard.writeText(out.value); btn.textContent = 'Copié ✓'; } catch(e) { out.select(); document.execCommand('copy'); btn.textContent = 'Copié ✓'; } };
  };
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const BDK = new Set(String(BDKS || '').split(','));
  const getBD = async (list, max) => {
    const need = list.filter(f => f[1] && !BDK.has(H(f[0])));
    for (let i = need.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [need[i], need[j]] = [need[j], need[i]]; }
    const pick = need.slice(0, max), out = []; let k = 0, n = 0;
    const re = /data-backdrop="https:\/\/a\.ltrbxd\.com\/resized\/([^"]+?)"/;
    const one = async slug => { const r = await fetch('/film/' + slug + '/'); if (!r.ok || !r.body) return null; const rd = r.body.getReader(), dec = new TextDecoder(); let s = '', m = null; for (;;) { const x = await rd.read(); if (x.done) break; s += dec.decode(x.value, {stream: true}); if ((m = s.match(re)) || s.length > 900000) break; } try { rd.cancel(); } catch (e) {} return m ? m[1].replace(/&amp;/g, '&') : ''; };
    const worker = async () => { while (k < pick.length) { const f = pick[k++]; try { const v = await one(f[1]); if (v !== null) out.push([f[0], v]); } catch (e) {} n++; if (n % 5 === 0 || n === pick.length) msg('Scènes cultes : ' + n + '/' + pick.length); } };
    await Promise.all(Array.from({length: 8}, worker));
    return out;
  };
  (async () => {
    try {
      const lbUser = location.pathname.split('/')[1];
      if (/letterboxd\.com$/.test(location.hostname) && /^\/[^/]+\/(films\/?.*)?$/.test(location.pathname) && !['film','films','list','lists','search','settings','activity','members','journal','sign-in','tags','crew','actor','director','showdown','lists'].includes(lbUser)) {
        let user = lbUser;
        msg('Lecture des films de ' + user + '…');
        const parse = d => [...d.querySelectorAll('[data-item-slug]')].map(e => [e.dataset.itemName, e.dataset.itemSlug, +(((e.closest('li')||e.parentElement).querySelector('.rating')||{}).className||'').replace(/.*rated-(\d+).*/, '$1') || 0]);
        const page = async p => new DOMParser().parseFromString(await (await fetch(`/${user}/films/` + (p>1 ? `page/${p}/` : ''))).text(), 'text/html');
        const first = await page(1);
        const name = (first.title || user).replace(/[‎‏]/g, '').replace(/[’']s films.*$/i, '').trim() || user;
        const last = Math.max(1, ...[...first.querySelectorAll('.paginate-page a')].map(a => +a.textContent || 0));
        let all = parse(first);
        for (let p = 2; p <= last; p += 4) {
          const batch = await Promise.all([p, p+1, p+2, p+3].filter(x => x <= last).map(page));
          batch.forEach(d => all.push(...parse(d)));
          msg(`Lecture des films… page ${Math.min(p+3,last)}/${last}`);
        }
        const seen = new Set(); all = all.filter(f => f[1] && !seen.has(f[1]) && seen.add(f[1]));
        all.forEach(f => { if (isNaN(f[2])) f[2] = 0; });
        const fresh = all.filter(f => !known.has(H(f[0])));
        const add = []; let k = 0, doneN = 0;
        const re1 = /^https:\/\/a\.ltrbxd\.com\/resized\/film-poster\/(?:\d\/)+(\d+-[^?]+?)-0-\d+-0-\d+-crop\.jpg/, re2 = /^https:\/\/a\.ltrbxd\.com\/resized(\/.+?)-0-\d+-0-\d+-crop\.jpg/;
        const worker = async () => { while (k < fresh.length) { const [nm, slug, r] = fresh[k++];
          try {
            const [d, p] = await Promise.all([fetch(`/film/${slug}/json/`).then(x => x.json()), fetch(`/film/${slug}/poster/std/150/`).then(x => x.json()).catch(() => ({}))]);
            const u = p.url2x || p.url || ''; let m, path = '';
            if (!/empty-poster/.test(u)) { if ((m = u.match(re1))) path = m[1]; else if ((m = u.match(re2))) path = m[1]; }
            add.push([d.name, d.releaseYear || 0, (d.directors || []).map(x => x.name).join(', '), r, path, nm]);
          } catch (e) { add.push([nm.replace(/ \(\d{4}\)$/, ''), +(nm.match(/\((\d{4})\)$/) || [0,0])[1], '', r, '', nm]); }
          msg(`Nouveaux films : ${++doneN}/${fresh.length}`); } };
        await Promise.all([worker(), worker(), worker(), worker(), worker()]);
        const bd = [];
        done({k:'lb', v:4, user, name, all: all.map(f => [f[0], f[2]]), add, bd}, `${name} : ${all.length} films lus, ${add.length} à compléter. Clique sur Copier, puis colle dans Ring.`);
      } else if (location.hostname === 'open.spotify.com' && /\/playlist\//.test(location.pathname)) {
        const pl = location.pathname.split('/playlist/')[1].split(/[/?]/)[0];
        const grid = document.querySelector('[data-testid="playlist-tracklist"]');
        if (!grid) { msg('Ouvre la page de la playlist, attends qu’elle charge, puis reclique.'); return; }
        const title = (document.querySelector('[data-testid="entityTitle"]') || document.querySelector('main h1') || {}).textContent || 'Playlist';
        const owner = (document.querySelector('[data-testid="creator-link"]') || {}).textContent || '';
        const total = +grid.getAttribute('aria-rowcount') - 1 || 0;
        let sc = grid; while (sc && !(sc.scrollHeight > sc.clientHeight + 50 && /auto|scroll/.test(getComputedStyle(sc).overflowY))) sc = sc.parentElement;
        sc = sc || document.scrollingElement;
        const got = new Map();
        const grab = () => grid.querySelectorAll('[data-testid="tracklist-row"]').forEach(r => {
          const idx = +r.closest('[aria-rowindex]').getAttribute('aria-rowindex') - 2;
          const a = r.querySelector('a[data-testid="internal-track-link"]'); if (!a || idx < 0) return;
          const im = r.querySelector('img'); const src = im ? (im.src.split('/image/')[1] || '') : '';
          const artists = [...r.querySelectorAll('[aria-colindex="2"] a[href*="/artist/"]')].map(x => x.textContent).join(', ');
          got.set(idx, [a.textContent, artists, a.getAttribute('href').split('/track/')[1].split('?')[0], src.length === 40 && src.startsWith('ab67616d') ? src.slice(16) : (src ? '!' + src : '')]);
        });
        sc.scrollTop = 0; await wait(900);
        for (let k = 0; k < 1500; k++) {
          grab(); msg(`Lecture de la playlist… ${got.size}/${total || '?'}`);
          if (total && got.size >= total) break;
          const before = sc.scrollTop; sc.scrollTop += 450; await wait(350);
          if (sc.scrollTop === before) { await wait(800); grab(); if (sc.scrollTop === before) break; }
        }
        const tracks = [...got.entries()].sort((a, b) => a[0] - b[0]).map(x => x[1]);
        done({k:'sp', v:4, pl, name: title.trim(), owner: owner.trim(), tracks}, `${title.trim()} : ${tracks.length} sons lus${total && tracks.length < total ? ` (sur ${total} : relance si il en manque)` : ''}. Clique sur Copier, puis colle dans Ring.`);
      } else if (/myanimelist\.net$/.test(location.hostname) && /^\/(anime|manga)list\/[^/?]+/.test(location.pathname)) {
        /* MyAnimeList : lit toute la liste (animés ou mangas / manhwas) */
        const mm = location.pathname.match(/^\/(anime|manga)list\/([^/?]+)/), A = mm[1] === 'anime', user = mm[2];
        let all = [], off = 0;
        for (let k = 0; k < 40; k++) { const j = await (await fetch(`/${mm[1]}list/${user}/load.json?status=7&offset=${off}`)).json(); if (!Array.isArray(j) || !j.length) break; all = all.concat(j); off += j.length; msg('Lecture de la liste… ' + all.length); if (j.length < 300) break; }
        const items = all.map(x => { const t = A ? x.anime_title : x.manga_title, typ = A ? x.anime_media_type_string : x.manga_media_type_string, d = String((A ? x.anime_start_date_string : x.manga_start_date_string) || ''), y = +((d.match(/(\d{4})/) || d.match(/\d\d-\d\d-(\d\d)$/) || [])[1] || 0); const yy = y && y < 100 ? (y > 30 ? 1900 + y : 2000 + y) : y; return [String(t || ''), [typ, yy || ''].filter(Boolean).join(' · '), String((A ? x.anime_image_path : x.manga_image_path) || '').replace(/\/r\/\d+x\d+/, '').replace(/\?s=.*$/, ''), 'https://myanimelist.net' + (A ? x.anime_url : x.manga_url), '', yy]; }).filter(x => x[0]);
        done({k:'gen', v:5, src: location.href.split('?')[0], host: 'myanimelist.net', name: `${A ? 'Animés' : 'Mangas'} de ${user}`, kind: A ? 'anime' : 'manga', items}, `${items.length} ${A ? 'animés' : 'mangas'} lus. Clique sur Copier, puis colle dans Ring.`);
      } else if (/letterboxd\.com$/.test(location.hostname) && document.querySelector('[data-item-slug]')) {
        /* Watchlist, listes, likes… Letterboxd : lit toutes les pages, puis les affiches */
        const base = location.pathname.replace(/page\/\d+\/?$/, '').replace(/\/?$/, '/');
        const page = async n => new DOMParser().parseFromString(await (await fetch(base + (n > 1 ? `page/${n}/` : ''))).text(), 'text/html');
        const parse = d => [...d.querySelectorAll('[data-item-slug]')].map(e => [e.dataset.itemFullDisplayName || e.dataset.itemName || '', e.dataset.itemSlug]);
        msg('Lecture de la page 1…');
        const first = await page(1);
        const last = Math.max(1, ...[...first.querySelectorAll('.paginate-page a')].map(a => +a.textContent || 0));
        let all = parse(first);
        for (let p = 2; p <= last; p += 4) {
          const batch = await Promise.all([p, p + 1, p + 2, p + 3].filter(x => x <= last).map(page));
          batch.forEach(d => all.push(...parse(d)));
          msg(`Lecture des pages… ${Math.min(p + 3, last)}/${last}`);
        }
        const seen = new Set(); all = all.filter(f => f[1] && f[0] && !seen.has(f[1]) && seen.add(f[1]));
        const items = all.map(([nm, slug]) => { const m = nm.match(/\((\d{4})\)\s*$/); return [nm, '', '', 'https://letterboxd.com/film/' + slug + '/', '', m ? +m[1] : 0]; });
        const need = items.filter(it => !known.has(H(it[0])));
        let k = 0, doneN = 0;
        const worker = async () => { while (k < need.length) { const it = need[k++];
          try { const pj = await (await fetch(it[3].replace('https://letterboxd.com', '') + 'poster/std/230/')).json(); const u = pj.url2x || pj.url || ''; if (u && !/empty-poster/.test(u)) it[2] = u.split('?')[0]; } catch (e) {}
          doneN++; if (doneN % 5 === 0 || doneN === need.length) msg(`Affiches : ${doneN}/${need.length}`); } };
        await Promise.all(Array.from({length: 12}, worker));
        const bd = [];
        const dt = document.title.replace(/[\u200e\u200f]/g, '').trim();
        const who = (dt.match(/^(.+?)[’']s\s/) || dt.match(/list of films by (.+?)\s*•/) || [])[1] || location.pathname.split('/')[1];
        const kindName = /\/watchlist\//.test(base) ? 'Watchlist' : /\/likes\//.test(base) ? 'Films likés' : /\/list\//.test(base) ? ((dt.match(/^[‘'](.+?)[’'],/) || [])[1] || 'Liste') : 'Films';
        done({k:'gen', v:5, src: 'https://letterboxd.com' + base, host: 'letterboxd.com', name: `${kindName.trim()} de ${who.trim()}`.slice(0, 80), kind: 'films', items, bd}, `${items.length} films lus sur ${last} page${last > 1 ? 's' : ''}. Clique sur Copier, puis colle dans Ring.`);
      } else {
        const host = location.hostname.replace(/^www\./, '');
        const abs = u => { try { return u && !/^(data|javascript):/.test(u) ? new URL(u, location.href).href : ''; } catch (e) { return ''; } };
        const got = new Map();
        const ph = u => !u || /empty|placeholder|blank|spacer|default|loading|grey|gray|transparent/i.test(u);
        const put = it => { if (!it[0]) return; if (ph(it[2])) it[2] = ''; const k = it[3] || (it[0] + '|' + it[1]); if (!got.has(k)) got.set(k, it); else if (!got.get(k)[2] && it[2]) got.set(k, it); };
        let kind = /imdb|senscritique|themoviedb|trakt|allocine|mubi|justwatch|letterboxd|filmaffinity|rottentomatoes|metacritic|netflix|primevideo|disneyplus|canalplus|criterion|tvtime|serializd|anilist|myanimelist/.test(host) ? 'films' : /deezer|music\.apple|soundcloud|tidal|youtube|youtu\.be|last\.fm|bandcamp|qobuz|spotify|genius|rateyourmusic|discogs|shazam|napster|audiomack/.test(host) ? 'music' : 'items';
        if (/serializd|tvtime|tvmaze|betaseries|trakt\.tv\/users\/[^/]+\/(shows|progress)/.test(host + location.pathname)) kind = 'series'; else if (/myanimelist|anilist|kitsu/.test(host)) kind = /manga/.test(location.pathname) ? 'manga' : 'anime'; else if (/mangadex|mangaupdates|webtoons|comick|mangacollec/.test(host)) kind = 'manga'; else if (/backloggd|howlongtobeat|grouvee|steamcommunity|steampowered|igdb|rawg|glitchwave|infinite-backlog|senscritique\.com\/[^/]+\/collection.*jeux/.test(host + location.pathname)) kind = 'games';
        let extract;
        if (/youtube\.com$/.test(location.hostname) && document.querySelector('ytd-playlist-video-renderer, ytd-playlist-panel-video-renderer')) {
          extract = () => document.querySelectorAll('ytd-playlist-video-renderer, ytd-playlist-panel-video-renderer').forEach(r => {
            const a = r.querySelector('a#video-title, #video-title'); if (!a) return;
            const href = (a.closest('a') || a).getAttribute('href') || ''; const m = href.match(/[?&]v=([\w-]{11})/); if (!m) return;
            const ch = (r.querySelector('ytd-channel-name a, #channel-name a, #byline') || {}).textContent || '';
            put([(a.getAttribute('title') || a.textContent).trim(), ch.trim().replace(/\s*-\s*Topic$/, ''), `https://i.ytimg.com/vi/${m[1]}/hqdefault.jpg`, 'https://www.youtube.com/watch?v=' + m[1], m[1], 0]);
          });
          kind = 'music';
        } else {
          const bad = /logo|avatar|icon|sprite|emoji|badge|flag|profile-pic|pixel|spacer|ads?[-_]/i;
          const bestSrc = im => {
            const ss = im.getAttribute('srcset') || im.getAttribute('data-srcset') || '';
            if (ss) { const c = ss.split(/,\s+/).map(x => x.trim().split(/\s+/)).filter(x => x[0]).map(x => [x[0], parseFloat(x[1]) || 0]).sort((a, b) => b[1] - a[1]); if (c[0] && !/^data:/.test(c[0][0])) return abs(c[0][0]); }
            if (im.tagName !== 'IMG') { const m = getComputedStyle(im).backgroundImage.match(/url\(["']?(.+?)["']?\)/); return m ? abs(m[1]) : ''; }
            return abs(im.getAttribute('data-src') || im.getAttribute('data-lazy-src') || im.getAttribute('data-original') || (/^data:/.test(im.currentSrc || im.src) ? '' : (im.currentSrc || im.src)));
          };
          const sig = e => e.tagName + '.' + [...e.classList].filter(c => !/\d|active|selected|hover|focus|visible|loaded|lazy/i.test(c)).sort().slice(0, 3).join('.');
          const junk = l => !l || l.length > 160 || /^[\d\s.,:#/★☆½+\-–%()]*$/.test(l) || /^(voir|see|more|plus|play|lire|watch|add|ajouter|like|j’aime)$/i.test(l);
          const altOf = im => (im.getAttribute('alt') || im.getAttribute('aria-label') || im.getAttribute('title') || '').replace(/^(poster|affiche|cover|pochette|image|photo|thumbnail|miniature)\s*(for|of|de|du|de la|:)?\s*/i, '').trim();
          extract = () => {
            const cands = [...document.querySelectorAll('img, [style*="background-image"]')].filter(im => {
              if (im.closest('#ringsync, header, nav, footer, [role="banner"], [role="navigation"], aside')) return false;
              const r = im.getBoundingClientRect(), w = r.width || im.width || 0, h = r.height || im.height || 0;
              return w >= 40 && h >= 40 && !bad.test((im.className && im.className.baseVal === undefined ? im.className : '') + ' ' + (im.getAttribute('src') || '') + ' ' + (im.getAttribute('alt') || ''));
            });
            const groups = new Map();
            cands.forEach(im => {
              let u = im;
              for (let d = 0; d < 9 && u.parentElement && u.parentElement !== document.body; d++) {
                const p = u.parentElement, s = sig(u);
                if ([...p.children].filter(c => sig(c) === s).length >= 3) break;
                u = p;
              }
              if (!u.parentElement) return;
              const key = sig(u.parentElement) + '>' + sig(u);
              if (!groups.has(key)) groups.set(key, new Map());
              if (!groups.get(key).has(u)) groups.get(key).set(u, im);
            });
            let best = null; groups.forEach((g, k) => { if (g.size >= 3 && (!best || g.size > best[1].size)) best = [k, g]; });
            if (!best) return;
            if (!extract.key) extract.key = best[0];
            const g = groups.get(extract.key) || best[1];
            g.forEach((im, u) => {
              const lines = (u.innerText || '').split('\n').map(l => l.trim()).filter(l => !junk(l));
              const hd = u.querySelector('h1,h2,h3,h4,h5,h6,[class*="title" i],[class*="name" i]');
              const alt = altOf(im);
              let t = (hd && !junk((hd.innerText || hd.textContent || '').trim()) ? (hd.innerText || hd.textContent).trim().split('\n')[0] : '') || (alt.length > 1 ? alt : '') || lines[0] || '';
              t = t.replace(/^\d+\.\s+/, '').trim();
              const sub = lines.find(l => l !== t && !t.includes(l) && !l.includes(t)) || '';
              const a = u.tagName === 'A' ? u : (u.closest('a[href]') || u.querySelector('a[href]'));
              const yr = ((u.innerText || '') + ' ' + alt).match(/\b(19[0-9]{2}|20[0-9]{2})\b/);
              put([t, sub, bestSrc(im), a ? abs(a.getAttribute('href')) : '', '', yr ? +yr[1] : 0]);
            });
          };
        }
        const scrollers = () => [document.scrollingElement, ...[...document.querySelectorAll('main, [role="main"], div, section')].filter(e => e.scrollHeight > e.clientHeight + 200 && e.clientHeight > 250 && /auto|scroll/.test(getComputedStyle(e).overflowY))].filter(Boolean);
        const sc = scrollers().sort((a, b) => b.scrollHeight - a.scrollHeight)[0] || document.scrollingElement;
        sc.scrollTop = 0; await wait(600); extract();
        let still = 0;
        for (let k = 0; k < 150 && still < 3; k++) {
          const before = sc.scrollTop, hb = sc.scrollHeight;
          sc.scrollTop += Math.max(500, sc.clientHeight * 0.8); await wait(650);
          extract(); msg(`Lecture de la page… ${got.size} trouvés`);
          if (sc.scrollTop === before && sc.scrollHeight === hb) { still++; await wait(700); } else still = 0;
        }
        extract();
        const items = [...got.values()];
        if (!items.length) { msg('Aucune liste trouvée sur cette page. Ouvre une page qui montre une liste avec des images (playlist, liste de films…), puis reclique.'); return; }
        const name = (document.querySelector('h1') || {}).textContent || document.title || host;
        done({k:'gen', v:5, src: location.href.split('#')[0], host, name: name.trim().replace(/\s+/g, ' ').slice(0, 80), kind, items}, `${items.length} éléments trouvés sur ${host}. Clique sur Copier, puis colle dans Ring (tu pourras vérifier avant d’ajouter).`);
      }
    } catch (e) { msg('Erreur : ' + e.message); }
  })();
}
function refreshBookmarklet(){
  const known = [...allFilmMap().keys()].join(',');
  $('bm').href = 'javascript:' + encodeURIComponent(`(${ringSync.toString()})(${JSON.stringify(known)},${JSON.stringify(bdKnown())})`);
}

/* ---------- Navigation ---------- */
let curView = 'home';
const VIEWS = {home:()=>renderHome(), duel:()=>renderDuel(), tour:()=>renderTour(), rank:()=>renderRank(), game:()=>renderGame(), tier:()=>renderTier(), swipe:()=>renderSwipe(), tonight:()=>renderTonight(), stats:()=>renderStats(), trophy:()=>renderTrophies()};
function go(v){
  if (v !== 'game') stopAudio();
  if (v !== 'game' && EXT.on) { extLeave(); G.id = null; G.cur = null; }
  curView = v;
  if (v !== 'home') { S.view = v; save(); }
  if (v !== 'game' && typeof G === 'object') G.tok++;
  if (v !== 'game') { try { if (document.fullscreenElement) document.exitFullscreen(); } catch(e){} if (typeof gTimer !== 'undefined') clearTimeout(gTimer); }
  renderSide(); renderTop(); renderBottom();
  VIEWS[v]();
  window.scrollTo(0, 0);
}
function colIcon(col){
  let it = null;
  if (C && col.id === C.id && F && N) { let b = 0; for (let k = 1; k < N; k++) if (S.elo[k] > S.elo[b]) b = k; it = F[b]; }
  else { const sn = colSnapshot(col), i = sn.order[0]; it = i !== undefined ? sn.items[i] : null; }
  return it && it.img ? `<img src="${it.img}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()">` : (col.type==='films' ? '🎬' : col.type==='music' ? '🎵' : '★');
}
function renderSide(){ const sd = $('side'); if (sd) sd.innerHTML = ''; return; }
function renderSideOld(){
  const cols = allCols();
  const item = c => `<button class="sitem" data-id="${esc(c.id)}" aria-current="${curView!=='home' && C && C.id===c.id}"><span class="ico">${colIcon(c)}</span><span><span class="nm">${esc(c.label)}</span><span class="sub">${fmt(colRows(c).length)} ${colType(c).many}</span></span></button>`;
  const grp = (t, l) => { const g = cols.filter(c => c.type === t); return g.length ? `<div class="slabel">${l}</div><div class="snav">${g.map(item).join('')}</div>` : ''; };
  $('side').innerHTML = `<button class="logo" id="logo" aria-label="Accueil"><b>Ring</b><i>${TY ? TY.brand : 'Ciné'}</i></button>
    <div class="snav"><button class="sitem" id="s-home" aria-current="${curView==='home'}"><span class="ico">⌂</span><span class="nm">Accueil</span></button></div>
    ${grp('films', 'Films')}${grp('music', 'Musique')}${grp('items', 'Autres')}
    <button class="sadd" id="s-add">＋ Ajouter / mettre à jour</button>
    <div class="sfoot"><button id="s-set">⚙ Réglages et sauvegarde</button><button id="s-conn" title=""><span class="conn ${SERVER?'ok':'off'}" id="conn"></span>${SERVER ? 'Sauvegarde auto active' : 'Sauvegarde dans ce navigateur'}</button></div>`;
  $('logo').onclick = $('s-home').onclick = () => go('home');
  $('side').querySelectorAll('.sitem[data-id]').forEach(b => b.onclick = () => switchCol(b.dataset.id, curView==='home' ? 'duel' : curView));
  $('s-add').onclick = () => openSync();
  $('s-set').onclick = openSettings;
  $('s-conn').onclick = openSettings;
}
function renderBottom(){
  const it = [['home','⌂','Accueil'],['duel','⚔','Duels'],['tour','🏆','Tournoi'],['rank','☰','Classement'],['game','🎮','Jeux'],['more','•••','Plus']];
  $('bottombar').innerHTML = it.map(([v,i,l]) => `<button data-v="${v}" aria-current="${curView===v}"><span class="i">${i}</span>${l}</button>`).join('');
  $('bottombar').querySelectorAll('button').forEach(b => b.onclick = () => b.dataset.v === 'more' ? openMore() : go(b.dataset.v));
  const mb = $('bottombar').querySelector('[data-v="more"]'); if (mb && ['tier','swipe','tonight','stats','trophy'].includes(curView)) mb.setAttribute('aria-current', 'true');
}
function openMore(){
  const it = [['tier','▤','Tier list'],['swipe','↕','Plus ou moins'],['tonight','🍿','Ce soir'],['stats','📊','Stats'],['trophy','🏅','Trophées']];
  openModal(`<div class="sheethead"><h2>Menu</h2><button class="x" aria-label="Fermer">✕</button></div>
    <div class="moregrid">${it.map(([v,i,l]) => `<button class="moreit" data-v="${v}" aria-current="${curView===v}"><span class="i">${i}</span>${l}</button>`).join('')}</div>
    <div class="row2" style="display:flex;flex-wrap:wrap;gap:8px"><button class="btn" id="mo-ring">🎬 Changer de ring</button><button class="btn" id="mo-add">＋ Ajouter</button><button class="btn" id="mo-set">⚙ Réglages</button></div>`, () => {
    $('sheet').querySelectorAll('.moreit').forEach(b => b.onclick = () => { closeModal(); go(b.dataset.v); });
    $('mo-ring').onclick = openPicker; $('mo-add').onclick = () => openSync(); $('mo-set').onclick = openSettings;
  });
}
function switchCol(id, view){
  if (C && C.id===id) { go(view || curView); return; }
  if (C) save();
  loadCol(id);
  pair=null; tpanel='feed'; tq=''; tshown=120; shown=100; query=''; grp='all'; sortBy='score'; open=-1;
  document.title = `Ring ${TY.brand}`;
  go(view || S.view || 'duel');
}
function deleteCol(id){
  ls.set('ringcine-cols', customCols().filter(c=>c.id!==id)); ls.del('ringcine-data-'+id); ls.del('ringcine-st-'+id);
  const t = ls.get('ringcine-sync', {}); delete t[id]; ls.set('ringcine-sync', t);
  if (C.id === id){ C = null; switchCol('films', 'home'); } else go(curView);
  toast('Collection supprimée');
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !$('modal').hidden) { closeModal(); return; }
  if (e.key === 'Escape' && e.target.matches('input,textarea,select')) { e.target.blur(); return; }
  if ($('modal').hidden && !e.ctrlKey && !e.metaKey && !e.altKey && (customKey(e) || gameKey(e) || swipeKey(e))) return;
  if (!$('modal').hidden || e.target.matches('input,textarea,select') || e.metaKey || e.altKey) return;
  if (e.ctrlKey) { if (e.key.toLowerCase() === 'z') { if (curView==='duel'){ e.preventDefault(); undoDuel(); } else if (curView==='tour'){ e.preventDefault(); undoTour(); } } return; }
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  if (k === '?' || k === ',') { e.preventDefault(); openKeys(); return; }
  if (k === 'h') { go('home'); return; }
  if (k === 's') { e.preventDefault(); openSync(); return; }
  if (k === 'g') { openPicker(); return; }
  const VK = {d:'duel',t:'tour',c:'rank',j:'game',l:'tier',r:'swipe',o:'tonight',x:'stats',y:'trophy'};
  if (curView === 'home') { if (VK[k]) go(VK[k]); return; }
  if (VK[k]) { go(VK[k]); return; }
  if (k === 'p') { e.preventDefault(); makePng(); return; }
  if (k === 'f' && curView === 'duel') { e.preventDefault(); fxOpen = !fxOpen; renderDuel(); return; }
  if (k === '/') { const q = view.querySelector('input[type=search]'); if (q) { e.preventDefault(); q.focus(); q.select(); } else if (curView === 'tour' && S.tour) { e.preventDefault(); tpanel = 'alive'; rerenderPanel(); const n = $('tq'); if (n) n.focus(); } return; }
  if (k === 'a' || k === '1' || k === '&') { if (togglePlayer(0)) e.preventDefault(); return; }
  if (k === 'e' || k === '2' || k === 'é') { if (togglePlayer(1)) e.preventDefault(); return; }
  const cards = view.querySelectorAll('.card:not([disabled])');
  if (e.key==='Backspace'){ if (curView==='duel'){ e.preventDefault(); undoDuel(); } else if (curView==='tour'){ e.preventDefault(); undoTour(); } return; }
  if (cards.length!==2) return;
  if (e.key==='ArrowLeft'){ e.preventDefault(); cards[0].click(); }
  else if (e.key==='ArrowRight'){ e.preventDefault(); cards[1].click(); }
  else if (e.key==='ArrowDown' && curView==='duel'){ e.preventDefault(); pair=null; renderDuel(); }
  else if (e.key==='ArrowUp' && curView==='duel'){ e.preventDefault(); $('draw').click(); }
});

/* ---------- Fenêtres ---------- */
function openModal(html, bind){ $('sheet').innerHTML = html; $('modal').hidden = false; if (bind) bind(); const x = $('sheet').querySelector('.x'); if (x) x.onclick = closeModal; }
function closeModal(){ $('modal').hidden = true; $('sheet').innerHTML = ''; }
$('modal').addEventListener('click', e => { if (e.target.id === 'modal') closeModal(); });
function openPicker(){
  const cols = allCols();
  openModal(`<div class="sheethead"><h2>Tes rings</h2><button class="x" aria-label="Fermer">✕</button></div>
    <div class="snav">${cols.map(c => `<button class="sitem" data-id="${esc(c.id)}" aria-current="${C && C.id===c.id}"><span class="ico">${colIcon(c)}</span><span><span class="nm">${esc(c.label)}</span><span class="sub">${typeName(c.type)} · ${fmt(colRows(c).length)} ${colType(c).many}</span></span></button>`).join('')}</div>
    <div class="row2" style="display:flex;flex-wrap:wrap;gap:8px"><button class="btn primary" id="pk-add">＋ Ajouter / mettre à jour</button><button class="btn" id="pk-set">⚙ Réglages</button></div>`, () => {
    $('sheet').querySelectorAll('.sitem').forEach(b => b.onclick = () => { closeModal(); switchCol(b.dataset.id, curView === 'home' ? 'duel' : curView); });
    $('pk-add').onclick = () => openSync();
    $('pk-set').onclick = openSettings;
  });
}

/* ---------- Ajouter / mettre à jour avec Ring Sync ---------- */
function markSynced(id){ const t = ls.get('ringcine-sync', {}); t[id] = Date.now(); ls.set('ringcine-sync', t); }
function ago(ts){
  if (!ts) return 'jamais mis à jour';
  const m = Math.round((Date.now() - ts) / 60000);
  if (m < 1) return 'mis à jour à l’instant'; if (m < 60) return `mis à jour il y a ${m} min`;
  const h = Math.round(m / 60); if (h < 24) return `mis à jour il y a ${h} h`;
  const d = Math.round(h / 24); return d === 1 ? 'mis à jour hier' : `mis à jour il y a ${d} jours`;
}
const srcUrl = col => col.src ? (safeUrl(col.src) || '#') : col.type === 'films' ? `https://letterboxd.com/${encodeURIComponent(col.user || '')}/` : `https://open.spotify.com/playlist/${encodeURIComponent(col.pl || '')}`;
function openSync(onlyCol){
  const installed = ls.get('ringcine-bm', false);
  const cols = onlyCol ? [onlyCol] : allCols().filter(c => c.user || c.pl || c.src);
  openModal(`<div class="sheethead"><h2>${onlyCol ? 'Mettre à jour' : 'Ajouter ou mettre à jour'}</h2><button class="x" aria-label="Fermer">✕</button></div>
    <ol class="steps">
      <li class="${installed ? 'done' : ''}"><div><b>Installe le bouton Ring Sync</b>${installed ? ' <span class="note" style="display:inline">(déjà fait ✓)</span>' : ''}
        <p class="note">Glisse-le dans ta barre de favoris, une seule fois. Si elle est cachée : <kbd>Ctrl</kbd>+<kbd>Maj</kbd>+<kbd>B</kbd>. Si tu avais une ancienne version, remplace-la.</p>
        <a class="bm" id="bm" href="#">⟳ Ring Sync</a></div></li>
      <li><div><b>Ouvre la page à lire</b>
        <p class="note">${onlyCol ? 'Clique pour ouvrir la page de ce ring :' : 'N’importe quel site marche : profil Letterboxd, playlist Spotify ou YouTube, liste IMDb, SensCritique, Deezer, Apple Music… Les tiennes :'}</p>
        <div class="srcs">${cols.map(c => `<a href="${srcUrl(c)}" target="_blank" rel="noopener">${esc(c.label)} ↗</a>`).join('')}${onlyCol ? '' : '<a href="https://letterboxd.com/" target="_blank" rel="noopener">Autre profil Letterboxd ↗</a>'}</div>${onlyCol ? '' : '<p class="note" style="margin-top:8px">Pas de site ? <button class="lnk" id="manual">Tape ta liste à la main</button></p>'}</div></div></li>
      <li><div><b>Clique sur le favori Ring Sync, puis sur « Copier »</b><p class="note">Une petite fenêtre dorée apparaît en bas à droite de la page. Attends qu’elle ait fini de lire.</p></div></li>
      <li><div><b>Reviens ici et colle</b><p class="note">Appuie simplement sur <kbd>Ctrl</kbd>+<kbd>V</kbd> n’importe où sur Ring. Ça s’ajoute tout seul.</p></div></li>
    </ol>
    ${onlyCol ? '' : `<div class="alist"><b>Animés / mangas / manhwas depuis AniList</b> <span class="note">(sans le bouton : tape juste ton pseudo)</span><div class="fx" style="gap:8px;margin-top:8px;flex-wrap:wrap"><input class="input" id="aluser" placeholder="Pseudo AniList" style="flex:1;min-width:160px"><div class="seg" id="altype"><button data-t="ANIME" aria-pressed="true">Animés</button><button data-t="MANGA" aria-pressed="false">Mangas</button></div><button class="btn sm primary" id="algo">Importer</button></div></div>`}
    <div class="pastezone" id="pastezone"><strong>Ctrl + V</strong><span class="note">ou colle le texte ici :</span><textarea id="synccode" placeholder="Texte copié par Ring Sync…"></textarea><div><button class="btn primary sm" id="syncgo">Ajouter</button></div></div>
    <div id="syncres"></div>`, () => {
    refreshBookmarklet();
    $('bm').onclick = e => { e.preventDefault(); toast('Glisse ce bouton dans ta barre de favoris (ne clique pas dessus ici).'); };
    $('syncgo').onclick = () => handleSyncText($('synccode').value);
    if ($('manual')) $('manual').onclick = openManual;
    if ($('algo')) { $('altype').querySelectorAll('button').forEach(b => b.onclick = () => $('altype').querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x === b))); $('algo').onclick = () => anilistImport($('aluser').value.trim(), $('altype').querySelector('[aria-pressed="true"]').dataset.t); }
  });
}
document.addEventListener('paste', e => {
  const t = (e.clipboardData && e.clipboardData.getData('text')) || '';
  if (/^\s*\{"k":"(lb|sp|gen)"/.test(t)) { e.preventDefault(); handleSyncText(t); }
});
function handleSyncText(t){
  let o = null; try { o = JSON.parse(String(t||'').trim()); } catch(e){}
  const nbd = o && o.bd ? saveBD(o.bd) : 0; if (nbd) setTimeout(() => toast(`🌟 ${nbd} scène${nbd > 1 ? 's' : ''} culte${nbd > 1 ? 's' : ''} ajoutée${nbd > 1 ? 's' : ''} pour le jeu Scène culte`), 1800);
  if (o && o.k === 'gen') { openGenPreview(o); return; }
  const r = applySync(t);
  if (r.ok) ls.set('ringcine-bm', true);
  const html = `<div class="result${r.ok ? '' : ' err'}">${esc(r.msg)}${r.ok && r.id ? ` <button class="lnk" id="gores">Aller à ce ring →</button>` : ''}</div>`;
  if (r.ok && r.id) afterSync(r.id);
  if ($('modal').hidden || !$('syncres')) openSync();
  const z = $('pastezone'); if (z && r.ok) { z.classList.add('flash'); setTimeout(() => z.classList.remove('flash'), 900); }
  $('syncres').innerHTML = html; if ($('synccode')) $('synccode').value = '';
  if ($('gores')) $('gores').onclick = () => { closeModal(); switchCol(r.id, 'duel'); };
  toast(r.ok ? r.msg : 'Texte non reconnu');
}
function afterSync(id){
  if (C && C.id === id) { const v = curView; C = null; switchCol(id, v); }
  else go(curView);
}
function applySync(text){
  let o; try { o = JSON.parse(String(text || '').trim()); } catch(e) { return {ok:false, msg:"Ce texte n'est pas reconnu. Recopie-le depuis la fenêtre Ring Sync (bouton Copier)."}; }
  const full = 'Stockage plein : supprime une collection puis recommence.';
  const pl = n => n > 1 ? 's' : '';
  if (o.k === 'lb') {
    if (!o.user) return {ok:false, msg:'Ce texte vient d’une ancienne version du bouton Ring Sync. Remplace le favori par le nouveau (étape 1), puis recommence.'};
    const known = allFilmMap(), addMap = new Map((o.add||[]).map(r => [keyHash(r[5] || `${r[0]} (${r[1]})`), r]));
    const rowsFor = (o.all||[]).map(([name, r]) => { const k = keyHash(name); const b = addMap.get(k) || known.get(k); return b ? [b[0], b[1], b[2], r, b[4]] : null; }).filter(Boolean);
    const target = allCols().find(c => c.type==='films' && (c.user||'').toLowerCase() === o.user.toLowerCase());
    if (!target) {
      const meta = {id:'lb:' + o.user.toLowerCase(), type:'films', label:`Films de ${o.name || o.user}`, user:o.user};
      if (!addCustomCol(meta, rowsFor)) return {ok:false, msg:full};
      markSynced(meta.id); return {ok:true, id:meta.id, msg:`Nouveau ring « ${meta.label} » : ${fmt(rowsFor.length)} films.`};
    }
    const added = []; let upd = 0;
    if (target.id === 'films') {
      const have = new Map(colRows(target).map(r => [keyHash(`${r[0]} (${r[1]})`), r]));
      const ov = ls.get('ringcine-ratings', {}), extra = ls.get('ringcine-extra-films', []);
      rowsFor.forEach(r => { const k = keyHash(`${r[0]} (${r[1]})`), h = have.get(k); if (!h) { extra.push(r); have.set(k, r); added.push(r[0]); } else if (r[3] && h[3] !== r[3]) { ov[k] = r[3]; upd++; } });
      ls.set('ringcine-ratings', ov); if (!ls.set('ringcine-extra-films', extra)) return {ok:false, msg:full};
    } else {
      const rows = colRows(target), have = new Map(rows.map((r,i) => [keyHash(`${r[0]} (${r[1]})`), i]));
      rowsFor.forEach(r => { const k = keyHash(`${r[0]} (${r[1]})`), i = have.get(k); if (i === undefined) { rows.push(r); have.set(k, rows.length-1); added.push(r[0]); } else if (r[3] && rows[i][3] !== r[3]) { rows[i] = [rows[i][0], rows[i][1], rows[i][2], r[3], rows[i][4]]; upd++; } });
      if (!ls.set('ringcine-data-' + target.id, rows)) return {ok:false, msg:full};
    }
    markSynced(target.id);
    return {ok:true, id:target.id, msg: added.length || upd ? `« ${target.label} » : ${added.length} film${pl(added.length)} ajouté${pl(added.length)}${added.length ? ' (' + added.slice(0,3).join(', ') + (added.length > 3 ? '…' : '') + ')' : ''}, ${upd} note${pl(upd)} mise${pl(upd)} à jour.` : `« ${target.label} » : tout est déjà à jour.`};
  }
  if (o.k === 'sp') {
    const tracks = (o.tracks||[]).filter(t => t[2]);
    const pool = allTrackMap();
    const full5 = t => { const p = pool.get(t[2]); return p ? p.slice(0,5) : [t[0], t[1], t[2], t[3], '']; };
    const target = allCols().find(c => c.type==='music' && c.pl === o.pl);
    if (!target) {
      const meta = {id:'sp:' + o.pl, type:'music', label:`${o.name || 'Playlist'}${o.owner ? ' (' + o.owner + ')' : ''}`, pl:o.pl};
      if (!addCustomCol(meta, tracks.map(full5))) return {ok:false, msg:full};
      markSynced(meta.id); return {ok:true, id:meta.id, msg:`Nouveau ring « ${meta.label} » : ${fmt(tracks.length)} sons.`};
    }
    const ids = new Set(colRows(target).map(r => r[2])), fresh = tracks.filter(t => !ids.has(t[2])).map(full5);
    if (target.id === 'music') { if (!ls.set('ringcine-extra-music', ls.get('ringcine-extra-music', []).concat(fresh))) return {ok:false, msg:full}; }
    else if (!ls.set('ringcine-data-' + target.id, colRows(target).concat(fresh))) return {ok:false, msg:full};
    markSynced(target.id);
    return {ok:true, id:target.id, msg: fresh.length ? `« ${target.label} » : ${fresh.length} son${pl(fresh.length)} ajouté${pl(fresh.length)} (${fresh.slice(0,3).map(r=>r[0]).join(', ')}${fresh.length > 3 ? '…' : ''}).` : `« ${target.label} » : tout est déjà à jour.`};
  }
  return {ok:false, msg:"Ce texte n'est pas reconnu."};
}


/* ---------- Import depuis n'importe quel site ---------- */
const GTY = [['films','Films'],['music','Musique'],['series','Séries'],['anime','Animés'],['manga','Mangas / manhwas'],['games','Jeux vidéo'],['items','Autre']];
function genRows(o, type){
  const seen = new Set(), out = []; let FM = null;
  (o.items||[]).forEach(([t, sub, im, link, yt, year]) => {
    t = String(t||'').trim(); if (!t) return; sub = String(sub||'').trim();
    const k = keyHash(link || (t + sub)); if (seen.has(k)) return; seen.add(k);
    if (type === 'films') { let y = +year || 0, tt = t; const m = t.match(/^(.*?)\s*\((\d{4})\)\s*$/); if (m) { tt = m[1]; y = +m[2]; } if (!y) { const m2 = sub.match(/\b(19\d\d|20\d\d)\b/); if (m2) y = +m2[1]; }
      let pim = im || '', dir = /^\d{4}$/.test(sub) ? '' : sub; if (!pim || !dir) { const kf = (FM ||= allFilmMap()).get(keyHash(`${tt} (${y})`)); if (kf) { if (!pim && kf[4]) pim = kf[4]; if (!dir && kf[2]) dir = kf[2]; } }
      out.push([tt, y, dir, 0, pim]); }
    else if (type === 'music') out.push([t, sub, yt ? 'yt:' + yt : 'x:' + k, im||'', yt||'']);
    else out.push([t, sub, im||'', link||'', k]);
  });
  return out;
}
function rowKey(type, r){ return type === 'films' ? keyHash(`${r[0]} (${r[1]})`) : type === 'music' ? r[2] : r[4]; }
function saveGen(meta, rows){
  const full = {ok:false, msg:'Stockage plein : supprime une collection puis recommence.'};
  const ex = colById(meta.id), pl = n => n > 1 ? 's' : '';
  if (!ex) { if (!addCustomCol(meta, rows)) return full; markSynced(meta.id); return {ok:true, id:meta.id, msg:`Nouveau ring « ${meta.label} » : ${fmt(rows.length)} ${colType(meta).many}.`}; }
  const old = colRows(ex), have = new Set(old.map(r => rowKey(ex.type, r)));
  const fresh = ex.type === meta.type ? rows.filter(r => !have.has(rowKey(ex.type, r))) : [];
  const cols = customCols().map(c => c.id === ex.id ? Object.assign({}, c, {label: meta.label, shape: meta.shape}, meta.kind ? {kind: meta.kind} : {}) : c); ls.set('ringcine-cols', cols);
  if (!ls.set('ringcine-data-' + ex.id, old.concat(fresh))) return full;
  markSynced(ex.id);
  return {ok:true, id:ex.id, msg: fresh.length ? `« ${meta.label} » : ${fresh.length} ajouté${pl(fresh.length)} (${fresh.slice(0,3).map(r=>r[0]).join(', ')}${fresh.length > 3 ? '…' : ''}).` : `« ${meta.label} » : tout est déjà à jour.`};
}
function openGenPreview(o){
  const id = 'gx:' + keyHash(o.src || o.name || 'liste'), ex = colById(id);
  let type = ex ? (ex.kind || ex.type) : (o.kind || 'items'), shape = ex && ex.shape ? ex.shape : (type === 'music' ? 'sq' : 'pt');
  const items = o.items || [];
  if (!items.length) { openSync(); $('syncres').innerHTML = `<div class="result err">Aucune liste trouvée sur ${esc(o.host||'cette page')}. Fais défiler la page pour tout afficher, puis reclique sur Ring Sync. Sinon, <button class="lnk" id="man2">tape ta liste à la main</button>.</div>`; $('man2').onclick = openManual; return; }
  const draw = () => {
    openModal(`<div class="sheethead"><h2>${ex ? 'Mettre à jour' : 'Nouveau ring'}</h2><button class="x" aria-label="Fermer">✕</button></div>
      <p class="note" style="margin:0 0 12px"><b style="color:var(--text)">${fmt(items.length)}</b> éléments trouvés sur <b style="color:var(--text)">${esc(o.host||'')}</b>. Vérifie que c’est bien la bonne liste avant d’ajouter.</p>
      <label class="note" for="gname">Nom du ring</label>
      <input id="gname" class="input" style="width:100%;margin:4px 0 12px" value="${esc(ex ? ex.label : (o.name||'Ma liste').slice(0,70))}">
      <div class="fx" style="gap:16px;flex-wrap:wrap;margin-bottom:12px">
        <div><div class="note">C’est quoi ?</div><div class="seg" id="gtype">${GTY.map(([k,l]) => `<button data-t="${k}" aria-pressed="${type===k}">${l}</button>`).join('')}</div></div>
        <div><div class="note">Images</div><div class="seg" id="gshape"><button data-s="pt" aria-pressed="${shape==='pt'}">Affiche</button><button data-s="sq" aria-pressed="${shape==='sq'}">Carré</button></div></div>
      </div>
      <div class="gprev">${items.slice(0, 24).map(it => `<div class="gi">${it[2] ? `<img class="${shape==='sq'?'sq':''}" src="${esc(it[2])}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'noimg'}))">` : '<div class="noimg"></div>'}<span>${esc(it[0])}</span></div>`).join('')}</div>
      ${items.length > 24 ? `<p class="note">… et ${fmt(items.length - 24)} autres.</p>` : ''}
      <div class="fx" style="gap:8px;justify-content:flex-end;margin-top:14px"><button class="btn sm" id="gcancel">Annuler</button><button class="btn primary sm" id="gok">${ex ? `Mettre à jour « ${esc(ex.label)} »` : 'Ajouter ce ring'}</button></div>`, () => {
      $('gtype').querySelectorAll('button').forEach(b => b.onclick = () => { type = b.dataset.t; if (!ex) shape = type === 'music' ? 'sq' : 'pt'; const n = $('gname').value; draw(); $('gname').value = n; });
      $('gshape').querySelectorAll('button').forEach(b => b.onclick = () => { shape = b.dataset.s; const n = $('gname').value; draw(); $('gname').value = n; });
      $('gcancel').onclick = closeModal;
      $('gok').onclick = () => {
        const isK = !!KINDS[type], meta = {id, type: isK ? 'items' : type, label: $('gname').value.trim() || o.name || 'Ma liste', src: o.src, host: o.host, shape}; if (isK) meta.kind = type;
        const r = saveGen(meta, genRows(o, isK ? 'items' : type));
        if (r.ok) ls.set('ringcine-bm', true);
        toast(r.msg); if (!r.ok) return;
        closeModal(); if (C && C.id === r.id) { C = null; } switchCol(r.id, 'duel');
      };
    });
  };
  draw();
}
function openManual(){
  openModal(`<div class="sheethead"><h2>Ta liste à la main</h2><button class="x" aria-label="Fermer">✕</button></div>
    <p class="note" style="margin:0 0 10px">Un élément par ligne (films, séries, jeux, plats, joueurs… ce que tu veux). Tu peux ajouter un détail après un tiret : <i>Zidane - France</i>.</p>
    <label class="note" for="mname">Nom du ring</label><input id="mname" class="input" style="width:100%;margin:4px 0 10px" placeholder="Ex. : Meilleurs jeux vidéo">
    <textarea id="mlist" class="input" style="width:100%;height:220px;font:14px/1.5 var(--sans, system-ui)" placeholder="Minecraft&#10;GTA V&#10;Zelda - Breath of the Wild"></textarea>
    <div class="fx" style="gap:8px;justify-content:flex-end;margin-top:12px"><button class="btn sm" id="mcancel">Annuler</button><button class="btn primary sm" id="mok">Créer le ring</button></div>`, () => {
    $('mcancel').onclick = closeModal;
    $('mok').onclick = () => {
      const lines = $('mlist').value.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
      if (lines.length < 2) { toast('Mets au moins 2 lignes.'); return; }
      const label = $('mname').value.trim() || 'Ma liste';
      const items = lines.map(l => { const m = l.split(/\s+[-–—]\s+/); return [m[0], m.slice(1).join(' - '), '', '', '']; });
      const r = saveGen({id: 'mx:' + keyHash(label + Date.now()), type: 'items', label, host: 'Liste perso', shape: 'pt'}, genRows({items}, 'items'));
      toast(r.msg); if (!r.ok) return; closeModal(); switchCol(r.id, 'duel');
    };
  });
}

/* ---------- Accueil ---------- */
function renderHome(){
  const cols = allCols();
  const last = colById(ls.get('ringcine-col', 'films')) || cols[0];
  const L = colSnapshot(last), lst = ls.get(stateKey(last), null), lty = colType(last);
  const ltour = lst && lst.tour && !lst.tour.done ? lst.tour : null;
  const pimg = (items, i, cls, sq) => { const it = items[i]; return it.img ? `<img class="${cls}${sq ? ' sq' : ''}" decoding="async" src="${esc(it.img)}" alt="${esc(it.t)}" loading="lazy" referrerpolicy="no-referrer" onerror="noPoster(this)">` : `<div class="noposter ${cls}${sq ? ' sq' : ''}">${esc(it.t)}</div>`; };
  const ringCard = col => {
    const sn = colSnapshot(col), ty = colType(col), cur = col.id === last.id;
    return `<button class="hc-ring${cur ? ' cur' : ''}" data-id="${esc(col.id)}"><span class="hc-art${ty.sq ? ' sq' : ''}">${sn.order.slice(0, 3).map(i => pimg(sn.items, i, 'p', ty.sq)).join('')}</span>
      <span class="hc-txt"><b>${esc(col.label)}</b><small>${typeName(col.type)} · ${fmt(sn.n)} ${ty.many} · ${fmt(sn.total)} duels</small></span></button>`;
  };
  const top = L.order.slice(0, 10);
  view.innerHTML = `<div class="hm">
    ${!SERVER ? `<div class="filehint">Ouvre Ring avec <b>Ring.bat</b> pour les vidéos et la sauvegarde automatique.</div>` : ''}
    <section class="hm-hero">
      <span class="hm-k">${typeName(last.type)}</span>
      <h1>${esc(last.label)}</h1>
      <p class="hm-meta">${fmt(L.n)} ${lty.many} · ${fmt(L.total)} duels${ltour ? ` · tournoi ${fmt(ltour.log.length)}/${fmt(ltour.ent.length - 1)}` : ''}</p>
      <div class="hm-acts"><button class="btn primary" id="h-duel">Continuer les duels</button><button class="btn" id="h-tour">${ltour ? 'Reprendre le tournoi' : 'Tournoi'}</button><button class="btn" id="h-game">Jouer</button></div>
    </section>
    ${top.length >= 3 ? `<section class="hm-sec"><div class="hm-head"><h2>Ton top 10</h2><button class="lnk" id="h-rank">Tout le classement</button></div>
      <div class="hm-top">${top.map((i, k) => `<button class="hm-t" data-i="${i}" title="${esc(L.items[i].t)}">${pimg(L.items, i, 'p', lty.sq)}<span><em>${k + 1}</em>${esc(L.items[i].t)}</span></button>`).join('')}</div></section>` : ''}
    <section class="hm-sec"><div class="hm-head"><h2>Tes rings</h2><button class="lnk" id="h-add">＋ Ajouter</button></div>
      <div class="hm-rings">${cols.map(ringCard).join('')}</div></section>
  </div>`;
  $('h-duel').onclick = () => switchCol(last.id, 'duel');
  $('h-tour').onclick = () => switchCol(last.id, 'tour');
  $('h-game').onclick = () => switchCol(last.id, 'game');
  $('h-add').onclick = () => openSync();
  if ($('h-rank')) $('h-rank').onclick = () => switchCol(last.id, 'rank');
  view.querySelectorAll('.hm-t').forEach(b => b.onclick = () => { switchCol(last.id, 'rank'); open = +b.dataset.i; renderRank(); const r = view.querySelector(`.row[data-i="${b.dataset.i}"]`); if (r) r.scrollIntoView({block:'center'}); });
  view.querySelectorAll('.hc-ring').forEach(b => b.onclick = () => switchCol(b.dataset.id, 'duel'));
}

/* ---------- Réglages et sauvegarde ---------- */
const enc = o => btoa(unescape(encodeURIComponent(JSON.stringify(o))));
const dec = s => JSON.parse(decodeURIComponent(escape(atob(s.trim()))));
function CATS_KEY(id){ return BUILTIN.find(b=>b.id===id).key; }
function openSettings(){
  openModal(`<div class="sheethead"><h2>Réglages</h2><button class="x" aria-label="Fermer">✕</button></div>
    <div class="setgrp"><div class="h3">Lecteur de musique</div>
      <div class="seg" id="seg-player"><button data-p="yt" aria-pressed="${playerPref==='yt'}">YouTube (sons en entier)</button><button data-p="sp" aria-pressed="${playerPref==='sp'}">Spotify</button></div>
      <p class="note">Spotify ne joue les sons en entier que si tu es connecté à Spotify (Premium) dans ce navigateur.</p></div>
    <div class="setgrp"><div class="h3">Apparence</div>
      <div class="fx" style="gap:16px;flex-wrap:wrap"><div><div class="note">Thème</div><div class="seg" id="seg-theme"><button data-v="dark" aria-pressed="${ls.get('ringcine-theme','dark')==='dark'}">🌙 Sombre</button><button data-v="light" aria-pressed="${ls.get('ringcine-theme','dark')==='light'}">☀️ Clair</button></div></div>
      <div><div class="note">Couleur</div><div class="seg" id="seg-accent">${[['gold','Doré'],['red','Rouge'],['blue','Bleu']].map(([v,l])=>`<button data-v="${v}" aria-pressed="${ls.get('ringcine-accent','gold')===v}"><i class="swatch ${v}"></i>${l}</button>`).join('')}</div></div>
      <div><div class="note">Sons et effets</div><div class="seg" id="seg-sfx"><button data-v="1" aria-pressed="${sfxOn()}">🔊 Activés</button><button data-v="0" aria-pressed="${!sfxOn()}">🔇 Coupés</button></div></div></div></div>
    <div class="setgrp"><div class="h3">Sauvegarde</div>
      <p class="note">${SERVER ? 'Tout est enregistré automatiquement dans <b>Ring-sauvegarde.json</b>, à côté de Ring.bat.' : 'Tes choix sont gardés dans ce navigateur.'} Pour changer d’appareil, copie ta sauvegarde et importe-la là-bas.</p>
      <label class="note" for="myname" style="display:grid;gap:6px">Ton prénom (affiché sur les classements que tu partages)<input class="input" id="myname" maxlength="30" value="${esc(ls.get('ringcine-name', ''))}" placeholder="Ex. : Zine"></label>
      <div class="row2"><button class="btn sm" id="exp">Copier ma sauvegarde</button><button class="btn sm" id="share">Partager « ${esc(C.label)} »</button></div>
      <textarea id="code" placeholder="Colle ici un code de sauvegarde, ou le code de collection d’un pote…"></textarea>
      <div class="row2"><button class="btn sm" id="imp">Importer le code collé</button></div>
      <div class="msg" id="msg"></div></div>
    <div class="setgrp"><div class="h3">Ring affiché : ${esc(C.label)}</div>
      <div class="row2"><button class="btn sm danger" id="reset">Remettre les duels à zéro</button>${C.builtin ? '' : '<button class="btn sm danger" id="del">Supprimer ce ring</button>'}</div>
      <div id="setconf"></div></div>
    ${SERVER ? '<div class="setgrp"><div class="h3">Ring.bat</div><div class="row2"><button class="btn sm" id="quit">Fermer Ring</button></div></div>' : ''}`, bindSettings);
}
function bindSettings(){
  const seg = (id, key, after) => $(id).querySelectorAll('button').forEach(b => b.onclick = () => { ls.set(key, key === 'ringcine-sfx' ? b.dataset.v === '1' : b.dataset.v); $(id).querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x === b)); if (after) after(); });
  seg('seg-theme', 'ringcine-theme', applyTheme); seg('seg-accent', 'ringcine-accent', applyTheme); seg('seg-sfx', 'ringcine-sfx', () => { if (sfxOn()) sfx('bell'); });
  const msg = t => { $('msg').textContent = t; };
  $('myname').onchange = e => ls.set('ringcine-name', e.target.value.trim());
  $('seg-player').querySelectorAll('button').forEach(b => b.onclick = () => { playerPref = b.dataset.p; ls.set('ringcine-player', playerPref); $('seg-player').querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x === b)); if (curView !== 'home') refreshPlayers(); });
  $('exp').onclick = async () => {
    save();
    const cust = customCols();
    const all = {v:4, films: ls.get(CATS_KEY('films'), null), music: ls.get(CATS_KEY('music'), null), xf: ls.get('ringcine-extra-films', []), xm: ls.get('ringcine-extra-music', []), rt: ls.get('ringcine-ratings', {}), yt: ls.get('ringcine-yt', {}),
      cols: cust.map(c => ({meta:c, rows: ls.get('ringcine-data-'+c.id, []), st: ls.get('ringcine-st-'+c.id, null)}))};
    const code = enc(all); $('code').value = code;
    msg(await copyText(code) ? 'Sauvegarde complète copiée.' : 'Code affiché ci-dessus : sélectionne-le et copie-le.');
  };
  $('share').onclick = async () => {
    save();
    const who = ($('myname').value || '').trim(); ls.set('ringcine-name', who);
    const code = enc({v:4, share:{meta:{id:C.id, type:C.type, label: who ? `${C.label} · classé par ${who}` : C.label, user:C.user, pl:C.pl}, rows: colRows(C), st: S}});
    $('code').value = code;
    msg(await copyText(code) ? `Code de « ${C.label} » copié : envoie-le à qui tu veux.` : 'Code affiché ci-dessus : sélectionne-le et copie-le.');
  };
  $('imp').onclick = () => {
    let o; try { o = dec($('code').value); } catch(e) { msg("Ce code n'est pas valide. Vérifie qu'il est complet."); return; }
    try {
      if (o.share) {
        const m = Object.assign({}, o.share.meta);
        if (colById(m.id)) { m.id = m.id + '~' + Date.now().toString(36); if (!/classé par/.test(m.label)) m.label = m.label + ' (importé)'; }
        delete m.key; delete m.builtin;
        if (!addCustomCol(m, o.share.rows || [])) throw 0;
        if (o.share.st) ls.set('ringcine-st-' + m.id, o.share.st);
        closeModal(); C = null; switchCol(m.id, 'rank'); toast(`« ${m.label} » importé : il est dans tes rings.`); return;
      }
      if (o.v === 3 || o.v === 4) {
        if (o.films) ls.set(CATS_KEY('films'), o.films); if (o.music) ls.set(CATS_KEY('music'), o.music);
        ls.set('ringcine-extra-films', o.xf||[]); ls.set('ringcine-extra-music', o.xm||[]); ls.set('ringcine-ratings', o.rt||{});
        if (o.yt) ls.set('ringcine-yt', Object.assign(ls.get('ringcine-yt', {}), o.yt));
        if (o.cols) { ls.set('ringcine-cols', o.cols.map(x=>x.meta)); o.cols.forEach(x => { ls.set('ringcine-data-'+x.meta.id, x.rows); if (x.st) ls.set('ringcine-st-'+x.meta.id, x.st); }); }
      } else if (o.elo) ls.set(CATS_KEY('films'), o);
      else throw 0;
      closeModal(); const cur = colById(C.id) ? C.id : 'films'; C = null; switchCol(cur, 'home'); toast('Sauvegarde importée.');
    } catch(e) { msg('Import impossible (code invalide ou stockage plein).'); }
  };
  $('reset').onclick = () => {
    $('setconf').innerHTML = `<div class="confirm" style="margin-top:8px">Effacer tous les duels et le tournoi de « ${esc(C.label)} » ? <button class="btn sm danger" id="yr">Oui, tout effacer</button><button class="btn sm" id="nr">Annuler</button></div>`;
    $('yr').onclick = () => { S = fresh(); save(); pair = null; closeModal(); go('duel'); toast('Ring remis à zéro.'); };
    $('nr').onclick = () => $('setconf').innerHTML = '';
  };
  if ($('del')) $('del').onclick = () => {
    $('setconf').innerHTML = `<div class="confirm" style="margin-top:8px">Supprimer « ${esc(C.label)} » et ses duels ? <button class="btn sm danger" id="yd">Oui, supprimer</button><button class="btn sm" id="nd">Annuler</button></div>`;
    $('yd').onclick = () => { closeModal(); deleteCol(C.id); };
    $('nd').onclick = () => $('setconf').innerHTML = '';
  };
  if ($('quit')) $('quit').onclick = async () => { await pushStore(); try { await fetch('/api/quit'); } catch(e){} document.body.innerHTML = '<div style="padding:80px 16px;text-align:center;font:18px var(--body);color:var(--text)">Ring est fermé. Double-clique sur <b>Ring.bat</b> pour le relancer.</div>'; };
}

/* ================= v7 : bureau, clavier, arbre, images, import ================= */

/* ---------- Lecteurs au clavier (A / 1 = gauche, E / 2 = droite) ---------- */
function togglePlayer(side){
  const p = view.querySelectorAll('.player')[side]; if (!p) return false;
  const f = p.querySelector('iframe');
  p.classList.remove('kflash'); void p.offsetWidth; p.classList.add('kflash');
  if (!f) { const b = p.querySelector('.findyt'); if (b) b.click(); return true; }
  const playing = !!playState.get(f.contentWindow);
  try {
    if (f.classList.contains('ytf')) f.contentWindow.postMessage(JSON.stringify({event:'command', func: playing ? 'pauseVideo' : 'playVideo', args:[]}), '*');
    else f.contentWindow.postMessage({command:'toggle'}, '*');
  } catch(e){}
  if (!playing) document.querySelectorAll('iframe.ytf, iframe.spf').forEach(o => { if (o !== f) { pauseFrame(o); playState.set(o.contentWindow, false); } });
  playState.set(f.contentWindow, !playing);
  return true;
}

/* ---------- Aide des raccourcis ---------- */
const KEYS = [
  ['Plus ou moins', [['↑','Plus haut'],['↓','Plus bas'],['Entrée','Rejouer']]],
  ['Garder / jeter', [['←','Jeter'],['→','Garder']]],
  ['Choisir', [['←','Rouge (gauche)'],['→','Bleu (droite)'],['↑','Égalité'],['↓','Passer'],['Retour','Annuler le dernier choix']]],
  ['Écouter', [['A ou 1','Lecture / pause du son de gauche'],['E ou 2','Lecture / pause du son de droite']]],
  ['Jeux', [['Espace','Écouter l’extrait'],['Tab','Indice suivant'],['Entrée','Valider / manche suivante'],['1 à 4','Réponse en mode 4 choix']]],
  ['Aller à', [['H','Accueil'],['D','Duels'],['T','Tournoi'],['C','Classement'],['L','Tier list'],['R','Plus ou moins'],['O','Ce soir'],['J','Jeux'],['X','Stats'],['Y','Trophées'],['G','Changer de ring']]],
  ['Outils', [['F','Filtres'],['/','Chercher'],['P','Créer l’image PNG'],['S','Ajouter / Ring Sync'],['?','Cette aide'],['Échap','Fermer une fenêtre']]],
];
function openKeys(){
  openModal(`<div class="sheethead"><h2>Raccourcis clavier</h2><button class="x" aria-label="Fermer">✕</button></div>
    <div class="keygrid">${KEYS.map(([h, ks]) => `<div><h3 class="h3">${h}</h3>${ks.map(([k, l]) => `<div class="krow">${k.split(' ou ').map(x => `<kbd>${x}</kbd>`).join(' <span class="note">ou</span> ')}<span>${l}</span></div>`).join('')}</div>`).join('')}</div>
    <p class="note">Tu peux aussi glisser-déposer un export Letterboxd (.zip ou .csv) n’importe où dans la fenêtre.</p>`);
}

/* ---------- Effet 3D des cartes + couleur d'ambiance ---------- */
const FINE = matchMedia('(hover:hover) and (pointer:fine)').matches && !matchMedia('(prefers-reduced-motion: reduce)').matches;
if (FINE) {
  let tiltEv = null, tiltRaf = 0;
  view.addEventListener('mousemove', e => { tiltEv = e; if (!tiltRaf) tiltRaf = requestAnimationFrame(() => { tiltRaf = 0; tilt(tiltEv); }); });
  function tilt(e){
    const c = e.target.closest && e.target.closest('.card'); if (!c || c.disabled || !c.isConnected) return;
    const r = c.querySelector('.art').getBoundingClientRect();
    const x = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)), y = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
    c.style.setProperty('--ry', ((x - .5) * 14).toFixed(2) + 'deg'); c.style.setProperty('--rx', ((.5 - y) * 12).toFixed(2) + 'deg');
    c.style.setProperty('--gx', (x * 100).toFixed(1) + '%'); c.style.setProperty('--gy', (y * 100).toFixed(1) + '%');
  }
  view.addEventListener('mouseout', e => { const c = e.target.closest('.card'); if (c && !c.contains(e.relatedTarget)) { c.style.removeProperty('--rx'); c.style.removeProperty('--ry'); } });
}
const proxied = u => SERVER && /^https:/.test(u || '') ? '/img?u=' + encodeURIComponent(u) : null;
function loadImg(src, ms = 9000){
  return new Promise(res => { if (!src) return res(null); const im = new Image(); const t = setTimeout(() => res(null), ms); im.onload = () => { clearTimeout(t); res(im); }; im.onerror = () => { clearTimeout(t); res(null); }; im.src = src; });
}
const ambCache = new Map();
async function dominant(url){
  if (ambCache.has(url)) return ambCache.get(url);
  const p = (async () => {
    const im = await loadImg(proxied(url), 6000); if (!im) return null;
    try {
      const cv = document.createElement('canvas'); cv.width = cv.height = 24; const g = cv.getContext('2d'); g.drawImage(im, 0, 0, 24, 24);
      const d = g.getImageData(0, 0, 24, 24).data; let r = 0, gg = 0, b = 0, w = 0;
      for (let i = 0; i < d.length; i += 4) { const mx = Math.max(d[i], d[i+1], d[i+2]), mn = Math.min(d[i], d[i+1], d[i+2]); const s = mx ? (mx - mn) / mx : 0; const k = .15 + s * s * (mx > 40 ? 1 : .2); r += d[i] * k; gg += d[i+1] * k; b += d[i+2] * k; w += k; }
      return [r / w, gg / w, b / w].map(v => Math.round(v));
    } catch(e){ return null; }
  })();
  ambCache.set(url, p); return p;
}
async function ambience(a, b){
  const st = view.querySelector('.stage'); if (!st || !SERVER) return;
  const [ca, cb] = await Promise.all([dominant(F[a] && F[a].img), dominant(F[b] && F[b].img)]);
  if (!st.isConnected) return;
  if (ca) st.style.setProperty('--ambL', `rgba(${ca.join(',')},.55)`);
  if (cb) st.style.setProperty('--ambR', `rgba(${cb.join(',')},.55)`);
}

/* ---------- Filtres thématiques ---------- */
let fxOpen = false;
const fxOf = () => (S.fx ||= {dir:'', y1:0, y2:0, r:0});
const fxActive = () => { const f = fxOf(); return !!(f.dir || f.y1 || f.y2 || f.r || (S.battle && S.battle.type && S.battle.a && S.battle.b)); };
function fxMatch(i){
  const f = S.fx; if (!f) return true; const it = F[i];
  if (f.dir && !((it.sub || '').split(/,\s*/).includes(f.dir))) return false;
  if (f.y1 && !(it.y >= f.y1)) return false;
  if (f.y2 && !(it.y && it.y <= f.y2)) return false;
  if (f.r && !(it.r >= f.r)) return false;
  return true;
}
function fxOptions(){
  const cnt = new Map();
  F.forEach(it => (it.sub || '').split(/,\s*/).forEach(d => { if (d) cnt.set(d, (cnt.get(d) || 0) + 1); }));
  return [...cnt].filter(x => x[1] >= 2).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}
function fxPanel(){
  const f = fxOf(), opts = fxOptions(), n = pool().length, films = C.type === 'films';
  const who = films ? 'Réalisateur' : C.type === 'music' ? 'Artistes' : 'Détail';
  return `<div class="fxpanel" id="fxpanel">
    ${opts.length ? `<label>${who}<select id="fxdir"><option value="">Tous</option>${opts.map(([d, k]) => `<option value="${esc(d)}" ${f.dir === d ? 'selected' : ''}>${esc(d)} (${k})</option>`).join('')}</select></label>` : ''}
    ${films ? `<label>De<input class="input" id="fxy1" type="number" min="1890" max="2100" placeholder="1900" value="${f.y1 || ''}"></label><label>À<input class="input" id="fxy2" type="number" min="1890" max="2100" placeholder="${new Date().getFullYear()}" value="${f.y2 || ''}"></label>
    <label>Note mini<select id="fxr"><option value="0">Toutes</option>${[4,6,7,8,9,10].map(r => `<option value="${r}" ${f.r === r ? 'selected' : ''}>${starStr(r)} et +</option>`).join('')}</select></label>` : ''}
    ${C.type !== 'items' ? battlePanel() : ''}
    <span class="fxn">${(() => { const bs = battleSides(); return bs ? `<b>${bs[0].length}</b> vs <b>${bs[1].length}</b> ${TY.many} en battle` : `<b>${fmt(n)}</b> ${TY.many} en jeu`; })()}</span>
    <button class="lnk" id="fxreset" ${fxActive() ? '' : 'disabled'}>Réinitialiser</button>
  </div>`;
}
function bindFx(){
  const upd = () => { save(); pair = null; nextPair = null; renderDuel(); };
  const f = fxOf();
  if ($('fxdir')) $('fxdir').onchange = e => { f.dir = e.target.value; upd(); };
  if ($('fxy1')) $('fxy1').onchange = e => { f.y1 = +e.target.value || 0; upd(); };
  if ($('fxy2')) $('fxy2').onchange = e => { f.y2 = +e.target.value || 0; upd(); };
  if ($('fxr')) $('fxr').onchange = e => { f.r = +e.target.value || 0; upd(); };
  if ($('fxreset')) $('fxreset').onclick = () => { S.fx = {dir:'', y1:0, y2:0, r:0}; S.battle = null; upd(); };
  bindBattle();
}

/* ---------- Arbre du tournoi ---------- */
let bStart = null;
function bracketRounds(t){
  const R = Math.round(Math.log2(t.first)), rounds = [];
  const curR = t.done ? R + 1 : (t.prelim ? 0 : t.round);
  for (let r = 1; r <= R; r++) {
    const n = t.first >> r;
    let ms;
    if (r < curR || (r === curR)) {
      ms = t.log.filter(m => !m.prelim && m.round === r).map(m => ({a:m.a, b:m.b, win:m.win}));
      if (r === curR) for (let k = 0; k < t.queue.length; k += 2) ms.push({a:t.queue[k], b:t.queue[k+1], win:null, now: k === 0});
    } else if (r === 1) {
      const list = t.alive.concat(t.next); while (list.length < t.first) list.push(null);
      ms = []; for (let k = 0; k < n; k++) ms.push({a:list[2*k], b:list[2*k+1], win:null});
    } else {
      const prev = rounds[r - 2]; ms = [];
      for (let k = 0; k < n; k++) { const p1 = prev[2*k], p2 = prev[2*k+1]; ms.push({a: p1 && p1.win != null ? p1.win : null, b: p2 && p2.win != null ? p2.win : null, win:null}); }
    }
    rounds.push(ms);
  }
  return rounds;
}
const roundShort = n => ({1:'Finale', 2:'Demies', 4:'Quarts', 8:'8es', 16:'16es', 32:'32es', 64:'64es'})[n] || `${n * 2} restants`;
function bracketHtml(t){
  const rounds = bracketRounds(t), R = rounds.length;
  if (!R) return '<div class="empty">Pas encore d’arbre.</div>';
  const starts = rounds.map((ms, k) => [k, ms.length]).filter(([k, n]) => n <= 256);
  if (bStart === null || bStart >= R || rounds[bStart].length > 256) bStart = Math.max(0, R - 5);
  const cols = rounds.slice(bStart), n0 = cols[0].length, SLOT = 70, H = n0 * SLOT, G = 38;
  const slot = (i, m) => {
    if (i == null) return `<div class="bs tbd"><span class="bth"></span><span class="bn">à venir</span></div>`;
    const st = m.win == null ? '' : m.win === i ? ' w' : ' l';
    return `<div class="bs${st}" title="${T(i)}">${img(i, 'bth')}<span class="bn">${T(i)}</span></div>`;
  };
  const links = ci => { const n = cols[ci].length; let d = ''; for (let k = 0; k < n; k++) { const y1 = (2*k + .5) * H / (2*n), y2 = (2*k + 1.5) * H / (2*n), ym = (k + .5) * H / n; d += `M0 ${y1}H${G/2}V${y2}M0 ${y2}H${G/2}M${G/2} ${ym}H${G}`; } return `<svg class="blink" width="${G}" height="${H}" viewBox="0 0 ${G} ${H}"><path d="${d}"/></svg>`; };
  let html = '';
  cols.forEach((ms, ci) => {
    if (ci) html += links(ci);
    html += `<div class="bcol"><div class="bh">${roundShort(ms.length)}</div><div class="bm-list" style="height:${H}px">${ms.map(m => `<div class="bmatch${m.now ? ' now' : ''}">${slot(m.a, m)}${slot(m.b, m)}</div>`).join('')}</div></div>`;
  });
  const champ = t.done ? t.champ : null;
  html += `<svg class="blink" width="${G}" height="${H}" viewBox="0 0 ${G} ${H}"><path d="M0 ${H/2}H${G}"/></svg><div class="bcol"><div class="bh">Champion</div><div class="bm-list" style="height:${H}px"><div class="bmatch champ">${champ != null ? `${img(champ, 'bth')}<span class="bn">🏆 ${T(champ)}</span>` : '<span class="bn">🏆 ?</span>'}</div></div></div>`;
  return `<div class="btools"><label class="note">Commencer l’arbre aux <select id="bstart">${starts.map(([k, n]) => `<option value="${k}" ${k === bStart ? 'selected' : ''}>${roundShort(n)} (${fmt(n)} matchs)</option>`).join('')}</select></label>${t.hasPre ? '<span class="note">Les barrages ne sont pas dans l’arbre.</span>' : ''}<span class="note" style="margin-left:auto">Glisse avec la souris pour te déplacer</span></div>
    <div class="bracket" id="bracket"><div class="binner">${html}</div></div>`;
}
let bDrag = null;
window.addEventListener('mousemove', e => { if (!bDrag) return; bDrag.el.scrollLeft = bDrag.l - (e.clientX - bDrag.x); bDrag.el.scrollTop = bDrag.t - (e.clientY - bDrag.y); });
window.addEventListener('mouseup', () => { if (bDrag) { bDrag.el.classList.remove('drag'); bDrag = null; } });
function bindBracket(){
  const b = $('bracket'); if (!b) return;
  if ($('bstart')) $('bstart').onchange = e => { bStart = +e.target.value; rerenderPanel(); };
  const now = b.querySelector('.bmatch.now'); if (now) { const r = now.getBoundingClientRect(), br = b.getBoundingClientRect(); b.scrollLeft += r.left - br.left - br.width / 2 + r.width / 2; b.scrollTop += r.top - br.top - br.height / 2; }
  b.onmousedown = e => { if (e.button) return; bDrag = {el:b, x:e.clientX, y:e.clientY, l:b.scrollLeft, t:b.scrollTop}; b.classList.add('drag'); e.preventDefault(); };
}

/* ---------- Images PNG à partager ---------- */
function wrapText(g, text, x, y, maxW, lh, maxLines){
  const words = String(text).split(/\s+/); let line = '', lines = [];
  for (const w of words) { const t = line ? line + ' ' + w : w; if (g.measureText(t).width > maxW && line) { lines.push(line); line = w; } else line = t; }
  if (line) lines.push(line);
  if (lines.length > maxLines) { lines = lines.slice(0, maxLines); let l = lines[maxLines - 1]; while (g.measureText(l + '…').width > maxW && l.length) l = l.slice(0, -1); lines[maxLines - 1] = l + '…'; }
  lines.forEach((l, k) => g.fillText(l, x, y + k * lh));
  return lines.length;
}
function rrect(g, x, y, w, h, r){ g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r); g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath(); }
function drawCover(g, im, x, y, w, h, label){
  g.save(); rrect(g, x, y, w, h, 10); g.clip();
  if (im) { const s = Math.max(w / im.width, h / im.height), iw = im.width * s, ih = im.height * s; g.drawImage(im, x + (w - iw) / 2, y + (h - ih) / 2, iw, ih); }
  else { g.fillStyle = '#17151C'; g.fillRect(x, y, w, h); g.fillStyle = '#A69E8F'; g.font = `600 ${Math.max(12, w / 9)}px Inter, sans-serif`; g.textAlign = 'center'; wrapText(g, label || '', x + w / 2, y + h / 2 - 10, w - 16, w / 7, 3); g.textAlign = 'left'; }
  g.restore();
}
async function pngFonts(){ try { await Promise.all(['900 60px Archivo', '800 60px Archivo', '600 20px Inter', '500 20px Inter'].map(f => document.fonts.load(f))); } catch(e){} }
function pngFrame(g, W, H, kicker, title){
  const bg = g.createLinearGradient(0, 0, W, H); bg.addColorStop(0, '#100E13'); bg.addColorStop(1, '#060608'); g.fillStyle = bg; g.fillRect(0, 0, W, H);
  const rg = g.createRadialGradient(0, 0, 0, 0, 0, W * .8); rg.addColorStop(0, 'rgba(216,180,106,.16)'); rg.addColorStop(1, 'rgba(216,180,106,0)'); g.fillStyle = rg; g.fillRect(0, 0, W, H);
  const bgr = g.createRadialGradient(W, H, 0, W, H, W * .8); bgr.addColorStop(0, 'rgba(200,64,79,.10)'); bgr.addColorStop(1, 'rgba(200,64,79,0)'); g.fillStyle = bgr; g.fillRect(0, 0, W, H);
  const gg = g.createLinearGradient(70, 60, 260, 130); gg.addColorStop(0, '#F5E3AE'); gg.addColorStop(.5, '#D8B46A'); gg.addColorStop(1, '#A87F3C'); g.font = 'italic 600 78px Archivo, Inter, sans-serif'; g.fillStyle = gg; g.fillText('Ring', 66, 118); const w = g.measureText('Ring  ').width; g.font = '600 16px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText(TY.brand.toUpperCase().split('').join(' '), 66 + w, 112);
  g.font = '600 17px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText(kicker.toUpperCase().split('').join('\u200A'), 72, 172);
  g.font = '600 86px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; wrapText(g, title, 68, 258, W - 140, 86, 2);
  const who = ls.get('ringcine-name', ''), d = new Date().toLocaleDateString('fr-FR', {day:'numeric', month:'long', year:'numeric'});
  g.font = '600 18px Inter, sans-serif'; g.fillStyle = '#6E6759'; g.fillText(`${who ? 'classé par ' + who + ' · ' : ''}${fmt(S.total)} duels · ${d}`, 72, H - 50);
  g.textAlign = 'right'; g.fillText('RING', W - 70, H - 50); g.textAlign = 'left';
}
async function savePng(cv, name){
  const blob = await new Promise(r => { try { cv.toBlob(r, 'image/png'); } catch(e){ r(null); } });
  if (!blob) { toast('Impossible de créer l’image.'); return; }
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  let copied = false; try { await navigator.clipboard.write([new ClipboardItem({'image/png': blob})]); copied = true; } catch(e){}
  toast(copied ? 'Image téléchargée et copiée : colle-la direct dans Discord (Ctrl+V).' : 'Image téléchargée.');
}
const fileSafe = s => String(s).normalize('NFKD').replace(/[^\w-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').toLowerCase().slice(0, 40) || 'ring';
async function pngTop10(){
  toast('Création de l’image…');
  await pngFonts();
  const {order} = ranking(), top = order.slice(0, 10), sq = TY.sq;
  const W = 1600, rowH = sq ? 150 : 190, H = 330 + top.length * (rowH + 20) + 90;
  const cv = document.createElement('canvas'); cv.width = W; cv.height = H; const g = cv.getContext('2d');
  pngFrame(g, W, H, `Top ${top.length} · ${typeName(C.type)}`, C.label);
  const ims = await Promise.all(top.map(i => loadImg(proxied(hiRes(F[i].img, true)))));
  top.forEach((i, k) => {
    const y = 330 + k * (rowH + 20), it = F[i], cw = sq ? rowH : Math.round(rowH * 2 / 3);
    g.fillStyle = k < 3 ? 'rgba(216,180,106,.08)' : 'rgba(216,180,106,.035)'; rrect(g, 60, y, W - 120, rowH, 16); g.fill();
    g.font = 'italic 600 96px Archivo, Inter, sans-serif'; g.fillStyle = k === 0 ? '#D8B46A' : k < 3 ? '#F3DFA8' : '#6E6759'; g.textAlign = 'center'; g.fillText(String(k + 1), 150, y + rowH / 2 + 30); g.textAlign = 'left';
    drawCover(g, ims[k], 230, y + 10, cw, rowH - 20, it.t);
    const tx = 230 + cw + 34, tw = W - tx - 260;
    g.font = '600 50px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; const nl = wrapText(g, it.t, tx, y + rowH / 2 - (sq ? 6 : 12), tw, 46, 2);
    g.font = '500 26px Inter, sans-serif'; g.fillStyle = '#A69E8F';
    const meta = C.type === 'films' ? [it.y || '', it.sub].filter(Boolean).join(' · ') : (it.sub || '');
    wrapText(g, meta, tx, y + rowH / 2 - (sq ? 6 : 12) + nl * 46, tw, 30, 1);
    g.font = '600 26px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.textAlign = 'right'; g.fillText(`${Math.round(S.elo[i])} pts`, W - 100, y + rowH / 2 + 4);
    g.font = '600 18px Inter, sans-serif'; g.fillStyle = '#6E6759'; g.fillText(`${S.w[i]}V ${S.l[i]}D`, W - 100, y + rowH / 2 + 36); g.textAlign = 'left';
  });
  await savePng(cv, `ring-top10-${fileSafe(C.label)}.png`);
}
async function pngChamp(){
  const t = S.tour; if (!t || !t.done) { toast('Termine un tournoi pour créer l’image du vainqueur.'); return; }
  toast('Création de l’image…'); await pngFonts();
  const c = t.champ, path = t.log.filter(m => m.win === c).map(m => ({lab: entryLabel(t, m), op: m.a === c ? m.b : m.a})), sq = TY.sq;
  const W = 1600, rowH = 96, H = Math.max(1100, 360 + path.length * (rowH + 14) + 120);
  const cv = document.createElement('canvas'); cv.width = W; cv.height = H; const g = cv.getContext('2d');
  pngFrame(g, W, H, `Champion · ${t.label}`, F[c].t);
  const [cim, ...oims] = await Promise.all([loadImg(proxied(hiRes(F[c].img, true)))].concat(path.map(p => loadImg(proxied(F[p.op].img)))));
  const cw = 560, ch = sq ? 560 : 840, cx = 70, cy = 330;
  g.save(); g.shadowColor = 'rgba(216,180,106,.5)'; g.shadowBlur = 60; g.fillStyle = '#D8B46A'; rrect(g, cx - 6, cy - 6, cw + 12, ch + 12, 16); g.fill(); g.restore();
  drawCover(g, cim, cx, cy, cw, ch, F[c].t);
  g.font = '700 30px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText('🏆  ' + fmt(t.ent.length) + ' ' + TY.many + ' au départ, un seul survivant', cx, cy + ch + 56);
  const x0 = cx + cw + 70, tw = W - x0 - 70;
  g.font = '600 20px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText('SON PARCOURS', x0, cy + 10);
  path.forEach((p, k) => {
    const y = cy + 36 + k * (rowH + 14), fin = k === path.length - 1;
    g.fillStyle = fin ? 'rgba(216,180,106,.1)' : 'rgba(255,255,255,.04)'; rrect(g, x0, y, tw, rowH, 12); g.fill();
    drawCover(g, oims[k], x0 + 10, y + 8, sq ? rowH - 16 : Math.round((rowH - 16) * 2 / 3), rowH - 16, F[p.op].t);
    const tx = x0 + 10 + (sq ? rowH - 16 : Math.round((rowH - 16) * 2 / 3)) + 20;
    g.font = '600 17px Inter, sans-serif'; g.fillStyle = fin ? '#D8B46A' : '#A69E8F'; g.fillText(p.lab.toUpperCase(), tx, y + 34);
    g.font = '700 28px Inter, sans-serif'; g.fillStyle = '#F3EDE2'; wrapText(g, 'bat ' + F[p.op].t, tx, y + 70, tw - (tx - x0) - 20, 30, 1);
  });
  await savePng(cv, `ring-champion-${fileSafe(F[c].t)}.png`);
}
function makePng(){ if (curView === 'tour' && S.tour && S.tour.done) pngChamp(); else if (curView === 'tier') pngTier(); else pngTop10(); }

/* ---------- Glisser-déposer : export Letterboxd (.zip / .csv) ou n'importe quel CSV ---------- */
function parseCsv(text){
  const head0 = String(text).slice(0, 400), sep = head0.includes('\t') && !head0.includes(',') ? '\t' : !head0.includes(',') && head0.includes(';') ? ';' : ',';
  const rows = []; let row = [], f = '', q = false;
  text = text.replace(/^﻿/, '');
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i+1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === sep) { row.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i+1] === '\n') i++; row.push(f); f = ''; if (row.length > 1 || row[0]) rows.push(row); row = []; }
    else f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  if (!rows.length) return [];
  const head = rows[0].map(h => h.trim());
  return rows.slice(1).map(r => Object.fromEntries(head.map((h, k) => [h, (r[k] || '').trim()])));
}
async function unzip(buf){
  const dv = new DataView(buf), u8 = new Uint8Array(buf), out = {};
  let e = -1; for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 70000); i--) if (dv.getUint32(i, true) === 0x06054b50) { e = i; break; }
  if (e < 0) throw new Error('zip');
  let p = dv.getUint32(e + 16, true); const n = dv.getUint16(e + 10, true), td = new TextDecoder();
  for (let k = 0; k < n; k++) {
    const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), nl = dv.getUint16(p + 28, true), xl = dv.getUint16(p + 30, true), cl = dv.getUint16(p + 32, true), off = dv.getUint32(p + 42, true);
    const name = td.decode(u8.subarray(p + 46, p + 46 + nl)); p += 46 + nl + xl + cl;
    if (!/\.csv$/i.test(name)) continue;
    const ds = off + 30 + dv.getUint16(off + 26, true) + dv.getUint16(off + 28, true), data = u8.slice(ds, ds + csize);
    if (method === 0) out[name] = td.decode(data);
    else if (method === 8) out[name] = await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text();
  }
  return out;
}
const col = (r, re) => { const k = Object.keys(r).find(h => re.test(h)); return k ? r[k] : ''; };
async function importFile(file){
  try {
    let csvs = {};
    if (/\.zip$/i.test(file.name)) csvs = await unzip(await file.arrayBuffer());
    else if (/\.(csv|txt|tsv)$/i.test(file.name)) csvs[file.name] = await file.text();
    else { toast('Dépose un fichier .csv ou le .zip exporté par Letterboxd.'); return; }
    const pick = re => { const k = Object.keys(csvs).find(n => re.test(n)); return k ? parseCsv(csvs[k]) : null; };
    const watched = pick(/(^|\/)watched\.csv$/i), ratings = pick(/(^|\/)ratings\.csv$/i);
    let lb = null;
    if (watched || ratings) lb = {watched: watched || [], ratings: ratings || []};
    else {
      const any = Object.values(csvs).map(parseCsv).find(r => r.length);
      if (!any) { toast('Fichier vide ou illisible.'); return; }
      if ('Letterboxd URI' in any[0] && 'Name' in any[0]) lb = {watched: any, ratings: any.filter(r => r.Rating)};
      else return importGenericCsv(any, file.name);
    }
    openLbImport(lb, file.name);
  } catch(e) { toast('Impossible de lire ce fichier.'); }
}
function openLbImport(lb, fname){
  const films = new Map();
  lb.watched.concat(lb.ratings).forEach(r => { if (!r.Name) return; const y = +r.Year || 0, k = keyHash(`${r.Name} (${y})`); const f = films.get(k) || {t:r.Name, y, r:0}; if (r.Rating) f.r = Math.round(parseFloat(r.Rating.replace(',', '.')) * 2) || f.r; films.set(k, f); });
  const list = [...films.entries()];
  if (!list.length) { toast('Aucun film trouvé dans ce fichier.'); return; }
  const targets = allCols().filter(c => c.type === 'films');
  let tid = C && C.type === 'films' ? C.id : targets[0].id;
  const stats = id => { if (id === '_new') return {add: list.length, upd: 0}; const have = new Map(colRows(colById(id)).map(r => [keyHash(`${r[0]} (${r[1]})`), r])); let add = 0, upd = 0; list.forEach(([k, f]) => { const h = have.get(k); if (!h) add++; else if (f.r && h[3] !== f.r) upd++; }); return {add, upd}; };
  const draw = () => {
    const s = stats(tid);
    openModal(`<div class="sheethead"><h2>Import Letterboxd</h2><button class="x" aria-label="Fermer">✕</button></div>
      <p class="note" style="margin:0"><b style="color:var(--text)">${fmt(list.length)}</b> films dans <b style="color:var(--text)">${esc(fname)}</b>.</p>
      <label class="note" style="display:grid;gap:6px">Mettre à jour<select id="lbt">${targets.map(c => `<option value="${esc(c.id)}" ${c.id === tid ? 'selected' : ''}>${esc(c.label)}</option>`).join('')}<option value="_new" ${tid === '_new' ? 'selected' : ''}>＋ Nouveau ring</option></select></label>
      ${tid === '_new' ? `<label class="note" style="display:grid;gap:6px">Nom<input class="input" id="lbn" value="Films (import)"></label>` : ''}
      <div class="result">${s.add ? `<b>${fmt(s.add)}</b> nouveau${s.add > 1 ? 'x' : ''} film${s.add > 1 ? 's' : ''}` : 'Aucun nouveau film'} · <b>${fmt(s.upd)}</b> note${s.upd > 1 ? 's' : ''} changée${s.upd > 1 ? 's' : ''}</div>
      ${s.add && tid !== '_new' ? '<p class="note">Les nouveaux films arrivent sans affiche (l’export Letterboxd n’en contient pas). Ring Sync sur ton profil les complétera.</p>' : ''}
      <div class="fx" style="gap:8px;justify-content:flex-end"><button class="btn sm" id="lbc">Annuler</button><button class="btn primary sm" id="lbok">Importer</button></div>`, () => {
      $('lbt').onchange = e => { tid = e.target.value; draw(); };
      $('lbc').onclick = closeModal;
      $('lbok').onclick = () => {
        const known = allFilmMap();
        const rows = list.map(([k, f]) => { const b = known.get(k); return b ? [b[0], b[1], b[2], f.r || b[3], b[4]] : [f.t, f.y, '', f.r, '']; });
        let id = tid, msg;
        if (tid === '_new') { const label = ($('lbn').value || '').trim() || 'Films (import)'; id = 'csv:' + keyHash(label + Date.now()); if (!addCustomCol({id, type:'films', label, host:'Export Letterboxd'}, rows)) return toast('Stockage plein.'); msg = `Nouveau ring « ${label} » : ${fmt(rows.length)} films.`; }
        else {
          const target = colById(tid); let added = 0, upd = 0;
          if (target.id === 'films') {
            const have = new Map(colRows(target).map(r => [keyHash(`${r[0]} (${r[1]})`), r])), ov = ls.get('ringcine-ratings', {}), extra = ls.get('ringcine-extra-films', []);
            rows.forEach(r => { const k = keyHash(`${r[0]} (${r[1]})`), h = have.get(k); if (!h) { extra.push(r); have.set(k, r); added++; } else if (r[3] && h[3] !== r[3]) { ov[k] = r[3]; upd++; } });
            ls.set('ringcine-ratings', ov); ls.set('ringcine-extra-films', extra);
          } else {
            const cur = colRows(target), have = new Map(cur.map((r, i) => [keyHash(`${r[0]} (${r[1]})`), i]));
            rows.forEach(r => { const k = keyHash(`${r[0]} (${r[1]})`), i = have.get(k); if (i === undefined) { cur.push(r); have.set(k, cur.length - 1); added++; } else if (r[3] && cur[i][3] !== r[3]) { cur[i] = [cur[i][0], cur[i][1], cur[i][2], r[3], cur[i][4]]; upd++; } });
            ls.set('ringcine-data-' + target.id, cur);
          }
          markSynced(target.id); msg = `« ${target.label} » : ${added} film${added > 1 ? 's' : ''} ajouté${added > 1 ? 's' : ''}, ${upd} note${upd > 1 ? 's' : ''} mise${upd > 1 ? 's' : ''} à jour.`;
        }
        closeModal(); toast(msg); if (C && C.id === id) C = null; switchCol(id, curView === 'home' ? 'rank' : curView);
      };
    });
  };
  draw();
}
function importGenericCsv(rows, fname){
  const r0 = rows[0];
  const tk = Object.keys(r0).find(h => /^(track name|name|title|titre|nom|film|song|chanson|morceau|jeu|game)$/i.test(h)) || Object.keys(r0).find(h => /name|title|titre|nom/i.test(h)) || Object.keys(r0)[0];
  const music = Object.keys(r0).some(h => /artist|artiste/i.test(h));
  const films = Object.keys(r0).some(h => /^(year|année|annee|director|réalisateur)$/i.test(h));
  const items = rows.map(r => {
    const t = r[tk]; const sub = col(r, /artist|artiste|director|réalisateur|realisateur|auteur|author/i) || col(r, /^(year|année|annee)$/i);
    const uri = col(r, /track uri|spotify/i), sp = (uri.match(/track[:/]([A-Za-z0-9]{22})/) || [])[1];
    return [t, sub.split(/;\s*/).join(', '), col(r, /image|poster|affiche|cover|pochette|thumbnail/i), sp ? 'https://open.spotify.com/track/' + sp : col(r, /^(url|link|lien|uri)$/i), '', +col(r, /^(year|année|annee)$/i) || 0];
  }).filter(it => it[0]);
  openGenPreview({k:'gen', v:5, src:'fichier:' + fname, host:fname, name: fname.replace(/\.[^.]+$/, ''), kind: music ? 'music' : films ? 'films' : 'items', items});
}
let dragN = 0;
const hasFiles = e => e.dataTransfer && [...(e.dataTransfer.types || [])].includes('Files');
window.addEventListener('dragenter', e => { if (!hasFiles(e)) return; e.preventDefault(); dragN++; document.body.classList.add('dropping'); });
window.addEventListener('dragover', e => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('dragleave', e => { if (!hasFiles(e)) return; if (--dragN <= 0) { dragN = 0; document.body.classList.remove('dropping'); } });
window.addEventListener('drop', e => { if (!hasFiles(e)) return; e.preventDefault(); dragN = 0; document.body.classList.remove('dropping'); const f = e.dataTransfer.files[0]; if (f) importFile(f); });

/* ================= v8 : onglet Jeux ================= */
const GAMES = {
  spot:    {name:'1 seconde', icon:'⏱', types:['films','music'], kind:'clip', get visible(){ return !C || C.type !== 'music'; }, cont:true, steps:[1,3,6,10], unit:'s', server:true, desc:() => C.type === 'music' ? 'Juste le son, sans la vidéo : 1 s, puis 3 s, 6 s et 10 s. Chaque erreur ou « Plus long » dévoile la suite.' : 'Une vraie scène du film (pas la bande-annonce) : 1 s, puis 3 s, 6 s et 10 s. Chaque erreur ou « Plus long » dévoile la suite.'},
  blind:   {name:'Blind test', icon:'🎧', types:['music'], kind:'clip', visible:true, steps:[1,5,10,25,30], unit:'s', desc:'Le clip YouTube se dévoile petit à petit : 1 s, 5 s, 10 s, 25 s puis 30 s. Trouve le titre le plus vite possible.'},
  cover:   {name:'Pochette zoomée', icon:'🔍', types:['music','items'], kind:'crop', steps:[9,5.5,3.4,2,1], desc:'Un gros zoom sur la pochette, qui se dézoome à chaque erreur.'},
  poster:  {name:'Affiche zoomée', icon:'🔍', types:['films','items'], kind:'crop', steps:[9,5.5,3.4,2,1], desc:'Un morceau de l’affiche en gros plan. Chaque erreur dézoome un peu.'},
  plot:    {name:'Synopsis caché', icon:'📜', types:['films'], kind:'plot', steps:[0,1,2,3,4], desc:'Le résumé du film, avec les noms cachés, révélé phrase par phrase. Puis l’année, le réalisateur et l’affiche.'},
  sound:   {name:'Son du film', icon:'🔊', types:['films'], kind:'clip', visible:false, steps:[3,6,12,25], unit:'s', server:true, desc:'Juste le son de la bande-annonce en VO (anglais), sans aucune image ni texte.'},
};
const G = {id:null, pool:'all', src:'mine', diff:'medium', mode:'type', round:0, score:0, streak:0, cur:null, used:new Set(), busy:false, tok:0};
const gStats = () => ls.get('ringcine-games', {});
const gKey = id => C.id + (EXT.on ? ':ext' : '') + ':' + id;
const norm = s => String(s || '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
const rnd = (a, b) => a + Math.random() * (b - a);
const gLabel = i => F[i].t + (C.type === 'films' && F[i].y ? ` (${F[i].y})` : C.type === 'music' && F[i].first ? ` · ${F[i].first}` : '');

/* ---------- Lecteur YouTube piloté (extraits de n secondes) ---------- */
let gWait = null, gTimer = null, gPlayT0 = 0;
const gFrame = () => document.getElementById('gframe');
const ytCmd = (f, func, args = []) => { try { f.contentWindow.postMessage(JSON.stringify({event:'command', func, args}), '*'); } catch(e){} };
function clipHtml(c, g){
  if (c.audio) return `<div class="gclip aud"><audio id="gaudio" src="${esc(c.audio)}" preload="auto"></audio><div class="gmask"><span id="gmaskt">🎧</span></div><div class="gprog"><i id="gprog"></i></div></div>`;
  const url = `https://www.youtube.com/embed/${c.yt}?enablejsapi=1&controls=0&disablekb=1&rel=0&playsinline=1&iv_load_policy=3&fs=0&modestbranding=1${G.id === 'blind' || G.id === 'fsong' || G.id === 'sceneclip' ? '' : '&cc_load_policy=1&cc_lang_pref=fr&hl=fr'}&start=${Math.floor(c.start)}${ONLINE ? '&origin=' + encodeURIComponent(location.origin) : ''}`;
  return `<div class="gclip${g.visible ? ' vis' : ''}${g.captions ? ' caps' : ''}"><iframe id="gframe" src="${url}" allow="autoplay; encrypted-media" onload="ytListen(this);setTimeout(()=>this.dataset.ready=1,400)" title="Extrait"></iframe><div class="gmask"><span id="gmaskt">${g.visible ? '▶ Appuie sur Voir' : '🎧'}</span></div>${g.captions ? '<div class="gsubs" id="gsubs"></div>' : ''}<div class="gprog"><i id="gprog"></i></div></div>${g.captions ? `<div class="gsubnote">${c.subs ? `Sous-titres ${c.subsTr ? 'traduits automatiquement en français' : 'en français'}` : 'Pas de sous-titres trouvés pour cette bande-annonce : juste le son.'}</div>` : ''}`;
}
function gPlay(sec, full, tries = 0, from = 0){
  const au = $('gaudio');
  if (au && G.cur && G.cur.audio) {
    clearTimeout(gTimer); gWait = {sec, full, from, id: Date.now()}; const w = gWait;
    try { au.currentTime = full ? 0 : G.cur.start + from; } catch(e){}
    au.volume = gVol(); au.play().then(() => { if (gWait === w) gStartTimer(); }).catch(() => { const mt = $('gmaskt'); if (mt) mt.textContent = '🔇 Clique sur Écouter pour lancer le son'; });
    return;
  }
  const f = gFrame(); if (!f) return;
  if (!f.dataset.ready) { if (tries < 50) setTimeout(() => gPlay(sec, full, tries + 1, from), 200); return; }
  clearTimeout(gTimer); gWait = {sec, full, from, id: Date.now()};
  const c = G.cur; ytCmd(f, 'unMute'); ytCmd(f, 'setVolume', [Math.round(gVol() * 100)]); ytCmd(f, 'seekTo', [c.start + from, true]); ytCmd(f, 'playVideo');
  const w = gWait; setTimeout(() => { if (gWait === w) gStartTimer(); }, 3500);
  const mt = $('gmaskt'); if (mt) mt.textContent = 'Chargement…';
}
let gSubT = null;
function gSubsRun(on){
  clearInterval(gSubT); const box = $('gsubs'); if (!box) return;
  if (!on) { setTimeout(() => { if (!gSubT && $('gsubs')) $('gsubs').textContent = ''; }, 700); gSubT = null; return; }
  const c = G.cur; if (!c || !c.subs) return;
  const t0 = performance.now(), p0 = c.start;
  gSubT = setInterval(() => { const cur = (p0 + (performance.now() - t0) / 1000) * 1000; const q = c.subs.find(x => x.s <= cur && cur < x.e); const el = $('gsubs'); if (el) el.textContent = q ? q.text : ''; }, 80);
}
function gStartTimer(){
  const w = gWait; if (!w) return; gWait = null;
  const box = document.querySelector('.gclip'); if (box) box.classList.add('playing');
  const mt = $('gmaskt'); if (mt) mt.textContent = '🎧';
  const from = w.from || 0, dur = Math.max(.2, w.sec - from);
  const pr = $('gprog'); if (pr && !w.full) { pr.style.transition = 'none'; pr.style.width = (from / w.sec * 100) + '%'; void pr.offsetWidth; pr.style.transition = `width ${dur}s linear`; pr.style.width = '100%'; }
  gSubsRun(true);
  if (w.full) return;
  gTimer = setTimeout(() => { const f = gFrame(); if (f) ytCmd(f, 'pauseVideo'); const au = $('gaudio'); if (au) au.pause(); gSubsRun(false); if (box) box.classList.remove('playing'); const t = $('gmaskt'); if (t) t.textContent = G.cur && G.cur.done ? '' : GAMES[G.id] && GAMES[G.id].visible ? '▶ Revoir' : '▶ Réécouter'; }, dur * 1000);
}
window.addEventListener('message', e => {
  const f = gFrame(); if (!f || e.source !== f.contentWindow) return;
  let d = e.data; if (typeof d === 'string') { try { d = JSON.parse(d); } catch(err) { return; } }
  if (!d) return;
  const st = d.event === 'onStateChange' ? d.info : d.event === 'infoDelivery' && d.info ? d.info.playerState : undefined;
  if (st === 1 && gWait) gStartTimer();
  if (d.event === 'onError' || (d.event === 'infoDelivery' && d.info && d.info.error)) { const t = $('gmaskt'); if (t) t.textContent = 'Vidéo bloquée par YouTube : on passe à une autre…'; if (G.cur && !G.cur.done && !G.busy) { G.busy = true; G.round--; const tk = G.tok; setTimeout(() => { if (G.id && tk === G.tok) gNewRound(); }, 1300); } }
});

/* ---------- Extraits Spotify (30 s, fichier audio direct) pour les jeux musique ---------- */
const PVC = new Map(), PV_RX = /^https:\/\/p\.scdn\.co\/mp3-preview\/[A-Za-z0-9]+$/;
async function spPreview(id){
  if (!SERVER || !/^[A-Za-z0-9]{22}$/.test(id || '')) return '';
  if (PVC.has(id)) return PVC.get(id);
  let u = ''; try { u = (await (await fetch('/sppv?id=' + id)).json()).url || ''; } catch(e){}
  if (!PV_RX.test(u)) u = ''; PVC.set(id, u); return u;
}
/* début de l'extrait selon la difficulté, sans dépasser les 30 s */
function pvStart(d, last){ const r = {easy:[10, 17], medium:[6, 13], hard:[3, 8], expert:[1, 4], impossible:[0, 1]}[d || 'medium']; return Math.max(0, Math.min(rnd(r[0], r[1]), 29.5 - last)); }
/* volume des jeux (extraits Spotify et vidéos YouTube), mémorisé */
const gVol = () => { const v = +ls.get('ringcine-vol', 70); return Math.max(0, Math.min(100, isNaN(v) ? 70 : v)) / 100; };
const volHtml = () => `<label class="gvol" title="Volume">${gVol() ? '🔊' : '🔇'}<input type="range" min="0" max="100" step="5" value="${Math.round(gVol() * 100)}" aria-label="Volume"></label>`;
function setVol(p){
  ls.set('ringcine-vol', p); const v = p / 100;
  document.querySelectorAll('audio').forEach(a => { a.volume = v; });
  ['gframe', 'mpframe'].forEach(id => { const f = $(id); if (f) ytCmd(f, 'setVolume', [p]); });
  document.querySelectorAll('.gvol').forEach(l => { l.firstChild.textContent = p ? '🔊' : '🔇'; });
}
document.addEventListener('input', e => { if (e.target.matches && e.target.matches('.gvol input')) setVol(+e.target.value); });
document.addEventListener('keydown', e => { if (e.target.matches && e.target.matches('.gvol input')) e.stopPropagation(); }, true);
function stopAudio(){ document.querySelectorAll('audio').forEach(a => { try { a.pause(); } catch(e){} }); }

/* ---------- Données : YouTube, Wikipédia ---------- */
async function ytList(q){ if (!SERVER) return []; try { return (await (await fetch('/yts?q=' + encodeURIComponent(q))).json()).items || []; } catch(e){ return []; } }
/* Bande-annonce : VOSTFR en priorité, sinon la bande-annonce originale en anglais (jamais la VF) */
function relTitle(it){
  const W = [...new Set([it.t, it.en || it.t])].map(t => norm(t).split(' ').filter(w => w.length > 2 && !['the','and','les','des'].includes(w)));
  return x => { const n = norm(x.t); return W.some(words => !words.length || words.filter(w => n.includes(w)).length >= Math.ceil(words.length / 2)); };
}
async function trailerFind(it){
  const rel = relTitle(it);
  const bad = /\bvf\b|\bvff\b|\bvfq\b|version fran|doubl|french dub|en fran[cç]ais|reaction|réaction|review|critique|explained|expliqu|ending|fan[- ]?made|concept|parody|parodie|recap|résumé/i;
  const vost = /vostfr|\bvost\b|sous[- ]?titr|\bst ?fr\b|subtitul/i;
  let L = await ytList(`${it.t} ${it.y || ''} bande annonce vostfr`);
  let v = L.find(x => vost.test(x.t) && !bad.test(x.t) && rel(x)) || L.slice(0, 3).find(x => vost.test(x.t) && !bad.test(x.t));
  if (v) return v.id;
  L = await ytList(`${it.t} ${it.y || ''} official trailer`);
  v = L.find(x => /trailer|teaser/i.test(x.t) && !bad.test(x.t) && !/bande[- ]annonce/i.test(x.t) && rel(x)) || L.find(x => /trailer/i.test(x.t) && !bad.test(x.t) && !/bande[- ]annonce/i.test(x.t));
  if (v) return v.id;
  if (L.length) return '';
  return await ytFind(`${it.t} ${it.y || ''} official trailer`);
}
/* Son du film : bande-annonce en VO avec vrais sous-titres (texte), traduits en français si besoin */
async function ytSubs(v){
  if (!SERVER) return null;
  try {
    const j = await (await fetch('/subs?v=' + v)).json(); if (!j || !j.data) return null;
    const d = JSON.parse(j.data);
    const cues = (d.events || []).filter(e => e.segs && e.tStartMs != null).map(e => ({s: e.tStartMs, e: e.tStartMs + (e.dDurationMs || 2500), text: e.segs.map(x => x.utf8 || '').join('').replace(/\s+/g, ' ').trim()})).filter(x => x.text && !/^\[.*\]$/.test(x.text) || x.text.length > 12);
    return cues.length >= 3 ? {cues, tr: !!j.tr} : null;
  } catch(e){ return null; }
}
function gSubStart(cues){
  const mid = cues.filter(x => x.s > 12000 && x.s < 110000); const pick = (mid.length ? mid : cues)[Math.floor(Math.random() * Math.min(4, (mid.length ? mid : cues).length))];
  return Math.max(0, pick.s / 1000 - 0.6);
}
async function voTrailer(it){
  const rel = relTitle(it);
  const bad = /\bvf\b|\bvff\b|\bvfq\b|version fran|doubl|french dub|en fran[cç]ais|bande[- ]annonce|vostfr|reaction|réaction|review|critique|explained|ending|fan[- ]?made|concept|parody|recap/i;
  const L = (await ytList(`${it.t} ${it.y || ''} official trailer`)).filter(x => /trailer|teaser/i.test(x.t) && !bad.test(x.t));
  const v = L.find(rel) || L[0];
  return v ? v.id : await ytFind(`${it.t} ${it.y || ''} official trailer`);
}
async function soundFind(it){
  const rel = relTitle(it);
  const bad = /\bvf\b|\bvff\b|\bvfq\b|version fran|doubl|french dub|en fran[cç]ais|bande[- ]annonce|reaction|réaction|review|critique|explained|ending|fan[- ]?made|concept|parody|recap/i;
  const L = (await ytList(`${it.t} ${it.y || ''} official trailer`)).filter(x => /trailer|teaser/i.test(x.t) && !bad.test(x.t));
  const cand = L.filter(rel).concat(L.filter(x => !rel(x))).slice(0, 4);
  for (const x of cand) { const s = await ytSubs(x.id); if (s) return {yt: x.id, subs: s.cues.map(q => Object.assign(q, {text: maskText(q.text, it)})), tr: s.tr}; }
  return {yt: cand[0] ? cand[0].id : await trailerFind(it), subs: null};
}
async function ytFind(q){ if (!SERVER) return ''; try { const j = await (await fetch('/yt?q=' + encodeURIComponent(q))).json(); return j.id || ''; } catch(e){ return ''; } }
const wikiCache = new Map();
async function wikiPlot(it){
  const key = it.t + '|' + it.y; if (wikiCache.has(key)) return wikiCache.get(key);
  const J = async u => (await fetch(u)).json();
  const api = (lang, q) => J(`https://${lang}.wikipedia.org/w/api.php?format=json&origin=*&${q}`);
  const SEC = /\n==\s*(Synopsis(?: détaillé)?|Résumé(?: détaillé)?|Intrigue|Histoire|Scénario|Plot|Plot summary|Storyline)\s*==\s*\n([\s\S]*?)(?=\n==[^=]|$)/i;
  const clean = t => t.replace(/\n=+[^=\n]+=+\n/g, '\n').replace(/\s*\n+\s*/g, ' ').trim();
  const extract = async (lang, title) => { const e = await api(lang, `action=query&prop=extracts|langlinks&lllang=fr&explaintext=1&exsectionformat=wiki&redirects=1&titles=${encodeURIComponent(title)}`); const pg = Object.values((e.query && e.query.pages) || {})[0] || {}; return {txt: pg.extract || '', title: pg.title || title, fr: pg.langlinks && pg.langlinks[0] && pg.langlinks[0]['*']}; };
  const isFilm = txt => /film|movie|long métrage|animated|animation|téléfilm/i.test(txt.slice(0, 700)) && (!it.y || txt.slice(0, 2000).includes(String(it.y)));
  const frPlot = txt => { const m = txt.match(SEC); if (m && clean(m[2]).length >= 120) return clean(m[2]); return ''; };
  const res = (async () => {
    let enPlot = '';
    try {
      // 1) Wikipédia en français, recherche directe
      const s = await api('fr', `action=query&list=search&srsearch=${encodeURIComponent(`${it.t} film ${it.y || ''}`)}&srlimit=4`);
      for (const r of (s.query && s.query.search) || []) { const {txt, title} = await extract('fr', r.title); if (isFilm(txt)) { const p = frPlot(txt); if (p) return {plot: p.slice(0, 1400), lang:'fr', title}; } }
      // 2) Wikipédia anglais (titres Letterboxd en anglais) puis sa version française
      const s2 = await api('en', `action=query&list=search&srsearch=${encodeURIComponent(`${it.en || it.t} ${it.y || ''} film`)}&srlimit=4`);
      for (const r of (s2.query && s2.query.search) || []) {
        const {txt, fr} = await extract('en', r.title); if (!isFilm(txt)) continue;
        if (fr) { const f = await extract('fr', fr); const p = frPlot(f.txt); if (p) return {plot: p.slice(0, 1400), lang:'fr', title: f.title}; const intro = clean(f.txt.split('\n==')[0]); if (intro.length >= 160) return {plot: intro.slice(0, 1400), lang:'fr', title: f.title}; }
        const m = txt.match(SEC); if (m && !enPlot) enPlot = clean(m[2]);
        if (enPlot) break;
      }
    } catch(e){}
    return enPlot.length >= 120 ? {plot: enPlot.slice(0, 1400), lang:'en', title: ''} : null;
  })();
  wikiCache.set(key, res); return res;
}

function maskText(text, it, extra = ''){
  const stop = new Set(['the','and','les','des','une','del','der','die','das','for','with','dans','sur','pour','qui','que','est','son','ses','aux','par','film']);
  const words = new Set();
  [it.t, it.en || '', it.sub || '', String(extra).replace(/\((film|téléfilm)[^)]*\)/gi, '')].join(' ').split(/[\s:,.'’\-–!?()]+/).forEach(w => { const n = norm(w); if (n.length >= 3 && !stop.has(n)) words.add(n); });
  return text.split(/([\p{L}\p{N}]+)/u).map(tok => words.has(norm(tok)) ? '▇'.repeat(Math.min(Math.max(tok.length, 3), 9)) : tok).join('');
}

/* ---------- Jouer hors de sa liste : films célèbres (Wikidata) / tubes Spotify ---------- */
const EXT_FILMS = [["Titanic",1997,"James Cameron","","https://upload.wikimedia.org/wikipedia/en/1/18/Titanic_%281997_film%29_poster.png"],["Le Parrain",1972,"Francis Ford Coppola","The Godfather","https://upload.wikimedia.org/wikipedia/en/1/1c/Godfather_ver1.jpg"],["Avatar",2009,"James Cameron","","https://upload.wikimedia.org/wikipedia/en/d/d6/Avatar_%282009_film%29_poster.jpg"],["Matrix",1999,"Lana Wachowski, Lilly Wachowski","The Matrix","https://upload.wikimedia.org/wikipedia/en/d/db/The_Matrix.png"],["Gladiator",2000,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/f/fb/Gladiator_%282000_film_poster%29.png"],["Pulp Fiction",1994,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/3/3b/Pulp_Fiction_%281994%29_poster.jpg"],["The Dark Knight : Le Chevalier noir",2008,"Christopher Nolan","The Dark Knight","https://upload.wikimedia.org/wikipedia/en/1/1c/The_Dark_Knight_%282008_film%29.jpg"],["Casablanca",1942,"Michael Curtiz","","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b3/CasablancaPoster-Gold.jpg/330px-CasablancaPoster-Gold.jpg"],["Les Évadés",1994,"Frank Darabont","The Shawshank Redemption","https://upload.wikimedia.org/wikipedia/en/8/81/ShawshankRedemptionMoviePoster.jpg"],["Le Silence des agneaux",1991,"Jonathan Demme","The Silence of the Lambs","https://upload.wikimedia.org/wikipedia/en/8/86/The_Silence_of_the_Lambs_poster.jpg"],["Retour vers le futur",1985,"Robert Zemeckis","Back to the Future","https://upload.wikimedia.org/wikipedia/en/d/d2/Back_to_the_Future.jpg"],["La Liste de Schindler",1993,"Steven Spielberg","Schindler's List","https://upload.wikimedia.org/wikipedia/en/3/38/Schindler%27s_List_movie.jpg"],["Fight Club",1999,"David Fincher","","https://upload.wikimedia.org/wikipedia/en/f/fc/Fight_Club_poster.jpg"],["Terminator",1984,"James Cameron","The Terminator","https://upload.wikimedia.org/wikipedia/en/6/6d/The_Terminator.png"],["Jurassic Park",1993,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/e/e7/Jurassic_Park_poster.jpg"],["Harry Potter à l'école des sorciers",2001,"Chris Columbus","Harry Potter and the Philosopher's Stone","https://thumb.wikimedia.org/wikipedia/en/thumb/7/7a/Harry_Potter_and_the_Philosopher%27s_Stone_banner.jpg/330px-Harry_Potter_and_the_Philosopher%27s_Stone_banner.jpg"],["Interstellar",2014,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/b/bc/Interstellar_film_poster.jpg"],["V pour Vendetta",2005,"James McTeigue","V for Vendetta","https://upload.wikimedia.org/wikipedia/en/9/9f/Vforvendettamov.jpg"],["Le Seigneur des anneaux : La Communauté de l'anneau",2001,"Peter Jackson","The Lord of the Rings: The Fellowship of the Ring","https://upload.wikimedia.org/wikipedia/en/f/fb/Lord_Rings_Fellowship_Ring.jpg"],["Inception",2010,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/2/2e/Inception_%282010%29_theatrical_poster.jpg"],["Autant en emporte le vent",1939,"George Cukor, Victor Fleming, Sam Wood","Gone with the Wind","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/27/Poster_-_Gone_With_the_Wind_01.jpg/330px-Poster_-_Gone_With_the_Wind_01.jpg"],["La Guerre des étoiles",1977,"George Lucas","Star Wars: Episode IV – A New Hope","https://upload.wikimedia.org/wikipedia/en/8/87/StarWarsMoviePoster1977.jpg"],["Avengers",2012,"Joss Whedon","The Avengers","https://upload.wikimedia.org/wikipedia/en/8/8a/The_Avengers_%282012_film%29_poster.jpg"],["Le Bon, la Brute et le Truand",1966,"Sergio Leone","The Good, the Bad and the Ugly","https://upload.wikimedia.org/wikipedia/en/4/45/Good_the_bad_and_the_ugly_poster.jpg"],["Harry Potter et la Chambre des secrets",2002,"Chris Columbus","Harry Potter and the Chamber of Secrets","https://thumb.wikimedia.org/wikipedia/en/thumb/c/c0/Harry_Potter_and_the_Chamber_of_Secrets_movie.jpg/330px-Harry_Potter_and_the_Chamber_of_Secrets_movie.jpg"],["Le Seigneur des anneaux : Le Retour du roi",2003,"Peter Jackson","The Lord of the Rings: The Return of the King","https://upload.wikimedia.org/wikipedia/en/4/48/Lord_Rings_Return_King.jpg"],["Terminator 2 : Le Jugement dernier",1991,"James Cameron","Terminator 2: Judgment Day","https://upload.wikimedia.org/wikipedia/en/5/5e/Terminator_2-Judgment_Day.png"],["Braveheart",1995,"Mel Gibson","","https://upload.wikimedia.org/wikipedia/en/e/e1/Braveheart_film_poster.png"],["Star Wars, épisode I : La Menace fantôme",1999,"George Lucas","Star Wars: Episode I – The Phantom Menace","https://upload.wikimedia.org/wikipedia/en/4/40/Star_Wars_Phantom_Menace_poster.jpg"],["2001, l'Odyssée de l'espace",1968,"Stanley Kubrick","2001: A Space Odyssey","https://upload.wikimedia.org/wikipedia/en/1/11/2001_A_Space_Odyssey_%281968%29.png"],["Pirates des Caraïbes : La Malédiction du Black Pearl",2003,"Gore Verbinski","Pirates of the Caribbean: The Curse of the Black Pearl","https://upload.wikimedia.org/wikipedia/en/8/89/Pirates_of_the_Caribbean_-_The_Curse_of_the_Black_Pearl.png"],["Harry Potter et le Prisonnier d'Azkaban",2004,"Alfonso Cuarón","Harry Potter and the Prisoner of Azkaban","https://upload.wikimedia.org/wikipedia/en/1/18/Harry_Potter_and_the_Prisoner_of_Azkaban_film_poster.jpg"],["Harry Potter et la Coupe de feu",2005,"Mike Newell","Harry Potter and the Goblet of Fire","https://thumb.wikimedia.org/wikipedia/en/thumb/c/c9/Harry_Potter_and_the_Goblet_of_Fire_Poster.jpg/330px-Harry_Potter_and_the_Goblet_of_Fire_Poster.jpg"],["Harry Potter et le Prince de sang-mêlé",2009,"David Yates","Harry Potter and the Half-Blood Prince","https://thumb.wikimedia.org/wikipedia/en/thumb/3/3f/Harry_Potter_and_the_Half-Blood_Prince_poster.jpg/330px-Harry_Potter_and_the_Half-Blood_Prince_poster.jpg"],["Slumdog Millionaire",2008,"Danny Boyle, Loveleen Tandan","","https://upload.wikimedia.org/wikipedia/en/9/92/Slumdog_Millionaire_poster.png"],["Le Seigneur des anneaux : Les Deux Tours",2002,"Peter Jackson","The Lord of the Rings: The Two Towers","https://upload.wikimedia.org/wikipedia/en/a/a1/Lord_Rings_Two_Towers.jpg"],["Harry Potter et l'Ordre du Phénix",2007,"David Yates","Harry Potter and the Order of the Phoenix","https://thumb.wikimedia.org/wikipedia/en/thumb/e/e7/Harry_Potter_and_the_Order_of_the_Phoenix_poster.jpg/330px-Harry_Potter_and_the_Order_of_the_Phoenix_poster.jpg"],["Star Wars, épisode III : La Revanche des Sith",2005,"George Lucas","Star Wars: Episode III – Revenge of the Sith","https://upload.wikimedia.org/wikipedia/en/9/93/Star_Wars_Episode_III_Revenge_of_the_Sith_poster.jpg"],["Il faut sauver le soldat Ryan",1998,"Steven Spielberg","Saving Private Ryan","https://upload.wikimedia.org/wikipedia/en/a/ac/Saving_Private_Ryan_poster.jpg"],["Le Parrain 2",1974,"Francis Ford Coppola","The Godfather Part II","https://upload.wikimedia.org/wikipedia/en/0/03/Godfather_part_ii.jpg"],["Le Cercle des poètes disparus",1989,"Peter Weir","Dead Poets Society","https://upload.wikimedia.org/wikipedia/en/8/86/Dead_poets_society.png"],["Un homme d'exception",2001,"Ron Howard","A Beautiful Mind","https://upload.wikimedia.org/wikipedia/en/b/b8/A_Beautiful_Mind_Poster.jpg"],["Pirates des Caraïbes : Jusqu'au bout du monde",2007,"Gore Verbinski","Pirates of the Caribbean: At World's End","https://upload.wikimedia.org/wikipedia/en/5/5a/Pirates_AWE_Poster.jpg"],["Batman Begins",2005,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/a/af/Batman_Begins_Poster.jpg"],["Le Secret de Brokeback Mountain",2005,"Ang Lee","Brokeback Mountain","https://upload.wikimedia.org/wikipedia/en/a/a1/Brokeback_mountain.jpg"],["Citizen Kane",1941,"Orson Welles","","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c0/Citizen_Kane_poster%2C_1941_%28Style_B%2C_unrestored%29.jpg/330px-Citizen_Kane_poster%2C_1941_%28Style_B%2C_unrestored%29.jpg"],["Spider-Man",2002,"Sam Raimi","","https://upload.wikimedia.org/wikipedia/en/6/6c/Spider-Man_%282002_film%29_poster.jpg"],["Apocalypse Now",1979,"Francis Ford Coppola","","https://upload.wikimedia.org/wikipedia/en/c/c2/Apocalypse_Now_poster.jpg"],["Blade Runner",1982,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/9/9f/Blade_Runner_%281982_poster%29.png"],["Pirates des Caraïbes : Le Secret du coffre maudit",2006,"Gore Verbinski","Pirates of the Caribbean: Dead Man's Chest","https://upload.wikimedia.org/wikipedia/en/2/2d/Pirates_of_the_caribbean_2_poster_b.jpg"],["Star Wars, épisode V : L'Empire contre-attaque",1980,"Irvin Kershner","Star Wars: Episode V – The Empire Strikes Back","https://upload.wikimedia.org/wikipedia/en/3/3f/The_Empire_Strikes_Back_%281980_film%29.jpg"],["Alien",1979,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/c/c3/Alien_movie_poster.jpg"],["Cars",2006,"John Lasseter, Joe Ranft","","https://upload.wikimedia.org/wikipedia/en/3/34/Cars_2006.jpg"],["Harry Potter et les Reliques de la Mort, partie 1",2010,"David Yates","Harry Potter and the Deathly Hallows – Part 1","https://thumb.wikimedia.org/wikipedia/en/thumb/2/2d/Harry_Potter_and_the_Deathly_Hallows_%E2%80%93_Part_1.jpg/330px-Harry_Potter_and_the_Deathly_Hallows_%E2%80%93_Part_1.jpg"],["300",2006,"Zack Snyder","","https://upload.wikimedia.org/wikipedia/en/5/5c/300poster.jpg"],["Star Wars, épisode VI : Le Retour du Jedi",1983,"Richard Marquand","Star Wars: Episode VI – Return of the Jedi","https://upload.wikimedia.org/wikipedia/en/b/b2/ReturnOfTheJediPoster1983.jpg"],["Star Wars, épisode II : L’Attaque des clones",2002,"George Lucas","Star Wars: Episode II – Attack of the Clones","https://upload.wikimedia.org/wikipedia/en/3/32/Star_Wars_-_Episode_II_Attack_of_the_Clones_%28movie_poster%29.jpg"],["Avengers : L'Ère d'Ultron",2015,"Joss Whedon","Avengers: Age of Ultron","https://upload.wikimedia.org/wikipedia/en/f/ff/Avengers_Age_of_Ultron_poster.jpg"],["Maman, j'ai raté l'avion !",1990,"Chris Columbus","Home Alone","https://upload.wikimedia.org/wikipedia/en/7/76/Home_alone_poster.jpg"],["Le Dictateur",1940,"Charlie Chaplin","The Great Dictator","https://thumb.wikimedia.org/wikipedia/commons/thumb/9/9d/The_Great_Dictator_%281940%29_poster.jpg/330px-The_Great_Dictator_%281940%29_poster.jpg"],["Harry Potter et les Reliques de la Mort, partie 2",2011,"David Yates","Harry Potter and the Deathly Hallows – Part 2","https://upload.wikimedia.org/wikipedia/en/d/df/Harry_Potter_and_the_Deathly_Hallows_%E2%80%93_Part_2.jpg"],["Oppenheimer",2023,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/4/4a/Oppenheimer_%28film%29.jpg"],["Parasite",2019,"Bong Joon-ho","","https://upload.wikimedia.org/wikipedia/en/5/53/Parasite_%282019_film%29.png"],["Certains l'aiment chaud",1959,"Billy Wilder","Some Like It Hot","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b8/Some_Like_It_Hot_%281959_poster%29.png/330px-Some_Like_It_Hot_%281959_poster%29.png"],["La vie est belle",1997,"Roberto Benigni","Life Is Beautiful","https://upload.wikimedia.org/wikipedia/en/7/7c/Vitaebella.jpg"],["Inglourious Basterds",2009,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/c/c3/Inglourious_Basterds_poster.jpg"],["Les Aventuriers de l'arche perdue",1981,"Steven Spielberg","Raiders of the Lost Ark","https://upload.wikimedia.org/wikipedia/en/4/4c/Raiders_of_the_Lost_Ark.jpg"],["Les Infiltrés",2006,"Martin Scorsese","The Departed","https://upload.wikimedia.org/wikipedia/en/5/50/Departed234.jpg"],["Lawrence d'Arabie",1962,"David Lean","Lawrence of Arabia","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c5/Lawrence_of_arabia_ver3_xxlg.jpg/330px-Lawrence_of_arabia_ver3_xxlg.jpg"],["Captain America: First Avenger",2011,"Joe Johnston","Captain America: The First Avenger","https://upload.wikimedia.org/wikipedia/en/3/37/Captain_America_The_First_Avenger_poster.jpg"],["Taxi Driver",1976,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/3/33/Taxi_Driver_%281976_film_poster%29.jpg"],["American Beauty",1999,"Sam Mendes","","https://upload.wikimedia.org/wikipedia/en/9/9a/American_Beauty_1999_film_poster.jpg"],["No Country for Old Men",2007,"Joel Coen, Ethan Coen","","https://upload.wikimedia.org/wikipedia/en/8/8b/No_Country_for_Old_Men_poster.jpg"],["Psychose",1960,"Alfred Hitchcock","Psycho","https://thumb.wikimedia.org/wikipedia/commons/thumb/7/76/Psycho_%281960%29_theatrical_poster_%28retouched%29.jpg/330px-Psycho_%281960%29_theatrical_poster_%28retouched%29.jpg"],["Le Prestige",2006,"Christopher Nolan","The Prestige","https://upload.wikimedia.org/wikipedia/en/d/d2/Prestige_poster.jpg"],["Le Fabuleux Destin d'Amélie Poulain",2001,"Jean-Pierre Jeunet","Amélie","https://upload.wikimedia.org/wikipedia/en/5/53/Amelie_poster.jpg"],["Skyfall",2012,"Sam Mendes","","https://thumb.wikimedia.org/wikipedia/en/thumb/a/a7/Skyfall_poster.jpg/330px-Skyfall_poster.jpg"],["Ben-Hur",1959,"William Wyler","","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/27/Ben_Hur_1959_film_Poster.jpg/330px-Ben_Hur_1959_film_Poster.jpg"],["Le Pianiste",2002,"Roman Polanski","The Pianist","https://upload.wikimedia.org/wikipedia/en/a/a6/The_Pianist_movie.jpg"],["Vol au-dessus d'un nid de coucou",1975,"Miloš Forman","One Flew Over the Cuckoo's Nest","https://upload.wikimedia.org/wikipedia/en/2/26/One_Flew_Over_the_Cuckoo%27s_Nest_poster.jpg"],["Twelve Years a Slave",2013,"Steve McQueen","12 Years a Slave","https://upload.wikimedia.org/wikipedia/en/5/5c/12_Years_a_Slave_film_poster.jpg"],["Thor",2011,"Kenneth Branagh","","https://upload.wikimedia.org/wikipedia/en/9/95/Thor_%28film%29_poster.jpg"],["Le Discours d'un roi",2010,"Tom Hooper","The King's Speech","https://upload.wikimedia.org/wikipedia/en/4/4a/The_King%27s_Speech_poster.jpg"],["Piège de cristal",1988,"John McTiernan","Die Hard","https://upload.wikimedia.org/wikipedia/en/c/ca/Die_Hard_%281988_film%29_poster.jpg"],["Gravity",2013,"Alfonso Cuarón","","https://upload.wikimedia.org/wikipedia/en/f/f6/Gravity_Poster.jpg"],["Black Panther",2018,"Ryan Coogler","","https://upload.wikimedia.org/wikipedia/en/d/d6/Black_Panther_%28film%29_poster.jpg"],["Joker",2019,"Todd Phillips","","https://upload.wikimedia.org/wikipedia/en/e/e1/Joker_%282019_film%29_poster.jpg"],["La Ligne verte",1999,"Frank Darabont","The Green Mile","https://upload.wikimedia.org/wikipedia/en/e/e2/The_Green_Mile_%28movie_poster%29.jpg"],["Douze Hommes en colère",1957,"Sidney Lumet","12 Angry Men","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b5/12_Angry_Men_%281957_film_poster%29.jpg/330px-12_Angry_Men_%281957_film_poster%29.jpg"],["Arrête-moi si tu peux",2002,"Steven Spielberg","Catch Me If You Can","https://upload.wikimedia.org/wikipedia/en/4/4d/Catch_Me_If_You_Can_2002_movie.jpg"],["Le Parrain 3",1990,"Francis Ford Coppola","The Godfather Part III","https://upload.wikimedia.org/wikipedia/en/5/55/GodfatherIII2.jpg"],["James Bond 007 contre Dr No",1962,"Terence Young","Dr. No","https://thumb.wikimedia.org/wikipedia/en/thumb/4/43/Dr._No_-_UK_cinema_poster.jpg/330px-Dr._No_-_UK_cinema_poster.jpg"],["Peter Pan",1953,"Clyde Geronimi, Hamilton Luske, Wilfred Jackson","","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dc/Peter_Pan_%281953_poster%29.jpg/330px-Peter_Pan_%281953_poster%29.jpg"],["Le Loup de Wall Street",2013,"Martin Scorsese","The Wolf of Wall Street","https://upload.wikimedia.org/wikipedia/en/d/d8/The_Wolf_of_Wall_Street_%282013%29.png"],["Shining",1980,"Stanley Kubrick","The Shining","https://upload.wikimedia.org/wikipedia/en/1/1d/The_Shining_%281980%29_U.K._release_poster_-_The_tide_of_terror_that_swept_America_IS_HERE.jpg"],["Star Wars, épisode VII : Le Réveil de la Force",2015,"J. J. Abrams","Star Wars: Episode VII – The Force Awakens","https://upload.wikimedia.org/wikipedia/en/a/a2/Star_Wars_The_Force_Awakens_Theatrical_Poster.jpg"],["Spider-Man: Homecoming",2017,"Jon Watts","","https://upload.wikimedia.org/wikipedia/en/f/f9/Spider-Man_Homecoming_poster.jpg"],["Troie",2004,"Wolfgang Petersen","Troy","https://upload.wikimedia.org/wikipedia/en/9/9f/Troy_03500296.png"],["Django Unchained",2012,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/8/8b/Django_Unchained_Poster.jpg"],["Le Hobbit : Un voyage inattendu",2012,"Peter Jackson","The Hobbit: An Unexpected Journey","https://upload.wikimedia.org/wikipedia/en/b/b3/The_Hobbit-_An_Unexpected_Journey.jpeg"],["Birdman",2014,"Alejandro González Iñárritu","","https://upload.wikimedia.org/wikipedia/en/6/63/Birdman_poster.png"],["Twilight, chapitre I : Fascination",2008,"Catherine Hardwicke","Twilight","https://upload.wikimedia.org/wikipedia/en/b/b6/Twilight_%282008_film%29_poster.jpg"],["Black Swan",2010,"Darren Aronofsky","","https://upload.wikimedia.org/wikipedia/en/6/68/Black_Swan_poster.jpg"],["Rain Man",1988,"Barry Levinson","","https://upload.wikimedia.org/wikipedia/en/b/b2/Rain_Man_poster.jpg"],["Iron Man 2",2010,"Jon Favreau","","https://upload.wikimedia.org/wikipedia/en/e/ed/Iron_Man_2_poster.jpg"],["Pirates des Caraïbes : La Fontaine de Jouvence",2011,"Rob Marshall","Pirates of the Caribbean: On Stranger Tides","https://upload.wikimedia.org/wikipedia/en/5/5e/Pirates_of_the_Caribbean_-_On_Stranger_Tides.png"],["The Social Network",2010,"David Fincher","",""],["Les Affranchis",1990,"Martin Scorsese","Goodfellas","https://upload.wikimedia.org/wikipedia/en/7/7b/Goodfellas.jpg"],["The Revenant",2015,"Alejandro González Iñárritu","","https://upload.wikimedia.org/wikipedia/en/b/b6/The_Revenant_2015_film_poster.jpg"],["The Artist",2011,"Michel Hazanavicius","","https://upload.wikimedia.org/wikipedia/en/a/a4/The_Artist_Poster.jpg"],["Les Sept Samouraïs",1954,"Akira Kurosawa","Seven Samurai","https://upload.wikimedia.org/wikipedia/en/c/c8/Seven_Samurai_Poster.png"],["Saludos Amigos",1942,"Hamilton Luske, Wilfred Jackson, Bill Roberts, Jack Kinney","","https://upload.wikimedia.org/wikipedia/en/a/af/Saludosposter.jpg"],["Doctor Strange",2016,"Scott Derrickson","","https://upload.wikimedia.org/wikipedia/en/a/a1/Doctor_Strange_%282016_film%29_poster.jpg"],["2012",2009,"Roland Emmerich","","https://upload.wikimedia.org/wikipedia/en/d/dd/2012_Poster.jpg"],["Léon",1994,"Luc Besson","Léon: The Professional","https://upload.wikimedia.org/wikipedia/en/0/03/Leon-poster.jpg"],["The Truman Show",1998,"Peter Weir","","https://upload.wikimedia.org/wikipedia/en/c/cd/Trumanshow.jpg"],["Hunger Games",2012,"Gary Ross","The Hunger Games","https://upload.wikimedia.org/wikipedia/en/4/42/HungerGamesPoster.jpg"],["L'Odyssée de Pi",2012,"Ang Lee","Life of Pi","https://upload.wikimedia.org/wikipedia/en/5/57/Life_of_Pi_2012_Poster.jpg"],["Seven",1995,"David Fincher","","https://upload.wikimedia.org/wikipedia/en/6/68/Seven_%28movie%29_poster.jpg"],["Docteur Folamour",1964,"Stanley Kubrick","Dr. Strangelove","https://upload.wikimedia.org/wikipedia/en/e/e6/Dr._Strangelove_poster.jpg"],["Orange mécanique",1971,"Stanley Kubrick","A Clockwork Orange","https://upload.wikimedia.org/wikipedia/en/7/73/A_Clockwork_Orange_%281971%29.png"],["Scarface",1983,"Brian De Palma","","https://upload.wikimedia.org/wikipedia/en/7/71/Scarface_-_1983_film.jpg"],["Les Dents de la mer",1975,"Steven Spielberg","Jaws","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/40/Jaws_movie_poster.jpg/330px-Jaws_movie_poster.jpg"],["Le Patient anglais",1996,"Anthony Minghella","The English Patient","https://upload.wikimedia.org/wikipedia/en/b/bd/The_English_Patient_Poster.jpg"],["Seul sur Mars",2015,"Ridley Scott","The Martian","https://upload.wikimedia.org/wikipedia/en/c/cd/The_Martian_film_poster.jpg"],["Memento",2000,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/c/c7/Memento_poster.jpg"],["Shakespeare in Love",1998,"John Madden","","https://upload.wikimedia.org/wikipedia/en/e/e8/Shakespeare_in_Love_1998_Poster.jpg"],["Deadpool",2016,"Tim Miller","","https://upload.wikimedia.org/wikipedia/en/2/23/Deadpool_%282016_poster%29.png"],["Alice au pays des merveilles",2010,"Tim Burton","Alice in Wonderland","https://upload.wikimedia.org/wikipedia/en/3/36/Alice_in_Wonderland_%282010_film%29.png"],["Amadeus",1984,"Miloš Forman","","https://upload.wikimedia.org/wikipedia/en/2/2f/Amadeusmov.jpg"],["Les Gardiens de la Galaxie",2014,"James Gunn","Guardians of the Galaxy","https://upload.wikimedia.org/wikipedia/en/3/33/Guardians_of_the_Galaxy_%28film%29_poster.jpg"],["Retour vers le futur 2",1989,"Robert Zemeckis","Back to the Future Part II","https://upload.wikimedia.org/wikipedia/en/c/c2/Back_to_the_Future_Part_II.jpg"],["Rocky",1976,"John G. Avildsen","","https://upload.wikimedia.org/wikipedia/en/1/18/Rocky_poster.jpg"],["Le Cuirassé Potemkine",1925,"Sergei Eisenstein","Battleship Potemkin","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/85/Vintage_Potemkin.jpg/330px-Vintage_Potemkin.jpg"],["La Mélodie du bonheur",1965,"Robert Wise","The Sound of Music","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c6/Sound_of_music.jpg/330px-Sound_of_music.jpg"],["The Dark Knight Rises",2012,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/8/83/Dark_knight_rises_poster.jpg"],["Shutter Island",2010,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/7/76/Shutterislandposter.jpg"],["Million Dollar Baby",2004,"Clint Eastwood","","https://upload.wikimedia.org/wikipedia/en/d/d3/Million_Dollar_Baby_poster.jpg"],["Captain America : Le Soldat de l'hiver",2014,"Anthony Russo, Joe Russo","Captain America: The Winter Soldier","https://upload.wikimedia.org/wikipedia/en/9/9e/Captain_America_The_Winter_Soldier_poster.jpg"],["Captain America : Civil War",2016,"Anthony Russo, Joe Russo","Captain America: Civil War","https://upload.wikimedia.org/wikipedia/en/5/53/Captain_America_Civil_War_poster.jpg"],["Independence Day",1996,"Roland Emmerich","","https://upload.wikimedia.org/wikipedia/en/b/bb/Independence_day_movieposter.jpg"],["Le Pont de la rivière Kwaï",1957,"David Lean","The Bridge on the River Kwai","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d9/The_Bridge_on_the_River_Kwai_%281958_US_poster_-_Style_A%29.jpg/330px-The_Bridge_on_the_River_Kwai_%281958_US_poster_-_Style_A%29.jpg"],["Casino Royale",2006,"Martin Campbell","","https://thumb.wikimedia.org/wikipedia/en/thumb/8/82/Casino_Royale_%282006_film_poster%29.jpg/330px-Casino_Royale_%282006_film_poster%29.jpg"],["La Momie",1999,"Stephen Sommers","The Mummy","https://upload.wikimedia.org/wikipedia/en/6/68/The_mummy.jpg"],["Iron Man 3",2013,"Shane Black","","https://upload.wikimedia.org/wikipedia/en/1/19/Iron_Man_3_poster.jpg"],["Barbie",2023,"Greta Gerwig","","https://upload.wikimedia.org/wikipedia/en/0/0b/Barbie_2023_poster.jpg"],["Wonder Woman",2017,"Patty Jenkins","","https://upload.wikimedia.org/wikipedia/en/b/b0/Wonder_Woman_%282017_film%29_poster.jpg"],["Thor : Ragnarok",2017,"Taika Waititi","Thor: Ragnarok","https://upload.wikimedia.org/wikipedia/en/7/7d/Thor_Ragnarok_poster.jpg"],["Green Book : Sur les routes du Sud",2018,"Peter Farrelly","Green Book","https://upload.wikimedia.org/wikipedia/en/5/5b/Green_Book_%282018_poster%29.png"],["Le Hobbit : La Désolation de Smaug",2013,"Peter Jackson","The Hobbit: The Desolation of Smaug","https://upload.wikimedia.org/wikipedia/en/4/4f/The_Hobbit_-_The_Desolation_of_Smaug_theatrical_poster.jpg"],["Reservoir Dogs",1992,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/0/01/Reservoir_Dogs.png"],["Mon voisin Totoro",1988,"Hayao Miyazaki","My Neighbor Totoro","https://upload.wikimedia.org/wikipedia/en/0/02/My_Neighbor_Totoro_-_Tonari_no_Totoro_%28Movie_Poster%29.jpg"],["Avatar : La Voie de l'eau",2022,"James Cameron","Avatar: The Way of Water","https://upload.wikimedia.org/wikipedia/en/5/54/Avatar_The_Way_of_Water_poster.jpg"],["007 Spectre",2015,"Sam Mendes","Spectre","https://thumb.wikimedia.org/wikipedia/en/thumb/b/b9/Spectre_2015_poster.jpg/330px-Spectre_2015_poster.jpg"],["Les Trois Caballeros",1944,"Norm Ferguson, Clyde Geronimi, Jack Kinney, Bill Roberts, Harold Young","The Three Caballeros","https://upload.wikimedia.org/wikipedia/en/7/7b/Three_caballeros_poster.png"],["Indiana Jones et le Temple maudit",1984,"Steven Spielberg","Indiana Jones and the Temple of Doom","https://upload.wikimedia.org/wikipedia/en/1/10/Indiana_Jones_and_the_Temple_of_Doom_PosterB.jpg"],["La Forme de l'eau",2017,"Guillermo del Toro","The Shape of Water","https://upload.wikimedia.org/wikipedia/en/3/37/The_Shape_of_Water_%28film%29.png"],["Will Hunting",1997,"Gus Van Sant","Good Will Hunting","https://upload.wikimedia.org/wikipedia/en/5/52/Good_Will_Hunting.png"],["Dune",2021,"Denis Villeneuve","","https://upload.wikimedia.org/wikipedia/en/8/8e/Dune_%282021_film%29.jpg"],["Aliens, le retour",1986,"James Cameron","Aliens","https://upload.wikimedia.org/wikipedia/en/f/fb/Aliens_poster.jpg"],["Vacances romaines",1953,"William Wyler","Roman Holiday","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d0/Roman_Holiday_%281953_poster%29.jpg/330px-Roman_Holiday_%281953_poster%29.jpg"],["La vie est belle",1946,"Frank Capra","It's a Wonderful Life","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/25/It%27s_a_Wonderful_Life_%281946_poster%29.jpeg/330px-It%27s_a_Wonderful_Life_%281946_poster%29.jpeg"],["Spider-Man: Far from Home",2019,"Jon Watts","Spider-Man: Far From Home","https://upload.wikimedia.org/wikipedia/en/b/bd/Spider-Man_Far_From_Home_poster.jpg"],["Spider-Man: No Way Home",2021,"Jon Watts","","https://upload.wikimedia.org/wikipedia/en/0/00/Spider-Man_No_Way_Home_poster.jpg"],["Les Minions",2015,"Pierre Coffin, Kyle Balda","Minions","https://upload.wikimedia.org/wikipedia/en/1/19/Minions_%282015_film%29.jpg"],["Spider-Man 2",2004,"Sam Raimi","","https://upload.wikimedia.org/wikipedia/en/4/4e/Spider-Man_2_USA_poster.jpg"],["Da Vinci Code",2006,"Ron Howard","The Da Vinci Code","https://upload.wikimedia.org/wikipedia/en/e/e9/The_da_vinci_code_final.jpg"],["Once Upon a Time in... Hollywood",2019,"Quentin Tarantino","Once Upon a Time in Hollywood","https://upload.wikimedia.org/wikipedia/en/a/a6/Once_Upon_a_Time_in_Hollywood_poster.png"],["Man of Steel",2013,"Zack Snyder","","https://upload.wikimedia.org/wikipedia/en/5/50/Man_of_Steel_%28film%29_poster.jpg"],["E.T., l'extra-terrestre",1982,"Steven Spielberg","E.T. the Extra-Terrestrial","https://upload.wikimedia.org/wikipedia/en/6/66/E_t_the_extra_terrestrial_ver3.jpg"],["Danse avec les loups",1990,"Kevin Costner","Dances with Wolves","https://upload.wikimedia.org/wikipedia/en/8/82/Dances_with_Wolves_poster.jpg"],["Quantum of Solace",2008,"Marc Forster","","https://thumb.wikimedia.org/wikipedia/en/thumb/2/2d/Quantum_of_Solace_-_UK_cinema_poster.jpg/330px-Quantum_of_Solace_-_UK_cinema_poster.jpg"],["Démineurs",2008,"Kathryn Bigelow","The Hurt Locker","https://upload.wikimedia.org/wikipedia/en/6/6c/HLposterUSA2.jpg"],["Ant-Man",2015,"Peyton Reed","","https://upload.wikimedia.org/wikipedia/en/1/12/Ant-Man_%28film%29_poster.jpg"],["Lost in Translation",2003,"Sofia Coppola","","https://upload.wikimedia.org/wikipedia/en/4/4c/Lost_in_Translation_poster.jpg"],["Love Actually",2003,"Richard Curtis","","https://upload.wikimedia.org/wikipedia/en/e/eb/Love_Actually_movie.jpg"],["L'Odyssée",2026,"Christopher Nolan","The Odyssey","https://upload.wikimedia.org/wikipedia/en/9/90/The_Odyssey_%282026_film%29_poster.jpg"],["Indiana Jones et la Dernière Croisade",1989,"Steven Spielberg","Indiana Jones and the Last Crusade","https://upload.wikimedia.org/wikipedia/en/8/8c/Indiana_Jones_and_the_Last_Crusade.png"],["Metropolis",1927,"Fritz Lang","","https://thumb.wikimedia.org/wikipedia/en/thumb/9/97/Metropolis_%28German_three-sheet_poster%29.jpg/330px-Metropolis_%28German_three-sheet_poster%29.jpg"],["GoldenEye",1995,"Martin Campbell","","https://thumb.wikimedia.org/wikipedia/en/thumb/2/24/GoldenEye_-_UK_cinema_poster.jpg/330px-GoldenEye_-_UK_cinema_poster.jpg"],["Thor : Le Monde des ténèbres",2013,"Alan Taylor","Thor: The Dark World","https://upload.wikimedia.org/wikipedia/en/7/7f/Thor_The_Dark_World_poster.jpg"],["Sixième Sens",1999,"M. Night Shyamalan","The Sixth Sense","https://upload.wikimedia.org/wikipedia/en/a/a4/The_Sixth_Sense_poster.png"],["Gangs of New York",2002,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/a/ae/Gangs_of_New_York_Poster.jpg"],["Gandhi",1982,"Richard Attenborough","","https://upload.wikimedia.org/wikipedia/en/1/10/Gandhi-poster.png"],["Transformers",2007,"Michael Bay","","https://upload.wikimedia.org/wikipedia/en/6/66/Transformers07.jpg"],["Spider-Man 3",2007,"Sam Raimi","","https://upload.wikimedia.org/wikipedia/en/7/7a/Spider-Man_3%2C_International_Poster.jpg"],["Ève",1950,"Joseph L. Mankiewicz","All About Eve","https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a7/All_About_Eve_%281950_poster_-_retouch%29.jpg/330px-All_About_Eve_%281950_poster_-_retouch%29.jpg"],["Seul au monde",2000,"Robert Zemeckis","Cast Away","https://upload.wikimedia.org/wikipedia/en/a/a7/Cast_away_film_poster.jpg"],["La Cité de Dieu",2002,"Fernando Meirelles, Kátia Lund","City of God","https://upload.wikimedia.org/wikipedia/en/1/10/CidadedeDeus.jpg"],["Le Hobbit : La Bataille des Cinq Armées",2014,"Peter Jackson","The Hobbit: The Battle of the Five Armies","https://upload.wikimedia.org/wikipedia/en/e/e7/The_Hobbit_-_The_Battle_of_the_Five_Armies.png"],["Spartacus",1960,"Stanley Kubrick","","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/ce/Spartacus_-_1960_-_poster.png/330px-Spartacus_-_1960_-_poster.png"],["Saw",2003,"James Wan","","https://upload.wikimedia.org/wikipedia/en/5/56/Saw_official_poster.jpg"],["Les Gardiens de la Galaxie Vol. 2",2017,"James Gunn","Guardians of the Galaxy Vol. 2","https://upload.wikimedia.org/wikipedia/en/3/32/Guardians_of_the_Galaxy_Vol._2_poster.jpg"],["Le Magicien d'Oz",1939,"King Vidor, Victor Fleming","The Wizard of Oz","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/Wizard_of_oz_movie_poster.jpg/330px-Wizard_of_oz_movie_poster.jpg"],["Usual Suspects",1995,"Bryan Singer","The Usual Suspects","https://upload.wikimedia.org/wikipedia/en/9/9c/Usual_suspects_ver1.jpg"],["Kingdom of Heaven",2005,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/9/9e/KoHposter.jpg"],["Maman, j'ai encore raté l'avion !",1992,"Chris Columbus","Home Alone 2: Lost in New York","https://upload.wikimedia.org/wikipedia/en/5/50/Home_Alone_2.jpg"],["Eternal Sunshine of the Spotless Mind",2004,"Michel Gondry","","https://upload.wikimedia.org/wikipedia/en/a/a4/Eternal_Sunshine_of_the_Spotless_Mind.png"],["The Amazing Spider-Man",2012,"Marc Webb","","https://upload.wikimedia.org/wikipedia/en/e/e0/The_Amazing_Spider-Man_%28film%29_poster.jpg"],["Fast and Furious",2001,"Rob Cohen","The Fast and the Furious","https://upload.wikimedia.org/wikipedia/en/5/54/Fast_and_the_furious_poster.jpg"],["Borat",2006,"Larry Charles","","https://upload.wikimedia.org/wikipedia/en/3/39/Borat_ver2.jpg"],["Sueurs froides",1958,"Alfred Hitchcock","Vertigo","https://thumb.wikimedia.org/wikipedia/commons/thumb/7/75/Vertigomovie_restoration.jpg/330px-Vertigomovie_restoration.jpg"],["Le Jour d'après",2004,"Roland Emmerich","The Day After Tomorrow","https://upload.wikimedia.org/wikipedia/en/5/58/The_Day_After_Tomorrow_movie.jpg"],["The Amazing Spider-Man : Le Destin d'un héros",2014,"Marc Webb","The Amazing Spider-Man 2","https://upload.wikimedia.org/wikipedia/en/2/24/The_Amazing_Spider-Man_2_poster.jpg"],["Les Animaux fantastiques",2016,"David Yates","Fantastic Beasts and Where to Find Them","https://upload.wikimedia.org/wikipedia/en/0/0b/FBAWTFT-poster.jpg"],["Premier Contact",2016,"Denis Villeneuve","Arrival","https://upload.wikimedia.org/wikipedia/en/d/df/Arrival%2C_Movie_Poster.jpg"],["Suicide Squad",2016,"David Ayer","","https://upload.wikimedia.org/wikipedia/en/5/5c/Suicide_Squad_%282016_film%29_poster.png"],["Apocalypto",2006,"Mel Gibson","","https://upload.wikimedia.org/wikipedia/en/6/62/Apocalypto-poster01.jpg"],["Terminator 3 : Le Soulèvement des machines",2003,"Jonathan Mostow","Terminator 3: Rise of the Machines","https://upload.wikimedia.org/wikipedia/en/3/39/Terminator_3_Rise_of_the_Machines_movie.jpg"],["Le Voleur de bicyclette",1948,"Vittorio De Sica","Bicycle Thieves","https://upload.wikimedia.org/wikipedia/en/2/20/Ladri3.jpg"],["Tigre et Dragon",2000,"Ang Lee","Crouching Tiger, Hidden Dragon","https://upload.wikimedia.org/wikipedia/en/2/27/Crouching_Tiger%2C_Hidden_Dragon_%28Chinese_poster%29.png"],["Predator",1987,"John McTiernan","","https://upload.wikimedia.org/wikipedia/en/9/95/Predator_Movie.jpg"],["Platoon",1986,"Oliver Stone","","https://upload.wikimedia.org/wikipedia/en/a/a9/Platoon_posters_86.jpg"],["Retour vers le futur 3",1990,"Robert Zemeckis","Back to the Future Part III","https://upload.wikimedia.org/wikipedia/en/4/4e/Back_to_the_Future_Part_III.jpg"],["Charlie et la Chocolaterie",2005,"Tim Burton","Charlie and the Chocolate Factory","https://upload.wikimedia.org/wikipedia/en/1/17/Charlie_and_the_Chocolate_Factory_%28film%29.png"],["Sherlock Holmes",2009,"Guy Ritchie","","https://thumb.wikimedia.org/wikipedia/en/thumb/e/e0/Sherlock_holmes_ver5.jpg/330px-Sherlock_holmes_ver5.jpg"],["Matrix Reloaded",2003,"Lilly Wachowski, Lana Wachowski","The Matrix Reloaded","https://upload.wikimedia.org/wikipedia/en/b/ba/Poster_-_The_Matrix_Reloaded.jpg"],["Goldfinger",1964,"Guy Hamilton","","https://thumb.wikimedia.org/wikipedia/en/thumb/9/9a/Goldfinger_-_UK_cinema_poster.jpg/330px-Goldfinger_-_UK_cinema_poster.jpg"],["The Mask",1994,"Chuck Russell","","https://upload.wikimedia.org/wikipedia/en/4/4b/The_Mask_%28film%29_poster.jpg"],["Batman v Superman : L'Aube de la justice",2016,"Zack Snyder","Batman v Superman: Dawn of Justice","https://upload.wikimedia.org/wikipedia/en/3/31/Batman_v_Superman_Dawn_of_Justice_poster.jpg"],["Indiana Jones et le Royaume du crâne de cristal",2008,"Steven Spielberg","Indiana Jones and the Kingdom of the Crystal Skull","https://upload.wikimedia.org/wikipedia/en/d/d5/Kingdomofthecrystalskull.jpg"],["Le Monde perdu : Jurassic Park",1997,"Steven Spielberg","The Lost World: Jurassic Park","https://upload.wikimedia.org/wikipedia/en/c/cc/The_Lost_World_%E2%80%93_Jurassic_Park_poster.jpg"],["Men in Black",1997,"Barry Sonnenfeld","","https://upload.wikimedia.org/wikipedia/en/f/fb/Men_in_Black_Poster.jpg"],["L'Armée des douze singes",1995,"Terry Gilliam","12 Monkeys","https://upload.wikimedia.org/wikipedia/en/c/cf/Twelve_monkeysmp.jpg"],["Argo",2012,"Ben Affleck","","https://upload.wikimedia.org/wikipedia/en/e/e1/Argo2012Poster.jpg"],["Annie Hall",1977,"Woody Allen","","https://upload.wikimedia.org/wikipedia/en/e/e6/Anniehallposter.jpg"],["Une merveilleuse histoire du temps",2014,"James Marsh","The Theory of Everything","https://upload.wikimedia.org/wikipedia/en/6/67/The_Theory_of_Everything_%282014%29.jpg"],["Aviator",2004,"Martin Scorsese","The Aviator","https://upload.wikimedia.org/wikipedia/en/f/fa/The_Aviator_%282004%29.png"],["Coquin de printemps",1947,"Jack Kinney, Bill Roberts, Hamilton Luske, William Morgan","Fun and Fancy Free","https://upload.wikimedia.org/wikipedia/en/b/b4/Funfanposter.jpg"],["Pour une poignée de dollars",1964,"Sergio Leone, Monte Hellman","A Fistful of Dollars","https://upload.wikimedia.org/wikipedia/en/f/f0/Fistful-of-Dollars-poster.jpg"],["Prometheus",2012,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/a/a3/Prometheusposterfixed.jpg"],["Batman",1989,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/5/5a/Batman_%281989%29_theatrical_poster.jpg"],["Le Dernier Samouraï",2003,"Edward Zwick","The Last Samurai","https://upload.wikimedia.org/wikipedia/en/c/c6/The_Last_Samurai.jpg"],["Matrix Revolutions",2003,"Lilly Wachowski, Lana Wachowski","The Matrix Revolutions","https://upload.wikimedia.org/wikipedia/en/7/7b/The-matrix-revolutions_oxlati6t.png"],["3 Idiots",2009,"Rajkumar Hirani","","https://upload.wikimedia.org/wikipedia/en/d/df/3_idiots_poster.jpg"],["Le Terminal",2004,"Steven Spielberg","The Terminal","https://upload.wikimedia.org/wikipedia/en/8/86/Movie_poster_the_terminal.jpg"],["Donnie Darko",2001,"Richard Kelly","","https://upload.wikimedia.org/wikipedia/en/d/db/Donnie_Darko_poster.jpg"],["Dunkerque",2017,"Christopher Nolan","Dunkirk","https://upload.wikimedia.org/wikipedia/en/1/15/Dunkirk_Film_poster.jpg"],["Le Septième Sceau",1957,"Ingmar Bergman","The Seventh Seal","https://upload.wikimedia.org/wikipedia/en/6/69/Seventhsealposter.jpg"],["Minuit à Paris",2011,"Woody Allen","Midnight in Paris","https://upload.wikimedia.org/wikipedia/en/9/9f/Midnight_in_Paris_Poster.jpg"],["Impitoyable",1992,"Clint Eastwood","Unforgiven","https://upload.wikimedia.org/wikipedia/en/4/4e/Unforgiven_2.jpg"],["Venom",2018,"Ruben Fleischer","","https://upload.wikimedia.org/wikipedia/en/1/10/Venom_%282018_film%29_poster.png"],["Pirates des Caraïbes: La Vengeance de Salazar",2017,"Espen Sandberg, Joachim Rønning","Pirates of the Caribbean: Dead Men Tell no Tales","https://upload.wikimedia.org/wikipedia/en/2/21/Pirates_of_the_Caribbean%2C_Dead_Men_Tell_No_Tales.jpg"],["Le Batman",2022,"Matt Reeves","The Batman","https://upload.wikimedia.org/wikipedia/en/f/ff/The_Batman_%28film%29_poster.jpg"],["Ant-Man et la Guêpe",2018,"Peyton Reed","Ant-Man and the Wasp","https://upload.wikimedia.org/wikipedia/en/2/2c/Ant-Man_and_the_Wasp_poster.jpg"],["Et pour quelques dollars de plus",1965,"Sergio Leone","For a Few Dollars More","https://upload.wikimedia.org/wikipedia/en/0/09/For_a_Few_Dollars_More-ita-poster.jpg"],["Le Dernier Empereur",1987,"Bernardo Bertolucci","The Last Emperor","https://upload.wikimedia.org/wikipedia/en/e/e5/The_Last_Emperor_filmposter.jpg"],["X-Men",2000,"Bryan Singer","","https://upload.wikimedia.org/wikipedia/en/8/81/X-MenfilmPoster.jpg"],["Imitation Game",2014,"Morten Tyldum","The Imitation Game","https://upload.wikimedia.org/wikipedia/en/8/87/The_Imitation_Game_%282014%29.png"],["Aquaman",2018,"James Wan","","https://upload.wikimedia.org/wikipedia/en/e/ed/Aquaman_%28film%29_poster.jpg"],["Bons Baisers de Russie",1963,"Terence Young","From Russia with Love","https://upload.wikimedia.org/wikipedia/en/a/ad/From_Russia_with_Love_%E2%80%93_UK_cinema_poster.jpg"],["Captain Marvel",2019,"Ryan Fleck, Anna Boden","","https://upload.wikimedia.org/wikipedia/en/4/4e/Captain_Marvel_%28film%29_poster.jpg"],["Blood Diamond",2006,"Edward Zwick","","https://upload.wikimedia.org/wikipedia/en/5/5a/Blooddiamondposter.jpg"],["Apollo 13",1995,"Ron Howard","","https://upload.wikimedia.org/wikipedia/en/9/9e/Apollo_thirteen_movie.jpg"],["Mr. et Mrs. Smith",2005,"Doug Liman","Mr. & Mrs. Smith","https://upload.wikimedia.org/wikipedia/en/f/fd/Mr_and_Mrs_Smith_poster.png"],["American History X",1998,"Tony Kaye","","https://upload.wikimedia.org/wikipedia/en/3/39/American_History_X_poster.png"],["Chicago",2002,"Rob Marshall","","https://upload.wikimedia.org/wikipedia/en/f/f6/Chicago_%282002_film%29.png"],["Trainspotting",1996,"Danny Boyle","","https://thumb.wikimedia.org/wikipedia/en/thumb/7/71/Trainspotting_ver2.jpg/330px-Trainspotting_ver2.jpg"],["Le Cinquième Élément",1997,"Luc Besson","The Fifth Element","https://upload.wikimedia.org/wikipedia/en/6/65/Fifth_element_poster_%281997%29.jpg"],["Mary Poppins",1964,"Robert Stevenson","","https://upload.wikimedia.org/wikipedia/en/7/78/Marypoppins.jpg"],["Fenêtre sur cour",1954,"Alfred Hitchcock","Rear Window","https://thumb.wikimedia.org/wikipedia/commons/thumb/3/38/Rear_Window_film_poster.jpg/330px-Rear_Window_film_poster.jpg"],["Eyes Wide Shut",1999,"Stanley Kubrick","","https://upload.wikimedia.org/wikipedia/en/7/73/Eyes_Wide_Shut_%281999%29.png"],["Full Metal Jacket",1987,"Stanley Kubrick","","https://upload.wikimedia.org/wikipedia/en/9/99/Full_Metal_Jacket_poster.jpg"],["Sin City",2005,"Quentin Tarantino, Robert Rodriguez, Frank Miller","","https://upload.wikimedia.org/wikipedia/en/9/9e/Sincitypostercast.jpg"],["L'Incroyable Hulk",2008,"Louis Leterrier","The Incredible Hulk","https://upload.wikimedia.org/wikipedia/en/f/f0/The_Incredible_Hulk_%28film%29_poster.jpg"],["Rebecca",1940,"Alfred Hitchcock","","https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ad/Rebecca_%281939_poster%29.jpeg/330px-Rebecca_%281939_poster%29.jpeg"],["Rashōmon",1950,"Akira Kurosawa","Rashomon","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/61/Rashomon_poster.jpg/330px-Rashomon_poster.jpg"],["Bohemian Rhapsody",2018,"Bryan Singer","","https://upload.wikimedia.org/wikipedia/en/2/2e/Bohemian_Rhapsody_poster.png"],["Spotlight",2015,"Tom McCarthy","","https://upload.wikimedia.org/wikipedia/en/f/f3/Spotlight_%28film%29_poster.jpg"],["Hugo Cabret",2011,"Martin Scorsese","Hugo","https://upload.wikimedia.org/wikipedia/en/7/73/Hugo_Poster.jpg"],["Call Me by Your Name",2017,"Luca Guadagnino","","https://upload.wikimedia.org/wikipedia/en/c/c9/CallMeByYourName2017.png"],["La Vie des autres",2006,"Florian Henckel von Donnersmarck","The Lives of Others","https://upload.wikimedia.org/wikipedia/en/9/9f/Leben_der_anderen.jpg"],["Jurassic World",2015,"Colin Trevorrow","","https://upload.wikimedia.org/wikipedia/en/6/6e/Jurassic_World_poster.jpg"],["Whiplash",2014,"Damien Chazelle","","https://upload.wikimedia.org/wikipedia/en/0/01/Whiplash_poster.jpg"],["L'Exorciste",1973,"William Friedkin","The Exorcist","https://upload.wikimedia.org/wikipedia/en/7/7b/Exorcist_ver2.jpg"],["Voyage au bout de l'enfer",1978,"Michael Cimino","The Deer Hunter","https://upload.wikimedia.org/wikipedia/en/5/57/The_Deer_Hunter_poster.jpg"],["Il était une fois dans l'Ouest",1968,"Sergio Leone","Once Upon a Time in the West","https://upload.wikimedia.org/wikipedia/en/a/a2/Once_upon_a_Time_in_the_West.jpg"],["Il était une fois en Amérique",1984,"Sergio Leone","Once Upon a Time in America","https://upload.wikimedia.org/wikipedia/en/c/c2/Once_Upon_a_Time_in_America.png"],["La Chute",2004,"Oliver Hirschbiegel","Downfall","https://upload.wikimedia.org/wikipedia/en/d/dc/Der_Untergang_Downfall_poster.png"],["L'Étrange Histoire de Benjamin Button",2008,"David Fincher","The Curious Case of Benjamin Button","https://upload.wikimedia.org/wikipedia/en/7/7c/The_Curious_Case_of_Benjamin_Button_%28film%29.png"],["Le Troisième Homme",1949,"Carol Reed","The Third Man","https://thumb.wikimedia.org/wikipedia/commons/thumb/7/77/The_Third_Man_%281949_American_theatrical_poster%29.jpg/330px-The_Third_Man_%281949_American_theatrical_poster%29.jpg"],["Maléfique",2014,"Robert Stromberg","Maleficent","https://upload.wikimedia.org/wikipedia/en/5/55/Maleficent_poster.jpg"],["Huit et demi",1963,"Federico Fellini","8½","https://upload.wikimedia.org/wikipedia/en/4/46/8Mezzo.jpg"],["Un jour sans fin",1993,"Harold Ramis","Groundhog Day","https://upload.wikimedia.org/wikipedia/en/b/b1/Groundhog_Day_%28movie_poster%29.jpg"],["Le Temps d'un week-end",1992,"Martin Brest","Scent of a Woman","https://upload.wikimedia.org/wikipedia/en/9/91/Scent_of_a_Woman.jpg"],["Les Sept Mercenaires",1960,"John Sturges","The Magnificent Seven","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/87/The_Magnificent_Seven_%281960_poster%29.jpg/330px-The_Magnificent_Seven_%281960_poster%29.jpg"],["Diamants sur canapé",1961,"Blake Edwards","Breakfast at Tiffany's","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4b/Breakfast_at_Tiffany%27s_%281961_poster%29.jpg/330px-Breakfast_at_Tiffany%27s_%281961_poster%29.jpg"],["Boulevard du crépuscule",1950,"Billy Wilder","Sunset Boulevard","https://thumb.wikimedia.org/wikipedia/commons/thumb/1/14/Sunset_Boulevard_%281950_poster%29.jpg/330px-Sunset_Boulevard_%281950_poster%29.jpg"],["Out of Africa",1985,"Sydney Pollack","","https://upload.wikimedia.org/wikipedia/en/d/d8/Out_of_Africa_%281985%29.jpg"],["Kramer contre Kramer",1979,"Robert Benton","Kramer vs. Kramer","https://upload.wikimedia.org/wikipedia/en/b/b0/Oscar_posters_79.jpg"],["Sur les quais",1954,"Elia Kazan","On the Waterfront","https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ee/On_the_Waterfront_%281954_poster%29.jpg/330px-On_the_Waterfront_%281954_poster%29.jpg"],["À l'Ouest, rien de nouveau",1930,"Lewis Milestone","All Quiet on the Western Front","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6c/All_Quiet_on_the_Western_Front_%281930_film%29_poster.jpg/330px-All_Quiet_on_the_Western_Front_%281930_film%29_poster.jpg"],["Top Gun",1986,"Tony Scott","","https://upload.wikimedia.org/wikipedia/en/4/46/Top_Gun_Movie.jpg"],["Le monde ne suffit pas",1999,"Michael Apted","The World Is Not Enough","https://upload.wikimedia.org/wikipedia/en/0/0c/The_World_Is_Not_Enough_%28UK_cinema_poster%29.jpg"],["Rambo",1982,"Ted Kotcheff","First Blood","https://upload.wikimedia.org/wikipedia/en/d/d6/First_blood_poster.jpg"],["Mulholland Drive",2001,"David Lynch","","https://upload.wikimedia.org/wikipedia/en/0/0f/Mulholland.png"],["Requiem for a Dream",2000,"Darren Aronofsky","","https://upload.wikimedia.org/wikipedia/en/9/92/Requiem_for_a_dream.jpg"],["Le Livre de la jungle",2016,"Jon Favreau, Jacobo Calderón, Juan Logar Jr.","The Jungle Book","https://upload.wikimedia.org/wikipedia/en/a/a4/The_Jungle_Book_%282016%29.jpg"],["Aladdin",2019,"Guy Ritchie","","https://upload.wikimedia.org/wikipedia/en/9/9a/Aladdin_%28Official_2019_Film_Poster%29.png"],["Intouchables",2011,"Olivier Nakache, Éric Toledano","The Intouchables","https://upload.wikimedia.org/wikipedia/en/9/93/The_Intouchables.jpg"],["Star Wars, épisode VIII : Les Derniers Jedi",2017,"Rian Johnson","Star Wars: Episode VIII – The Last Jedi","https://upload.wikimedia.org/wikipedia/en/7/7f/Star_Wars_The_Last_Jedi.jpg"],["Mad Max: Fury Road",2015,"George Miller","","https://upload.wikimedia.org/wikipedia/en/6/6e/Mad_Max_Fury_Road.jpg"],["Sonic, le film",2020,"Jeff Fowler","Sonic the Hedgehog","https://upload.wikimedia.org/wikipedia/en/4/45/Sonic_the_Hedgehog_film_poster.jpg"],["Meurs un autre jour",2002,"Lee Tamahori","Die Another Day","https://thumb.wikimedia.org/wikipedia/en/thumb/3/3d/Die_another_Day_-_UK_cinema_poster.jpg/330px-Die_another_Day_-_UK_cinema_poster.jpg"],["Collision",2004,"Paul Haggis","Crash","https://upload.wikimedia.org/wikipedia/en/d/d0/Crash_ver2.jpg"],["Transformers 3: La Face cachée de la Lune",2011,"Michael Bay","Transformers: Dark of the Moon","https://upload.wikimedia.org/wikipedia/en/b/bf/Transformers_dark_of_the_moon_ver5.jpg"],["Lucy",2014,"Luc Besson","","https://upload.wikimedia.org/wikipedia/en/1/14/Lucy_%282014_film%29_poster.jpg"],["Anges et Démons",2009,"Ron Howard","Angels & Demons","https://upload.wikimedia.org/wikipedia/en/4/44/Angels_and_demons.jpg"],["La Mémoire dans la peau",2002,"Doug Liman","The Bourne Identity","https://upload.wikimedia.org/wikipedia/en/4/49/The_Bourne_Identity_%282002%29_US_poster.jpg"],["Jumanji",1995,"Joe Johnston","","https://upload.wikimedia.org/wikipedia/en/b/b6/Jumanji_poster.jpg"],["Twilight, chapitre II : Tentation",2009,"Chris Weitz","The Twilight Saga: New Moon","https://upload.wikimedia.org/wikipedia/en/9/93/The_Twilight_Saga-_New_Moon_poster.JPG"],["La Vengeance dans la peau",2007,"Paul Greengrass","The Bourne Ultimatum","https://upload.wikimedia.org/wikipedia/en/f/fe/The_Bourne_Ultimatum_%282007_film_poster%29.jpg"],["Je suis une légende",2007,"Francis Lawrence","I Am Legend","https://upload.wikimedia.org/wikipedia/en/d/df/I_am_legend_teaser.jpg"],["Fargo",1996,"Joel Coen, Ethan Coen","","https://upload.wikimedia.org/wikipedia/en/3/33/Fargo_%281996_movie_poster%29.jpg"],["The Big Lebowski",1998,"Joel Coen, Ethan Coen","","https://upload.wikimedia.org/wikipedia/en/3/35/Biglebowskiposter.jpg"],["Fast and Furious: Tokyo Drift",2006,"Justin Lin","The Fast and the Furious: Tokyo Drift","https://upload.wikimedia.org/wikipedia/en/4/4f/Poster_-_Fast_and_Furious_Tokyo_Drift.jpg"],["Sherlock Holmes : Jeu d'ombres",2011,"Guy Ritchie","Sherlock Holmes: A Game of Shadows","https://thumb.wikimedia.org/wikipedia/en/thumb/5/53/Sherlock_Holmes2Poster.jpg/330px-Sherlock_Holmes2Poster.jpg"],["Dix Bonnes Raisons de te larguer",1999,"Gil Junger","10 Things I Hate About You","https://upload.wikimedia.org/wikipedia/en/9/95/10_Things_I_Hate_About_You_film.jpg"],["Les Temps modernes",1936,"Charlie Chaplin","Modern Times","https://thumb.wikimedia.org/wikipedia/commons/thumb/3/36/Modern_Times_poster.jpg/330px-Modern_Times_poster.jpg"],["La dolce vita",1960,"Federico Fellini","La Dolce Vita","https://upload.wikimedia.org/wikipedia/en/c/c1/La_Dolce_Vita_%281960_film%29_coverart.jpg"],["Chinatown",1974,"Roman Polanski","","https://upload.wikimedia.org/wikipedia/en/3/38/Chinatownposter1.jpg"],["Monty Python : La Vie de Brian",1979,"Terry Jones","Monty Python’s Life of Brian","https://upload.wikimedia.org/wikipedia/en/1/18/Lifeofbrianfilmposter.jpg"],["Old Boy",2003,"Park Chan-wook","Oldboy","https://upload.wikimedia.org/wikipedia/en/6/67/Oldboykoreanposter.jpg"],["The Grand Budapest Hotel",2014,"Wes Anderson","","https://upload.wikimedia.org/wikipedia/en/1/1c/The_Grand_Budapest_Hotel.png"],["Scream",1996,"Wes Craven","","https://upload.wikimedia.org/wikipedia/en/8/86/Scream_%281996_film%29_poster.jpg"],["1917",2019,"Sam Mendes","","https://thumb.wikimedia.org/wikipedia/en/thumb/f/fe/1917_%282019%29_Film_Poster.jpeg/330px-1917_%282019%29_Film_Poster.jpeg"],["Harvey Milk",2008,"Gus Van Sant","Milk","https://upload.wikimedia.org/wikipedia/en/0/02/Milkposter08.jpg"],["Munich",2005,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/0/08/Munich_1_Poster.jpg"],["Le Roi lion",2019,"Jon Favreau","The Lion King","https://upload.wikimedia.org/wikipedia/en/9/9d/Disney_The_Lion_King_2019.jpg"],["Her",2013,"Spike Jonze","","https://upload.wikimedia.org/wikipedia/en/4/44/Her2013Poster.jpg"],["Logan",2017,"James Mangold","","https://upload.wikimedia.org/wikipedia/en/3/37/Logan_2017_poster.jpg"],["Babel",2006,"Alejandro González Iñárritu","","https://upload.wikimedia.org/wikipedia/en/9/9e/Babel_poster.png"],["Mélodie Cocktail",1948,"Clyde Geronimi, Hamilton Luske, Jack Kinney, Wilfred Jackson","Melody Time","https://upload.wikimedia.org/wikipedia/en/2/26/Melody_Time_poster.jpg"],["My Fair Lady",1964,"George Cukor","","https://upload.wikimedia.org/wikipedia/en/d/d5/My_fair_lady_poster.jpg"],["Le Docteur Jivago",1965,"David Lean","Doctor Zhivago","https://upload.wikimedia.org/wikipedia/en/6/64/DrZhivago_Asheet.jpg"],["Fast and Furious 7",2015,"James Wan","Furious 7","https://upload.wikimedia.org/wikipedia/en/b/b8/Furious_7_poster.jpg"],["Jurassic Park 3",2001,"Joe Johnston","Jurassic Park III","https://upload.wikimedia.org/wikipedia/en/6/6d/Jurassic_Park_III_poster.jpg"],["Die Hard 4 : Retour en enfer",2007,"Len Wiseman","Live Free or Die Hard","https://upload.wikimedia.org/wikipedia/en/4/46/Live_Free_or_Die_Hard.jpg"],["Doctor Strange in the Multiverse of Madness",2022,"Sam Raimi","","https://upload.wikimedia.org/wikipedia/en/1/17/Doctor_Strange_in_the_Multiverse_of_Madness_poster.jpg"],["Basic Instinct",1992,"Paul Verhoeven","","https://upload.wikimedia.org/wikipedia/en/f/f9/Basic_Instinct.png"],["On ne vit que deux fois",1967,"Lewis Gilbert","You Only Live Twice","https://thumb.wikimedia.org/wikipedia/en/thumb/3/32/You_Only_Live_Twice_-_UK_cinema_poster.jpg/330px-You_Only_Live_Twice_-_UK_cinema_poster.jpg"],["Pretty Woman",1990,"Garry Marshall","","https://upload.wikimedia.org/wikipedia/en/b/b6/Pretty_woman_movie.jpg"],["Mourir peut attendre",2021,"Cary Joji Fukunaga","No Time to Die","https://thumb.wikimedia.org/wikipedia/en/thumb/f/fe/No_Time_to_Die_poster.jpg/330px-No_Time_to_Die_poster.jpg"],["Blade Runner 2049",2017,"Denis Villeneuve","","https://upload.wikimedia.org/wikipedia/en/9/9b/Blade_Runner_2049_poster.png"],["Demain ne meurt jamais",1997,"Roger Spottiswoode","Tomorrow Never Dies","https://thumb.wikimedia.org/wikipedia/en/thumb/b/b3/Tomorrow_Never_Dies_%28UK_cinema_poster%29.jpg/330px-Tomorrow_Never_Dies_%28UK_cinema_poster%29.jpg"],["Qui veut la peau de Roger Rabbit",1988,"Robert Zemeckis","Who Framed Roger Rabbit","https://upload.wikimedia.org/wikipedia/en/3/32/Movie_poster_who_framed_roger_rabbit.jpg"],["Star Trek",2009,"J. J. Abrams","","https://upload.wikimedia.org/wikipedia/en/2/29/Startrekposter.jpg"],["Fast and Furious 5",2011,"Justin Lin","Fast Five","https://upload.wikimedia.org/wikipedia/en/0/0c/Fast_Five_poster.jpg"],["X-Men 2",2003,"Bryan Singer","X2","https://upload.wikimedia.org/wikipedia/en/3/3e/X2_poster.jpg"],["Les Lumières de la ville",1931,"Charlie Chaplin","City Lights","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/09/City_Lights_%281931_theatrical_poster_-_retouched%29.jpg/330px-City_Lights_%281931_theatrical_poster_-_retouched%29.jpg"],["Barry Lyndon",1975,"Stanley Kubrick","","https://upload.wikimedia.org/wikipedia/en/e/ee/Barry_Lyndon_A.jpg"],["Tu ne tueras point",2016,"Mel Gibson","Hacksaw Ridge","https://upload.wikimedia.org/wikipedia/en/8/8a/Hacksaw_Ridge_poster.png"],["La Passion du Christ",2004,"Mel Gibson","The Passion of the Christ","https://upload.wikimedia.org/wikipedia/en/c/c4/The_Passion_of_the_Christ_poster.png"],["Dune",1984,"David Lynch","","https://upload.wikimedia.org/wikipedia/en/5/51/Dune_1984_Poster.jpg"],["Les Oiseaux",1963,"Alfred Hitchcock","The Birds","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c0/The_Birds_original_poster.jpg/330px-The_Birds_original_poster.jpg"],["La Mort aux trousses",1959,"Alfred Hitchcock","North by Northwest","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/83/Northbynorthwest1.jpg/330px-Northbynorthwest1.jpg"],["Into the Wild",2007,"Sean Penn","","https://upload.wikimedia.org/wikipedia/en/d/dc/Into_the_Wild_%282007_film_poster%29.png"],["There Will Be Blood",2007,"Paul Thomas Anderson","","https://upload.wikimedia.org/wikipedia/en/d/da/There_Will_Be_Blood_Poster.jpg"],["Heat",1995,"Michael Mann","","https://upload.wikimedia.org/wikipedia/en/6/6c/Heatposter.jpg"],["Gone Girl",2014,"David Fincher","","https://upload.wikimedia.org/wikipedia/en/0/05/Gone_Girl_Poster.jpg"],["Tootsie",1982,"Sydney Pollack","","https://upload.wikimedia.org/wikipedia/en/a/a2/Tootsie_imp.jpg"],["X-Men: Days of Future Past",2014,"Bryan Singer","","https://upload.wikimedia.org/wikipedia/en/0/0c/X-Men_Days_of_Future_Past_poster.jpg"],["Halloween : La Nuit des masques",1978,"John Carpenter","Halloween","https://upload.wikimedia.org/wikipedia/en/a/af/Halloween_%281978%29_theatrical_poster.jpg"],["Raging Bull",1980,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/5/5f/Raging_Bull_poster.jpg"],["Gatsby le Magnifique",2013,"Baz Luhrmann","The Great Gatsby","https://upload.wikimedia.org/wikipedia/en/c/c2/TheGreatGatsby2013Poster.jpg"],["Black Widow",2021,"Cate Shortland","","https://upload.wikimedia.org/wikipedia/en/e/e9/Black_Widow_%282021_film%29_poster.jpg"],["Ocean's Eleven",2001,"Steven Soderbergh","","https://upload.wikimedia.org/wikipedia/en/6/68/Ocean%27s_Eleven_2001_Poster.jpg"],["Nosferatu le vampire",1922,"F. W. Murnau","Nosferatu","https://thumb.wikimedia.org/wikipedia/en/thumb/9/90/Nosferatu_poster_%28Albin_Grau%2C_1922%29_1.jpg/330px-Nosferatu_poster_%28Albin_Grau%2C_1922%29_1.jpg"],["Tant qu'il y aura des hommes",1953,"Fred Zinnemann","From Here to Eternity","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/53/From_Here_to_Eternity_%281953_poster%29.jpg/330px-From_Here_to_Eternity_%281953_poster%29.jpg"],["Moulin rouge",2001,"Baz Luhrmann","Moulin Rouge!","https://upload.wikimedia.org/wikipedia/en/9/9f/Moulin_rouge_poster.jpg"],["Les Minions 2 : Il était une fois Gru",2022,"Kyle Balda","Minions: The Rise of Gru","https://upload.wikimedia.org/wikipedia/en/4/45/Minions_The_Rise_of_Gru_poster.jpg"],["La Belle et la Bête",2017,"Bill Condon","Beauty and the Beast","https://upload.wikimedia.org/wikipedia/en/d/d6/Beauty_and_the_Beast_2017_poster.jpg"],["Les diamants sont éternels",1971,"Guy Hamilton","Diamonds Are Forever","https://thumb.wikimedia.org/wikipedia/en/thumb/7/77/Diamonds_Are_Forever_-_UK_cinema_poster.jpg/330px-Diamonds_Are_Forever_-_UK_cinema_poster.jpg"],["Everything Everywhere All at Once",2022,"Dan Kwan, Daniel Scheinert","","https://upload.wikimedia.org/wikipedia/en/1/1e/Everything_Everywhere_All_at_Once.jpg"],["Opération Tonnerre",1965,"Terence Young","Thunderball",""],["2 Fast 2 Furious",2003,"John Singleton","","https://upload.wikimedia.org/wikipedia/en/9/9d/Two_fast_two_furious_ver5.jpg"],["Les Chariots de feu",1981,"Hugh Hudson","Chariots of Fire","https://thumb.wikimedia.org/wikipedia/en/thumb/b/b5/Chariots_of_fire.jpg/330px-Chariots_of_fire.jpg"],["Fast and Furious 4",2009,"Justin Lin","Fast & Furious","https://upload.wikimedia.org/wikipedia/en/8/8f/Fast_and_Furious_Poster.jpg"],["SOS Fantômes",1984,"Ivan Reitman","Ghostbusters","https://upload.wikimedia.org/wikipedia/en/2/2f/Ghostbusters_%281984%29_theatrical_poster.png"],["Terminator Renaissance",2009,"McG","Terminator Salvation","https://upload.wikimedia.org/wikipedia/en/9/95/Terminator-salvation-poster.jpg"],["Les Huit Salopards",2015,"Quentin Tarantino","The Hateful Eight","https://upload.wikimedia.org/wikipedia/en/d/d4/The_Hateful_Eight.jpg"],["Stalker",1979,"Andrei Tarkovsky","","https://upload.wikimedia.org/wikipedia/en/d/d4/Stalker_poster.jpg"],["Blue Velvet",1986,"David Lynch","","https://upload.wikimedia.org/wikipedia/en/f/fd/Blue_Velvet_%281986%29.png"],["Un Américain à Paris",1951,"Vincente Minnelli","An American in Paris","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8d/An_American_in_Paris_%281951_film_poster%29.jpg/330px-An_American_in_Paris_%281951_film_poster%29.jpg"],["Le Monde de Narnia : Le Lion, la Sorcière blanche et l'Armoire magique",2005,"Andrew Adamson","The Chronicles of Narnia: The Lion, the Witch and the Wardrobe","https://upload.wikimedia.org/wikipedia/en/1/10/The_Chronicles_of_Narnia_-_The_Lion%2C_the_Witch_and_the_Wardrobe.jpg"],["Les Fraises sauvages",1957,"Ingmar Bergman","Wild Strawberries","https://upload.wikimedia.org/wikipedia/en/4/48/Wildstrawberriesposter.jpg"],["Tenet",2020,"Christopher Nolan","","https://upload.wikimedia.org/wikipedia/en/1/14/Tenet_movie_poster.jpg"],["King Kong",2005,"Peter Jackson","","https://upload.wikimedia.org/wikipedia/en/6/6a/Kingkong_bigfinal1.jpg"],["Lolita malgré moi",2004,"Mark Waters","Mean Girls","https://upload.wikimedia.org/wikipedia/en/a/ac/Mean_Girls_film_poster.png"],["A.I. Intelligence artificielle",2001,"Steven Spielberg","A.I. Artificial Intelligence","https://upload.wikimedia.org/wikipedia/en/e/e6/AI_Poster.jpg"],["Expendables : Unité spéciale",2010,"Sylvester Stallone","The Expendables","https://upload.wikimedia.org/wikipedia/en/7/76/Expendablesposter.jpg"],["New York-Miami",1934,"Frank Capra","It Happened One Night","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dc/It-happened-one-night-poster.jpg/330px-It-happened-one-night-poster.jpg"],["Batman : Le Défi",1992,"Tim Burton","Batman Returns","https://upload.wikimedia.org/wikipedia/en/8/83/Batman_returns_poster2.jpg"],["American Bluff",2013,"David O. Russell","American Hustle","https://upload.wikimedia.org/wikipedia/en/8/85/American_Hustle_2013_poster.jpg"],["Ghost",1990,"Jerry Zucker","","https://upload.wikimedia.org/wikipedia/en/4/41/Ghost_%281990_movie_poster%29.jpg"],["Pour le pire et pour le meilleur",1997,"James L. Brooks","As Good as It Gets","https://upload.wikimedia.org/wikipedia/en/d/dc/As_good_as_it_gets.jpg"],["Robin des Bois",2010,"Ridley Scott","Robin Hood","https://thumb.wikimedia.org/wikipedia/en/thumb/e/ee/Robin_Hood_2010_UK_poster.jpg/330px-Robin_Hood_2010_UK_poster.jpg"],["American Psycho",2000,"Mary Harron","","https://upload.wikimedia.org/wikipedia/en/0/0c/American_Psycho.png"],["Ça",2017,"Andy Muschietti","It","https://upload.wikimedia.org/wikipedia/en/5/5a/It_%282017%29_poster.jpg"],["Fast and Furious 8",2017,"F. Gary Gray","The Fate of the Furious","https://upload.wikimedia.org/wikipedia/en/2/2d/The_Fate_of_The_Furious_Theatrical_Poster.jpg"],["Alexandre",2004,"Oliver Stone","Alexander","https://upload.wikimedia.org/wikipedia/en/a/ae/AlexanderPoster.jpg"],["Transformers 2: La Revanche",2009,"Michael Bay","Transformers: Revenge of the Fallen","https://upload.wikimedia.org/wikipedia/en/c/cb/TF2SteelPoster.jpg"],["I, Robot",2004,"Alex Proyas","","https://upload.wikimedia.org/wikipedia/en/3/3b/Movie_poster_i_robot.jpg"],["Vivre et laisser mourir",1973,"Guy Hamilton","Live and Let Die","https://thumb.wikimedia.org/wikipedia/en/thumb/3/36/Live_and_Let_Die-_UK_cinema_poster.jpg/330px-Live_and_Let_Die-_UK_cinema_poster.jpg"],["Moonlight",2016,"Barry Jenkins","","https://upload.wikimedia.org/wikipedia/en/8/84/Moonlight_%282016_film%29.png"],["X-Men : L'Affrontement final",2006,"Brett Ratner","X-Men: The Last Stand","https://upload.wikimedia.org/wikipedia/en/5/5b/X-Men_The_Last_Stand_theatrical_poster.jpg"],["The Reader",2008,"Stephen Daldry","","https://upload.wikimedia.org/wikipedia/en/6/6c/Reader_ver2.jpg"],["Space Jam",1996,"Bruce W. Smith, Joe Pytka, Tony Cervone","","https://upload.wikimedia.org/wikipedia/en/1/14/Space_jam.jpg"],["La Mort dans la peau",2004,"Paul Greengrass","The Bourne Supremacy","https://upload.wikimedia.org/wikipedia/en/3/30/Bourne_supremacy_ver2.jpg"],["Happiness Therapy",2012,"David O. Russell","Silver Linings Playbook","https://upload.wikimedia.org/wikipedia/en/9/9a/Silver_Linings_Playbook_Poster.jpg"],["Hôtel Rwanda",2004,"Terry George","Hotel Rwanda","https://upload.wikimedia.org/wikipedia/en/d/d5/Hotel_Rwanda_movie.jpg"],["Star Trek Into Darkness",2013,"J. J. Abrams","","https://upload.wikimedia.org/wikipedia/en/5/50/StarTrekIntoDarkness_FinalUSPoster.jpg"],["Speed",1994,"Jan de Bont","","https://upload.wikimedia.org/wikipedia/en/4/45/Speed_movie_poster.jpg"],["District 9",2009,"Neill Blomkamp","","https://upload.wikimedia.org/wikipedia/en/d/d7/District_nine_ver2.jpg"],["Le diable s'habille en Prada",2006,"David Frankel","The Devil Wears Prada","https://upload.wikimedia.org/wikipedia/en/e/e7/The_Devil_Wears_Prada_main_onesheet.jpg"],["La Couleur des sentiments",2011,"Tate Taylor","The Help","https://upload.wikimedia.org/wikipedia/en/d/d3/The_Help_%282011_film%29.jpg"],["Le Pont des espions",2015,"Steven Spielberg","Bridge of Spies","https://upload.wikimedia.org/wikipedia/en/f/fa/Bridge_of_Spies_poster.jpg"],["Lincoln",2012,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/6/6a/Lincoln_2012_Teaser_Poster.jpg"],["Macadam Cowboy",1969,"John Schlesinger","Midnight Cowboy","https://upload.wikimedia.org/wikipedia/en/f/f2/Midnight_Cowboy-poster.jpg"],["La Guerre des mondes",2005,"Steven Spielberg","War of the Worlds","https://upload.wikimedia.org/wikipedia/en/8/83/War_of_the_Worlds_2005_poster.jpg"],["Edward aux mains d'argent",1990,"Tim Burton","Edward Scissorhands","https://upload.wikimedia.org/wikipedia/en/3/3b/Edwardscissorhandsposter.JPG"],["Le Lauréat",1967,"Mike Nichols","The Graduate","https://upload.wikimedia.org/wikipedia/en/8/8b/Graduateposter67.jpg"],["La Garçonnière",1960,"Billy Wilder","The Apartment","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8b/The_Apartment_%281960_poster%29.jpg/330px-The_Apartment_%281960_poster%29.jpg"],["Orgueil et Préjugés",2005,"Joe Wright","Pride & Prejudice","https://upload.wikimedia.org/wikipedia/en/0/03/Prideandprejudiceposter.jpg"],["Les Mitchell contre les machines",2021,"Mike Rianda, Jeff Rowe","The Mitchells vs. The Machines","https://upload.wikimedia.org/wikipedia/en/4/41/MitchellsMachinesPoster.jpg"],["127 Heures",2010,"Danny Boyle","127 Hours","https://upload.wikimedia.org/wikipedia/en/b/b3/127_Hours_Poster.jpg"],["RoboCop",1987,"Paul Verhoeven","","https://upload.wikimedia.org/wikipedia/en/1/16/RoboCop_%281987%29_theatrical_poster.jpg"],["Armageddon",1998,"Michael Bay","","https://upload.wikimedia.org/wikipedia/en/f/fc/Armageddon-poster06.jpg"],["Les Éternels",2021,"Chloé Zhao","Eternals","https://upload.wikimedia.org/wikipedia/en/9/9b/Eternals_%28film%29_poster.jpeg"],["Rogue One: A Star Wars Story",2016,"Gareth Edwards","","https://upload.wikimedia.org/wikipedia/en/d/d4/Rogue_One%2C_A_Star_Wars_Story_poster.png"],["Le Retour de la momie",2001,"Stephen Sommers","The Mummy Returns","https://upload.wikimedia.org/wikipedia/en/b/b7/The_Mummy_Returns_poster.jpg"],["Dune : Deuxième partie",2024,"Denis Villeneuve","Dune: Part Two","https://upload.wikimedia.org/wikipedia/en/5/52/Dune_Part_Two_poster.jpeg"],["Contact",1997,"Robert Zemeckis","","https://upload.wikimedia.org/wikipedia/en/7/75/Contact_ver2.jpg"],["American Pie",1999,"Chris Weitz, Paul Weitz","","https://upload.wikimedia.org/wikipedia/en/c/c8/American_Pie1.jpg"],["Johnny English",2003,"Peter Howitt","","https://upload.wikimedia.org/wikipedia/en/9/92/Johnny_English_movie.jpg"],["À la recherche du bonheur",2006,"Gabriele Muccino","The Pursuit of Happyness","https://upload.wikimedia.org/wikipedia/en/8/81/Poster-pursuithappyness.jpg"],["Les Rebelles de la forêt",2006,"Anthony Stacchi, Jill Culton, Roger Allers","Open Season","https://upload.wikimedia.org/wikipedia/en/9/9e/Open_Season.jpg"],["Tuer n'est pas jouer",1987,"John Glen","The Living Daylights","https://upload.wikimedia.org/wikipedia/en/a/ae/The_Living_Daylights_-_UK_cinema_poster.jpg"],["Snatch : Tu braques ou tu raques",2000,"Guy Ritchie","Snatch","https://thumb.wikimedia.org/wikipedia/en/thumb/a/a7/Snatch_ver4.jpg/330px-Snatch_ver4.jpg"],["Les Quatre Fantastiques",2005,"Tim Story","Fantastic Four","https://upload.wikimedia.org/wikipedia/en/4/4a/Fantastic_Four_poster.jpg"],["N'oublie jamais",2004,"Nick Cassavetes","The Notebook","https://upload.wikimedia.org/wikipedia/en/8/86/Posternotebook.jpg"],["Le Labyrinthe de Pan",2006,"Guillermo del Toro","Pan's Labyrinth","https://upload.wikimedia.org/wikipedia/en/6/67/Pan%27s_Labyrinth.jpg"],["Noé",2014,"Darren Aronofsky","Noah","https://upload.wikimedia.org/wikipedia/en/4/41/Noah2014Poster.jpg"],["La Ruée vers l'or",1925,"Charlie Chaplin","The Gold Rush","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4d/Gold_rush_poster.jpg/330px-Gold_rush_poster.jpg"],["Le Kid",1921,"Charlie Chaplin","The Kid","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b5/The_Kid_%281921%29_poster.jpg/330px-The_Kid_%281921%29_poster.jpg"],["Amarcord",1973,"Federico Fellini","","https://upload.wikimedia.org/wikipedia/en/9/97/Amarcord_%28film%29_poster.jpg"],["Kingsman : Services secrets",2014,"Matthew Vaughn","Kingsman: The Secret Service","https://upload.wikimedia.org/wikipedia/en/8/8b/Kingsman_The_Secret_Service_poster.jpg"],["Solaris",1972,"Andrei Tarkovsky","","https://upload.wikimedia.org/wikipedia/en/5/54/Solyaris_ussr_poster.jpg"],["Kill Bill: Volume 1",2003,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/2/2c/Kill_Bill_Volume_1.png"],["La Planète des singes : Les Origines",2011,"Rupert Wyatt","Rise of the Planet of the Apes","https://upload.wikimedia.org/wikipedia/en/8/81/Rise_of_the_Planet_of_the_Apes_Poster.jpg"],["Minority Report",2002,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/4/44/Minority_Report_Poster.jpg"],["Les Schtroumpfs",2011,"Raja Gosnell","The Smurfs","https://upload.wikimedia.org/wikipedia/en/1/11/TheSmurfs2011Poster.jpg"],["World War Z",2013,"Marc Forster","","https://upload.wikimedia.org/wikipedia/en/d/dc/World_War_Z_poster.jpg"],["Elephant Man",1980,"David Lynch","The Elephant Man","https://upload.wikimedia.org/wikipedia/en/2/27/TheElephantManposter.jpg"],["American Sniper",2014,"Clint Eastwood","","https://upload.wikimedia.org/wikipedia/en/1/10/American_Sniper_poster.jpg"],["Les Fils de l'homme",2006,"Alfonso Cuarón","Children of Men","https://thumb.wikimedia.org/wikipedia/en/thumb/f/fc/Children_of_men_ver4.jpg/330px-Children_of_men_ver4.jpg"],["Patton",1970,"Franklin J. Schaffner","","https://upload.wikimedia.org/wikipedia/en/f/f2/70_patton.jpg"],["Gran Torino",2008,"Clint Eastwood","","https://upload.wikimedia.org/wikipedia/en/c/c6/Gran_Torino_poster.jpg"],["Mystic River",2003,"Clint Eastwood","","https://upload.wikimedia.org/wikipedia/en/9/93/Mystic_River_poster.jpg"],["Le Dernier Tango à Paris",1972,"Bernardo Bertolucci","Last Tango in Paris","https://upload.wikimedia.org/wikipedia/en/d/d5/LastTango.jpg"],["X-Men: Apocalypse",2016,"Bryan Singer","","https://upload.wikimedia.org/wikipedia/en/0/04/X-Men_-_Apocalypse.jpg"],["Trois Billboards : Les Panneaux de la vengeance",2017,"Martin McDonagh","Three Billboards Outside Ebbing, Missouri","https://upload.wikimedia.org/wikipedia/en/c/c7/Three_Billboards_Outside_Ebbing%2C_Missouri_poster.png"],["Capitaine Phillips",2013,"Paul Greengrass","Captain Phillips","https://upload.wikimedia.org/wikipedia/en/a/a8/Captain_Phillips_Poster.jpg"],["Tout sur ma mère",1999,"Pedro Almodóvar","All About My Mother","https://upload.wikimedia.org/wikipedia/en/d/d7/All_about_my_mother.jpg"],["Madame Doubtfire",1993,"Chris Columbus","Mrs. Doubtfire","https://upload.wikimedia.org/wikipedia/en/5/5a/Mrs_Doubtfire.jpg"],["Sweeney Todd : Le Diabolique Barbier de Fleet Street",2007,"Tim Burton","Sweeney Todd: The Demon Barber of Fleet Street","https://upload.wikimedia.org/wikipedia/en/4/4b/Sweeneylarge.jpg"],["Terminator : Génésis",2015,"Alan Taylor","Terminator Genisys","https://upload.wikimedia.org/wikipedia/en/b/bc/Terminator_Genisys.JPG"],["Sonic 2, le film",2022,"Jeff Fowler","Sonic the Hedgehog 2","https://upload.wikimedia.org/wikipedia/en/3/3e/Sonic_the_Hedgehog_2_film_poster.jpg"],["La Ligne rouge",1998,"Terrence Malick","The Thin Red Line","https://upload.wikimedia.org/wikipedia/en/a/ae/The_Thin_Red_Line_Poster.jpg"],["Une journée en enfer",1995,"John McTiernan","Die Hard with a Vengeance","https://upload.wikimedia.org/wikipedia/en/4/4c/Die_Hard_With_A_Vengance.jpg"],["Pearl Harbor",2001,"Michael Bay","","https://upload.wikimedia.org/wikipedia/en/3/3c/Pearl_harbor_movie_poster.jpg"],["Deadpool 2",2018,"David Leitch","","https://upload.wikimedia.org/wikipedia/en/c/cf/Deadpool_2_poster.jpg"],["Van Helsing",2004,"Stephen Sommers","","https://upload.wikimedia.org/wikipedia/en/5/55/Van_Helsing_poster.jpg"],["Thor: Love and Thunder",2022,"Taika Waititi","","https://upload.wikimedia.org/wikipedia/en/8/88/Thor_Love_and_Thunder_poster.jpeg"],["Resident Evil",2002,"Paul W. S. Anderson","","https://upload.wikimedia.org/wikipedia/en/a/a1/Resident_evil_ver4.jpg"],["The Hours",2002,"Stephen Daldry","","https://upload.wikimedia.org/wikipedia/en/e/e6/The_Hours_poster.jpg"],["Mamma Mia!",2008,"Phyllida Lloyd","","https://upload.wikimedia.org/wikipedia/en/9/95/Mamma_Mia_%282008%29_US_poster.jpg"],["Coup de foudre à Notting Hill",1999,"Roger Michell","Notting Hill","https://upload.wikimedia.org/wikipedia/en/3/38/NottingHillRobertsGrant.jpg"],["X-Men Origins: Wolverine",2009,"Gavin Hood","","https://upload.wikimedia.org/wikipedia/en/0/08/X-Men_Origins_Wolverine_theatrical_poster.jpg"],["La Nuit au musée",2006,"Shawn Levy","Night at the Museum","https://upload.wikimedia.org/wikipedia/en/3/34/Night_at_the_Museum_poster.jpg"],["Au service secret de Sa Majesté",1969,"Peter R. Hunt","On Her Majesty's Secret Service","https://thumb.wikimedia.org/wikipedia/en/thumb/f/f3/On_Her_Majesty%27s_Secret_Service_-_UK_cinema_poster.jpg/330px-On_Her_Majesty%27s_Secret_Service_-_UK_cinema_poster.jpg"],["Octopussy",1983,"John Glen","","https://thumb.wikimedia.org/wikipedia/en/thumb/b/b2/Octopussy_-_UK_cinema_poster.jpg/330px-Octopussy_-_UK_cinema_poster.jpg"],["La strada",1954,"Federico Fellini","La Strada","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/48/La_strada_ddr_poster.webp/330px-La_strada_ddr_poster.webp"],["X-Men : Le Commencement",2011,"Matthew Vaughn","X-Men: First Class","https://upload.wikimedia.org/wikipedia/en/5/55/X-MenFirstClassMoviePoster.jpg"],["Monty Python : Sacré Graal !",1975,"Terry Gilliam, Terry Jones","Monty Python and the Holy Grail","https://thumb.wikimedia.org/wikipedia/en/thumb/0/08/Monty-Python-1975-poster.png/330px-Monty-Python-1975-poster.png"],["Cinema Paradiso",1988,"Giuseppe Tornatore","","https://upload.wikimedia.org/wikipedia/en/8/86/CinemaParadiso.jpg"],["French Connection",1971,"William Friedkin","The French Connection","https://upload.wikimedia.org/wikipedia/en/b/b8/TheFrenchConnection.jpg"],["Qu'elle était verte ma vallée",1941,"John Ford","How Green Was My Valley","https://thumb.wikimedia.org/wikipedia/commons/thumb/9/99/How_Green_Was_My_Valley_%281941_poster_-_Style_A%29.jpg/330px-How_Green_Was_My_Valley_%281941_poster_-_Style_A%29.jpg"],["Justice League",2017,"Zack Snyder","","https://upload.wikimedia.org/wikipedia/en/6/6b/Justice_League_%28film%29_poster.jpg"],["Casino",1995,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/c/cb/Casino_%28Martins_Scorsese_film%29.png"],["Mission impossible 2",2000,"John Woo","Mission: Impossible 2","https://upload.wikimedia.org/wikipedia/en/4/48/Mission_Impossible_II.jpg"],["Mission impossible",1996,"Brian De Palma","Mission: Impossible","https://upload.wikimedia.org/wikipedia/en/e/e1/MissionImpossiblePoster.jpg"],["Star Wars, épisode IX : l'Ascension de Skywalker",2019,"J. J. Abrams","Star Wars: Episode IX – The Rise of Skywalker","https://upload.wikimedia.org/wikipedia/en/a/af/Star_Wars_The_Rise_of_Skywalker_poster.jpg"],["Comme des bêtes",2016,"Chris Renaud, Yarrow Cheney","The Secret Life of Pets","https://upload.wikimedia.org/wikipedia/en/6/64/The_Secret_Life_of_Pets_poster.jpg"],["Les Quatre Cents Coups",1959,"François Truffaut","The 400 Blows","https://upload.wikimedia.org/wikipedia/en/f/f9/Quatre_coups2.jpg"],["Entretien avec un vampire",1994,"Neil Jordan","Interview with the Vampire","https://upload.wikimedia.org/wikipedia/en/f/fe/InterviewwithaVampireMoviePoste.JPG"],["Les Animaux fantastiques : Les Crimes de Grindelwald",2018,"David Yates","Fantastic Beasts: The Crimes of Grindelwald","https://upload.wikimedia.org/wikipedia/en/3/3c/Fantastic_Beasts_-_The_Crimes_of_Grindelwald_Poster.png"],["Chantons sous la pluie",1952,"Gene Kelly, Stanley Donen","Singin' in the Rain","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5d/Singin%27_in_the_Rain_%281952_poster%29.jpg/330px-Singin%27_in_the_Rain_%281952_poster%29.jpg"],["Watchmen : Les Gardiens",2009,"Zack Snyder","Watchmen","https://upload.wikimedia.org/wikipedia/en/b/bc/Watchmen_film_poster.jpg"],["Fast and Furious 6",2013,"Justin Lin","Fast & Furious 6","https://upload.wikimedia.org/wikipedia/en/3/30/Fast_%26_Furious_6_film_poster.jpg"],["Black Panther: Wakanda Forever",2022,"Ryan Coogler","","https://upload.wikimedia.org/wikipedia/en/3/3b/Black_Panther_Wakanda_Forever_poster.jpg"],["Les Gardiens de la Galaxie Vol. 3",2023,"James Gunn","Guardians of the Galaxy Vol. 3","https://upload.wikimedia.org/wikipedia/en/7/74/Guardians_of_the_Galaxy_Vol._3_poster.jpg"],["The Thing",1982,"John Carpenter","","https://upload.wikimedia.org/wikipedia/en/e/e3/The_Thing_%281982_film%29.png"],["Reviens-moi",2007,"Joe Wright","Atonement","https://upload.wikimedia.org/wikipedia/en/e/e4/Atonement_UK_poster.jpg"],["Philadelphia",1993,"Jonathan Demme","","https://upload.wikimedia.org/wikipedia/en/0/00/Philadelphia_imp.jpg"],["Dracula",1992,"Francis Ford Coppola","Bram Stoker's Dracula","https://upload.wikimedia.org/wikipedia/en/a/a0/Bram_Stoker%27s_Dracula_%281992_film%29.jpg"],["Le Nom de la rose",1986,"Jean-Jacques Annaud","The Name of the Rose","https://upload.wikimedia.org/wikipedia/en/c/c4/Name_of_rose_movieposter.jpg"],["Les Ailes",1927,"William A. Wellman, Harry d'Abbadie d'Arrast","Wings","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b3/Wings_%281927%29_poster.jpg/330px-Wings_%281927%29_poster.jpg"],["L'Inspecteur Harry",1971,"Don Siegel","Dirty Harry","https://upload.wikimedia.org/wikipedia/en/6/65/Dirty_harry.jpg"],["West Side Story",1961,"Robert Wise, Jerome Robbins","","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0b/West_Side_Story_1961_film_poster.jpg/330px-West_Side_Story_1961_film_poster.jpg"],["Conjuring : Les Dossiers Warren",2013,"James Wan","The Conjuring","https://upload.wikimedia.org/wikipedia/en/8/8c/The_Conjuring_poster.jpg"],["Spider-Man: Brand New Day",2026,"Destin Daniel Cretton","","https://upload.wikimedia.org/wikipedia/en/9/9a/Spider-Man_Brand_New_Day_poster.jpg"],["Mission impossible 3",2006,"J. J. Abrams","Mission: Impossible III","https://upload.wikimedia.org/wikipedia/en/b/bc/Mission_Impossible_III.jpg"],["Batman Forever",1995,"Joel Schumacher","","https://upload.wikimedia.org/wikipedia/en/9/9d/Batman_Forever_poster.png"],["Get Out",2017,"Jordan Peele","","https://upload.wikimedia.org/wikipedia/en/a/a3/Get_Out_poster.png"],["L'Homme au pistolet d'or",1974,"Guy Hamilton","The Man with the Golden Gun","https://thumb.wikimedia.org/wikipedia/en/thumb/0/0c/The_Man_with_the_Golden_Gun_-_UK_cinema_poster.jpg/330px-The_Man_with_the_Golden_Gun_-_UK_cinema_poster.jpg"],["Tom et Jerry",2021,"Tim Story","Tom & Jerry","https://upload.wikimedia.org/wikipedia/en/1/14/Tom_%26_Jerry_%28Official_2021_Film_Poster%29.png"],["Stargate, la porte des étoiles",1994,"Roland Emmerich","Stargate","https://upload.wikimedia.org/wikipedia/en/e/e0/Stargateposter.jpg"],["Twilight, chapitre III : Hésitation",2010,"David Slade","The Twilight Saga: Eclipse","https://upload.wikimedia.org/wikipedia/en/d/d7/Eclipse_Theatrical_One-Sheet.jpg"],["La Planète des singes : L'Affrontement",2014,"Matt Reeves","Dawn of the Planet of the Apes","https://upload.wikimedia.org/wikipedia/en/7/77/Dawn_of_the_Planet_of_the_Apes.jpg"],["Fury",2014,"David Ayer","","https://upload.wikimedia.org/wikipedia/en/1/17/Fury_2014_poster.jpg"],["King Kong",1933,"Ernest B. Schoedsack, Merian C. Cooper","","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f3/Kingkongposter.jpg/330px-Kingkongposter.jpg"],["L'Effet papillon",2004,"Eric Bress, J. Mackye Gruber","The Butterfly Effect","https://upload.wikimedia.org/wikipedia/en/4/43/Butterflyeffect_poster.jpg"],["Happy Feet",2006,"George Miller","","https://upload.wikimedia.org/wikipedia/en/5/5c/Happy_Feet_Poster.jpg"],["True Grit",2010,"Joel Coen, Ethan Coen","","https://upload.wikimedia.org/wikipedia/en/c/ce/True_Grit_Poster.jpg"],["La Momie : La Tombe de l'empereur Dragon",2008,"Rob Cohen","The Mummy: Tomb of the Dragon Emperor","https://upload.wikimedia.org/wikipedia/en/d/df/The_Mummy_-_Tomb_of_the_Dragon_Emperor.jpg"],["Vanilla Sky",2001,"Cameron Crowe","","https://upload.wikimedia.org/wikipedia/en/2/2d/Vanilla_Sky_poster.png"],["Scary Movie",2000,"Keenen Ivory Wayans","","https://upload.wikimedia.org/wikipedia/en/2/29/Movie_poster_for_%22Scary_Movie%22.jpg"],["Bruce tout-puissant",2003,"Tom Shadyac","Bruce Almighty","https://upload.wikimedia.org/wikipedia/en/6/60/BruceAlmighty_poster.jpg"],["Ace Ventura, détective chiens et chats",1994,"Tom Shadyac","Ace Ventura: Pet Detective","https://upload.wikimedia.org/wikipedia/en/8/84/Ace_ventura_pet_detective.jpg"],["Dangereusement vôtre",1985,"John Glen","A View to a Kill","https://thumb.wikimedia.org/wikipedia/en/thumb/0/03/A_View_to_a_Kill_-_UK_cinema_poster.jpg/330px-A_View_to_a_Kill_-_UK_cinema_poster.jpg"],["Avatar 3",2025,"James Cameron","Avatar: Fire and Ash","https://upload.wikimedia.org/wikipedia/en/9/95/Avatar_Fire_and_Ash_poster.jpeg"],["Bonnie et Clyde",1967,"Arthur Penn","Bonnie and Clyde","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b6/Bonnie_and_Clyde_%281967_teaser_poster%29.jpg/330px-Bonnie_and_Clyde_%281967_teaser_poster%29.jpg"],["L'Arnaque",1973,"George Roy Hill","The Sting","https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/The_Sting_%281973_alt_poster%29.jpeg/330px-The_Sting_%281973_alt_poster%29.jpeg"],["Transformers : L'Âge de l'extinction",2014,"Michael Bay","Transformers: Age of Extinction","https://upload.wikimedia.org/wikipedia/en/0/0f/Transformers_Age_of_Extinction_poster.jpg"],["Mission: Impossible – Fallout",2018,"Christopher McQuarrie","","https://upload.wikimedia.org/wikipedia/en/f/ff/MI_%E2%80%93_Fallout.jpg"],["American Gangster",2007,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/9/9f/American_Gangster_poster.jpg"],["3 h 10 pour Yuma",2007,"James Mangold","3:10 to Yuma","https://upload.wikimedia.org/wikipedia/en/2/27/310_to_Yuma_%282007_film%29.jpg"],["Dans la chaleur de la nuit",1967,"Norman Jewison","In the Heat of the Night","https://upload.wikimedia.org/wikipedia/en/d/d5/In_the_Heat_of_the_Night_%28film%29.jpg"],["Good Bye, Lenin!",2003,"Wolfgang Becker","Good Bye Lenin!","https://upload.wikimedia.org/wikipedia/en/6/63/Good_Bye_Lenin.jpg"],["Solo: A Star Wars Story",2018,"Ron Howard","","https://upload.wikimedia.org/wikipedia/en/5/54/Solo_A_Star_Wars_Story_poster.jpg"],["Total Recall",1990,"Paul Verhoeven","","https://upload.wikimedia.org/wikipedia/en/2/2d/Total_Recall_%281990_film%29_poster.jpg"],["Les Incorruptibles",1987,"Brian De Palma","The Untouchables","https://upload.wikimedia.org/wikipedia/en/9/92/UntouchablesThe.jpg"],["Le train sifflera trois fois",1952,"Fred Zinnemann","High Noon","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/81/High_Noon_%281952_poster%29.jpg/330px-High_Noon_%281952_poster%29.jpg"],["Dallas Buyers Club",2013,"Jean-Marc Vallée","","https://upload.wikimedia.org/wikipedia/en/a/a8/Dallas_Buyers_Club_poster.jpg"],["Cinquante Nuances de Grey",2015,"Sam Taylor-Johnson","Fifty Shades of Grey","https://upload.wikimedia.org/wikipedia/en/7/73/Fifty_Shades_of_Grey_poster.jpg"],["Collatéral",2004,"Michael Mann","Collateral","https://upload.wikimedia.org/wikipedia/en/4/45/Collateral_%28Movie%29.jpg"],["Destination finale",2000,"James Wong","Final Destination","https://upload.wikimedia.org/wikipedia/en/a/a3/Final_Destination_movie.jpg"],["L.A. Confidential",1997,"Curtis Hanson","","https://upload.wikimedia.org/wikipedia/en/d/d8/La_confidential.jpg"],["Stalingrad",2001,"Jean-Jacques Annaud","Enemy at the Gates","https://upload.wikimedia.org/wikipedia/en/a/ab/Enemy_at_the_gates_ver2.jpg"],["Jumanji : Bienvenue dans la jungle",2017,"Jake Kasdan","Jumanji: Welcome to the Jungle","https://upload.wikimedia.org/wikipedia/en/d/dc/Jumanji_Welcome_to_the_Jungle.png"],["Erin Brockovich, seule contre tous",2000,"Steven Soderbergh","Erin Brockovich","https://upload.wikimedia.org/wikipedia/en/a/a9/Erin_Brockovich_%28film_poster%29.jpg"],["L'Espion qui m'aimait",1977,"Lewis Gilbert","The Spy Who Loved Me","https://upload.wikimedia.org/wikipedia/en/d/d7/The_Spy_Who_Loved_Me_%28UK_cinema_poster%29.jpg"],["Moonraker",1979,"Lewis Gilbert","","https://thumb.wikimedia.org/wikipedia/en/thumb/6/66/Moonraker_%28UK_cinema_poster%29.jpg/330px-Moonraker_%28UK_cinema_poster%29.jpg"],["Moscou ne croit pas aux larmes",1980,"Vladimir Menshov","Moscow Does Not Believe in Tears","https://upload.wikimedia.org/wikipedia/en/a/a3/Moscow_for_US.jpg"],["Jojo Rabbit",2019,"Taika Waititi","","https://upload.wikimedia.org/wikipedia/en/a/a2/Jojo_Rabbit_%282019%29_poster.jpg"],["Bons Baisers de Bruges",2008,"Martin McDonagh","In Bruges","https://upload.wikimedia.org/wikipedia/en/e/ee/In_Bruges_poster.png"],["Wolverine : Le Combat de l'immortel",2013,"James Mangold","The Wolverine","https://upload.wikimedia.org/wikipedia/en/7/74/The_Wolverine_posterUS.jpg"],["The Crow",1994,"Alex Proyas","","https://upload.wikimedia.org/wikipedia/en/3/39/Crow_ver2.jpg"],["Du silence et des ombres",1962,"Robert Mulligan","To Kill a Mockingbird","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2f/To_Kill_a_Mockingbird_%281963_US_theatrical_poster%29.jpg/330px-To_Kill_a_Mockingbird_%281963_US_theatrical_poster%29.jpg"],["Saw 2",2005,"Darren Lynn Bouseman","Saw II","https://upload.wikimedia.org/wikipedia/en/f/f4/Saw_II_poster.jpg"],["Rambo 2 : La Mission",1985,"George P. Cosmatos","Rambo: First Blood Part II","https://upload.wikimedia.org/wikipedia/en/f/fc/Rambo_first_blood_part_ii.jpg"],["L'Associé du diable",1997,"Taylor Hackford","The Devil's Advocate","https://upload.wikimedia.org/wikipedia/en/3/3f/Devilsadvocate.jpg"],["Permis de tuer",1989,"John Glen","Licence to Kill","https://thumb.wikimedia.org/wikipedia/en/thumb/c/c2/Licence_to_Kill_-_UK_cinema_poster.jpg/330px-Licence_to_Kill_-_UK_cinema_poster.jpg"],["Kill Bill: Volume 2",2004,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/c/c4/Kill_Bill_Volume_2.png"],["Un après-midi de chien",1975,"Sidney Lumet","Dog Day Afternoon","https://upload.wikimedia.org/wikipedia/en/4/44/Dog_Day_Afternoon_film_poster.jpg"],["Empire du soleil",1987,"Steven Spielberg","Empire of the Sun","https://upload.wikimedia.org/wikipedia/en/5/59/Empire_of_the_Sun.jpg"],["Rambo 3",1988,"Peter MacDonald","Rambo III","https://upload.wikimedia.org/wikipedia/en/a/a3/Rambo3poster.jpg"],["Les Révoltés du Bounty",1935,"Frank Lloyd","Mutiny on the Bounty","https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b8/Mutiny_on_the_Bounty_poster.jpg/330px-Mutiny_on_the_Bounty_poster.jpg"],["Les Nerfs à vif",1991,"Martin Scorsese","Cape Fear","https://upload.wikimedia.org/wikipedia/en/1/1b/Cape_fear_91.jpg"],["Cours, Lola, cours",1998,"Tom Tykwer","Run Lola Run","https://upload.wikimedia.org/wikipedia/en/f/f5/Lola_Rennt_poster.jpg"],["La Plage",2000,"Danny Boyle","The Beach","https://upload.wikimedia.org/wikipedia/en/b/bc/The_Beach_film.jpg"],["La Nuit des morts-vivants",1968,"George A. Romero","Night of the Living Dead","https://upload.wikimedia.org/wikipedia/en/9/91/Night_of_the_Living_Dead_%281968%29_poster.jpg"],["Le Géant de fer",1999,"Brad Bird","The Iron Giant","https://upload.wikimedia.org/wikipedia/en/d/d3/The_Iron_Giant_poster.JPG"],["Twilight, chapitre IV : Révélation, partie 1",2011,"Bill Condon","The Twilight Saga: Breaking Dawn – Part 1","https://upload.wikimedia.org/wikipedia/en/c/c2/Breaking_Dawn_Part_1_Poster.jpg"],["La Chute du faucon noir",2001,"Ridley Scott","Black Hawk Down","https://upload.wikimedia.org/wikipedia/en/0/0c/Black_hawk_down_ver1.jpg"],["Sleepy Hollow",1999,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/0/09/Sleepy_hollow_ver2.jpg"],["Bob l'éponge, le film",2004,"Stephen Hillenburg, Mark Osborne","The SpongeBob SquarePants Movie","https://upload.wikimedia.org/wikipedia/en/9/9b/The_SpongeBob_SquarePants_Movie_official_poster.jpg"],["Public Enemies",2009,"Michael Mann","","https://upload.wikimedia.org/wikipedia/en/4/46/PEPOSTERsm.jpg"],["8 Mile",2002,"Curtis Hanson","","https://upload.wikimedia.org/wikipedia/en/1/1e/8_Mile_official_poster.jpg"],["Walkyrie",2008,"Bryan Singer","Valkyrie","https://upload.wikimedia.org/wikipedia/en/b/b8/Valkyrie_poster.jpg"],["Lord of War",2005,"Andrew Niccol","","https://upload.wikimedia.org/wikipedia/en/9/92/Lordofwar.jpg"],["Very Bad Trip",2009,"Todd Phillips","The Hangover","https://upload.wikimedia.org/wikipedia/en/b/b9/Hangoverposter09.jpg"],["Taken",2008,"Pierre Morel","","https://upload.wikimedia.org/wikipedia/en/e/ed/Taken_film_poster.jpg"],["La Proposition",2009,"Anne Fletcher","The Proposal","https://upload.wikimedia.org/wikipedia/en/0/02/The_Proposal.jpg"],["Superman",1978,"Richard Donner","","https://upload.wikimedia.org/wikipedia/en/b/b0/Superman_%281978_film_poster%29.jpg"],["Alvin et les Chipmunks",2007,"Tim Hill","Alvin and the Chipmunks","https://upload.wikimedia.org/wikipedia/en/d/dc/Alvin_and_the_Chipmunks2007.jpg"],["Juno",2007,"Jason Reitman","","https://upload.wikimedia.org/wikipedia/en/3/36/Junoposter2007.png"],["Men in Black 2",2002,"Barry Sonnenfeld","Men in Black II","https://upload.wikimedia.org/wikipedia/en/3/3d/Men_in_Black_II_Poster.jpg"],["Miss Daisy et son chauffeur",1989,"Bruce Beresford","Driving Miss Daisy","https://upload.wikimedia.org/wikipedia/en/a/a5/Driving_Miss_Daisy_.jpg"],["Grand Hotel",1932,"Edmund Goulding","","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d6/GrandHotelFilmPoster.jpg/330px-GrandHotelFilmPoster.jpg"],["58 Minutes pour vivre",1990,"Renny Harlin","Die Hard 2","https://upload.wikimedia.org/wikipedia/en/2/2c/Die_Hard_2.jpg"],["Star Trek : Premier Contact",1996,"Jonathan Frakes","Star Trek: First Contact","https://upload.wikimedia.org/wikipedia/en/0/01/Star_trek_first_contact_poster.jpg"],["Le Stratège",2011,"Bennett Miller","Moneyball","https://upload.wikimedia.org/wikipedia/en/2/2e/Moneyball_Poster.jpg"],["Bienvenue à Zombieland",2009,"Ruben Fleischer","Zombieland","https://upload.wikimedia.org/wikipedia/en/a/a3/Zombieland-poster.jpg"],["Edge of Tomorrow",2014,"Doug Liman","","https://upload.wikimedia.org/wikipedia/en/f/f9/Edge_of_Tomorrow_Poster.jpg"],["Cendrillon",2015,"Kenneth Branagh","Cinderella","https://upload.wikimedia.org/wikipedia/en/c/c2/Cinderella_2015_official_poster.jpg"],["The Irishman",2019,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/8/80/The_Irishman_poster.jpg"],["Deadpool & Wolverine",2024,"Shawn Levy","","https://upload.wikimedia.org/wikipedia/en/4/4c/Deadpool_%26_Wolverine_poster.jpg"],["A Star Is Born",2018,"Bradley Cooper","","https://upload.wikimedia.org/wikipedia/en/3/39/A_Star_is_Born.png"],["Danish Girl",2015,"Tom Hooper","The Danish Girl","https://upload.wikimedia.org/wikipedia/en/f/f2/The_Danish_Girl_%28film%29_poster.jpg"],["John Wick",2014,"David Leitch, Chad Stahelski","","https://upload.wikimedia.org/wikipedia/en/9/98/John_Wick_TeaserPoster.jpg"],["The Suicide Squad",2021,"James Gunn","","https://upload.wikimedia.org/wikipedia/en/0/06/The_Suicide_Squad_%28film%29_poster.jpg"],["Jurassic World: Fallen Kingdom",2018,"J. A. Bayona","","https://upload.wikimedia.org/wikipedia/en/c/c6/Jurassic_World_Fallen_Kingdom.png"],["Passengers",2015,"Morten Tyldum","","https://upload.wikimedia.org/wikipedia/en/8/8e/Passengers_2016_film_poster.jpg"],["Jurassic World : Le Monde d'après",2022,"Colin Trevorrow","Jurassic World Dominion","https://upload.wikimedia.org/wikipedia/en/c/ce/JurassicWorldDominion_Poster.jpeg"],["En avant",2020,"Dan Scanlon","Onward","https://upload.wikimedia.org/wikipedia/en/0/03/Onward_poster.jpg"],["Room",2015,"Lenny Abrahamson","","https://upload.wikimedia.org/wikipedia/en/c/c2/Room_%282015_film%29.png"],["Hunger Games : L'Embrasement",2013,"Francis Lawrence","The Hunger Games: Catching Fire","https://upload.wikimedia.org/wikipedia/en/1/12/Catching-Fire_poster.jpg"],["John Wick: Chaptire 2",2017,"Chad Stahelski","John Wick: Chapter 2","https://upload.wikimedia.org/wikipedia/en/3/31/John_Wick_Chapter_Two.png"],["Mission impossible : Protocole Fantôme",2011,"Brad Bird","Mission: Impossible – Ghost Protocol","https://upload.wikimedia.org/wikipedia/en/b/b5/Mission_impossible_ghost_protocol.jpg"],["Taare Zameen Par",2007,"Aamir Khan, Amole Gupte, Ram Madhvani","","https://upload.wikimedia.org/wikipedia/en/b/b4/Taare_Zameen_Par_Like_Stars_on_Earth_poster.png"],["Une bataille après l'autre",2025,"Paul Thomas Anderson","One Battle After Another","https://upload.wikimedia.org/wikipedia/en/5/5d/One_Battle_After_Another.jpg"],["Brazil",1985,"Terry Gilliam","","https://thumb.wikimedia.org/wikipedia/en/thumb/e/e9/Brazil_%281985_film%29_poster.jpg/330px-Brazil_%281985_film%29_poster.jpg"],["La Horde sauvage",1969,"Sam Peckinpah","The Wild Bunch","https://upload.wikimedia.org/wikipedia/en/0/05/The_Wild_Bunch.JPG"],["In the Mood for Love",2000,"Wong Kar-wai","","https://upload.wikimedia.org/wikipedia/en/4/45/In_the_Mood_for_Love_movie.jpg"],["Kick-Ass",2010,"Matthew Vaughn","","https://upload.wikimedia.org/wikipedia/en/3/30/Kick-Ass_film_poster.jpg"],["Dersou Ouzala",1975,"Akira Kurosawa","Dersu Uzala","https://upload.wikimedia.org/wikipedia/en/d/d8/Uzala1.jpg"],["Gladiator 2",2024,"Ridley Scott","Gladiator II","https://upload.wikimedia.org/wikipedia/en/0/04/Gladiator_II_%282024%29_poster.jpg"],["Roma",2018,"Alfonso Cuarón","","https://upload.wikimedia.org/wikipedia/en/8/85/Roma_theatrical_poster.png"],["Rencontres du troisième type",1977,"Steven Spielberg","Close Encounters of the Third Kind","https://upload.wikimedia.org/wikipedia/en/b/ba/Close_Encounters_of_the_Third_Kind_%281977%29_theatrical_poster.jpg"],["Manhattan",1979,"Woody Allen","","https://upload.wikimedia.org/wikipedia/en/f/f3/Manhattan-poster01.jpg"],["Hannah et ses sœurs",1986,"Woody Allen","Hannah and Her Sisters","https://upload.wikimedia.org/wikipedia/en/a/af/Hannah_and_her_sisters.jpg"],["Boyhood",2014,"Richard Linklater","","https://upload.wikimedia.org/wikipedia/en/a/a6/Boyhood_%282014%29.png"],["Alita: Battle Angel",2019,"Robert Rodriguez","","https://upload.wikimedia.org/wikipedia/en/e/ee/Alita_Battle_Angel_%282019_poster%29.png"],["Jackie Brown",1997,"Quentin Tarantino","","https://upload.wikimedia.org/wikipedia/en/8/89/Jackie_Brown_%281997%29.png"],["Aguirre, la colère de Dieu",1972,"Werner Herzog","Aguirre, the Wrath of God","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/68/Aguirre%2C_The_Wrath_of_God_%28New_Yorker_Films%2C_1977%29.jpg/330px-Aguirre%2C_The_Wrath_of_God_%28New_Yorker_Films%2C_1977%29.jpg"],["La Planète des singes",1968,"Franklin J. Schaffner","Planet of the Apes","https://upload.wikimedia.org/wikipedia/en/f/fd/PlanetoftheapesPoster.jpg"],["Neverland",2004,"Marc Forster","Finding Neverland","https://upload.wikimedia.org/wikipedia/en/2/2e/Findingneverlandposter.jpg"],["Lolita",1962,"Stanley Kubrick","","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c1/Lolita_%281962_film_poster%29.jpg/330px-Lolita_%281962_film_poster%29.jpg"],["Rosemary's Baby",1968,"Roman Polanski","","https://upload.wikimedia.org/wikipedia/en/e/ef/Rosemarys_baby_poster.jpg"],["Butch Cassidy et le Kid",1969,"George Roy Hill","Butch Cassidy and the Sundance Kid","https://upload.wikimedia.org/wikipedia/en/f/fd/Butch_sundance_poster.jpg"],["Lettres d'Iwo Jima",2006,"Clint Eastwood","Letters from Iwo Jima","https://upload.wikimedia.org/wikipedia/en/8/87/Letters_from_Iwo_Jima.jpg"],["L'Échange",2008,"Clint Eastwood","Changeling","https://upload.wikimedia.org/wikipedia/en/4/43/Changeling_poster.jpg"],["Mission: Impossible – Rogue Nation",2015,"Christopher McQuarrie","","https://upload.wikimedia.org/wikipedia/en/f/fb/Mission_Impossible_Rogue_Nation_poster.jpg"],["Thelma et Louise",1991,"Ridley Scott","Thelma & Louise","https://upload.wikimedia.org/wikipedia/en/8/8f/Thelma_%26_Louise_poster.png"],["Big Fish",2003,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/4/41/Big_Fish_movie_poster.png"],["Beetlejuice",1988,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/7/76/Beetlejuice_%281988_film_poster%29.png"],["La Planète des singes",2001,"Tim Burton","Planet of the Apes","https://upload.wikimedia.org/wikipedia/en/2/2c/PotA-2001poster.jpg"],["Les Pingouins de Madagascar",2014,"Eric Darnell, Simon J. Smith","Penguins of Madagascar","https://upload.wikimedia.org/wikipedia/en/5/5f/Penguins_of_Madagascar_poster.jpg"],["Les Plus Belles Années de notre vie",1946,"William Wyler","The Best Years of Our Lives","https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7d/The_Best_Years_of_Our_Lives_%281946_poster%29.jpg/330px-The_Best_Years_of_Our_Lives_%281946_poster%29.jpg"],["Fast & Furious: Hobbs & Shaw",2019,"David Leitch","Hobbs & Shaw","https://upload.wikimedia.org/wikipedia/en/0/00/Fast_%26_Furious_Presents_Hobbs_%26_Shaw_-_theatrical_poster.jpg"],["Le Bras de diamant",1969,"Leonid Gaidai","The Diamond Arm","https://upload.wikimedia.org/wikipedia/en/9/90/Brilruka.jpg"],["Easy Rider",1969,"Dennis Hopper","","https://upload.wikimedia.org/wikipedia/en/3/32/EasyRider.jpg"],["Divergente",2014,"Neil Burger","Divergent","https://upload.wikimedia.org/wikipedia/en/7/7e/Divergent_film_poster.jpg"],["Superman",2025,"James Gunn","","https://upload.wikimedia.org/wikipedia/en/3/32/Superman_%282025_film%29_poster.jpg"],["L'Odyssée de l'African Queen",1951,"John Huston","The African Queen","https://thumb.wikimedia.org/wikipedia/commons/thumb/8/81/The_African_Queen_%281952_US_poster%29.jpg/330px-The_African_Queen_%281952_US_poster%29.jpg"],["Shang-Chi et la Légende des Dix Anneaux",2021,"Destin Daniel Cretton","Shang-Chi and the Legend of the Ten Rings","https://upload.wikimedia.org/wikipedia/en/7/74/Shang-Chi_and_the_Legend_of_the_Ten_Rings_poster.jpeg"],["À bout de souffle",1960,"Jean-Luc Godard","Breathless","https://upload.wikimedia.org/wikipedia/en/3/3f/%C3%80_bout_de_souffle_%28movie_poster%29.jpg"],["Alien 3",1992,"David Fincher","","https://upload.wikimedia.org/wikipedia/en/b/b9/Alien3_poster.jpg"],["Superman Returns",2006,"Bryan Singer","","https://upload.wikimedia.org/wikipedia/en/1/10/Superman_Returns.jpg"],["Arnaques, Crimes et Botanique",1998,"Guy Ritchie","Lock, Stock and Two Smoking Barrels","https://thumb.wikimedia.org/wikipedia/en/thumb/e/e9/Lock%2C_Stock_and_Two_Smoking_Barrels_2.jpg/330px-Lock%2C_Stock_and_Two_Smoking_Barrels_2.jpg"],["La Leçon de piano",1993,"Jane Campion","The Piano","https://upload.wikimedia.org/wikipedia/en/9/90/The-piano-poster.jpg"],["Dans la peau de John Malkovich",1999,"Spike Jonze","Being John Malkovich","https://upload.wikimedia.org/wikipedia/en/5/55/Being_John_Malkovich_poster.jpg"],["The Patriot",2000,"Roland Emmerich","","https://upload.wikimedia.org/wikipedia/en/6/68/Patriot_promo_poster.jpg"],["Mission",1986,"Roland Joffé","The Mission","https://upload.wikimedia.org/wikipedia/en/c/c1/The_Mission_%281986_film_poster%29.jpg"],["Alice au pays des Merveilles 2",2016,"James Bobin","Alice Through the Looking Glass","https://upload.wikimedia.org/wikipedia/en/1/15/Alice_Through_the_Looking_Glass_%282016_film%29_poster.png"],["Anora",2024,"Sean Baker","","https://upload.wikimedia.org/wikipedia/en/2/2b/Anora_%282024_film%29_poster.jpg"],["The Descendants",2011,"Alexander Payne","","https://upload.wikimedia.org/wikipedia/en/7/7d/Descendants_film_poster.jpg"],["Quatre mariages et un enterrement",1994,"Mike Newell","Four Weddings and a Funeral","https://upload.wikimedia.org/wikipedia/en/3/35/Four_weddings_poster.jpg"],["Une vie volée",1999,"James Mangold","Girl, Interrupted","https://upload.wikimedia.org/wikipedia/en/b/b7/Girl%2C_Interrupted_%281999%29.png"],["Broadway Melody",1929,"Harry Beaumont","The Broadway Melody","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f0/Broadway_Melody_poster.jpg/330px-Broadway_Melody_poster.jpg"],["Quand Harry rencontre Sally",1989,"Rob Reiner","When Harry Met Sally","https://upload.wikimedia.org/wikipedia/en/1/1c/WhenHarryMetSallyPoster.jpg"],["Braquage à l'italienne",2003,"F. Gary Gray","The Italian Job","https://upload.wikimedia.org/wikipedia/en/d/db/Italianjob.jpg"],["Les Rois de la glisse",2007,"Chris Buck, Ash Brannon","Surf's Up","https://upload.wikimedia.org/wikipedia/en/6/6a/Surfs_upmp.jpg"],["Jerry Maguire",1996,"Cameron Crowe","","https://upload.wikimedia.org/wikipedia/en/e/ea/Jerry_Maguire_movie_poster.jpg"],["Un tramway nommé Désir",1951,"Elia Kazan","A Streetcar Named Desire","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fe/A_Streetcar_Named_Desire_%281951%29.jpg/330px-A_Streetcar_Named_Desire_%281951%29.jpg"],["Expendables 2 : Unité spéciale",2012,"Simon West","The Expendables 2","https://upload.wikimedia.org/wikipedia/en/e/ed/The_Expendables_2_poster.jpg"],["Le Choc des Titans",2010,"Louis Leterrier","Clash of the Titans","https://upload.wikimedia.org/wikipedia/en/8/80/Clashofthetitansremakeposter1.jpg"],["Bienvenue à Gattaca",1997,"Andrew Niccol","Gattaca","https://upload.wikimedia.org/wikipedia/en/d/de/Gattaca_poster.jpg"],["Breakfast Club",1985,"John Hughes","The Breakfast Club","https://upload.wikimedia.org/wikipedia/en/d/d1/The_Breakfast_Club_poster.jpg"],["Resident Evil: Apocalypse",2004,"Alexander Witt","","https://upload.wikimedia.org/wikipedia/en/5/50/Resident_evil_apocalypse_poster.jpg"],["Little Miss Sunshine",2006,"Valerie Faris, Jonathan Dayton","","https://upload.wikimedia.org/wikipedia/en/1/16/Little_miss_sunshine_poster.jpg"],["Ran",1985,"Akira Kurosawa","","https://upload.wikimedia.org/wikipedia/en/f/f2/Kuroran.jpg"],["La mort vous va si bien",1992,"Robert Zemeckis","Death Becomes Her","https://upload.wikimedia.org/wikipedia/en/e/e9/Death_Becomes_Her_poster.jpg"],["Cheval de guerre",2011,"Steven Spielberg","War Horse","https://upload.wikimedia.org/wikipedia/en/d/da/War-horse-poster.jpg"],["Vicky Cristina Barcelona",2008,"Woody Allen","","https://upload.wikimedia.org/wikipedia/en/0/05/Vicky_Cristina_Barcelona_film_poster.png"],["Venom: Let There Be Carnage",2021,"Andy Serkis","","https://upload.wikimedia.org/wikipedia/en/a/a7/Venom_Let_There_Be_Carnage_poster.jpg"],["Le Bateau",1981,"Wolfgang Petersen","Das Boot","https://upload.wikimedia.org/wikipedia/en/a/a3/Das_boot_ver1.jpg"],["Les Hommes du président",1976,"Alan J. Pakula","All the President's Men","https://upload.wikimedia.org/wikipedia/en/9/92/All_the_president%27s_men.jpg"],["L'Interview qui tue !",2014,"Seth Rogen, Evan Goldberg","The Interview","https://upload.wikimedia.org/wikipedia/en/2/27/The_Interview_2014_poster.jpg"],["Matrix Resurrections",2021,"the Wachowskis, Lana Wachowski","The Matrix Resurrections","https://upload.wikimedia.org/wikipedia/en/5/50/The_Matrix_Resurrections.jpg"],["Desperado",1995,"Robert Rodriguez","","https://upload.wikimedia.org/wikipedia/en/a/a6/Desperado1.jpg"],["Le Grinch",2018,"Scott Mosier, Yarrow Cheney","The Grinch","https://upload.wikimedia.org/wikipedia/en/4/4f/The_Grinch%2C_final_poster.jpg"],["Indiana Jones et le Cadran de la destinée",2023,"James Mangold","Indiana Jones and the Dial of Destiny","https://upload.wikimedia.org/wikipedia/en/c/c3/Indiana_Jones_and_the_Dial_of_Destiny_theatrical_poster.jpg"],["Les Misérables",2012,"Tom Hooper","","https://upload.wikimedia.org/wikipedia/en/b/b0/Les-miserables-movie-poster1.jpg"],["Les Blues Brothers",1980,"John Landis","The Blues Brothers","https://upload.wikimedia.org/wikipedia/en/a/ae/Bluesbrothersmovieposter.jpg"],["Sabrina",1954,"Billy Wilder","","https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3b/Sabrina_%281954_film_poster%29.jpg/330px-Sabrina_%281954_film_poster%29.jpg"],["Le Poison",1945,"Billy Wilder","The Lost Weekend","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2d/The_Lost_Weekend_%281945_film%29.jpg/330px-The_Lost_Weekend_%281945_film%29.jpg"],["Ant-Man et la Guêpe : Quantumania",2023,"Peyton Reed","Ant-Man and the Wasp: Quantumania","https://upload.wikimedia.org/wikipedia/en/3/30/Ant-Man_and_the_Wasp_Quantumania_poster.jpg"],["Ghost Rider",2007,"Mark Steven Johnson","","https://upload.wikimedia.org/wikipedia/en/7/71/GhostRiderBigPoster.jpg"],["Sur la route de Madison",1995,"Clint Eastwood","The Bridges of Madison County","https://upload.wikimedia.org/wikipedia/en/5/5a/The_Bridges_Of_Madison_County.jpg"],["Before Sunrise",1995,"Richard Linklater","","https://upload.wikimedia.org/wikipedia/en/d/da/Before_Sunrise_poster.jpg"],["Don't Look Up : Déni cosmique",2021,"Adam McKay","Don't Look Up","https://upload.wikimedia.org/wikipedia/en/5/5c/Don%27t_Look_Up_2021_film.jpg"],["Un homme pour l'éternité",1966,"Fred Zinnemann","A Man for All Seasons","https://upload.wikimedia.org/wikipedia/en/c/cb/A_Man_for_All_Seasons_%281966_movie_poster%29.gif"],["Le Village",2004,"M. Night Shyamalan","The Village","https://upload.wikimedia.org/wikipedia/en/a/a0/The_Village_movie.jpg"],["Sicario",2015,"Denis Villeneuve","","https://upload.wikimedia.org/wikipedia/en/4/4b/Sicario_poster.jpg"],["Fast and Furious 9",2021,"Justin Lin","F9","https://upload.wikimedia.org/wikipedia/en/2/2b/F9_film_poster.jpg"],["Le Grinch",2000,"Ron Howard","Dr. Seuss' How the Grinch Stole Christmas","https://upload.wikimedia.org/wikipedia/en/e/e7/How_the_Grinch_Stole_Christmas_film_poster.jpg"],["Wall Street",1987,"Oliver Stone","","https://upload.wikimedia.org/wikipedia/en/b/bc/Wall_Street_film.jpg"],["The Tree of Life",2011,"Terrence Malick","","https://upload.wikimedia.org/wikipedia/en/4/4e/Thetreeoflifeposter.jpg"],["Conan le Barbare",1982,"John Milius","Conan the Barbarian","https://upload.wikimedia.org/wikipedia/en/e/ed/Conan_movie_psoter.jpg"],["Le Faucon maltais",1941,"John Huston","The Maltese Falcon","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6b/The_Maltese_Falcon_%281941_film_poster%29.jpg/330px-The_Maltese_Falcon_%281941_film_poster%29.jpg"],["Le Labyrinthe",2014,"Wes Ball","The Maze Runner","https://upload.wikimedia.org/wikipedia/en/b/be/The_Maze_Runner_poster.jpg"],["Obsession",2025,"Curry Barker","","https://upload.wikimedia.org/wikipedia/en/0/05/Obsession_theatrical_poster.jpeg"],["Blade 2",2002,"Guillermo del Toro","Blade II","https://upload.wikimedia.org/wikipedia/en/6/6d/Blade_II_movie.jpg"],["Dernier Train pour Busan",2016,"Yeon Sang-ho","Train to Busan","https://upload.wikimedia.org/wikipedia/en/9/95/Train_to_Busan.jpg"],["Nomadland",2020,"Chloé Zhao","","https://upload.wikimedia.org/wikipedia/en/a/a5/Nomadland_poster.jpeg"],["Godzilla",2014,"Gareth Edwards","","https://upload.wikimedia.org/wikipedia/en/1/10/Godzilla_%282014%29_poster.jpg"],["Minecraft, le film",2025,"Jared Hess","A Minecraft Movie","https://upload.wikimedia.org/wikipedia/en/6/66/A_Minecraft_Movie_poster.jpg"],["Ted",2012,"Seth MacFarlane","","https://upload.wikimedia.org/wikipedia/en/d/d4/Ted_%28film%29.png"],["Contagion",2011,"Steven Soderbergh","","https://upload.wikimedia.org/wikipedia/en/8/86/Contagion_Poster.jpg"],["Tendres Passions",1983,"James L. Brooks","Terms of Endearment","https://upload.wikimedia.org/wikipedia/en/e/e9/Terms_of_endearment.png"],["Amour",2012,"Michael Haneke","","https://upload.wikimedia.org/wikipedia/en/9/95/Amour-poster-french.jpg"],["Nuits blanches à Seattle",1993,"Nora Ephron","Sleepless in Seattle","https://upload.wikimedia.org/wikipedia/en/e/e1/Sleepless_in_seattle.jpg"],["Jamais plus jamais",1983,"Irvin Kershner","Never Say Never Again","https://upload.wikimedia.org/wikipedia/en/6/6c/Never_Say_Never_Again_%E2%80%93_UK_cinema_poster.jpg"],["Le Monde de Narnia : Le Prince Caspian",2008,"Andrew Adamson","The Chronicles of Narnia: Prince Caspian","https://upload.wikimedia.org/wikipedia/en/c/c8/Principe_Caspain_poster.jpg"],["Rencontre avec Joe Black",1998,"Martin Brest","Meet Joe Black","https://upload.wikimedia.org/wikipedia/en/f/f5/Meet_Joe_Black-_1998.jpg"],["Star Trek, le film",1979,"Robert Wise","Star Trek: The Motion Picture","https://upload.wikimedia.org/wikipedia/en/d/df/Star_Trek_The_Motion_Picture_poster.png"],["Red",2010,"Robert Schwentke","RED","https://upload.wikimedia.org/wikipedia/en/4/41/Red_ver7.jpg"],["Good Morning, Vietnam",1987,"Barry Levinson","","https://upload.wikimedia.org/wikipedia/en/0/07/Good_morning_vietnam.png"],["Les Looney Tunes passent à l'action",2003,"Joe Dante","Looney Tunes: Back in Action","https://upload.wikimedia.org/wikipedia/en/7/7c/Movie_poster_looney_tunes_back_in_action.JPG"],["Dogville",2003,"Lars von Trier","","https://upload.wikimedia.org/wikipedia/en/1/10/Dogville_poster.jpg"],["Love Story",1970,"Arthur Hiller","","https://upload.wikimedia.org/wikipedia/en/b/b7/Love_Story_%281970_film%29.jpg"],["Training Day",2001,"Antoine Fuqua","","https://upload.wikimedia.org/wikipedia/en/b/b3/Training_Day_Poster.jpg"],["Insaisissables",2013,"Louis Leterrier","Now You See Me","https://upload.wikimedia.org/wikipedia/en/c/c7/Now_You_See_Me_Poster.jpg"],["Karaté Kid",2010,"Harald Zwart","The Karate Kid","https://upload.wikimedia.org/wikipedia/en/d/d5/Karate_kid_ver2.jpg"],["Dumb and Dumber",1994,"Bobby Farrelly, Peter Farrelly","","https://upload.wikimedia.org/wikipedia/en/6/64/Dumbanddumber.jpg"],["Rush Hour",1998,"Brett Ratner","","https://upload.wikimedia.org/wikipedia/en/4/49/Rush_Hour_poster.png"],["Rien que pour vos yeux",1981,"John Glen","For Your Eyes Only","https://thumb.wikimedia.org/wikipedia/en/thumb/c/cd/For_Your_Eyes_Only_-_UK_cinema_poster.jpg/330px-For_Your_Eyes_Only_-_UK_cinema_poster.jpg"],["Batman et Robin",1997,"Joel Schumacher","Batman & Robin","https://upload.wikimedia.org/wikipedia/en/3/37/Batman_%26_Robin_poster.jpg"],["Tron",1982,"Steven Lisberger","","https://upload.wikimedia.org/wikipedia/en/1/17/Tron_poster.jpg"],["O'Brother",2000,"Joel Coen, Ethan Coen","O Brother, Where Art Thou?","https://upload.wikimedia.org/wikipedia/en/5/5b/O_brother_where_art_thou_ver1.jpg"],["L'Enfance d'Ivan",1962,"Andrei Tarkovsky","Ivan's Childhood","https://upload.wikimedia.org/wikipedia/en/9/9c/1962_ivanovo_detstvo.jpg"],["Eraserhead",1977,"David Lynch","","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4f/Eraserhead_-_Filmex_%2777_poster.jpg/330px-Eraserhead_-_Filmex_%2777_poster.jpg"],["Charade",1963,"Stanley Donen","","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fd/Charade_%281963_poster%29.jpg/330px-Charade_%281963_poster%29.jpg"],["Le Charme discret de la bourgeoisie",1972,"Luis Buñuel","The Discreet Charm of the Bourgeoisie","https://upload.wikimedia.org/wikipedia/en/d/d3/Discreet-charm-poster.jpg"],["La Prisonnière du désert",1956,"John Ford","The Searchers","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/59/SearchersPoster-BillGold.jpg/330px-SearchersPoster-BillGold.jpg"],["Madame Miniver",1942,"William Wyler","Mrs. Miniver","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/47/Mrs._Miniver_%281942_poster_-_Style_C%29.jpg/330px-Mrs._Miniver_%281942_poster_-_Style_C%29.jpg"],["Highlander",1986,"Russell Mulcahy","","https://upload.wikimedia.org/wikipedia/en/b/bc/Highlander_1986%2Cposter.jpg"],["Les Dix Commandements",1956,"Cecil B. DeMille","The Ten Commandments","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/df/The_Ten_Commandments_%281956_film_poster%29.jpg/330px-The_Ten_Commandments_%281956_film_poster%29.jpg"],["La Ruée vers l'Ouest",1931,"Wesley Ruggles","Cimarron","https://upload.wikimedia.org/wikipedia/en/9/9e/Cimarron_%281931_film%29_poster.jpg"],["Le Chanteur de jazz",1927,"Alan Crosland","The Jazz Singer","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d2/The_Jazz_Singer_1927_Poster.jpg/330px-The_Jazz_Singer_1927_Poster.jpg"],["Le Tour du monde en quatre-vingts jours",1956,"Michael Anderson, John Farrow","Around the World in 80 Days","https://upload.wikimedia.org/wikipedia/en/5/5e/Around_the_World_in_80_Days_%281956_film%29_poster.jpg"],["Stardust",2007,"Matthew Vaughn","","https://upload.wikimedia.org/wikipedia/en/6/6f/Stardust_promo_poster.jpg"],["Fanny et Alexandre",1982,"Ingmar Bergman","Fanny and Alexander","https://upload.wikimedia.org/wikipedia/en/5/56/Fanny%26Alexander.jpg"],["Magnolia",1999,"Paul Thomas Anderson","","https://upload.wikimedia.org/wikipedia/en/4/4b/Magnolia_poster.png"],["Star Trek 2 : La Colère de Khan",1982,"Nicholas Meyer","Star Trek II: The Wrath of Khan","https://upload.wikimedia.org/wikipedia/en/9/9a/Star_Trek_II_The_Wrath_of_Khan.png"],["Killers of the Flower Moon",2023,"Martin Scorsese","","https://upload.wikimedia.org/wikipedia/en/8/88/Killers_of_the_Flower_Moon_film_poster.jpg"],["Annabelle",2014,"John R. Leonetti","","https://upload.wikimedia.org/wikipedia/en/9/90/Annabelle_film_poster.jpg"],["Tonnerre sous les tropiques",2008,"Ben Stiller","Tropic Thunder","https://upload.wikimedia.org/wikipedia/en/d/d6/Tropic_thunder_ver3.jpg"],["Inferno",2016,"Ron Howard","","https://upload.wikimedia.org/wikipedia/en/6/66/Inferno_%282016_film%29.png"],["Closer, entre adultes consentants",2004,"Mike Nichols","Closer","https://upload.wikimedia.org/wikipedia/en/4/45/Closer_movie_poster.jpg"],["PK",2014,"Rajkumar Hirani","","https://upload.wikimedia.org/wikipedia/en/c/c3/PK_poster.jpg"],["Hulk",2003,"Ang Lee","","https://upload.wikimedia.org/wikipedia/en/5/59/Hulk_movie.jpg"],["True Lies",1994,"James Cameron","","https://upload.wikimedia.org/wikipedia/en/8/81/True_Lies_poster.png"],["Babe, le cochon devenu berger",1995,"Chris Noonan","Babe","https://upload.wikimedia.org/wikipedia/en/6/6f/Babe_ver1.jpg"],["Cruella",2021,"Craig Gillespie","","https://upload.wikimedia.org/wikipedia/en/f/f6/Cruella_2021_film_poster.jpg"],["21 Grammes",2003,"Alejandro González Iñárritu","21 Grams","https://upload.wikimedia.org/wikipedia/en/7/74/21_grams_movie.jpg"],["Le Talentueux Mr Ripley",1999,"Anthony Minghella","The Talented Mr. Ripley","https://upload.wikimedia.org/wikipedia/en/2/22/Talented_mr_ripley.jpg"],["Les Heures sombres",2017,"Joe Wright","Darkest Hour","https://upload.wikimedia.org/wikipedia/en/3/38/Darkest_Hour_poster.png"],["Hannibal",2001,"Ridley Scott","","https://upload.wikimedia.org/wikipedia/en/9/9b/Hannibal_movie_poster.jpg"],["Ocean's Twelve",2004,"Steven Soderbergh","","https://upload.wikimedia.org/wikipedia/en/7/7d/Ocean%27s_Twelve_poster.jpg"],["X-Men: Dark Phoenix",2019,"Simon Kinberg","Dark Phoenix","https://upload.wikimedia.org/wikipedia/en/9/9e/Dark_Phoenix_%28film%29.png"],["Menteur, menteur",1997,"Tom Shadyac","Liar Liar","https://upload.wikimedia.org/wikipedia/en/3/3d/Liar_Liar_poster.JPG"],["Fighter",2010,"David O. Russell","The Fighter","https://upload.wikimedia.org/wikipedia/en/9/93/The_Fighter_Poster.jpg"],["Mission: Impossible – Dead Reckoning Partie 1",2023,"Christopher McQuarrie","Mission: Impossible – Dead Reckoning Part One","https://upload.wikimedia.org/wikipedia/en/e/ed/Mission-_Impossible_%E2%80%93_Dead_Reckoning_Part_One_poster.jpg"],["In the Air",2009,"Jason Reitman","Up in the Air","https://upload.wikimedia.org/wikipedia/en/b/b2/Up_in_the_Air_Poster.jpg"],["Wonder Woman 1984",2020,"Patty Jenkins","","https://upload.wikimedia.org/wikipedia/en/4/4f/Wonder_Woman_1984_poster.png"],["Les Quatre Fantastiques",2015,"Josh Trank","Fantastic Four","https://upload.wikimedia.org/wikipedia/en/f/f4/Fantastic_Four_2015_poster.jpg"],["Hellboy",2004,"Guillermo del Toro","","https://upload.wikimedia.org/wikipedia/en/6/6b/Hellboy_poster.jpg"],["Le Chocolat",2000,"Lasse Hallström","Chocolat","https://upload.wikimedia.org/wikipedia/en/0/08/Chocolat_sheet.jpg"],["Gilbert Grape",1993,"Lasse Hallström","What's Eating Gilbert Grape","https://upload.wikimedia.org/wikipedia/en/5/5c/What%27s_Eating_Gilbert_Grape_poster.png"],["The Big Short",2015,"Adam McKay","","https://upload.wikimedia.org/wikipedia/en/1/16/The_Big_Short_%282015_film_poster%29.png"],["Des hommes d'influence",1997,"Barry Levinson","Wag the Dog","https://upload.wikimedia.org/wikipedia/en/8/85/Wag_The_Dog_Poster.jpg"],["Les Griffes de la nuit",1984,"Wes Craven","A Nightmare on Elm Street","https://upload.wikimedia.org/wikipedia/en/f/fa/A_Nightmare_on_Elm_Street_%281984%29_theatrical_poster.jpg"],["La Dame de fer",2011,"Phyllida Lloyd","The Iron Lady","https://thumb.wikimedia.org/wikipedia/en/thumb/f/f7/Iron_lady_film_poster.jpg/330px-Iron_lady_film_poster.jpg"],["JFK",1991,"Oliver Stone","","https://upload.wikimedia.org/wikipedia/en/2/2c/Jfk1991-xxlg.png"],["Kong: Skull Island",2017,"Jordan Vogt-Roberts","","https://upload.wikimedia.org/wikipedia/en/3/34/Kong_Skull_Island_poster.jpg"],["Terminator: Dark Fate",2019,"Tim Miller","","https://upload.wikimedia.org/wikipedia/en/5/5f/Terminator_Dark_Fate_poster.jpg"],["L'Arme fatale",1987,"Richard Donner","Lethal Weapon","https://upload.wikimedia.org/wikipedia/en/d/d9/Lethal_weapon1.jpg"],["Le Cercle",2002,"Gore Verbinski","The Ring","https://upload.wikimedia.org/wikipedia/en/3/37/Theringpostere.jpg"],["Zodiac",2007,"David Fincher","","https://upload.wikimedia.org/wikipedia/en/3/3a/Zodiac2007Poster.jpg"],["The Blind Side",2009,"John Lee Hancock","","https://upload.wikimedia.org/wikipedia/en/6/60/Blind_side_poster.jpg"],["Commando",1985,"Mark L. Lester","","https://upload.wikimedia.org/wikipedia/en/d/d9/Commandoposter.jpg"],["Men in Black 3",2012,"Barry Sonnenfeld","","https://upload.wikimedia.org/wikipedia/en/8/8a/Men_In_Black_3.jpg"],["Alvin et les Chipmunks 3",2011,"Mike Mitchell","Alvin and the Chipmunks: Chipwrecked","https://upload.wikimedia.org/wikipedia/en/c/cc/Alvin_and_the_Chipmunks_3_teaser.jpg"],["Oblivion",2013,"Joseph Kosinski","","https://upload.wikimedia.org/wikipedia/en/2/2e/Oblivion2013Poster.jpg"],["Amour et Amnésie",2004,"Peter Segal","50 First Dates","https://upload.wikimedia.org/wikipedia/en/9/9d/50FirstDates.jpg"],["Constantine",2005,"Francis Lawrence","","https://upload.wikimedia.org/wikipedia/en/2/2b/Constantine_poster.jpg"],["The Dictator",2012,"Larry Charles","","https://upload.wikimedia.org/wikipedia/en/4/4b/The_Dictator_Poster.jpg"],["Le Petit Monde de Charlotte",2006,"Gary Winick","Charlotte's Web","https://upload.wikimedia.org/wikipedia/en/c/c9/Charlotte%27s_Web_2006.jpg"],["Les Sentiers de la gloire",1957,"Stanley Kubrick","Paths of Glory","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fa/Paths_of_Glory_%281957_poster%29.jpg/330px-Paths_of_Glory_%281957_poster%29.jpg"],["Les 39 Marches",1935,"Alfred Hitchcock","The 39 Steps","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/ce/The_39_Steps_%281935%29_-_poster.jpg/330px-The_39_Steps_%281935%29_-_poster.jpg"],["Andreï Roublev",1966,"Andrei Tarkovsky","Andrei Rublev","https://upload.wikimedia.org/wikipedia/en/a/ae/Andrei_Rublev_Russian_poster.jpg"],["Le Cirque",1928,"Charlie Chaplin","The Circus","https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4f/The_Circus_%281928%29_-_Hap_Hadley_poster.jpg/330px-The_Circus_%281928%29_-_Hap_Hadley_poster.jpg"],["La Vie d'Adèle",2013,"Abdellatif Kechiche","Blue Is the Warmest Colour","https://upload.wikimedia.org/wikipedia/en/3/3e/La_Vie_d%27Ad%C3%A8le_film_poster.png"],["Mississippi Burning",1988,"Alan Parker","","https://upload.wikimedia.org/wikipedia/en/e/e9/Mississippi_Burning.jpg"],["Le Guépard",1963,"Luchino Visconti","The Leopard","https://upload.wikimedia.org/wikipedia/en/2/28/OLeopardo.jpg"],["Le Garde du corps",1961,"Akira Kurosawa","Yojimbo","https://upload.wikimedia.org/wikipedia/en/7/74/Yojimbo_film_poster.jpg"],["Blade",1998,"Stephen Norrington","","https://upload.wikimedia.org/wikipedia/en/1/19/Blade_movie.jpg"],["Hunger Games : La Révolte, partie 1",2014,"Francis Lawrence","The Hunger Games: Mockingjay – Part 1","https://upload.wikimedia.org/wikipedia/en/6/63/MockingjayPart1Poster3.jpg"],["John Rambo",2008,"Sylvester Stallone","Rambo","https://upload.wikimedia.org/wikipedia/en/5/52/Rambo_%282008%29_poster.jpg"],["Rocky 4",1985,"Sylvester Stallone","Rocky IV","https://upload.wikimedia.org/wikipedia/en/9/95/Rocky_IV.jpg"],["Rocky 2",1979,"Sylvester Stallone","Rocky II","https://upload.wikimedia.org/wikipedia/en/b/bc/Rocky_ii_poster.jpg"],["Transformers: The Last Knight",2017,"Michael Bay","","https://upload.wikimedia.org/wikipedia/en/2/26/Transformers_The_Last_Knight_poster.jpg"],["M le maudit",1931,"Fritz Lang","M","https://upload.wikimedia.org/wikipedia/en/a/ab/M_poster.jpg"],["Bob l'éponge, le film : Un héros sort de l'eau",2015,"Mike Mitchell, Paul Tibbitt","The SpongeBob Movie: Sponge Out of Water","https://upload.wikimedia.org/wikipedia/en/5/54/The_SpongeBob_Movie%2C_Sponge_Out_of_Water_%282015_film%29.jpg"],["Cloud Atlas",2012,"Tom Tykwer, Lilly Wachowski, Lana Wachowski","","https://upload.wikimedia.org/wikipedia/en/2/20/Cloud_Atlas_Poster.jpg"],["Jupiter : Le Destin de l'univers",2015,"Lana Wachowski, Lilly Wachowski","Jupiter Ascending","https://upload.wikimedia.org/wikipedia/en/7/76/%27Jupiter_Ascending%27_Theatrical_Poster.jpg"],["La Chevauchée fantastique",1939,"John Ford","Stagecoach","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/00/Stagecoach_%281939_poster%29.jpg/330px-Stagecoach_%281939_poster%29.jpg"],["Comme des bêtes 2",2019,"Chris Renaud","The Secret Life of Pets 2","https://upload.wikimedia.org/wikipedia/en/e/eb/The_Secret_Life_of_Pets_2_%282019%29_Final_Poster.jpg"],["Le Jour le plus long",1962,"Bernhard Wicki, Darryl F. Zanuck, Gerd Oswald, Ken Annakin","The Longest Day","https://upload.wikimedia.org/wikipedia/en/7/79/Original_movie_poster_for_the_film_The_Longest_Day.jpg"],["Raison et Sentiments",1995,"Ang Lee","Sense and Sensibility","https://upload.wikimedia.org/wikipedia/en/6/69/Sense_and_sensibility.jpg"],["La Légende de Beowulf",2007,"Robert Zemeckis","Beowulf","https://upload.wikimedia.org/wikipedia/en/5/54/Beowulf_%282007_film%29.png"],["Carrie au bal du diable",1976,"Brian De Palma","Carrie","https://upload.wikimedia.org/wikipedia/en/d/d7/Carrieposter.jpg"],["Retour à Cold Mountain",2003,"Anthony Minghella","Cold Mountain","https://upload.wikimedia.org/wikipedia/en/2/2a/Cold_Mountain_Poster.jpg"],["Billy Elliot",2000,"Stephen Daldry","","https://thumb.wikimedia.org/wikipedia/en/thumb/3/31/Billy_Elliot_movie.jpg/330px-Billy_Elliot_movie.jpg"],["Captain America: New World Order",2025,"Julius Onah","Captain America: Brave New World","https://upload.wikimedia.org/wikipedia/en/a/a4/Captain_America_Brave_New_World_poster.jpg"],["Lady Bird",2017,"Greta Gerwig","","https://upload.wikimedia.org/wikipedia/en/6/61/Lady_Bird_poster.jpeg"],["Le Parfum",2006,"Tom Tykwer","Perfume: The Story of a Murderer","https://upload.wikimedia.org/wikipedia/en/6/69/Perfume_poster.jpg"],["Tron : L'Héritage",2010,"Joseph Kosinski","Tron: Legacy","https://upload.wikimedia.org/wikipedia/en/c/c2/Tron_Legacy_poster.jpg"],["John Wick : Chaptire 4",2023,"Chad Stahelski","John Wick: Chapter 4","https://upload.wikimedia.org/wikipedia/en/d/d0/John_Wick_-_Chapter_4_promotional_poster.jpg"],["Tueurs nés",1994,"Oliver Stone","Natural Born Killers","https://upload.wikimedia.org/wikipedia/en/a/a5/Natural_Born_Killers.jpg"],["Twilight, chapitre V : Révélation, partie 2",2012,"Bill Condon","The Twilight Saga: Breaking Dawn – Part 2","https://upload.wikimedia.org/wikipedia/en/4/49/The_Twilight_Saga_Breaking_Dawn_Part_2_poster.jpg"],["Sonic 3, le film",2024,"Jeff Fowler","Sonic the Hedgehog 3","https://upload.wikimedia.org/wikipedia/en/f/f2/Sonic_the_Hedgehog_3_film_poster.jpg"],["À couteaux tirés",2019,"Rian Johnson","Knives Out","https://upload.wikimedia.org/wikipedia/en/1/1f/Knives_Out_poster.jpeg"],["Prince of Persia : Les Sables du Temps",2010,"Mike Newell","Prince of Persia: The Sands of Time","https://upload.wikimedia.org/wikipedia/en/d/df/Prince_of_Persia_poster.jpg"],["Le Sourire de Mona Lisa",2003,"Mike Newell","Mona Lisa Smile","https://upload.wikimedia.org/wikipedia/en/0/0e/Monalisasmile.jpg"],["The Substance",2024,"Coralie Fargeat","","https://upload.wikimedia.org/wikipedia/en/f/ff/The_Substance_poster.jpg"],["Misery",1990,"Rob Reiner","","https://upload.wikimedia.org/wikipedia/en/5/52/Misery_%281990_film_poster%29.png"],["Le Dernier Roi d'Écosse",2006,"Kevin Macdonald","The Last King of Scotland","https://thumb.wikimedia.org/wikipedia/en/thumb/d/d9/Last_king_of_scotland_uk.jpg/330px-Last_king_of_scotland_uk.jpg"],["Yes Man",2008,"Peyton Reed","","https://upload.wikimedia.org/wikipedia/en/7/71/YesMan2008poster.jpg"],["Frankenstein",1931,"James Whale","","https://thumb.wikimedia.org/wikipedia/commons/thumb/9/92/Frankenstein_poster_1931.jpg/330px-Frankenstein_poster_1931.jpg"],["28 Jours plus tard",2002,"Danny Boyle","28 Days Later","https://thumb.wikimedia.org/wikipedia/en/thumb/e/e4/28_days_later.jpg/330px-28_days_later.jpg"],["Sept Ans au Tibet",1997,"Jean-Jacques Annaud","Seven Years in Tibet","https://upload.wikimedia.org/wikipedia/en/9/97/Seven_Years_in_Tibet_cover.jpeg"],["L'Évadé d'Alcatraz",1979,"Don Siegel","Escape from Alcatraz","https://upload.wikimedia.org/wikipedia/en/0/0d/Escape_from_alcatraz.jpg"],["Drive",2011,"Nicolas Winding Refn","","https://upload.wikimedia.org/wikipedia/en/1/13/Drive2011Poster.jpg"],["Le Dragon récalcitrant",1941,"Erwin Verity, Jasper Blystone, Ford Beebe Jr., Jim Handley, Alfred L. Werker, Hamilton Luske","The Reluctant Dragon","https://upload.wikimedia.org/wikipedia/en/f/fe/Reluctant_Dragon.jpg"],["Millénium, les hommes qui n'aimaient pas les femmes",2011,"David Fincher","The Girl with the Dragon Tattoo","https://upload.wikimedia.org/wikipedia/en/8/80/The_Girl_with_the_Dragon_Tattoo_Poster.jpg"],["La Chatte sur un toit brûlant",1958,"Richard Brooks","Cat on a Hot Tin Roof","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/51/Cat_roof.jpg/330px-Cat_roof.jpg"],["Les Fous du roi",1950,"Robert Rossen","All the King's Men","https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a1/All_the_King%27s_Men_%281949_film_poster%29.jpg/330px-All_the_King%27s_Men_%281949_film_poster%29.jpg"],["Le Dernier des Mohicans",1992,"Michael Mann","The Last of the Mohicans","https://upload.wikimedia.org/wikipedia/en/d/dd/Mohicansposter.jpg"],["Midnight Express",1978,"Alan Parker","","https://upload.wikimedia.org/wikipedia/en/5/52/Original_poster_for_Midnight_Express%2C_1978.jpg"],["Les Quatre Fantastiques et le Surfer d'argent",2007,"Tim Story","Fantastic Four: Rise of the Silver Surfer","https://upload.wikimedia.org/wikipedia/en/e/e6/Fantastic_Four_2_Poster.jpg"],["Hop",2011,"Tim Hill","","https://upload.wikimedia.org/wikipedia/en/b/b5/Hop_%282011%29_US_Poster.jpg"],["Il était une fois",2007,"Kevin Lima","Enchanted","https://upload.wikimedia.org/wikipedia/en/2/2a/Enchantedposter.jpg"],["Le Roi Arthur",2004,"Antoine Fuqua","King Arthur","https://upload.wikimedia.org/wikipedia/en/5/59/Movie_poster_king_arthur.jpg"],["Lara Croft: Tomb Raider",2001,"Simon West","","https://upload.wikimedia.org/wikipedia/en/0/00/Lara_Croft_-_Tomb_Raider.png"],["La Famille indienne",2001,"Karan Johar","Sometimes Happiness Sometimes Sadness...","https://upload.wikimedia.org/wikipedia/en/4/4d/Kabhi_Khushi_Kabhie_Gham..._poster.jpg"],["Laisse parler ton cœur",1998,"Karan Johar","Kuch Kuch Hota Hai","https://upload.wikimedia.org/wikipedia/en/0/07/Kuch_Kuch_Hota_Hai_poster.jpg"],["Evil Dead",1981,"Sam Raimi","The Evil Dead","https://upload.wikimedia.org/wikipedia/en/7/7d/Evil_dead_ver1.jpg"],["Maman, je m'occupe des méchants !",1997,"Raja Gosnell","Home Alone 3","https://upload.wikimedia.org/wikipedia/en/c/cc/Home_Alone_3_film.jpg"],["La Môme",2007,"Olivier Dahan","La Vie en Rose","https://upload.wikimedia.org/wikipedia/en/1/1c/La_Vie_en_Rose_poster.png"],["Ready Player One",2018,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/7/74/Ready_Player_One_%28film%29.png"],["Mélodie du Sud",1946,"Wilfred Jackson, Harve Foster","Song of the South","https://thumb.wikimedia.org/wikipedia/commons/thumb/6/66/Song_of_the_South_%28three_sheet_poster%29.jpg/330px-Song_of_the_South_%28three_sheet_poster%29.jpg"],["Le Retour de Mary Poppins",2018,"Rob Marshall","Mary Poppins Returns","https://upload.wikimedia.org/wikipedia/en/4/48/Mary_Poppins_Returns_%282018_film_poster%29.png"],["Le Cabinet du docteur Caligari",1920,"Robert Wiene","The Cabinet of Dr. Caligari","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/52/Das_Cabinet_des_Dr._Caligari.JPG/330px-Das_Cabinet_des_Dr._Caligari.JPG"],["The Flash",2023,"Andy Muschietti","","https://upload.wikimedia.org/wikipedia/en/e/ed/The_Flash_%28film%29_poster.jpg"],["Ça : Chapitre 2",2019,"Andy Muschietti","It: Chapter Two","https://upload.wikimedia.org/wikipedia/en/d/d8/It_Chapter_Two_Poster.jpg"],["Mortal Engines",2018,"Christian Rivers","","https://upload.wikimedia.org/wikipedia/en/1/19/MortalEngines2018poster.jpg"],["La Favorite",2018,"Yorgos Lanthimos","The Favourite","https://thumb.wikimedia.org/wikipedia/en/thumb/c/cc/The_Favourite.png/330px-The_Favourite.png"],["Pauvres Créatures",2023,"Yorgos Lanthimos","Poor Things","https://upload.wikimedia.org/wikipedia/en/f/f3/Poor_Things_poster.jpg"],["Les Filles du docteur March",2019,"Greta Gerwig","Little Women","https://upload.wikimedia.org/wikipedia/en/9/9d/Little_Women_%282019_film%29.jpeg"],["Le Grand Ziegfeld",1936,"Robert Z. Leonard","The Great Ziegfeld","https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a7/Great-Ziegfeld-1936-Poster.jpg/330px-Great-Ziegfeld-1936-Poster.jpg"],["Fast and Furious X",2023,"Louis Leterrier","Fast X","https://upload.wikimedia.org/wikipedia/en/f/f2/Fast_X_poster.jpg"],["The Fantastic Four: First Steps",2025,"Matt Shakman","","https://upload.wikimedia.org/wikipedia/en/1/13/The_Fantastic_Four_First_Steps_poster.jpg"],["La Route semée d'étoiles",1944,"Leo McCarey","Going My Way","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/df/Going_My_Way_%281944_poster%29.jpg/330px-Going_My_Way_%281944_poster%29.jpg"],["La Corde",1948,"Alfred Hitchcock","Rope","https://upload.wikimedia.org/wikipedia/en/8/8e/Rope2.jpg"],["L'Ombre d'un doute",1943,"Alfred Hitchcock","Shadow of a Doubt","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fa/Shadow_of_a_Doubt_%281942_poster_-_Style_C%29.jpg/330px-Shadow_of_a_Doubt_%281942_poster_-_Style_C%29.jpg"],["Les Raisins de la colère",1940,"John Ford","The Grapes of Wrath","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c1/The_Grapes_of_Wrath_%281940_poster%29.jpg/330px-The_Grapes_of_Wrath_%281940_poster%29.jpg"],["Phantom Thread",2017,"Paul Thomas Anderson","","https://upload.wikimedia.org/wikipedia/en/1/1e/Phantom_Thread.png"],["Assurance sur la mort",1944,"Billy Wilder","Double Indemnity","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/ce/Double_Indemnity_%281944_poster%29.jpg/330px-Double_Indemnity_%281944_poster%29.jpg"],["La Vie d'Émile Zola",1937,"William Dieterle","The Life of Emile Zola","https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7c/The_Life_of_Emile_Zola_%281937_film_poster%29.jpg/330px-The_Life_of_Emile_Zola_%281937_film_poster%29.jpg"],["En eaux troubles",2018,"Jon Turteltaub","The Meg","https://upload.wikimedia.org/wikipedia/en/a/a5/The_Meg_2018_film_cover.png"],["John Wick: Chaptire 3 – Parabellum",2019,"Chad Stahelski","John Wick: Chapter 3 – Parabellum","https://upload.wikimedia.org/wikipedia/en/9/94/John_Wick_Chapter_3_Parabellum.png"],["Conclave",2024,"Edward Berger","","https://upload.wikimedia.org/wikipedia/en/7/76/Conclave_film_poster.jpg"],["The Greatest Showman",2017,"Michael Gracey","","https://upload.wikimedia.org/wikipedia/en/1/10/The_Greatest_Showman_poster.png"],["The Marvels",2023,"Nia DaCosta","","https://upload.wikimedia.org/wikipedia/en/7/7a/The_Marvels_poster.jpg"],["Mulan",2020,"Niki Caro","","https://upload.wikimedia.org/wikipedia/en/1/17/Mulan_%282020_film%29_poster.jpg"],["Le Mans 66",2019,"James Mangold","Ford v Ferrari","https://upload.wikimedia.org/wikipedia/en/a/a4/Ford_v._Ferrari_%282019_film_poster%29.png"],["Jumanji: Next Level",2019,"Jake Kasdan","Jumanji: The Next Level","https://upload.wikimedia.org/wikipedia/en/1/12/Jumanji_-The_Next_Level_film_poster.jpg"],["Bumblebee",2018,"Travis Knight","","https://upload.wikimedia.org/wikipedia/en/7/77/Bumblebee_%28film%29_poster.png"],["Les Enchaînés",1946,"Alfred Hitchcock","Notorious","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/04/Notorious_%281946_film_poster%29.jpg/330px-Notorious_%281946_film_poster%29.jpg"],["Cavalcade",1933,"Frank Lloyd","","https://upload.wikimedia.org/wikipedia/en/3/3f/Cavalcade_film_poster.jpg"],["Dilwale Dulhania Le Jayenge",1995,"Aditya Chopra","","https://upload.wikimedia.org/wikipedia/en/8/80/Dilwale_Dulhania_Le_Jayenge_poster.jpg"],["Pentagon Papers",2017,"Steven Spielberg","The Post","https://upload.wikimedia.org/wikipedia/en/0/0b/The_Post_%28film%29.png"],["Les Aventures de Robin des Bois",1938,"Michael Curtiz, William Keighley","The Adventures of Robin Hood","https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f7/The_Adventures_of_Robin_Hood_%281938_poster%29.jpg/330px-The_Adventures_of_Robin_Hood_%281938_poster%29.jpg"],["Dracula",1931,"Tod Browning, Karl Freund","","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/04/Dracula_%281931_film_poster_-_Style_F%29.jpg/330px-Dracula_%281931_film_poster_-_Style_F%29.jpg"],["Vous ne l'emporterez pas avec vous",1938,"Frank Capra","You Can't Take It With You","https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d1/You_Can%27t_Take_it_With_You_film_poster.jpg/330px-You_Can%27t_Take_it_With_You_film_poster.jpg"],["Moi, Tonya",2017,"Craig Gillespie","I, Tonya","https://upload.wikimedia.org/wikipedia/en/0/0e/I%2C_Tonya_%282017_film%29.png"],["Angry Birds : Copains comme cochons",2019,"Thurop Van Orman","The Angry Birds Movie 2","https://upload.wikimedia.org/wikipedia/en/1/11/The_Angry_Birds_Movie_2_%282019_film%29.jpg"],["Wicked",2024,"Jon M. Chu","","https://upload.wikimedia.org/wikipedia/en/3/3c/Wicked_%282024_film%29_poster.png"],["Joker: Folie à Deux",2024,"Todd Phillips","","https://upload.wikimedia.org/wikipedia/en/e/e8/Joker_-_Folie_%C3%A0_Deux_poster.jpg"],["Projet Dernière Chance",2026,"Christopher Miller, Phil Lord","Project Hail Mary","https://upload.wikimedia.org/wikipedia/en/3/3b/Project_Hail_Mary_poster.jpg"],["Thunderbolts*",2025,"Jake Schreier","","https://upload.wikimedia.org/wikipedia/en/9/90/Thunderbolts%2A_poster.jpg"],["Venom: The Last Dance",2024,"Kelly Marcel","","https://upload.wikimedia.org/wikipedia/en/a/a3/Venom_The_Last_Dance_Poster.jpg"],["Mission impossible 8",2025,"Christopher McQuarrie","Mission: Impossible – The Final Reckoning","https://upload.wikimedia.org/wikipedia/en/1/1f/Mission_Impossible_%E2%80%93_The_Final_Reckoning_Poster.jpg"],["Sinners",2025,"Ryan Coogler","","https://upload.wikimedia.org/wikipedia/en/5/5f/Sinners_%282025_film%29_poster.jpg"],["Abominable",2019,"Todd Wilderman, Jill Culton","","https://upload.wikimedia.org/wikipedia/en/1/10/Abominable_%282019_poster%29.png"],["Birds of Prey et la fantabuleuse histoire de Harley Quinn",2020,"Cathy Yan","Birds of Prey and the Fantabulous Emancipation of One Harley Quinn","https://upload.wikimedia.org/wikipedia/en/1/1c/Birds_of_Prey_%282020_film%29_poster.jpg"],["The Father",2020,"Florian Zeller","","https://thumb.wikimedia.org/wikipedia/en/thumb/a/ab/The_Father_2020_poster.jpg/330px-The_Father_2020_poster.jpg"],["Bullet Train",2022,"David Leitch","","https://upload.wikimedia.org/wikipedia/en/1/13/Bullet_Train_%28poster%29.jpeg"],["La Maison du docteur Edwardes",1945,"Alfred Hitchcock","Spellbound","https://upload.wikimedia.org/wikipedia/en/d/d2/Spellbound_original.jpg"],["Michael",2026,"Antoine Fuqua","","https://upload.wikimedia.org/wikipedia/en/3/37/Michael_%282026_film_poster%29.png"],["Jurassic World: Renaissance",2025,"Gareth Edwards","Jurassic World Rebirth","https://upload.wikimedia.org/wikipedia/en/a/a5/Jurassic_World_Rebirth_poster.jpg"],["L'Impossible Monsieur Bébé",1938,"Howard Hawks","Bringing Up Baby","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/20/Bringing_Up_Baby_%281938_poster%29.jpg/330px-Bringing_Up_Baby_%281938_poster%29.jpg"],["F1",2025,"Joseph Kosinski","","https://upload.wikimedia.org/wikipedia/en/3/38/F1_%282025_film%29.png"],["Les Animaux fantastiques: Les Secrets de Dumbledore",2022,"David Yates","Fantastic Beasts: The Secrets of Dumbledore","https://upload.wikimedia.org/wikipedia/en/3/34/Fantastic_Beasts-_The_Secrets_of_Dumbledore.png"],["Le Mécano de la « General »",1926,"Buster Keaton, Clyde Bruckman","The General","https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/The_General_%281926%29_-_Movie_Poster_2.png/330px-The_General_%281926%29_-_Movie_Poster_2.png"],["Le Triomphe de la volonté",1935,"Leni Riefenstahl","Triumph of the Will","https://upload.wikimedia.org/wikipedia/en/1/1a/Triumph_des_Willens_poster.jpg"],["L'Aurore",1927,"F. W. Murnau","Sunrise: A Song of Two Humans","https://thumb.wikimedia.org/wikipedia/commons/thumb/2/27/Sunrise_-_A_Song_of_Two_Humans.jpg/330px-Sunrise_-_A_Song_of_Two_Humans.jpg"],["Sans un bruit",2018,"John Krasinski","A Quiet Place","https://upload.wikimedia.org/wikipedia/en/a/a0/A_Quiet_Place_film_poster.png"],["Godzilla II : Roi des monstres",2019,"Michael Dougherty","Godzilla: King of the Monsters","https://upload.wikimedia.org/wikipedia/en/9/9a/Godzilla_%E2%80%93_King_of_the_Monsters_%282019%29_poster.png"],["Uncharted",2022,"Ruben Fleischer","","https://upload.wikimedia.org/wikipedia/en/d/d4/Uncharted_Official_Poster.jpg"],["Black Adam",2022,"Jaume Collet-Serra","","https://upload.wikimedia.org/wikipedia/en/a/a9/Black_Adam_%28film%29_poster.jpg"],["Dumbo",2019,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/9/91/Dumbo_%282019_film%29.png"],["Hantise",1944,"George Cukor","Gaslight","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5f/Gaslight_%281944_poster%29.jpg/330px-Gaslight_%281944_poster%29.jpg"],["Blanche-Neige",2025,"Marc Webb","Snow White","https://upload.wikimedia.org/wikipedia/en/1/1f/Snow_White_%282025_film%29_final_poster.jpg"],["Elvis",2022,"Baz Luhrmann","","https://upload.wikimedia.org/wikipedia/en/7/79/Elvis_2022_poster.jpg"],["Hôtel Transylvanie 4",2022,"Derek Drymon, Jennifer Kluska","Hotel Transylvania: Transformania","https://upload.wikimedia.org/wikipedia/en/8/8b/Hotel_Transylvania_Transformania.jpg"],["Space Jam : Nouvelle Ère",2021,"Malcolm D. Lee, Spike Brandt","Space Jam: A New Legacy","https://upload.wikimedia.org/wikipedia/en/b/b7/SpaceJamANewLegacyOfficialPoster.jpg"],["Godzilla vs Kong",2021,"Adam Wingard","Godzilla vs. Kong","https://upload.wikimedia.org/wikipedia/en/6/63/Godzilla_vs._Kong.png"],["CODA",2021,"Siân Héder","","https://upload.wikimedia.org/wikipedia/en/8/89/Coda_poster.jpeg"],["Hamlet",1948,"Laurence Olivier","","https://upload.wikimedia.org/wikipedia/en/d/d3/Amleto48-01.jpg"],["Une femme disparaît",1938,"Alfred Hitchcock","The Lady Vanishes","https://upload.wikimedia.org/wikipedia/en/1/1e/The_Lady_Vanishes_1938_Poster.jpg"],["Alexandre Nevski",1938,"Sergei Eisenstein, Dmitri Vasilyev","Alexander Nevsky","https://upload.wikimedia.org/wikipedia/en/a/a5/Alexander_Nevsky_Poster.jpg"],["Rome, ville ouverte",1945,"Roberto Rossellini","Rome, Open City","https://upload.wikimedia.org/wikipedia/en/1/19/Open_City_DVD.jpg"],["BlacKkKlansman",2018,"Spike Lee","","https://upload.wikimedia.org/wikipedia/en/d/d5/BlacKkKlansman.png"],["Le Trésor de la Sierra Madre",1948,"John Huston","The Treasure of the Sierra Madre","https://thumb.wikimedia.org/wikipedia/commons/thumb/1/1d/The_Treasure_of_the_Sierra_Madre_%281947_poster%29.jpg/330px-The_Treasure_of_the_Sierra_Madre_%281947_poster%29.jpg"],["Le Mur invisible",1947,"Elia Kazan","Gentleman's Agreement","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c3/Gentleman%27s_Agreement_%281947_poster%29.jpg/330px-Gentleman%27s_Agreement_%281947_poster%29.jpg"],["La Soupe au canard",1933,"Leo McCarey","Duck Soup","https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c7/Duck_Soup_%281933_poster%2C_Style_B_half_sheet%29.jpeg/330px-Duck_Soup_%281933_poster%2C_Style_B_half_sheet%29.jpeg"],["Anatomie d'une chute",2023,"Justine Triet","Anatomy of a Fall","https://upload.wikimedia.org/wikipedia/en/8/88/Anatomy_of_a_Fall_%282023%29_film_poster.jpg"],["Indiscrétions",1940,"George Cukor","The Philadelphia Story","https://thumb.wikimedia.org/wikipedia/commons/thumb/5/54/The-Philadelphia-Story-%281940%29.jpg/330px-The-Philadelphia-Story-%281940%29.jpg"],["Ocean’s 8",2018,"Gary Ross","Ocean's 8","https://upload.wikimedia.org/wikipedia/en/d/dd/OceansEightPoster.jpeg"],["Morbius",2022,"Daniel Espinosa","","https://upload.wikimedia.org/wikipedia/en/2/2f/Morbius_%28film%29_poster.jpg"],["Ad Astra",2019,"James Gray","","https://upload.wikimedia.org/wikipedia/en/c/cb/Ad_Astra_-_film_poster.jpg"],["La Nonne",2018,"Corin Hardy","The Nun","https://upload.wikimedia.org/wikipedia/en/3/34/TheNunPoster.jpg"],["Enola Holmes",2020,"Harry Bradbeer","","https://upload.wikimedia.org/wikipedia/en/e/e6/Enola_Holmes_poster.jpeg"],["RRR",2022,"S. S. Rajamouli","","https://upload.wikimedia.org/wikipedia/en/d/d7/RRR_Poster.jpg"],["Emilia Pérez",2024,"Jacques Audiard","","https://upload.wikimedia.org/wikipedia/en/2/29/Emilia_P%C3%A9rez_film_poster.png"],["28 Ans plus tard",2025,"Danny Boyle","28 Years Later","https://upload.wikimedia.org/wikipedia/en/3/38/28_Years_Later_film_poster.jpg"],["La Zone d'intérêt",2023,"Jonathan Glazer","The Zone of Interest","https://upload.wikimedia.org/wikipedia/en/2/24/The_Zone_of_Interest_film_poster.jpg"],["Furiosa",2024,"George Miller","Furiosa: A Mad Max Saga","https://upload.wikimedia.org/wikipedia/en/3/34/Furiosa_A_Mad_Max_Saga.jpg"],["Marriage Story",2019,"Noah Baumbach","","https://upload.wikimedia.org/wikipedia/en/5/55/MarriageStoryPoster.png"],["La Petite Sirène",2023,"Rob Marshall","The Little Mermaid","https://upload.wikimedia.org/wikipedia/en/f/f4/The_Little_Mermaid_%282023_film%29.png"],["Napoléon",2023,"Ridley Scott","Napoleon","https://upload.wikimedia.org/wikipedia/en/2/2e/Napoleon_Film_poster.jpg"],["The Power of the Dog",2021,"Jane Campion","","https://upload.wikimedia.org/wikipedia/en/6/6d/The_Power_of_the_Dog_%28film%29.jpg"],["Annihilation",2018,"Alex Garland","","https://upload.wikimedia.org/wikipedia/en/f/f6/Annihilation_%28film%29.png"],["First Man: Le Premier Homme sur le lune",2018,"Damien Chazelle","First Man","https://upload.wikimedia.org/wikipedia/en/a/a8/First_Man_%28film%29.png"],["Bob l'éponge, le film : Éponge en eaux troubles",2020,"Tim Hill","The SpongeBob Movie: Sponge on the Run","https://upload.wikimedia.org/wikipedia/en/3/34/The_SpongeBob_Movie_-_Sponge_on_the_Run.png"],["Love, Simon",2018,"Greg Berlanti","","https://upload.wikimedia.org/wikipedia/en/b/bc/Love%2C_Simon_poster.png"],["Les Nouveaux Mutants",2020,"Josh Boone","The New Mutants","https://upload.wikimedia.org/wikipedia/en/1/1a/TheNewMutantsPoster.jpeg"],["The King's Man : Première Mission",2021,"Matthew Vaughn","The King's Man","https://upload.wikimedia.org/wikipedia/en/6/67/The_King%27s_Man.jpg"],["Wonka",2023,"Paul King","","https://upload.wikimedia.org/wikipedia/en/9/90/Wonka_2023_film_poster.jpg"],["SOS Fantômes : L'Héritage",2021,"Jason Reitman","Ghostbusters: Afterlife","https://upload.wikimedia.org/wikipedia/en/d/d1/Ghostbusters_-_Afterlife_official_theatrical_poster.jpg"],["Pokémon: Détective Pikachu",2019,"Rob Letterman","Detective Pikachu","https://upload.wikimedia.org/wikipedia/en/e/e5/Pok%C3%A9mon_Detective_Pikachu_teaser_poster.jpg"],["Zack Snyder's Justice League",2021,"Zack Snyder","","https://upload.wikimedia.org/wikipedia/en/6/60/Zack_Snyder%27s_Justice_League.png"],["Les Deux Papes",2019,"Fernando Meirelles","The Two Popes","https://upload.wikimedia.org/wikipedia/en/0/02/The_Two_Popes_poster.png"],["The Gentlemen",2019,"Guy Ritchie","","https://upload.wikimedia.org/wikipedia/en/0/06/The_Gentlemen_poster.jpg"],["Men in Black: International",2019,"F. Gary Gray","","https://upload.wikimedia.org/wikipedia/en/1/1b/Men_in_Black_International_%28Official_Film_Poster%29.png"],["Sans filtre",2022,"Ruben Östlund","Triangle of Sadness","https://upload.wikimedia.org/wikipedia/en/2/2d/TriangleOfSadness2022Poster.jpg"],["The Brutalist",2024,"Brady Corbet","","https://upload.wikimedia.org/wikipedia/en/7/7c/TheBrutalist2024.png"],["Backrooms",2026,"Kane Parsons","","https://upload.wikimedia.org/wikipedia/en/3/3d/Backrooms_%28film%29_poster.jpg"],["Annabelle : La Maison du mal",2019,"Gary Dauberman","Annabelle Comes Home","https://upload.wikimedia.org/wikipedia/en/5/50/AnnabelleComesHomePoster.jpg"],["Aquaman et le Royaume perdu",2023,"James Wan","Aquaman and the Lost Kingdom","https://upload.wikimedia.org/wikipedia/en/4/4a/Aquaman_and_the_Lost_Kingdom_poster.jpg"],["Johnny English 3",2018,"David Kerr","Johnny English Strikes Again","https://upload.wikimedia.org/wikipedia/en/f/fc/Johnny_English_Strikes_Again_poster.jpg"],["Mamma Mia! Here We Go Again",2018,"Ol Parker","","https://upload.wikimedia.org/wikipedia/en/b/be/Mamma_Mia%21_Here_We_Go_Again.png"],["À l'Ouest, rien de nouveau",2022,"Edward Berger","All Quiet on the Western Front","https://upload.wikimedia.org/wikipedia/en/c/c3/All_quiet_on_the_western_front_%282022_film%29.jpg"],["La Planète des singes : Le Nouveau Royaume",2024,"Wes Ball","Kingdom of the Planet of the Apes","https://upload.wikimedia.org/wikipedia/en/c/cf/Kingdom_of_the_Planet_of_the_Apes_poster.jpg"],["Les Goonies",1985,"Richard Donner","The Goonies","https://upload.wikimedia.org/wikipedia/en/c/c6/The_Goonies.jpg"],["West Side Story",2021,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/2/2e/West_Side_Story_2021_Official_Poster.jpg"],["Free Guy",2021,"Shawn Levy","","https://upload.wikimedia.org/wikipedia/en/1/1c/Free_Guy_2021_Poster.jpg"],["The Whale",2022,"Darren Aronofsky","","https://upload.wikimedia.org/wikipedia/en/f/f3/TheWhalePoster.jpg"],["Bird Box",2018,"Susanne Bier","","https://upload.wikimedia.org/wikipedia/en/b/bd/Bird_Box_%28film%29.png"],["Tomb Raider",2018,"Roar Uthaug","","https://upload.wikimedia.org/wikipedia/en/b/bd/Tomb_Raider_%282018_film%29.png"],["Maléfique : Le Pouvoir du mal",2019,"Joachim Rønning","Maleficent: Mistress of Evil","https://upload.wikimedia.org/wikipedia/en/7/7b/Maleficent_Mistress_of_Evil_%28Official_Film_Poster%29.png"],["Mortal Kombat",2021,"Simon McQuoid","","https://upload.wikimedia.org/wikipedia/en/3/37/Mortal_Kombat_%282021_film%29.png"],["Valeur sentimentale",2025,"Joachim Trier","Sentimental Value","https://upload.wikimedia.org/wikipedia/en/5/5c/Sentimental_Value_2025.jpeg"],["Glass",2019,"M. Night Shyamalan","","https://upload.wikimedia.org/wikipedia/en/0/01/Glass_%282019_poster%29.png"],["Alien: Romulus",2024,"Fede Álvarez","","https://upload.wikimedia.org/wikipedia/en/c/cb/Alien_Romulus_2024_%28poster%29.jpg"],["Scream 6",2023,"Tyler Gillett, Matt Bettinelli-Olpin","Scream VI","https://upload.wikimedia.org/wikipedia/en/c/c9/Scream_VI_poster.jpg"],["The Disaster Artist",2017,"James Franco","","https://upload.wikimedia.org/wikipedia/en/c/c9/TheDisastorArtistTeaserPoster.jpg"],["Capharnaüm",2018,"Nadine Labaki","Capernaum","https://upload.wikimedia.org/wikipedia/en/1/13/Capernaum_%28film%29.jpg"],["Blue Beetle",2023,"Angel Manuel Soto","","https://upload.wikimedia.org/wikipedia/en/6/68/Blue_Beetle_%28film%29_poster.jpg"],["Dragons",2025,"Dean DeBlois","How to Train Your Dragon","https://upload.wikimedia.org/wikipedia/en/8/80/How_To_Train_Your_Dragon_2025_Poster.jpg"],["Portrait de la jeune fille en feu",2019,"Céline Sciamma","Portrait of a Lady on Fire","https://upload.wikimedia.org/wikipedia/en/c/cb/Portrait_of_a_Lady_on_Fire.jpg"],["Retour à Zombieland",2019,"Ruben Fleischer","Zombieland: Double Tap","https://upload.wikimedia.org/wikipedia/en/1/15/Zombieland_Double_Tap_teaser_poster.jpg"],["Le Labyrinthe : Le Remède mortel",2018,"Wes Ball","Maze Runner: The Death Cure","https://upload.wikimedia.org/wikipedia/en/e/eb/MazeRunnerDeathCureFinalPoster.jpeg"],["20 jours à Marioupol",2023,"Mstyslav Chernov","20 Days in Mariupol","https://upload.wikimedia.org/wikipedia/en/b/be/20_Days_in_Mariupol_poster.jpg"],["Wonder",2017,"Stephen Chbosky","","https://upload.wikimedia.org/wikipedia/en/6/67/Wonder_%28film%29.png"],["Pierre Lapin",2018,"Will Gluck","Peter Rabbit","https://upload.wikimedia.org/wikipedia/en/3/3d/Peter-rabbit-teaser.jpg"],["Five Nights at Freddy's",2023,"Emma Tammi","","https://upload.wikimedia.org/wikipedia/en/d/d6/Five_Nights_At_Freddy%27s_poster.jpeg"],["Les Trolls 2 : Tournée mondiale",2020,"Walt Dohrn, David P. Smith","Trolls World Tour","https://upload.wikimedia.org/wikipedia/en/e/ed/Trolls_World_Tour_poster.jpg"],["Midsommar",2019,"Ari Aster","","https://upload.wikimedia.org/wikipedia/en/4/47/Midsommar_%282019_film_poster%29.png"],["Conjuring : Sous l'emprise du Diable",2021,"Michael Chaves","The Conjuring: The Devil Made Me Do It","https://upload.wikimedia.org/wikipedia/en/e/e8/The_Conjuring_-_The_Devil_Made_Me_Do_It.png"],["Paddington 2",2017,"Paul King","","https://upload.wikimedia.org/wikipedia/en/b/b6/Paddington_2_poster.jpg"],["The Fabelmans",2022,"Steven Spielberg","","https://upload.wikimedia.org/wikipedia/en/b/ba/Fabelmansposter.jpeg"],["Asteroid City",2023,"Wes Anderson","","https://upload.wikimedia.org/wikipedia/en/7/78/Asteroidcity.jpg"],["Beetlejuice Beetlejuice",2024,"Tim Burton","","https://upload.wikimedia.org/wikipedia/en/b/ba/Beetlejuice_Beetlejuice_poster.jpg"],["Frankenstein",2025,"Guillermo del Toro","","https://upload.wikimedia.org/wikipedia/en/9/94/Frankenstein_2025_film_poster.jpg"],["Babylon",2022,"Damien Chazelle","","https://upload.wikimedia.org/wikipedia/en/d/db/Babylon_2022_poster.jpg"],["The Beekeeper",2024,"David Ayer","","https://upload.wikimedia.org/wikipedia/en/8/82/The_Beekeeper_poster.jpg"],["Douleur et Gloire",2019,"Pedro Almodóvar","Pain and Glory","https://upload.wikimedia.org/wikipedia/en/e/ee/DolorYGloriaPoster.jpg"],["Les Banshees d'Inisherin",2022,"Martin McDonagh","The Banshees of Inisherin","https://upload.wikimedia.org/wikipedia/en/6/6e/The_Banshees_of_Inisherin.jpg"],["Train Dreams",2025,"Clint Bentley","","https://upload.wikimedia.org/wikipedia/en/5/58/Train_Dreams_poster.jpeg"],["Geostorm",2017,"Dean Devlin","","https://upload.wikimedia.org/wikipedia/en/7/76/Geostorm_official_teaser_poster.jpg"],["Drunk",2020,"Thomas Vinterberg","Another Round","https://upload.wikimedia.org/wikipedia/en/e/ea/Another_Round_%28film%29.jpg"],["Ballerina",2025,"Len Wiseman","","https://upload.wikimedia.org/wikipedia/en/f/f6/Ballerina_%282025_film%29_poster.jpg"],["Y a-t-il un flic pour sauver la reine ?",1988,"David Zucker","The Naked Gun: From the Files of Police Squad!","https://upload.wikimedia.org/wikipedia/en/5/5f/The_Naked_Gun_Poster.jpg"],["La Mort de Staline",2017,"Armando Iannucci","The Death of Stalin","https://thumb.wikimedia.org/wikipedia/en/thumb/8/86/The_Death_of_Stalin.png/330px-The_Death_of_Stalin.png"],["Bad Boys for Life",2020,"Adil El Arbi, Bilall Fallah","","https://upload.wikimedia.org/wikipedia/en/9/90/Bad_Boys_for_Life_poster.jpg"],["Black Phone",2021,"Scott Derrickson","The Black Phone","https://upload.wikimedia.org/wikipedia/en/7/7f/The_Black_Phone.jpg"],["Nosferatu",2024,"Robert Eggers","","https://upload.wikimedia.org/wikipedia/en/4/48/Nosferatu_IMAX_poster_2024.jpg"],["Rampage - Hors de contrôle",2018,"Brad Peyton","Rampage","https://upload.wikimedia.org/wikipedia/en/6/6b/Rampage_teaser_film_poster.jpg"],["Scream",2022,"Matt Bettinelli-Olpin, Tyler Gillett","","https://upload.wikimedia.org/wikipedia/en/2/24/Scream2022film.jpeg"]];
const EXT_PL = ['37i9dQZEVXbIPWwFssbupI', '37i9dQZEVXbMDoHDwVN2tF', '37i9dQZF1DXcBWIGoYBM5M', '37i9dQZF1DX5Ejj0EkURtP', '37i9dQZF1DX4o1oenSJRJd'];
const EXT = {on:false, saved:null};
const extOk = () => C && (C.type === 'films' || C.type === 'music');
const extNames = () => C.type === 'music' ? ['Ma playlist', 'Hors playlist'] : ['Mes films Letterboxd', 'Hors Letterboxd'];
function extEnter(items){ if (!EXT.on) EXT.saved = {F, N}; F = items; N = F.length; EXT.on = true; G.used.clear(); }
function extLeave(){ if (!EXT.on) return; F = EXT.saved.F; N = EXT.saved.N; EXT.on = false; EXT.saved = null; if (typeof G === 'object') G.used.clear(); }
function extMineSet(){ const s = new Set(); F.forEach(it => [it.t, it.en].forEach(t => { if (t) s.add(norm(t) + '|' + (it.y || '')); })); return s; }
async function jobRun(kind, args, onProg){
  const r = await (await fetch('/api/job', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({kind, args})})).json();
  if (!r.id) throw new Error(r.error || 'tâche refusée');
  for (let k = 0; k < 900; k++) {
    await new Promise(res => setTimeout(res, 700));
    const s = await (await fetch('/api/job?id=' + r.id)).json();
    if (s.status === 'run') { if (onProg) onProg(s.done, s.total); continue; }
    if (s.status === 'done') return s.result;
    throw new Error(s.error || 'échec');
  }
  throw new Error('trop long');
}
function spGid(id){ const A = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'; let n = 0n; for (const ch of id) n = n * 62n + BigInt(A.indexOf(ch)); return n.toString(16).padStart(32, '0'); }
async function extMusicRows(onProg){
  const cache = ls.get('ringcine-ext-music', null);
  if (cache && cache.rows && cache.rows.length >= 40 && Date.now() - cache.ts < 7 * 864e5) return cache.rows;
  const ids = new Set(); let tok = '';
  for (const pl of EXT_PL) { try { const r = await jobRun('spList', {pl}); if (r && r.token) tok = r.token; ((r && r.ids) || []).forEach(x => ids.add(x)); } catch(e){} }
  if (!ids.size || !tok) { if (cache && cache.rows && cache.rows.length) return cache.rows; throw new Error('Spotify ne répond pas (connexion ?)'); }
  const list = [...ids].slice(0, 450);
  const res = await jobRun('spDetails', {token: tok, noyt: true, items: list.map(x => [x, spGid(x)])}, onProg);
  const rows = (res || []).filter(r => r && r[1]).map(([id, t, a, c]) => [t, a, id, c, '']);
  if (rows.length < 20) { if (cache && cache.rows && cache.rows.length) return cache.rows; throw new Error('Spotify ne répond pas (connexion ?)'); }
  ls.set('ringcine-ext-music', {ts: Date.now(), rows}); return rows;
}
async function extItems(onProg){
  if (C.type === 'films') {
    const mine = extMineSet();
    return EXT_FILMS.filter(([t, y, , en]) => !mine.has(norm(t) + '|' + y) && !(en && mine.has(norm(en) + '|' + y)))
      .map(([t, y, d, en, im]) => ({t, y, sub: d, r: 0, en: en || '', img: safeUrl(im), key: keyHash(`${en || t} (${y})`)}));
  }
  const mine = new Set(F.map(it => it.key)), mineT = new Set(F.map(it => norm(it.t) + '|' + norm(it.first)));
  const rows = await extMusicRows(onProg);
  return rows.filter(([t, a, id]) => !mine.has(id) && !mineT.has(norm(t) + '|' + norm((a || '').split(', ')[0])))
    .map(([t, a, id, c]) => ({t, sub: a, id, c, img: coverUrl(c), key: id, first: (a || '').split(', ')[0], yt: ''}));
}
async function gStart(){
  if (G.src !== 'ext' || !extOk() || GAMES[G.id].custom) { extLeave(); return gNewRound(); }
  if (EXT.on) return gNewRound();
  const tok = ++G.tok, id = G.id;
  G.cur = {loading:true, msg: C.type === 'music' ? 'Récupération des tubes sur Spotify… (la première fois, environ 30 s)' : 'Préparation des films…'}; renderGame();
  try {
    const items = await extItems((d, t) => { const el = $('gloadt'); if (el && t) el.textContent = `Récupération des tubes sur Spotify… ${d} / ${t}`; });
    if (tok !== G.tok || G.id !== id || curView !== 'game') return;
    if (items.length < 8) throw new Error('pas assez de ' + TY.many + ' hors de ta liste');
    extEnter(items); gNewRound();
  } catch(e){ if (tok !== G.tok || G.id !== id) return; G.cur = {error: 'Impossible de préparer « ' + extNames()[1] + ' » : ' + e.message + '.'}; renderGame(); }
}

/* ---------- Déroulé d'une manche ---------- */
function gPoolIdx(){
  let P = [...Array(N).keys()];
  if (G.pool === 'top100') P = ranking().order.slice(0, 100);
  if (G.pool === 'top250') P = ranking().order.slice(0, 250);
  const g = GAMES[G.id];
  if (g.kind === 'crop') P = P.filter(i => F[i].img);
  if (g.kind === 'quote') P = P.filter(i => QUOTES.has(F[i].key));
  if (g.kind === 'year') P = P.filter(i => F[i].y > 1800);
  if (g.kind === 'iconic') { const all = bdAll(); P = P.filter(i => bdOf(i, all)); }
  if (g.kind === 'clip' && !g.server && !SERVER) P = P.filter(i => F[i].yt);
  if (G.id === 'spot' && C.type === 'films') { const base = P; let k0 = Math.max(0, DIFFS.indexOf(G.diff)); P = []; for (let n = 0; n < DIFFS.length && !P.length; n++) { const d = DIFFS[(k0 + n) % DIFFS.length]; P = base.filter(i => diffOk(F[i], d)); if (P.length) G.diff = d; } }
  return P;
}
async function gNewRound(){
  if (!G.id) return;
  const tok = ++G.tok, gid = G.id, stale = () => tok !== G.tok || G.id !== gid || curView !== 'game';
  const g = GAMES[G.id]; G.busy = true; clearTimeout(gTimer); stopAudio(); gWait = null; clearInterval(gSubT); gSubT = null;
  let P = gPoolIdx().filter(i => !G.used.has(i)); if (!P.length) { G.used.clear(); P = gPoolIdx(); }
  if (!P.length) { G.cur = {error: g.kind === 'iconic' ? 'Pas encore de scènes cultes pour ce ring. Mets à jour ton bouton Ring Sync (menu Ajouter → Ring Sync, reglisse le bouton dans tes favoris), puis clique dessus sur ta page de films Letterboxd : il récupère les scènes cultes (environ 300 films à chaque fois).' : G.id === 'fsong' ? 'Aucun film de ce ring n’a de chanson culte dans la liste de Ring.' : G.id === 'spot' && C.type === 'films' ? 'Pas assez de films dans cette source : choisis une autre source.' : EXT.on ? 'Ce jeu a besoin de données de ton ring : choisis la source « ' + extNames()[0] + ' » pour y jouer.' : 'Aucun élément utilisable pour ce jeu dans ce ring.'}; G.busy = false; return renderGame(); }
  G.cur = {loading:true}; renderGame();
  for (let tries = 0; tries < 6; tries++) {
    let i = P[Math.floor(Math.random() * P.length)];
    if (G.id === 'fsong' && Math.random() < .45) { const S2 = P.filter(j => FILM_SONGS.has(F[j].key)); if (S2.length) i = S2[Math.floor(Math.random() * S2.length)]; }
    G.used.add(i);
    const c = {i, step:0, done:false, won:false, wrong:[], fx: rnd(22, 78), fy: rnd(18, 70)};
    if (g.kind === 'clip') {
      if (G.id === 'blind') { c.yt = F[i].yt || await ytFind(`${F[i].first || F[i].sub || ''} ${F[i].t}`); if (c.yt && !F[i].yt) F[i].yt = c.yt; c.start = rnd(40, 70); }
      else if (G.id === 'sound') { c.yt = await voTrailer(F[i]); c.start = rnd(20, 50); }
      else if (G.id === 'fsong') { const L = FILM_SONGS.get(F[i].key); if (L) { c.song = L[Math.floor(Math.random() * L.length)]; c.yt = await ytFind(`${c.song[0]} - ${c.song[1]} official audio`); c.start = rnd(22, 45); } else { const o = await ostFind(F[i]); c.yt = o ? o.id : ''; c.ost = o ? o.t : ''; c.start = rnd(12, 40); } }
      else if (G.id === 'sceneclip') { c.yt = await sceneClipFind(F[i]); c.start = rnd(6, 30); }
      else if (G.id === 'spot') { c.diff = G.diff; if (C.type === 'music') { c.audio = await spPreview(F[i].key); if (c.audio) c.start = pvStart(G.diff, 10); else { c.yt = F[i].yt || await ytFind(`${F[i].first || F[i].sub || ''} ${F[i].t} official audio`); c.start = diffStart(G.diff); } } else { c.yt = await sceneClipFind(F[i]); c.start = rnd(3, 20); } }
      else { c.yt = await trailerFind(F[i]); c.start = rnd(18, 45); }
      if (stale()) return;
      if (!c.yt && !c.audio) continue;
    }
    if (g.kind === 'cast') { c.cast = await wikiCast(F[i]); if (stale()) return; if (!c.cast || (tries < 4 && c.cast.filter(x => x.img).length < 2)) continue; c.cast.forEach(x => { if (x.img) { const im = new Image(); im.referrerPolicy = 'no-referrer'; im.src = x.img; } }); }
    if (g.kind === 'scene') { c.yt = await trailerFind(F[i]); if (stale()) return; if (!c.yt) continue;
      c.frames = [[c.yt, 2], [c.yt, 1], [c.yt, 3]];
      const bad2 = /\bvf\b|reaction|réaction|review|critique|explained|expliqu|fan[- ]?made|concept|parody|recap|résumé|making of|interview/i;
      const rel2 = relTitle(F[i]);
      for (const q of [`${F[i].t} ${F[i].y || ''} trailer`, `${F[i].t} ${F[i].y || ''} clip scene`]) {
        if (c.frames.length >= 5) break;
        const L2 = (await ytList(q)).filter(x => x.id !== c.yt && !c.frames.some(f => f[0] === x.id) && !bad2.test(x.t) && rel2(x) && /trailer|teaser|bande|clip|scene|scène|extrait/i.test(x.t));
        if (stale()) return;
        if (L2[0]) c.frames.push([L2[0].id, 2], [L2[0].id, 1]);
      }
      c.frames = c.frames.slice(0, 5);
      c.frames.forEach(([v, n]) => { const im = new Image(); im.src = `https://i.ytimg.com/vi/${v}/maxres${n}.jpg`; }); }
    if (g.kind === 'iconic') { c.bd = bdOf(i); const im = new Image(); im.referrerPolicy = 'no-referrer'; im.src = c.bd; }
    if (g.kind === 'quote') { const q = QUOTES.get(F[i].key); c.q = [maskText(q[0], F[i]), maskText(q[1], F[i])]; }
    if (g.kind === 'plot') {
      const wp = await wikiPlot(F[i]); if (stale()) return; if (!wp) continue; const plot = wp.plot; c.lang = wp.lang;
      const sent = maskText(plot, F[i], wp.title).match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g) || [plot];
      c.sent = sent.map(s => s.trim()).filter(Boolean);
    }
    if (G.mode === 'choice') {
      const others = shuffle([...Array(N).keys()].filter(j => j !== i && norm(F[j].t) !== norm(F[i].t))).slice(0, 3);
      c.choices = shuffle([i, ...others]);
    }
    G.cur = c; G.round++; G.busy = false; renderGame();
    if (g.kind === 'clip' && G.round > 1) setTimeout(() => gPlay(g.steps[0]), 700);
    return;
  }
  G.cur = {error: GAMES[G.id].kind === 'plot' ? 'Impossible de trouver des résumés sur Wikipédia (connexion ?). Réessaie ou choisis un autre jeu.' : 'Impossible de trouver les vidéos. Vérifie que Ring a été ouvert avec Ring.bat et que tu as internet.'};
  G.busy = false; renderGame();
}
function gGuess(j, typed){
  const c = G.cur, g = GAMES[G.id]; if (!c || c.done || c.i === undefined) return;
  const ok = j === c.i || (j == null && typed && (norm(typed) === norm(F[c.i].t) || (F[c.i].en && norm(typed) === norm(F[c.i].en)) || (F[c.i].fr && norm(typed) === norm(F[c.i].fr)) || (norm(typed).length >= 4 && norm(F[c.i].t).replace(/^(the|le|la|les|l) /, '') === norm(typed).replace(/^(the|le|la|les|l) /, ''))));
  if (ok) return gEnd(true);
  c.wrong.push(j != null ? gLabel(j) : typed);
  if (c.step >= g.steps.length - 1) return gEnd(false);
  c.step++; renderGame(true);
  if (g.kind === 'clip') gPlayStep(g, c);
}
function gPlayStep(g, c){ gPlay(g.steps[c.step], false, 0, g.cont && c.step ? g.steps[c.step - 1] : 0); }
function gSkip(){ const c = G.cur, g = GAMES[G.id]; if (!c || c.done) return; if (c.step >= g.steps.length - 1) return gEnd(false); c.step++; renderGame(true); if (g.kind === 'clip') gPlayStep(g, c); }
function gEnd(won){
  const c = G.cur, g = GAMES[G.id]; c.done = true; c.won = won;
  if (G.id === 'spot' && won && c.diff && !c.nextDiff) { const k = DIFFS.indexOf(c.diff); c.nextDiff = DIFFS[(k + 1) % DIFFS.length]; c.looped = k === DIFFS.length - 1; if (c.looped) G.loop = (G.loop || 0) + 1; G.diff = c.nextDiff; }
  c.pts = won ? (g.kind === 'year' ? yearPts(c.guess - F[c.i].y) : g.steps.length - c.step) : 0;
  if (won) { sfx('win'); if (c.pts >= 4) confetti(80); } else sfx('lose');
  G.score += c.pts; G.streak = won ? G.streak + 1 : 0;
  const all = gStats(), s = all[gKey(G.id)] || {played:0, won:0, best:0, pts:0};
  if (won && (g.kind === 'year' ? c.pts === 5 : c.step === 0)) s.perfect = (s.perfect || 0) + 1;
  s.played++; if (won) s.won++; s.pts += c.pts; s.best = Math.max(s.best, G.streak); all[gKey(G.id)] = s; ls.set('ringcine-games', all);
  clearTimeout(gTimer); gWait = null;
  renderGame(true);
  if (g.kind === 'clip') { const f = gFrame(); if (f) { ytCmd(f, 'pauseVideo'); } stopAudio(); }
}

/* ---------- Affichage ---------- */
function gStepsBar(g, c){
  if (g.kind === 'year') return `<div class="gsteps">${[['Pile',5],['±1',4],['±2',3],['±5',2],['±10',1]].map(([l, p]) => `<span class="${c.done && c.pts === p ? 'cur' : ''}"><b>${l}</b><i>${p} pt${p > 1 ? 's' : ''}</i></span>`).join('')}</div>`;
  const lab = k => g.kind === 'iconic' ? ['Gros zoom', 'Zoom', 'Entière', '+ Année', '+ Réal.'][k] : g.kind === 'scene' ? (c.frames && c.frames.length <= k ? ['', '', '', '+ Année', '+ Réal.'][k] : (k + 1) + (k ? ' scènes' : ' scène')) : g.kind === 'quote' ? ['VO', '+ Trad.', '+ Année', '+ Réal.'][k] : g.kind === 'cast' ? ['1 acteur', '2 acteurs', '3 acteurs', '+ Année', '+ Réal.'][k] : g.kind === 'clip' ? `${g.steps[k]} s` : g.kind === 'crop' ? `×${g.steps[k]}`.replace('×1', 'Entière') : ['Début', 'Suite', 'Tout', 'Année', 'Affiche'][k];
  return `<div class="gsteps">${g.steps.map((_, k) => `<span class="${k < c.step ? 'past' : k === c.step ? 'cur' : ''}"><b>${lab(k)}</b><i>${g.steps.length - k} pt${g.steps.length - k > 1 ? 's' : ''}</i></span>`).join('')}</div>`;
}
function gClue(g, c){
  const it = F[c.i];
  if (g.kind === 'year') return `<div class="gcrop${TY.sq ? ' sq' : ''}"><img src="${esc(hiRes(it.img))}" data-lo="${esc(it.img)}" alt="Affiche" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}"></div>`;
  if (g.kind === 'scene') { const fr = c.frames || sceneOrder.map(n => [c.yt, n]), st = c.done ? 9 : c.step, n = Math.min(fr.length, st + 1), shown = fr.slice(0, n), extra = !c.done && st >= fr.length; return `<div class="gscene"><div class="gs-main">${sceneImg(...shown[shown.length - 1])}</div>${n > 1 ? `<div class="gs-thumbs">${shown.slice(0, -1).map(f => sceneImg(...f)).join('')}</div>` : ''}${extra ? `<div class="gfacts"><span>📅 ${it.y || '?'}</span>${st >= 4 ? `<span>🎥 ${esc(it.sub || '?')}</span>` : ''}</div>` : ''}</div>`; }
  if (g.kind === 'iconic') { const st = c.done ? 9 : c.step, z = ICZ[Math.min(st, 2)]; return `<div class="gscene"><div class="gs-main gs-ic"><img src="${esc(c.bd)}" alt="Scène culte" referrerpolicy="no-referrer" style="transform:scale(${z});transform-origin:${c.fx}% ${c.fy}%"></div>${!c.done && st >= 3 ? `<div class="gfacts"><span>📅 ${it.y || '?'}</span>${st >= 4 ? `<span>🎥 ${esc(it.sub || '?')}</span>` : ''}</div>` : ''}</div>`; }
  if (g.kind === 'quote') { const st = c.done ? 9 : c.step; return `<div class="gquote"><blockquote class="vo">« ${esc(c.q[0])} »<cite>VO</cite></blockquote>${st >= 1 ? `<blockquote class="fr">« ${esc(c.q[1])} »<cite>Traduction française</cite></blockquote>` : ''}${st >= 2 ? `<div class="gfacts"><span>📅 ${it.y || '?'}</span>${st >= 3 ? `<span>🎥 ${esc(it.sub || '?')}</span>` : ''}</div>` : ''}</div>`; }
  if (g.kind === 'cast') { const st = c.done ? 9 : c.step, n = c.done ? c.cast.length : Math.min(3, st + 1); return `<div class="gcast${c.done ? ' all' : ''}">${c.cast.slice(0, n).map((a, k) => `<div class="gactor">${a.img ? `<img src="${esc(a.img)}" alt="" referrerpolicy="no-referrer" onerror="this.replaceWith(Object.assign(document.createElement('i'),{className:'noface',textContent:'${esc(a.n.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase())}'}))">` : `<i class="noface">${esc(a.n.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase())}</i>`}<b>${esc(a.n)}</b></div>`).join('')}${st >= 3 && !c.done ? `<div class="gfacts"><span>📅 ${it.y || '?'}</span>${st >= 4 ? `<span>🎥 ${esc(it.sub || '?')}</span>` : ''}</div>` : ''}</div>`; }
  if (g.kind === 'clip') return clipHtml(c, g);
  if (g.kind === 'crop') { const z = c.done ? 1 : g.steps[c.step]; return `<div class="gcrop${TY.sq ? ' sq' : ''}"><img src="${hiRes(it.img, true)}" data-lo="${it.img}" alt="Image à deviner" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}" style="transform:scale(${z});transform-origin:${c.fx}% ${c.fy}%"></div>`; }
  if (g.kind === 'plot') {
    const n = c.sent.length, show = c.done ? n : [Math.max(1, Math.ceil(n * .34)), Math.max(1, Math.ceil(n * .67)), n, n, n][c.step];
    const extra = c.done || c.step >= 3 ? `<div class="gfacts"><span>📅 ${it.y || '?'}</span>${c.done || c.step >= 3 ? `<span>🎥 ${c.done ? esc(it.sub || '?') : esc((it.sub || '?').split(/,\s*/).map(n => n.split(' ').map(w => w[0] + '.').join(' ')).join(', '))}</span>` : ''}</div>` : '';
    const pic = !c.done && c.step >= 4 && it.img ? `<div class="gcrop mini"><img src="${hiRes(it.img)}" alt="" referrerpolicy="no-referrer" style="transform:scale(3);transform-origin:${c.fx}% ${c.fy}%"></div>` : '';
    return `<div class="gplot">${c.lang === 'en' ? '<div class="note" style="margin-bottom:8px">Pas de résumé en français pour ce film : version anglaise.</div>' : ''}<p>${esc(c.done ? c.sent.join(' ') : c.sent.slice(0, show).join(' '))}${!c.done && show < n ? ' <span class="more">…</span>' : ''}</p>${extra}${pic}</div>`;
  }
  return '';
}
function gAnswerHtml(c){
  if (c.done || GAMES[G.id].kind === 'year') return '';
  if (G.mode === 'choice') return `<div class="gchoices">${c.choices.map((j, k) => `<button class="btn gch" data-j="${j}" ${c.wrong.includes(gLabel(j)) ? 'disabled' : ''}><kbd>${k + 1}</kbd> ${esc(gLabel(j))}</button>`).join('')}</div>`;
  return `<div class="gguess"><input class="input" id="gin" autocomplete="off" placeholder="${C.type === 'music' ? 'Titre du son…' : C.type === 'films' ? 'Nom du film…' : 'Ta réponse…'}"><div class="gsug" id="gsug"></div></div>`;
}
function gQuit(){ stopAudio(); extLeave(); G.tok++; G.id = null; G.cur = null; clearTimeout(gTimer); clearInterval(gSubT); gSubT = null; gWait = null; try { if (document.fullscreenElement) document.exitFullscreen(); } catch(e){} renderGame(); }
function gRevealHtml(g, c){
  if (!c.done) return '';
  return `<div class="greveal ${c.won ? 'ok' : 'ko'}">
    <div class="gres">${c.won ? `Bien joué ! <b>+${c.pts} pt${c.pts > 1 ? 's' : ''}</b>` : 'Raté…'}</div>
    ${G.id === 'spot' && c.diff ? `<p class="gnextlvl">${c.won ? (c.looped ? '🔁 Impossible réussi ! Nouvelle boucle : on repart en <b class="gdiffb d-easy">Easy</b>' : `⬆ Niveau suivant : <b class="gdiffb d-${c.nextDiff}">${DIFF_NAME[c.nextDiff]}</b>`) : `On reste en <b class="gdiffb d-${c.diff}">${DIFF_NAME[c.diff]}</b> : trouve ce niveau pour monter.`}</p>` : ''}
    ${g.kind === 'year' ? `<p class="note" style="text-align:center;margin:-6px 0 0">Tu as dit <b>${c.guess}</b> · c’était <b>${F[c.i].y}</b> (${Math.abs(c.guess - F[c.i].y) === 0 ? 'pile !' : 'écart de ' + Math.abs(c.guess - F[c.i].y) + ' an' + (Math.abs(c.guess - F[c.i].y) > 1 ? 's' : '')})</p>` : ''}
    <div class="gcard">${imgHi(c.i)}<div><h3>${T(c.i)}</h3><div class="cmeta">${metaLine(c.i)}</div>${c.song ? `<p class="gsongline">🎶 <b>${esc(c.song[1])}</b> · ${esc(c.song[0])}</p>` : c.ost ? `<p class="gsongline">🎼 B.O. : ${esc(c.ost)}</p>` : ''}${c.wrong.length ? `<p class="note">Tes essais : ${c.wrong.map(esc).join(' · ')}</p>` : ''}</div></div>
    <div class="fx" style="gap:8px;justify-content:center;flex-wrap:wrap">${g.kind === 'clip' ? `<button class="btn" id="gfull">▶ ${g.visible ? 'Voir' : 'Écouter'} la suite</button>` : ''}<button class="btn primary" id="gnext">Manche suivante <kbd>Entrée</kbd></button></div>
  </div>`;
}
function gCtlHtml(g, c){
  if (c.done) return '';
  if (g.kind === 'year') return `<div class="gguess gyear"><input class="input" id="gyin" type="number" inputmode="numeric" min="1880" max="2100" placeholder="Année de sortie… (ex. 2008)"><button class="btn primary" id="gyok">Valider <kbd>Entrée</kbd></button></div><div class="gctl"><button class="btn ghost" id="gnew">↻ Autre</button></div>`;
  return `<div class="gctl">
      ${g.kind === 'clip' ? `<button class="btn primary" id="gplay">▶ ${g.visible ? (c.step && g.cont ? 'Revoir' : 'Voir') : 'Écouter'} ${g.steps[c.step]} s <kbd>Espace</kbd></button>` : ''}
      <button class="btn ghost" id="gnew" title="Changer d’élément sans perdre ta série">↻ Autre</button>
      <button class="btn ghost" id="gskip">${c.step >= g.steps.length - 1 ? 'Je donne ma langue au chat' : g.kind === 'clip' ? 'Plus long ⏩' : 'Indice suivant ⏩'} <kbd>Tab</kbd></button>
    </div>
    ${c.song && c.step >= g.steps.length - 1 ? `<div class="gsonghint">🎶 Indice : le son s’appelle « <b>${esc(c.song[1])}</b> »</div>` : G.id === 'fsong' && !c.song && c.step >= g.steps.length - 1 ? `<div class="gsonghint">🎼 Indice : c’est la musique composée pour le film · sorti en <b>${F[c.i].y || '?'}</b></div>` : ''}
    ${c.wrong.length ? `<div class="gwrong">${c.wrong.map(w => `<span>✗ ${esc(w)}</span>`).join('')}</div>` : ''}
    ${gAnswerHtml(c)}`;
}
function renderGame(update){
  if (!G.id) return renderGamePicker();
  if (GAMES[G.id] && GAMES[G.id].custom) return GAMES[G.id].render();
  const g = GAMES[G.id], c = G.cur || {};
  const ready = !c.error && !c.loading && c.i !== undefined;
  if (update && ready && $('gctlw')) {
    $('gstepsw').innerHTML = gStepsBar(g, c);
    if (g.kind === 'crop') { const im = view.querySelector('.gcrop img'); if (im) im.style.transform = `scale(${c.done ? 1 : g.steps[c.step]})`; }
    else if (g.kind !== 'clip') $('gcluew').innerHTML = gClue(g, c);
    else { const box = view.querySelector('.gclip'); if (box && c.done) box.classList.add('revealed'); }
    $('grevw').innerHTML = gRevealHtml(g, c);
    view.querySelector('.gboard').classList.toggle('done', !!c.done);
    $('gctlw').innerHTML = gCtlHtml(g, c);
    $('gscore').textContent = fmt(G.score); $('gstreak').textContent = G.streak;
    gBind(g, c, update !== 'nofocus');
    return;
  }
  const head = `<div class="stagehead"><div class="round"><b>${g.icon} ${g.name}</b> · manche ${fmt(G.round || 1)}${G.id === 'spot' ? ` · ${spotLadder(c.diff || G.diff)}` : ''}${EXT.on ? ` · <span class="gsrc">🌍 ${esc(extNames()[1])}</span>` : ''}</div>
    <div class="fx" style="gap:8px">${volHtml()}<span class="pill">Score <b id="gscore">${fmt(G.score)}</b></span><span class="pill">Série <b id="gstreak">${G.streak}</b></span><button class="btn sm ghost" id="gquit">✕ Quitter <kbd>Échap</kbd></button></div></div>`;
  let body;
  if (c.error) body = `<div class="empty" style="text-align:center;padding:40px 0">${esc(c.error)}</div><div style="text-align:center"><button class="btn primary" id="gretry">Réessayer</button></div>`;
  else if (!ready) body = `<div class="gload"><span class="spin"></span><span id="gloadt">${esc(c.msg || 'Préparation de la manche…')}</span></div>`;
  else body = `<div id="gstepsw">${gStepsBar(g, c)}</div>
      <div class="gboard${c.done ? ' done' : ''}"><div class="gclue" id="gcluew">${gClue(g, c)}</div><div id="grevw">${gRevealHtml(g, c)}</div></div>
      <div id="gctlw">${gCtlHtml(g, c)}</div>`;
  view.innerHTML = `<section class="stage game full" id="gstage">${head}${body}</section>`;
  $('gquit').onclick = gQuit;
  if ($('gretry')) $('gretry').onclick = () => G.src === 'ext' && !EXT.on ? gStart() : gNewRound();
  if (ready) gBind(g, c, true);
}
function gSuggest(q, titles){
  if (!q) return [];
  const qs = q.replace(/ /g, '');
  const sc = titles.map(([j, n, t]) => {
    let v = 0;
    if (t.startsWith(q)) v = 100 - t.length / 100;
    else if (t.split(' ').some(w => w.startsWith(q))) v = 80 - t.length / 100;
    else if (C.type === 'music' && F[j] && (' ' + norm(F[j].sub || '')).includes(' ' + q)) v = 70;
    else if (t.includes(q) || t.replace(/ /g, '').includes(qs)) v = 60;
    else if (n.includes(q)) v = 40;
    else if (q.length >= 3) { const bg = s => { const o = new Set(); const x = s.replace(/ /g, ''); for (let k = 0; k < x.length - 1; k++) o.add(x.slice(k, k + 2)); return o; }; const a = bg(qs), b = bg(t); let m = 0; a.forEach(x => { if (b.has(x)) m++; }); const d = 2 * m / (a.size + Math.min(b.size, a.size + 6) || 1); if (d > .45) v = d * 35; }
    return [j, v];
  }).filter(x => x[1] > 0).sort((a, b) => b[1] - a[1]);
  if (sc.length && sc[0][1] >= 80) sc.splice(sc.findIndex(x => x[1] < 80) >>> 0);
  const seen = new Set(), out = [];
  for (const [j] of sc) { const k = norm(F[j].t) + (C.type === 'films' ? F[j].y : '|' + norm(F[j].sub)); if (seen.has(k)) continue; seen.add(k); out.push(j); if (out.length >= 60) break; }
  return out;
}
function gBind(g, c, focus){
  const gy = $('gyin');
  if (gy) { const go2 = () => { const v = parseInt(gy.value, 10); if (!(v > 1800 && v < 2200)) { toast('Tape une année, par exemple 1999.'); return; } c.guess = v; gEnd(yearPts(v - F[c.i].y) > 0); };
    $('gyok').onclick = go2; gy.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); go2(); } }; if (focus) setTimeout(() => gy.focus(), 30); }
  if ($('gnext')) { $('gnext').onclick = gNewRound; if (focus) $('gnext').focus(); }
  if ($('gfull')) $('gfull').onclick = () => gPlay(0, true);
  if ($('gplay')) $('gplay').onclick = () => gPlay(g.steps[c.step]);
  if ($('gskip')) $('gskip').onclick = gSkip;
  if ($('gnew')) $('gnew').onclick = () => { G.round--; gNewRound(); };
  view.querySelectorAll('.gch').forEach(b => b.onclick = () => gGuess(+b.dataset.j));
  const gin = $('gin');
  if (gin) {
    const titles = F.flatMap((it, j) => { const a = [[j, norm(it.t + ' ' + (it.en || '') + ' ' + (it.fr || '') + ' ' + (it.sub || '')), norm(it.t)]]; if (it.en && it.en !== it.t) a.push([j, a[0][1], norm(it.en)]); if (it.fr) a.push([j, a[0][1], norm(it.fr)]); return a; });
    let sel = 0, hits = [];
    const draw = () => {
      const q = norm(gin.value);
      hits = gSuggest(q, titles);
      sel = Math.min(sel, Math.max(0, hits.length - 1));
      $('gsug').innerHTML = hits.map((j, k) => `<button class="${k === sel ? 'on' : ''}" data-j="${j}">${img(j, 'th')}<span>${esc(F[j].t)}<small>${esc(C.type === 'films' ? String(F[j].y || '') : F[j].sub || '')}${altTitle(F[j])}</small></span></button>`).join('');
      $('gsug').querySelectorAll('button').forEach(b => b.onmousedown = e => { e.preventDefault(); gGuess(+b.dataset.j); });
      const box = $('gsug'), on = box.querySelector('.on'); if (on) { if (on.offsetTop < box.scrollTop) box.scrollTop = on.offsetTop; else if (on.offsetTop + on.offsetHeight > box.scrollTop + box.clientHeight) box.scrollTop = on.offsetTop + on.offsetHeight - box.clientHeight; }
      if (hits.length) { const r = box.getBoundingClientRect(), st = $('gstage'); if (st && r.bottom > innerHeight) st.scrollBy({top: r.bottom - innerHeight + 20, behavior:'smooth'}); }
    };
    gin.oninput = () => { sel = 0; draw(); };
    gin.onkeydown = e => {
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(sel + 1, hits.length - 1); draw(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(sel - 1, 0); draw(); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (hits.length) gGuess(hits[sel]); else if (gin.value.trim()) gGuess(null, gin.value); }
      else if (e.key === 'Tab') { e.preventDefault(); gSkip(); }
      else if (e.key === ' ' && !gin.value) { e.preventDefault(); if ($('gplay')) $('gplay').click(); }
      else if (e.key === 'Escape') gin.blur();
    };
    if (focus) setTimeout(() => gin.focus(), 30);
  }
}
function renderGamePicker(){
  extLeave();
  const st = gStats(), list = Object.entries(GAMES).filter(([id, g]) => g.types.includes(C.type)), ext = G.src === 'ext' && extOk(), [mine, other] = extNames();
  const opt = (id, v, opts) => `<div class="seg" id="${id}">${opts.map(([k, l]) => `<button data-v="${k}" aria-pressed="${v === k}">${l}</button>`).join('')}</div>`;
  view.innerHTML = `<div class="sech"><h2>Jeux</h2></div>
    <p class="note" style="margin:-4px 0 16px">${ext ? `Devine des ${TY.many} <b>qui ne sont pas dans « ${esc(C.label)} »</b> : ${C.type === 'music' ? 'les tubes du moment et des années 2000-2010 (Spotify)' : 'environ 1 000 films parmi les plus connus au monde'}.` : `Devine les ${TY.many} de « ${esc(C.label)} ».`} Moins tu as besoin d’indices, plus tu marques de points.</p>
    <div class="gopts">${extOk() ? `<div><div class="note">Source</div>${opt('gsrc', ext ? 'ext' : 'mine', [['mine', (C.type === 'music' ? '🎧 ' : '📒 ') + mine], ['ext', '🌍 ' + other]])}</div>` : ''}
      ${ext ? '' : `<div><div class="note">Avec quels ${TY.many} ?</div>${opt('gpool', G.pool, [['all', 'Toute la liste'], ['top250', 'Mon top 250'], ['top100', 'Mon top 100']])}</div>`}
      <div><div class="note">Réponse</div>${opt('gmode', G.mode, [['type', 'Je tape'], ['choice', '4 choix (facile)']])}</div></div>
    <div class="modes gmodes">${list.map(([id, g]) => { const s = st[(ext ? C.id + ':ext:' : C.id + ':') + id]; const off = (g.server || (ext && C.type === 'music')) && !SERVER, mineOnly = ext && (g.custom || g.kind === 'iconic');
      return `<button class="mode${id === 'spot' ? ' hot' : ''}" data-g="${id}" ${off ? 'disabled title="Ouvre Ring avec Ring.bat pour ce jeu"' : mineOnly ? `disabled title="Ce jeu marche seulement avec ${esc(mine)}"` : ''}><em>${g.icon}</em><strong>${g.name}</strong><span>${typeof g.desc === 'function' ? g.desc() : g.desc}</span>${g.avail && !ext ? `<span class="gst">${g.avail()}</span>` : ''}${s ? `<span class="gst">${s.won}/${s.played} trouvés · record de série ${s.best}</span>` : ''}${off ? '<span class="gst">Nécessite Ring.bat</span>' : mineOnly ? `<span class="gst">Seulement avec ${esc(mine)}</span>` : ''}</button>`; }).join('')}</div>
    ${!list.length ? '<div class="empty">Pas de jeu pour ce type de ring.</div>' : ''}`;
  view.querySelectorAll('#gpool button').forEach(b => b.onclick = () => { G.pool = b.dataset.v; renderGame(); });
  view.querySelectorAll('#gsrc button').forEach(b => b.onclick = () => { G.src = b.dataset.v; renderGame(); });
  view.querySelectorAll('#gmode button').forEach(b => b.onclick = () => { G.mode = b.dataset.v; renderGame(); });
  view.querySelectorAll('.mode[data-g]').forEach(b => b.onclick = () => { try { if (!document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {}); } catch(e){} G.id = b.dataset.g; G.round = 0; G.diff = 'easy'; G.loop = 0; G.score = 0; G.streak = 0; G.used.clear(); if (GAMES[G.id].custom) { G.tok++; CH.center = null; PT.start = null; PT.over = false; CX.a = null; CX.solved = 0; CX.streak = 0; IN.round = 0; IN.cards = null; IN.over = false; renderGame(); } else gStart(); });
}
function gameKey(e){
  if (curView !== 'game' || !G.id || !G.cur) return false;
  const c = G.cur;
  if (c.done && e.key === 'Enter' && !e.target.matches('input,textarea,select')) { if (e.repeat) return true; e.preventDefault(); gNewRound(); return true; }
  if (e.target.matches('input,textarea,select')) return false;
  if (e.key === 'Escape') { e.preventDefault(); gQuit(); return true; }
  if (e.key === ' ') { e.preventDefault(); if ($('gplay')) $('gplay').click(); return true; }
  if (e.key === 'Tab' && !c.done) { e.preventDefault(); if (GAMES[G.id].kind !== 'year') gSkip(); return true; }
  const k = '1234'.indexOf(e.key) >= 0 ? '1234'.indexOf(e.key) : '&é"\''.indexOf(e.key);
  if (k >= 0 && G.mode === 'choice' && c.choices && !c.done) { const b = view.querySelectorAll('.gch')[k]; if (b && !b.disabled) b.click(); return true; }
  return false;
}

/* Répliques cultes : [VO, traduction française]. Clé = "Titre|année" (titres Letterboxd). */
const QUOTES_RAW = {
"The Dark Knight|2008": ["Why so serious?", "Pourquoi tant de sérieux ?"],
"Taxi Driver|1976": ["You talkin' to me?", "C'est à moi que tu parles ?"],
"Scarface|1983": ["Say hello to my little friend!", "Dis bonjour à mon petit ami !"],
"The Terminator|1984": ["I'll be back.", "Je reviendrai."],
"Terminator 2: Judgment Day|1991": ["Hasta la vista, baby.", "Hasta la vista, baby."],
"Star Wars|1977": ["May the Force be with you.", "Que la Force soit avec toi."],
"The Empire Strikes Back|1980": ["No, I am your father.", "Non, je suis ton père."],
"Return of the Jedi|1983": ["It's a trap!", "C'est un piège !"],
"Jaws|1975": ["You're gonna need a bigger boat.", "Il va nous falloir un plus gros bateau."],
"The Shining|1980": ["Here's Johnny!", "Voilà Johnny !"],
"Forrest Gump|1994": ["My mama always said life was like a box of chocolates. You never know what you're gonna get.", "Maman disait toujours : la vie, c'est comme une boîte de chocolats, on ne sait jamais sur quoi on va tomber."],
"Fight Club|1999": ["The first rule of Fight Club is: you do not talk about Fight Club.", "La première règle du Fight Club est : il est interdit de parler du Fight Club."],
"The Matrix|1999": ["There is no spoon.", "La cuillère n'existe pas."],
"Pulp Fiction|1994": ["Say 'what' again. I dare you, I double dare you!", "Dis encore « quoi », je te défie, je te mets au défi !"],
"The Silence of the Lambs|1991": ["A census taker once tried to test me. I ate his liver with some fava beans and a nice chianti.", "Un employé du recensement a voulu me tester un jour. J'ai mangé son foie avec des fèves et un bon chianti."],
"Toy Story|1995": ["To infinity and beyond!", "Vers l'infini et au-delà !"],
"The Lion King|1994": ["Hakuna Matata! It means no worries.", "Hakuna Matata ! Ça veut dire pas de soucis."],
"Back to the Future|1985": ["Roads? Where we're going, we don't need roads.", "Des routes ? Là où on va, on n'a pas besoin de routes."],
"Die Hard|1988": ["Yippee-ki-yay, motherf***er.", "Yippee-ki-yay, pauvre con."],
"Rocky|1976": ["Yo, Adrian!", "Yo, Adrian !"],
"Rocky Balboa|2006": ["It ain't about how hard you hit. It's about how hard you can get hit and keep moving forward.", "Ce n'est pas la force de tes coups qui compte, c'est combien de coups tu encaisses en continuant d'avancer."],
"Rocky IV|1985": ["I must break you.", "Je dois te briser."],
"Inception|2010": ["You mustn't be afraid to dream a little bigger, darling.", "Il ne faut pas avoir peur de rêver un peu plus grand, chéri."],
"Interstellar|2014": ["Love is the one thing we're capable of perceiving that transcends dimensions of time and space.", "L'amour est la seule chose que nous percevons qui transcende les dimensions du temps et de l'espace."],
"The Shawshank Redemption|1994": ["Get busy living, or get busy dying.", "Soit on s'occupe de vivre, soit on s'occupe de mourir."],
"Jurassic Park|1993": ["Life, uh, finds a way.", "La vie, euh… trouve toujours un chemin."],
"Home Alone|1990": ["Keep the change, ya filthy animal.", "Garde la monnaie, sale animal."],
"The Sixth Sense|1999": ["I see dead people.", "Je vois des gens qui sont morts."],
"Se7en|1995": ["What's in the box?!", "Qu'est-ce qu'il y a dans la boîte ?!"],
"The Usual Suspects|1995": ["The greatest trick the Devil ever pulled was convincing the world he didn't exist.", "Le plus grand coup du diable, c'est d'avoir fait croire au monde qu'il n'existait pas."],
"Léon: The Professional|1994": ["No women, no kids.", "Pas de femmes, pas d'enfants."],
"Avengers: Endgame|2019": ["I love you 3000.", "Je t'aime 3000."],
"Avengers: Infinity War|2018": ["Mr. Stark, I don't feel so good.", "Monsieur Stark, je ne me sens pas très bien."],
"Iron Man|2008": ["The truth is... I am Iron Man.", "La vérité, c'est que… je suis Iron Man."],
"Spider-Man|2002": ["With great power comes great responsibility.", "Un grand pouvoir implique de grandes responsabilités."],
"Harry Potter and the Philosopher's Stone|2001": ["You're a wizard, Harry.", "Tu es un sorcier, Harry."],
"Harry Potter and the Deathly Hallows: Part 2|2011": ["After all this time? — Always.", "Après tout ce temps ? — Toujours."],
"The Lord of the Rings: The Fellowship of the Ring|2001": ["You shall not pass!", "Vous ne passerez pas !"],
"The Lord of the Rings: The Two Towers|2002": ["My precious.", "Mon précieux."],
"The Lord of the Rings: The Return of the King|2003": ["I can't carry it for you, but I can carry you!", "Je ne peux pas le porter pour vous, mais je peux vous porter, vous !"],
"Finding Nemo|2003": ["Just keep swimming.", "Continue à nager."],
"Shrek|2001": ["Ogres are like onions.", "Les ogres, c'est comme les oignons."],
"Ratatouille|2007": ["Anyone can cook.", "Tout le monde peut cuisiner."],
"Up|2009": ["Squirrel!", "Écureuil !"],
"Taken|2008": ["I will look for you, I will find you, and I will kill you.", "Je vous chercherai, je vous trouverai, et je vous tuerai."],
"The Wolf of Wall Street|2013": ["Sell me this pen.", "Vends-moi ce stylo."],
"Whiplash|2014": ["Not quite my tempo.", "Pas tout à fait mon tempo."],
"Django Unchained|2012": ["The D is silent.", "Le D est muet."],
"Inglourious Basterds|2009": ["Oooh, that's a bingo!", "Oh, c'est un bingo !"],
"Kill Bill: Vol. 1|2003": ["Wiggle your big toe.", "Bouge ton gros orteil."],
"The Big Lebowski|1998": ["The Dude abides.", "Le Duc tient bon."],
"Good Will Hunting|1997": ["It's not your fault.", "C'est pas ta faute."],
"The Truman Show|1998": ["Good morning, and in case I don't see ya, good afternoon, good evening, and good night!", "Bonjour, et au cas où je ne vous reverrais pas, bon après-midi, bonne soirée et bonne nuit !"],
"Mean Girls|2004": ["On Wednesdays we wear pink.", "Le mercredi, on porte du rose."],
"The Pursuit of Happyness|2006": ["Don't ever let somebody tell you you can't do something.", "Ne laisse jamais personne te dire que tu ne peux pas faire quelque chose."],
"The Social Network|2010": ["A million dollars isn't cool. You know what's cool? A billion dollars.", "Un million de dollars, c'est pas cool. Tu sais ce qui est cool ? Un milliard de dollars."],
"Mad Max: Fury Road|2015": ["Oh, what a day... what a lovely day!", "Oh, quelle journée… quelle belle journée !"],
"John Wick|2014": ["People keep asking if I'm back... Yeah, I'm thinking I'm back!", "Les gens me demandent si je suis de retour… Ouais, je crois bien que je suis de retour !"],
"Gran Torino|2008": ["Get off my lawn.", "Dégage de ma pelouse."],
"Scream|1996": ["What's your favorite scary movie?", "Quel est ton film d'horreur préféré ?"],
"Get Out|2017": ["I would have voted for Obama for a third term if I could.", "J'aurais voté pour Obama une troisième fois si j'avais pu."],
"Black Panther|2018": ["Wakanda forever!", "Wakanda pour toujours !"],
"Deadpool|2016": ["Maximum effort!", "Effort maximum !"],
"Guardians of the Galaxy|2014": ["I am Groot.", "Je s'appelle Groot."],
"The Incredibles|2004": ["No capes!", "Pas de capes !"],
"Parasite|2019": ["You know what kind of plan never fails? No plan at all.", "Tu sais quel plan ne rate jamais ? Pas de plan du tout."],
"La Haine|1995": ["Jusqu'ici tout va bien…", "Jusqu'ici tout va bien…"],
"The Dinner Game|1998": ["Il s'appelle Juste Leblanc.", "Il s'appelle Juste Leblanc."],
"American Psycho|2000": ["I have to return some videotapes.", "Il faut que j'aille rendre des cassettes vidéo."],
"Donnie Darko|2001": ["Why are you wearing that stupid man suit?", "Pourquoi tu portes ce stupide costume d'homme ?"],
"Aliens|1986": ["Get away from her, you bitch!", "Éloigne-toi d'elle, salope !"],
"Blade Runner|1982": ["All those moments will be lost in time, like tears in rain.", "Tous ces moments se perdront dans l'oubli, comme les larmes dans la pluie."],
"Raiders of the Lost Ark|1981": ["Snakes. Why'd it have to be snakes?", "Des serpents. Pourquoi il faut toujours que ce soit des serpents ?"],
"Ferris Bueller's Day Off|1986": ["Life moves pretty fast. If you don't stop and look around once in a while, you could miss it.", "La vie passe vite. Si on ne s'arrête pas de temps en temps pour regarder autour de soi, on risque de la rater."],
"Psycho|1960": ["A boy's best friend is his mother.", "Le meilleur ami d'un garçon, c'est sa mère."],
"2001: A Space Odyssey|1968": ["I'm sorry, Dave. I'm afraid I can't do that.", "Je suis désolé, Dave. Je crains de ne pas pouvoir faire ça."],
"Dumb and Dumber|1994": ["So you're telling me there's a chance.", "Donc tu me dis qu'il y a une chance."],
"The Mask|1994": ["Smokin'!", "Ssssplendide !"],
"GoodFellas|1990": ["Funny how? Like I'm a clown? I amuse you?", "Drôle comment ? Comme un clown ? Je t'amuse ?"],
"Oppenheimer|2023": ["Now I am become Death, the destroyer of worlds.", "Maintenant je suis devenu la Mort, le destructeur des mondes."],
"Barbie|2023": ["I'm just Ken.", "Je suis juste Ken."],
"Dune|2021": ["Fear is the mind-killer.", "La peur tue l'esprit."],
"Spider-Man: Into the Spider-Verse|2018": ["Anyone can wear the mask.", "N'importe qui peut porter le masque."],
"Hot Fuzz|2007": ["The greater good.", "Pour le bien commun."],
"The Prestige|2006": ["Are you watching closely?", "Vous regardez attentivement ?"],
"No Country for Old Men|2007": ["What's the most you ever lost on a coin toss?", "Quelle est la plus grosse somme que vous ayez perdue à pile ou face ?"],
"Lilo & Stitch|2002": ["Ohana means family. Family means nobody gets left behind or forgotten.", "Ohana signifie famille. Et famille signifie que personne ne doit être abandonné, ni oublié."],
"Kung Fu Panda|2008": ["There are no accidents.", "Le hasard n'existe pas."],
"The Devil Wears Prada|2006": ["Florals? For spring? Groundbreaking.", "Des fleurs ? Pour le printemps ? Quelle audace."],
"The Hunger Games|2012": ["I volunteer as tribute!", "Je me porte volontaire !"],
"Mission: Impossible|1996": ["Your mission, should you choose to accept it...", "Votre mission, si toutefois vous l'acceptez…"],
"Aladdin|1992": ["Phenomenal cosmic powers! Itty-bitty living space.", "Des pouvoirs cosmiques phénoménaux… dans un minuscule espace vital."],
"Beetlejuice|1988": ["It's showtime!", "C'est l'heure du spectacle !"],
"Shutter Island|2010": ["Which would be worse: to live as a monster, or to die as a good man?", "Qu'est-ce qui serait pire : vivre comme un monstre, ou mourir en homme bien ?"],
"Carrie|1976": ["They're all gonna laugh at you!", "Ils vont tous se moquer de toi !"],
"A Nightmare on Elm Street|1984": ["Whatever you do, don't fall asleep.", "Quoi que vous fassiez, ne vous endormez pas."],
"Saw|2004": ["I want to play a game.", "Je voudrais faire un jeu."],
"Batman Begins|2005": ["Why do we fall? So we can learn to pick ourselves up.", "Pourquoi tombons-nous ? Pour apprendre à nous relever."],
"The Avengers|2012": ["Puny god.", "Dieu minable."],
"Thor: Ragnarok|2017": ["He's a friend from work!", "C'est un ami du boulot !"],
"Joker|2019": ["You get what you f***ing deserve!", "On a ce qu'on mérite !"]
};

/* ================= v11 : Tier list, Tri rapide, Ce soir, À deux, Stats, Récap, sons, thèmes ================= */

/* ---------- Sons (synthétisés, aucun fichier) ---------- */
const SFX = {ctx:null};
const sfxOn = () => ls.get('ringcine-sfx', true);
function sfx(kind){
  if (!sfxOn()) return;
  try {
    const a = SFX.ctx || (SFX.ctx = new (window.AudioContext || window.webkitAudioContext)());
    if (a.state === 'suspended') a.resume();
    const t = a.currentTime, out = a.createGain(); out.gain.value = .5; out.connect(a.destination);
    const tone = (f, f2, type, d, v, at = 0) => { const o = a.createOscillator(), g = a.createGain(); o.type = type; o.frequency.setValueAtTime(f, t + at); if (f2) o.frequency.exponentialRampToValueAtTime(f2, t + at + d); g.gain.setValueAtTime(0.0001, t + at); g.gain.exponentialRampToValueAtTime(v, t + at + .01); g.gain.exponentialRampToValueAtTime(0.0001, t + at + d); o.connect(g); g.connect(out); o.start(t + at); o.stop(t + at + d + .05); };
    const noise = (d, v, fq) => { const b = a.createBuffer(1, a.sampleRate * d, a.sampleRate), ch = b.getChannelData(0); for (let i = 0; i < ch.length; i++) ch[i] = (Math.random() * 2 - 1) * (1 - i / ch.length) ** 2; const s = a.createBufferSource(), f = a.createBiquadFilter(), g = a.createGain(); f.type = 'lowpass'; f.frequency.value = fq; g.gain.value = v; s.buffer = b; s.connect(f); f.connect(g); g.connect(out); s.start(t); };
    if (kind === 'ko') { noise(.18, .9, 900); tone(150, 45, 'sine', .22, .9); }
    else if (kind === 'bell') { [[830, .5], [1660, .25], [2490, .12], [415, .3]].forEach(([f, v]) => tone(f, 0, 'sine', 1.8, v)); tone(830, 0, 'sine', 1.8, .4, .45); }
    else if (kind === 'win') { [523, 659, 784, 1047].forEach((f, k) => tone(f, 0, 'triangle', .25, .35, k * .08)); }
    else if (kind === 'lose') { tone(240, 110, 'sawtooth', .35, .18); }
    else if (kind === 'tick') { tone(1200, 800, 'square', .05, .08); }
    else if (kind === 'whoosh') { noise(.25, .35, 2400); }
  } catch(e){}
}
function confetti(n = 170){
  if (!sfxOn() && !ls.get('ringcine-fx', true)) return;
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const cv = document.createElement('canvas'); cv.className = 'confetti'; document.body.appendChild(cv);
  const W = cv.width = innerWidth, H = cv.height = innerHeight, g = cv.getContext('2d');
  const cs = getComputedStyle(document.documentElement), cols = [cs.getPropertyValue('--gold').trim() || '#D8B46A', '#F3DFA8', '#C8404F', '#5584DD', '#ffffff'];
  const P = Array.from({length:n}, () => ({x: W / 2 + (Math.random() - .5) * W * .3, y: H * .35, vx: (Math.random() - .5) * 16, vy: -Math.random() * 16 - 4, s: 5 + Math.random() * 7, r: Math.random() * 6, vr: (Math.random() - .5) * .3, c: cols[Math.floor(Math.random() * cols.length)]}));
  const t0 = performance.now();
  const step = now => { const el = now - t0; g.clearRect(0, 0, W, H); P.forEach(p => { p.vy += .42; p.vx *= .99; p.x += p.vx; p.y += p.vy; p.r += p.vr; g.save(); g.translate(p.x, p.y); g.rotate(p.r); g.globalAlpha = Math.max(0, 1 - el / 2600); g.fillStyle = p.c; g.fillRect(-p.s / 2, -p.s / 4, p.s, p.s / 2); g.restore(); }); if (el < 2600) requestAnimationFrame(step); else cv.remove(); };
  requestAnimationFrame(step);
}

/* ---------- Thème (clair / sombre) et couleur ---------- */
function applyTheme(){
  const d = document.documentElement;
  d.dataset.theme = ls.get('ringcine-theme', 'dark');
  d.dataset.accent = ls.get('ringcine-accent', 'gold');
}

/* ---------- Historique du classement (rejoue les duels enregistrés) ---------- */
function eloStart(){
  const e = S.elo.slice();
  for (let k = S.log.length - 1; k >= 0; k--) { const h = S.log[k]; e[h.w] -= h.dl; e[h.l] += h.dl; }
  return e;
}
function rankIn(elo, i){ let r = 1; const v = elo[i]; for (let j = 0; j < elo.length; j++) if (elo[j] > v) r++; return r; }
function rankHistory(i, pts = 48){
  const L = S.log.length; if (!L) return [];
  const e = eloStart(), every = Math.max(1, Math.floor(L / pts)), out = [{k:0, r: rankIn(e, i)}];
  for (let k = 0; k < L; k++) { const h = S.log[k]; e[h.w] += h.dl; e[h.l] -= h.dl; if ((k + 1) % every === 0 || k === L - 1 || h.w === i || h.l === i) out.push({k: k + 1, r: rankIn(e, i)}); }
  return out;
}
function eloAtIndex(idx){ const e = eloStart(); for (let k = 0; k < Math.min(idx, S.log.length); k++) { const h = S.log[k]; e[h.w] += h.dl; e[h.l] -= h.dl; } return e; }
function histSvg(i){
  const H = rankHistory(i); if (H.length < 3) return '<div class="note">L’historique apparaîtra après quelques duels de ce ' + TY.one + '.</div>';
  const W = 520, Hh = 110, maxK = H[H.length - 1].k || 1, rs = H.map(p => p.r), lo = Math.min(...rs), hi = Math.max(...rs), span = Math.max(1, hi - lo);
  const x = k => 6 + k / maxK * (W - 12), y = r => 8 + (r - lo) / span * (Hh - 16);
  const d = H.map((p, n) => `${n ? 'L' : 'M'}${x(p.k).toFixed(1)} ${y(p.r).toFixed(1)}`).join('');
  const first = H[0].r, last = rs[rs.length - 1], best = lo;
  return `<div class="hist"><div class="hist-t">${first === last ? `Toujours n° ${last}` : `${last < first ? '▲' : '▼'} Passé de <b>#${first}</b> à <b>#${last}</b>`} · meilleur rang <b>#${best}</b></div>
    <svg viewBox="0 0 ${W} ${Hh}" preserveAspectRatio="none" class="hist-svg" role="img" aria-label="Évolution du rang"><path d="${d}" /><circle cx="${x(H[H.length - 1].k)}" cy="${y(last)}" r="4"/></svg>
    <div class="hist-l"><span>début</span><span>${fmt(maxK)} duels</span></div></div>`;
}

/* ---------- Données par ring : tier list et tri rapide ---------- */
const TIERS = [['S', '#E8C36A'], ['A', '#86C98A'], ['B', '#6FA8DC'], ['C', '#B48EDB'], ['D', '#D97A7A']];
const tierKey = () => 'ringcine-tier-' + C.id, swKey = () => 'ringcine-swipe-' + C.id;
function tierData(){ const d = ls.get(tierKey(), null) || {}; TIERS.forEach(([t]) => { if (!Array.isArray(d[t])) d[t] = []; }); return d; }
function swipeData(){ const d = ls.get(swKey(), null) || {}; d.keep ||= []; d.drop ||= []; d.hist ||= []; return d; }
let keepCache = {v:-1, id:null, set:null};
function keptSet(){ if (keepCache.v !== LSVER || keepCache.id !== C.id) keepCache = {v: LSVER, id: C.id, set: new Set(swipeData().keep)}; return keepCache.set; }
const keptIdx = () => { const s = keptSet(); const out = []; for (let i = 0; i < N; i++) if (s.has(F[i].key)) out.push(i); return out; };

/* ---------- Vue : Tier list ---------- */
let tierQ = '', tierShown = 80, tierOnlyKept = false, tierPop = null;
function renderTier(){
  if (!N) { view.innerHTML = '<div class="empty">Ce ring est vide.</div>'; return; }
  const d = tierData(), byKey = new Map(F.map((it, i) => [it.key, i]));
  TIERS.forEach(([t]) => d[t] = d[t].filter(k => byKey.has(k)));
  const placed = new Set(TIERS.flatMap(([t]) => d[t]));
  const q = norm(tierQ), ks = keptSet();
  const pool = ranking().order.filter(i => !placed.has(F[i].key) && (!tierOnlyKept || ks.has(F[i].key)) && (!q || norm(F[i].t + ' ' + (F[i].en || '') + ' ' + (F[i].sub || '')).includes(q)));
  const tile = i => `<div class="tt" draggable="true" data-k="${esc(F[i].key)}" title="${T(i)}">${img(i, 'tti')}</div>`;
  view.innerHTML = `<div class="tools">
      <input class="input" id="tq" type="search" placeholder="Chercher à placer…" value="${esc(tierQ)}">
      ${ks.size ? `<label class="note tchk"><input type="checkbox" id="tkept" ${tierOnlyKept ? 'checked' : ''}> Seulement mes gardés ♥ (${ks.size})</label>` : ''}
      <button class="btn sm" id="tauto" title="Remplit avec ton top 60 du classement">✨ Remplir depuis le classement</button>
      <button class="btn sm ghost" id="tclear">Tout vider</button>
      <button class="btn sm primary" id="tpng">🖼 Image <kbd>P</kbd></button></div>
    <p class="note" style="margin:-4px 0 12px">Glisse les affiches dans une rangée, ou clique sur une affiche pour choisir sa rangée.</p>
    <div class="tierboard">${TIERS.map(([t, c]) => `<div class="trow"><div class="tlab" style="--tc:${c}">${t}<small>${d[t].length}</small></div><div class="tzone" data-t="${t}">${d[t].map(k => tile(byKey.get(k))).join('') || '<span class="tempty">Dépose ici</span>'}</div></div>`).join('')}</div>
    <div class="panel tpoolp"><h3>À placer · ${fmt(pool.length)}</h3><div class="tzone pool" data-t="">${pool.slice(0, tierShown).map(tile).join('')}</div>
      ${pool.length > tierShown ? `<button class="btn more" id="tmore2">Afficher plus (${fmt(pool.length - tierShown)})</button>` : ''}</div>`;
  const saveMove = (k, t, beforeK) => {
    const dd = tierData(); TIERS.forEach(([x]) => dd[x] = dd[x].filter(y => y !== k));
    if (t) { const arr = dd[t], pos = beforeK ? arr.indexOf(beforeK) : -1; if (pos >= 0) arr.splice(pos, 0, k); else arr.push(k); }
    ls.set(tierKey(), dd); sfx('tick');
    const sy = scrollY; renderTier(); window.scrollTo(0, sy);
  };
  let dragK = null;
  view.querySelectorAll('.tt').forEach(el => {
    el.ondragstart = e => { dragK = el.dataset.k; e.dataTransfer.setData('text/plain', dragK); e.dataTransfer.effectAllowed = 'move'; el.classList.add('dragging'); };
    el.ondragend = () => el.classList.remove('dragging');
    el.onclick = e => {
      closeTierPop();
      const r = el.getBoundingClientRect(), pop = document.createElement('div'); pop.className = 'tpop';
      pop.innerHTML = TIERS.map(([t, c]) => `<button style="--tc:${c}" data-t="${t}">${t}</button>`).join('') + '<button data-t="" title="Retirer">✕</button>';
      pop.style.left = Math.min(innerWidth - 250, r.left + scrollX) + 'px'; pop.style.top = (r.bottom + scrollY + 6) + 'px';
      document.body.appendChild(pop); tierPop = pop;
      pop.querySelectorAll('button').forEach(b => b.onclick = ev => { ev.stopPropagation(); closeTierPop(); saveMove(el.dataset.k, b.dataset.t); });
      e.stopPropagation();
    };
  });
  view.querySelectorAll('.tzone').forEach(z => {
    z.ondragover = e => { e.preventDefault(); z.classList.add('over'); };
    z.ondragleave = () => z.classList.remove('over');
    z.ondrop = e => {
      e.preventDefault(); z.classList.remove('over');
      const k = e.dataTransfer.getData('text/plain') || dragK; if (!k) return;
      const target = [...z.querySelectorAll('.tt')].find(t => { const r = t.getBoundingClientRect(); return e.clientY < r.bottom && e.clientX < r.left + r.width / 2 && e.clientY > r.top - 10; });
      saveMove(k, z.dataset.t, target && target.dataset.k !== k ? target.dataset.k : null);
    };
  });
  const tq = $('tq'); tq.oninput = () => { tierQ = tq.value; clearTimeout(qT); qT = setTimeout(() => { renderTier(); const n = $('tq'); n.focus(); n.setSelectionRange(n.value.length, n.value.length); }, 140); };
  if ($('tkept')) $('tkept').onchange = e => { tierOnlyKept = e.target.checked; renderTier(); };
  if ($('tmore2')) $('tmore2').onclick = () => { tierShown += 120; renderTier(); };
  $('tauto').onclick = () => {
    const src = (tierOnlyKept && ks.size ? ranking().order.filter(i => ks.has(F[i].key)) : ranking().order).slice(0, 60);
    const cut = [6, 12, 18, 14, 10], dd = {}; let p = 0;
    TIERS.forEach(([t], n) => { dd[t] = src.slice(p, p + cut[n]).map(i => F[i].key); p += cut[n]; });
    ls.set(tierKey(), dd); renderTier(); toast('Tier list remplie avec ton top ' + src.length + '. Ajuste en glissant.');
  };
  $('tclear').onclick = () => { if ($('tclear').dataset.armed) { ls.set(tierKey(), {}); renderTier(); } else { $('tclear').dataset.armed = 1; $('tclear').textContent = 'Confirmer ?'; } };
  $('tpng').onclick = pngTier;
}
function closeTierPop(){ if (tierPop) { tierPop.remove(); tierPop = null; } }
document.addEventListener('click', e => { if (tierPop && !tierPop.contains(e.target)) closeTierPop(); });
async function pngTier(){
  const d = tierData(), byKey = new Map(F.map((it, i) => [it.key, i])), rows = TIERS.map(([t, c]) => ({t, c, items: d[t].filter(k => byKey.has(k)).map(k => byKey.get(k))}));
  if (!rows.some(r => r.items.length)) { toast('Place d’abord des affiches dans la tier list.'); return; }
  toast('Création de l’image…'); await pngFonts();
  const W = 1600, cw = TY.sq ? 110 : 96, ch = TY.sq ? 110 : 144, gap = 8, lab = 130, perRow = Math.floor((W - 80 - lab - 20) / (cw + gap));
  const heights = rows.map(r => Math.max(1, Math.ceil(r.items.length / perRow)) * (ch + gap) + gap);
  const H = 300 + heights.reduce((a, b) => a + b + 10, 0) + 80;
  const cv = document.createElement('canvas'); cv.width = W; cv.height = H; const g = cv.getContext('2d');
  pngFrame(g, W, H, `Tier list · ${typeName(C.type)}`, C.label);
  const all = rows.flatMap(r => r.items), ims = new Map((await Promise.all(all.map(i => loadImg(proxied(F[i].img))))).map((im, n) => [all[n], im]));
  let y = 300;
  rows.forEach((r, n) => {
    const h = heights[n];
    g.fillStyle = 'rgba(255,255,255,.04)'; rrect(g, 40, y, W - 80, h, 12); g.fill();
    g.fillStyle = r.c; rrect(g, 40, y, lab, h, 12); g.fill();
    g.fillStyle = '#16120A'; g.font = '900 64px Archivo, Inter, sans-serif'; g.textAlign = 'center'; g.fillText(r.t, 40 + lab / 2, y + h / 2 + 22); g.textAlign = 'left';
    r.items.forEach((i, k) => { const cx = 40 + lab + 16 + (k % perRow) * (cw + gap), cy = y + gap + Math.floor(k / perRow) * (ch + gap); drawCover(g, ims.get(i), cx, cy, cw, ch, F[i].t); });
    y += h + 10;
  });
  await savePng(cv, `ring-tierlist-${fileSafe(C.label)}.png`);
}

/* ---------- Vue : Tri rapide (garder / jeter) ---------- */
let swQueue = null, swQueueCol = null, swAnim = false;
function swNext(){
  const d = swipeData(), done = new Set(d.keep.concat(d.drop));
  if (!swQueue || swQueueCol !== C.id) { swQueue = shuffle([...Array(N).keys()]); swQueueCol = C.id; }
  while (swQueue.length && done.has(F[swQueue[0]].key)) swQueue.shift();
  return swQueue.length ? swQueue[0] : null;
}
function renderSwipe(){ if (hlMode === 'hl') return renderHL(); return renderSwipeKeep(); }
function renderSwipeKeep(){
  if (!N) { view.innerHTML = '<div class="empty">Ce ring est vide.</div>'; return; }
  const d = swipeData(), i = swNext(), left = swQueue ? swQueue.length : 0, ks = keptIdx();
  const nxt = swQueue && swQueue[1] != null ? swQueue[1] : null;
  view.innerHTML = `<div class="ptabs"><button data-hm="hl" aria-selected="false">⬆⬇ Plus ou moins</button><button data-hm="swipe" aria-selected="true">♥ Garder / jeter</button></div><div class="swipe">
    <div class="sw-side">
      <div class="panel"><h3>Ta progression</h3>
        <div class="sw-stats"><div><b>${fmt(d.keep.length)}</b><span>gardés ♥</span></div><div><b>${fmt(d.drop.length)}</b><span>jetés</span></div><div><b>${fmt(left)}</b><span>restants</span></div></div>
        <div class="bar"><i style="width:${N ? ((N - left) / N * 100).toFixed(1) : 0}%"></i></div></div>
      <div class="panel"><h3>Tes gardés</h3>
        ${ks.length ? `<div class="sw-kept">${ks.slice(-24).reverse().map(j => img(j, 'th')).join('')}</div>
          <div class="sw-acts"><button class="btn sm primary" id="swtour">🏆 Tournoi des gardés</button><button class="btn sm" id="swduel">⚔ Duels entre gardés</button><button class="btn sm" id="swtier">Tier list des gardés</button></div>` : '<div class="empty">Garde des ' + TY.many + ' pour faire ta sélection.</div>'}
        <p style="margin:12px 0 0"><button class="lnk danger" id="swreset">Tout recommencer</button></p></div>
    </div>
    <div class="sw-main">
      ${i == null ? `<div class="sw-done"><div class="big">Fini !</div><p class="note">Tu as trié tout le ring : ${fmt(d.keep.length)} gardés sur ${fmt(N)}.</p></div>` : `
      <div class="sw-stack">
        ${nxt != null ? `<div class="sw-card back">${imgHi(nxt)}</div>` : ''}
        <div class="sw-card" id="swcard">${imgHi(i)}<span class="sw-lab keep">GARDER</span><span class="sw-lab drop">JETER</span></div>
      </div>
      <div class="sw-info"><h2>${T(i)}</h2><div class="cmeta">${metaLine(i)}</div></div>
      ${C.type === 'music' ? `<div class="sw-player">${playerHtml(i, 0)}</div>` : ''}
      <div class="sw-btns">
        <button class="sw-b drop" id="swdrop" title="Jeter (←)">✕</button>
        <button class="sw-b undo" id="swundo" title="Annuler (Retour)" ${d.hist.length ? '' : 'disabled'}>↶</button>
        <button class="sw-b skip" id="swskip" title="Passer / pas vu (↓)">⤼</button>
        <button class="sw-b keep" id="swkeep" title="Garder (→)">♥</button>
      </div>
      <div class="khint"><span><kbd>←</kbd> jeter</span><span><kbd>→</kbd> garder</span><span><kbd>↓</kbd> passer</span><span><kbd>Retour</kbd> annuler</span></div>`}
    </div></div>`;
  view.querySelectorAll('[data-hm]').forEach(b => b.onclick = () => { hlMode = b.dataset.hm; renderSwipe(); });
  if ($('swtour')) $('swtour').onclick = () => { const ids = keptIdx(); if (ids.length < 2) return toast('Garde au moins 2 ' + TY.many + '.'); newTour({id:'keep', name:'Tournoi des gardés', n: ids.length, ids}); tpanel = 'feed'; go('tour'); };
  if ($('swduel')) $('swduel').onclick = () => { S.filter = 'keep'; save(); pair = null; nextPair = null; go('duel'); };
  if ($('swtier')) $('swtier').onclick = () => { tierOnlyKept = true; go('tier'); };
  $('swreset').onclick = () => { const b = $('swreset'); if (b.dataset.armed) { ls.set(swKey(), {keep:[], drop:[], hist:[]}); swQueue = null; renderSwipe(); } else { b.dataset.armed = 1; b.textContent = 'Sûr ? Clique encore pour tout effacer'; } };
  if (i == null) return;
  $('swdrop').onclick = () => swDecide('drop'); $('swkeep').onclick = () => swDecide('keep');
  $('swskip').onclick = () => swDecide('skip'); $('swundo').onclick = swUndo;
  const card = $('swcard'); let st = null;
  card.onpointerdown = e => { st = {x: e.clientX, y: e.clientY}; card.setPointerCapture(e.pointerId); card.style.transition = 'none'; };
  card.onpointermove = e => { if (!st) return; const dx = e.clientX - st.x, dy = e.clientY - st.y; card.style.transform = `translate(${dx}px,${dy * .3}px) rotate(${dx / 18}deg)`; card.classList.toggle('k', dx > 60); card.classList.toggle('d', dx < -60); };
  card.onpointerup = e => { if (!st) return; const dx = e.clientX - st.x; st = null; card.style.transition = ''; if (dx > 110) swDecide('keep'); else if (dx < -110) swDecide('drop'); else { card.style.transform = ''; card.classList.remove('k', 'd'); } };
}
function swDecide(kind){
  if (swAnim) return; const i = swNext(); if (i == null) return;
  const card = $('swcard'), k = F[i].key;
  const commit = () => {
    swAnim = false;
    if (kind === 'skip') { swQueue.push(swQueue.shift()); renderSwipe(); return; }
    const d = swipeData(); d[kind].push(k); d.hist.push([kind, k]); if (d.hist.length > 200) d.hist.shift(); ls.set(swKey(), d); renderSwipe();
  };
  sfx(kind === 'keep' ? 'tick' : kind === 'drop' ? 'whoosh' : 'tick');
  if (card) { swAnim = true; card.style.transition = 'transform .28s ease, opacity .28s'; card.style.transform = kind === 'keep' ? 'translate(120%, -4%) rotate(18deg)' : kind === 'drop' ? 'translate(-120%, -4%) rotate(-18deg)' : 'translateY(40%) scale(.9)'; card.style.opacity = '0'; setTimeout(commit, 260); }
  else commit();
}
function swUndo(){
  const d = swipeData(), h = d.hist.pop(); if (!h) return;
  d[h[0]] = d[h[0]].filter(x => x !== h[1]); ls.set(swKey(), d);
  const i = F.findIndex(it => it.key === h[1]); if (i >= 0 && swQueue) swQueue.unshift(i);
  renderSwipe();
}
function swipeKey(e){
  if (curView === 'tonight' && TN.reel && e.key === ' ' && !e.target.matches('input,textarea,select')) { e.preventDefault(); rlSpin(); return true; }
  if (hlKey(e)) return true;
  if (curView !== 'swipe' || hlMode !== 'swipe' || e.target.matches('input,textarea,select')) return false;
  if (e.key === 'ArrowLeft') { e.preventDefault(); swDecide('drop'); return true; }
  if (e.key === 'ArrowRight') { e.preventDefault(); swDecide('keep'); return true; }
  if (e.key === 'ArrowDown') { e.preventDefault(); swDecide('skip'); return true; }
  if (e.key === 'Backspace') { e.preventDefault(); swUndo(); return true; }
  return false;
}

/* ---------- Vue : Ce soir je regarde quoi ---------- */
const TN = {col:null, size:8, items:null, round:null, next:null, champ:null};
function tonightCols(){ return allCols().filter(c => colRows(c).length >= 2); }
function renderTonight(){
  if (TN.edit) return renderRlEdit();
  if (TN.reel && RL.list) return renderReel();
  const cols = tonightCols();
  if (!TN.round && !TN.champ) {
    const wl = cols.find(c => /watchlist/i.test((c.src || '') + ' ' + c.label));
    if (!TN.col || !colById(TN.col)) TN.col = (wl || C || cols[0]).id;
    view.innerHTML = `<section class="tn-intro">
      <span class="kicker">Ce soir</span><h2>Tu regardes quoi ?</h2>
      <p>Ring tire des ${TY.many} au hasard et tu les élimines un par un jusqu’au gagnant de la soirée.</p>
      <div class="tn-opts">
        <label class="note">Dans quel ring ?<select id="tncol">${cols.map(c => `<option value="${esc(c.id)}" ${c.id === TN.col ? 'selected' : ''}>${esc(c.label)} (${fmt(colRows(c).length)})</option>`).join('')}</select></label>
        <div><div class="note">Combien de candidats ?</div><div class="seg" id="tnsize">${[4, 8, 16].map(n => `<button data-n="${n}" aria-pressed="${TN.size === n}">${n}</button>`).join('')}</div></div>
      </div>
      <div class="fx" style="gap:10px;justify-content:center;flex-wrap:wrap"><button class="btn primary" id="tngo">🎬 Élimination</button><button class="btn primary" id="tnwheel">🎰 Roulette (tout le ring)</button><button class="btn" id="tnedit">✏️ Roulette perso</button></div>
      ${wl ? '' : `<p class="note tn-hint">Astuce : pour choisir parmi les films que tu n’as <b>pas encore vus</b>, ouvre ta watchlist Letterboxd (<a href="https://letterboxd.com/${esc(MY_LB)}/watchlist/" target="_blank" rel="noopener">letterboxd.com/${esc(MY_LB)}/watchlist</a>) et clique sur <b>Ring Sync</b>. Elle apparaîtra ici.</p>`}
    </section>`;
    $('tncol').onchange = e => { TN.col = e.target.value; };
    view.querySelectorAll('#tnsize button').forEach(b => b.onclick = () => { TN.size = +b.dataset.n; renderTonight(); });
    $('tnwheel').onclick = () => rlStartRing($('tncol').value || TN.col);
    $('tnedit').onclick = () => { TN.edit = true; renderTonight(); };
    $('tngo').onclick = () => { const sn = colSnapshot(colById(TN.col)); const ids = shuffle([...Array(sn.n).keys()]).slice(0, Math.min(TN.size, sn.n)); TN.items = sn; TN.round = ids; TN.next = []; TN.champ = null; renderTonight(); };
    return;
  }
  const sn = TN.items, sq = colType(sn.col).sq;
  const big = (i, side) => `<div class="fighter"><button class="card ${side}" data-i="${i}"><span class="art">${img(i, 'poster', sn.items, sq, true)}<span class="corner">${side === 'l' ? '← ' : ''}${side === 'l' ? 'ROUGE' : 'BLEU'}${side === 'r' ? ' →' : ''}</span><span class="pick">Celui-là</span><span class="stamp">K.O.</span></span><span class="ctitle">${esc(sn.items[i].t)}</span><span class="cmeta">${esc([sn.items[i].y || '', sn.items[i].sub].filter(Boolean).join(' · '))}</span></button></div>`;
  if (TN.champ != null) {
    const it = sn.items[TN.champ], q = encodeURIComponent(`${it.t} ${it.y || ''} bande annonce vostfr`);
    view.innerHTML = `<section class="tn-win"><div class="tn-bg">${it.img ? `<img src="${esc(hiRes(it.img))}" alt="" referrerpolicy="no-referrer">` : ''}</div>
      <div class="tn-in"><span class="kicker">Ce soir, tu regardes</span>${img(TN.champ, 'poster', sn.items, sq, true)}<h2>${esc(it.t)}</h2><div class="cmeta">${esc([it.y || '', it.sub].filter(Boolean).join(' · '))}</div>
      <div class="row"><a class="btn primary" href="https://www.youtube.com/results?search_query=${q}" target="_blank" rel="noopener">▶ Bande-annonce</a>${sn.col.type === 'films' || /letterboxd/.test(sn.col.host || '') ? `<a class="btn" href="${it.link ? esc(it.link) : `https://letterboxd.com/search/films/${encodeURIComponent(it.t + ' ' + (it.y || ''))}/`}" target="_blank" rel="noopener">Letterboxd ↗</a>` : ''}<button class="btn" id="tnagain">↻ Rejouer</button></div></div></section>`;
    $('tnagain').onclick = () => { TN.round = null; TN.champ = null; renderTonight(); };
    if (WH.sn && WH.sn === sn) { const b2 = document.createElement('button'); b2.className = 'btn'; b2.textContent = '🎡 Relancer la roulette'; b2.onclick = () => { TN.champ = null; TN.wheel = true; renderTonight(); }; view.querySelector('.tn-in .row').appendChild(b2); }
    return;
  }
  const a = TN.round[0], b = TN.round[1], total = TN.round.length + TN.next.length;
  view.innerHTML = `<section class="stage">
    <div class="stagehead"><div class="round"><b>Ce soir</b> · encore ${total} en lice</div><button class="btn sm ghost" id="tnquit">Arrêter</button></div>
    <div class="arena${sq ? ' sq-col' : ''}">${big(a, 'l')}<div class="vs">VS</div>${big(b, 'r')}</div>
    <div class="khint"><span><kbd>←</kbd> <kbd>→</kbd> choisir</span></div></section>`;
  view.querySelectorAll('.card').forEach(c => c.onclick = () => {
    const w = +c.dataset.i, lo = w === a ? b : a;
    const cw = c, cl = view.querySelector(`.card[data-i="${lo}"]`); cw.classList.add('win'); if (cl) cl.classList.add('ko'); view.querySelectorAll('.card').forEach(x => x.disabled = true); sfx('ko');
    setTimeout(() => {
      TN.round.splice(0, 2); TN.next.push(w);
      if (TN.round.length < 2) { const rest = TN.round.splice(0); TN.round = TN.next.concat(rest); TN.next = []; }
      if (TN.round.length === 1) { TN.champ = TN.round[0]; TN.round = null; renderTonight(); sfx('bell'); confetti(); } else renderTonight();
    }, 300);
  });
  $('tnquit').onclick = () => { TN.round = null; TN.champ = null; renderTonight(); };
}

/* ---------- Vue : Stats + Récap du mois ---------- */
let statsTab = 'stats', recapMonth = null;
function groupStats(){
  const m = new Map();
  F.forEach((it, i) => (it.sub || '').split(/,\s*/).filter(Boolean).forEach(p => { const g = m.get(p) || {n:0, sum:0, best:-1e9, bi:i}; g.n++; g.sum += S.elo[i]; if (S.elo[i] > g.best) { g.best = S.elo[i]; g.bi = i; } m.set(p, g); }));
  return [...m].filter(([, g]) => g.n >= 3).map(([p, g]) => ({p, n: g.n, avg: g.sum / g.n, bi: g.bi})).sort((a, b) => b.avg - a.avg);
}
function renderStats(){
  const tabs = `<div class="ptabs"><button data-s="stats" aria-selected="${statsTab === 'stats'}">🧬 Ton ADN ${C.type === 'music' ? 'musique' : 'ciné'}</button><button data-s="recap" aria-selected="${statsTab === 'recap'}">🗓 Récap du mois</button>${C.type === 'films' ? `<button data-s="map" aria-selected="${statsTab === 'map'}">🌍 Carte du monde</button><button data-s="web" aria-selected="${statsTab === 'web'}">🕸 Toile des acteurs</button>` : ''}</div>`;
  if (statsTab === 'recap') return renderRecap(tabs);
  if ((statsTab === 'map' || statsTab === 'web') && C.type !== 'films') statsTab = 'stats';
  if (statsTab === 'map') return renderMap(tabs);
  if (statsTab === 'web') return renderWeb(tabs);
  const {order, rank} = ranking(), st = curStats(), films = C.type === 'films';
  const groups = groupStats(), topG = groups.slice(0, 10), maxAvg = topG.length ? topG[0].avg : 1, minAvg = groups.length ? groups[groups.length - 1].avg : 0;
  const bar = (v, lo, hi) => `<span class="sbar"><i style="width:${Math.max(4, (v - lo) / Math.max(1, hi - lo) * 100).toFixed(1)}%"></i></span>`;
  let decades = '';
  if (films) {
    const m = new Map(); F.forEach((it, i) => { if (!it.y) return; const d = Math.floor(it.y / 10) * 10; const g = m.get(d) || {n:0, sum:0}; g.n++; g.sum += S.elo[i]; m.set(d, g); });
    const arr = [...m].filter(([, g]) => g.n >= 3).map(([d, g]) => ({d, n: g.n, avg: g.sum / g.n})).sort((a, b) => a.d - b.d);
    const lo = Math.min(...arr.map(x => x.avg)), hi = Math.max(...arr.map(x => x.avg));
    decades = `<div class="panel"><h3>Tes décennies préférées</h3><div class="srows">${arr.map(x => `<div class="srow"><span class="sname">Années ${String(x.d).slice(2)}${x.d < 2000 ? '' : ''}</span>${bar(x.avg, lo - 10, hi)}<span class="sval">${Math.round(x.avg)}<small>${x.n} films</small></span></div>`).join('')}</div></div>`;
  }
  const dom = [...Array(N).keys()].filter(i => games(i) >= 5).sort((a, b) => (S.w[b] + S.d[b] / 2) / games(b) - (S.w[a] + S.d[a] / 2) / games(a)).slice(0, 8);
  let lb = '';
  if (films) {
    const rated = [...Array(N).keys()].filter(i => F[i].r > 0 && games(i) >= 2);
    if (rated.length >= 10) {
      const byR = rated.slice().sort((a, b) => F[b].r - F[a].r), rp = new Map(byR.map((i, k) => [i, k / (byR.length - 1)])), byE = rated.slice().sort((a, b) => S.elo[b] - S.elo[a]), ep = new Map(byE.map((i, k) => [i, k / (byE.length - 1)]));
      const diff = rated.map(i => ({i, d: rp.get(i) - ep.get(i)}));
      const under = diff.slice().sort((a, b) => b.d - a.d).slice(0, 6), over = diff.slice().sort((a, b) => a.d - b.d).slice(0, 6);
      const li = x => `<div class="fight" style="grid-template-columns:minmax(0,1fr) auto"><span class="fx">${thumb(x.i)}<span class="nm">${T(x.i)}</span></span><span class="tag"><span class="stars">${starStr(F[x.i].r)}</span> · #${rank[x.i]}</span></div>`;
      lb = `<div class="panel"><h3>Sous-notés sur Letterboxd</h3><p class="note" style="margin:-6px 0 10px">Tu leur as mis une note moyenne, mais ils gagnent beaucoup de duels.</p><div class="feed">${under.map(li).join('')}</div></div>
        <div class="panel"><h3>Surnotés sur Letterboxd</h3><p class="note" style="margin:-6px 0 10px">Bonne note sur Letterboxd, mais ils perdent souvent en duel.</p><div class="feed">${over.map(li).join('')}</div></div>`;
    }
  }
  let risers = '';
  if (S.log.length >= 40) {
    const back = Math.min(200, Math.floor(S.log.length / 2)), e0 = eloAtIndex(S.log.length - back), r0 = rankOf(e0, N).rank;
    const mv = [...Array(N).keys()].map(i => ({i, d: r0[i] - rank[i]})).filter(x => x.d).sort((a, b) => b.d - a.d);
    const li = (x, up) => `<div class="fight" style="grid-template-columns:minmax(0,1fr) auto"><span class="fx">${thumb(x.i)}<span class="nm">${T(x.i)}</span></span><span class="tag ${up ? 'up' : 'down'}">${up ? '▲' : '▼'} ${Math.abs(x.d)} · #${rank[x.i]}</span></div>`;
    risers = `<div class="panel"><h3>Plus grosses montées <small class="note">· ${back} derniers duels</small></h3><div class="feed">${mv.slice(0, 6).map(x => li(x, true)).join('')}</div></div>
      <div class="panel"><h3>Plus grosses chutes</h3><div class="feed">${mv.slice(-6).reverse().map(x => li(x, false)).join('')}</div></div>`;
  }
  const champs = (S.champs || []).slice(-8).reverse();
  view.innerHTML = `${tabs}
    <div class="scards"><div class="scard"><b>${fmt(S.total)}</b><span>duels joués</span></div><div class="scard"><b>${fmt(N)}</b><span>${TY.many}</span></div><div class="scard"><b>${st.pct} %</b><span>classement fiable</span></div><div class="scard"><b>${fmt((S.champs || []).length)}</b><span>tournois gagnés</span></div></div>
    <div class="sgrid">
      ${films ? (() => { const gc = genreCounts(F), cache = ls.get(GENRE_KEY, {}); if (!gc.known) return `<div class="panel"><h3>Tes genres préférés</h3><p class="note">Lance l’analyse des genres dans l’onglet <b>Trophées</b> (touche Y) pour voir ton ADN par genre.</p></div>`; const arr = GENRES.map(([n, , ic]) => { let sum = 0, k = 0; F.forEach((it, i) => { const g = cache[it.key]; if (g && g.includes(n)) { sum += S.elo[i]; k++; } }); return {n, ic, k, avg: k ? sum / k : 0}; }).filter(x => x.k >= 5).sort((a, b) => b.avg - a.avg); const lo = Math.min(...arr.map(x => x.avg)), hi = Math.max(...arr.map(x => x.avg)); return `<div class="panel"><h3>Tes genres préférés <small class="note">· score moyen</small></h3><div class="srows">${arr.map(x => `<div class="srow"><span class="sname">${x.ic} ${x.n}</span>${bar(x.avg, lo - 10, hi)}<span class="sval">${Math.round(x.avg)}<small>${x.k} films</small></span></div>`).join('')}</div></div>`; })() : ''}
      ${topG.length ? `<div class="panel"><h3>${films ? 'Tes réalisateurs préférés' : C.type === 'music' ? 'Tes artistes préférés' : 'Tes catégories préférées'} <small class="note">· 3 ${TY.many} minimum</small></h3><div class="srows">${topG.map((g, k) => `<div class="srow"><span class="sname"><b>${k + 1}.</b> ${esc(g.p)}</span>${bar(g.avg, minAvg, maxAvg)}<span class="sval">${Math.round(g.avg)}<small>${g.n} ${TY.many}</small></span></div>`).join('')}</div></div>` : ''}
      ${decades}
      <div class="panel"><h3>Les plus dominants <small class="note">· 5 duels minimum</small></h3>${dom.length ? `<div class="feed">${dom.map(i => `<div class="fight" style="grid-template-columns:minmax(0,1fr) auto"><span class="fx">${thumb(i)}<span class="nm">${T(i)}</span></span><span class="tag">${Math.round((S.w[i] + S.d[i] / 2) / games(i) * 100)} % · ${S.w[i]}V ${S.l[i]}D</span></div>`).join('')}</div>` : '<div class="empty">Fais plus de duels pour voir qui domine.</div>'}</div>
      ${risers}${lb}
      ${champs.length ? `<div class="panel"><h3>Tes derniers champions</h3><div class="feed">${champs.map(c => { const i = F.findIndex(it => it.key === c.k); return i < 0 ? '' : `<div class="fight" style="grid-template-columns:minmax(0,1fr) auto"><span class="fx">${thumb(i)}<span class="nm">🏆 ${T(i)}</span></span><span class="tag">${esc(c.label)} · ${new Date(c.t).toLocaleDateString('fr-FR')}</span></div>`; }).join('')}</div></div>` : ''}
    </div>`;
  view.querySelectorAll('.ptabs [data-s]').forEach(b => b.onclick = () => { statsTab = b.dataset.s; renderStats(); });
}
const monthKey = t => { const d = new Date(t); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0'); };
const monthName = k => { const [y, m] = k.split('-'); return new Date(+y, +m - 1, 1).toLocaleDateString('fr-FR', {month:'long', year:'numeric'}); };
function recapData(mk){
  const idx = []; S.log.forEach((h, k) => { if (h.t && monthKey(h.t) === mk) idx.push(k); });
  if (!idx.length) return null;
  const a = idx[0], b = idx[idx.length - 1] + 1, e0 = eloAtIndex(a), e1 = eloAtIndex(b), r0 = rankOf(e0, N).rank, r1 = rankOf(e1, N).rank;
  const moves = [...Array(N).keys()].map(i => ({i, d: r0[i] - r1[i]})).sort((x, y) => y.d - x.d);
  const cnt = new Map(); idx.forEach(k => { const h = S.log[k]; [h.w, h.l].forEach(i => cnt.set(i, (cnt.get(i) || 0) + 1)); });
  const most = [...cnt].sort((x, y) => y[1] - x[1])[0];
  let close = null; idx.forEach(k => { const h = S.log[k]; if (h.dr) return; const v = Math.abs(h.dl - K / 2); if (!close || v < close.v) close = {v, h}; });
  const days = new Set(idx.map(k => new Date(S.log[k].t).toDateString())).size;
  const champs = (S.champs || []).filter(c => monthKey(c.t) === mk);
  const top1 = rankOf(e1, N).order[0];
  return {n: idx.length, days, up: moves.slice(0, 3).filter(x => x.d > 0), down: moves.slice(-3).reverse().filter(x => x.d < 0), most, close, champs, top1};
}
function renderRecap(tabs){
  const months = [...new Set(S.log.filter(h => h.t).map(h => monthKey(h.t)))].sort().reverse();
  if (!months.length) { view.innerHTML = `${tabs}<div class="panel"><h3>Récap du mois</h3><p class="note">Le récap compte les duels à partir de maintenant (les anciens duels n’avaient pas de date). Reviens après quelques duels !</p></div>`; view.querySelectorAll('.ptabs [data-s]').forEach(b => b.onclick = () => { statsTab = b.dataset.s; renderStats(); }); return; }
  if (!months.includes(recapMonth)) recapMonth = months[0];
  const R = recapData(recapMonth), {rank} = ranking();
  const tile = (i, lab, cls = '') => `<div class="rc-t ${cls}">${img(i, 'poster', F, TY.sq, true)}<div><b>${T(i)}</b><span>${lab}</span></div></div>`;
  view.innerHTML = `${tabs}
    <div class="tools"><select id="rmonth">${months.map(m => `<option value="${m}" ${m === recapMonth ? 'selected' : ''}>${monthName(m)}</option>`).join('')}</select><button class="btn sm primary" id="rpng">🖼 Image à partager (format story)</button></div>
    <section class="recap">
      <div class="rc-hero"><span class="kicker">Ton récap · ${monthName(recapMonth)}</span><h2>${esc(C.label)}</h2>
        <div class="bill-stats"><div><b>${fmt(R.n)}</b><span>duels</span></div><div><b>${R.days}</b><span>jours actifs</span></div><div><b>${R.champs.length}</b><span>tournois gagnés</span></div></div></div>
      <div class="rc-grid">
        <div class="panel"><h3>N° 1 à la fin du mois</h3>${tile(R.top1, 'Ton ' + TY.one + ' préféré', 'gold')}</div>
        <div class="panel"><h3>Plus grosses montées</h3>${R.up.length ? R.up.map(x => tile(x.i, `▲ ${x.d} places · #${rank[x.i]}`)).join('') : '<div class="empty">Pas de montée ce mois-ci.</div>'}</div>
        <div class="panel"><h3>Le plus combattu</h3>${R.most ? tile(R.most[0], `${R.most[1]} duels ce mois-ci`) : ''}</div>
        <div class="panel"><h3>Le duel le plus serré</h3>${R.close ? `<div class="rc-vs">${tile(R.close.h.w, 'vainqueur')}<span>VS</span>${tile(R.close.h.l, 'battu de peu')}</div>` : '<div class="empty">—</div>'}</div>
        ${R.champs.length ? `<div class="panel"><h3>Champions du mois</h3>${R.champs.map(c => { const i = F.findIndex(it => it.key === c.k); return i < 0 ? '' : tile(i, '🏆 ' + esc(c.label)); }).join('')}</div>` : ''}
        ${R.down.length ? `<div class="panel"><h3>Plus grosses chutes</h3>${R.down.map(x => tile(x.i, `▼ ${-x.d} places · #${rank[x.i]}`)).join('')}</div>` : ''}
      </div>
    </section>`;
  view.querySelectorAll('.ptabs [data-s]').forEach(b => b.onclick = () => { statsTab = b.dataset.s; renderStats(); });
  $('rmonth').onchange = e => { recapMonth = e.target.value; renderStats(); };
  $('rpng').onclick = () => pngRecap(R);
}
async function pngRecap(R){
  toast('Création de l’image…'); await pngFonts();
  const W = 1080, H = 1920, cv = document.createElement('canvas'); cv.width = W; cv.height = H; const g = cv.getContext('2d');
  const bg = g.createLinearGradient(0, 0, 0, H); bg.addColorStop(0, '#15110A'); bg.addColorStop(.5, '#0B0A0E'); bg.addColorStop(1, '#070709'); g.fillStyle = bg; g.fillRect(0, 0, W, H);
  const rg = g.createRadialGradient(W / 2, 0, 0, W / 2, 0, W); rg.addColorStop(0, 'rgba(216,180,106,.25)'); rg.addColorStop(1, 'rgba(216,180,106,0)'); g.fillStyle = rg; g.fillRect(0, 0, W, H);
  g.textAlign = 'center';
  g.font = '900 54px Archivo, Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText('RING', W / 2, 120);
  g.font = '700 26px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText(('RÉCAP · ' + monthName(recapMonth)).toUpperCase(), W / 2, 170);
  g.font = '900 76px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; wrapText(g, C.label.toUpperCase(), W / 2, 270, W - 120, 80, 2);
  const [im1, ...ims] = await Promise.all([loadImg(proxied(hiRes(F[R.top1].img, true)))].concat(R.up.map(x => loadImg(proxied(F[x.i].img)))));
  g.save(); g.shadowColor = 'rgba(216,180,106,.6)'; g.shadowBlur = 70; g.fillStyle = '#D8B46A'; rrect(g, W / 2 - 206, 356, 412, TY.sq ? 412 : 612, 18); g.fill(); g.restore();
  drawCover(g, im1, W / 2 - 200, 362, 400, TY.sq ? 400 : 600, F[R.top1].t);
  let y = (TY.sq ? 362 + 400 : 362 + 600) + 70;
  g.font = '700 24px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText('TON N° 1 DU MOIS', W / 2, y); y += 56;
  g.font = '900 52px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; y += wrapText(g, F[R.top1].t, W / 2, y, W - 140, 56, 2) * 56 + 30;
  const stat = (x, v, l) => { g.font = '900 72px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; g.fillText(v, x, y + 60); g.font = '700 20px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText(l, x, y + 96); };
  stat(W / 6, fmt(R.n), 'DUELS'); stat(W / 2, String(R.days), 'JOURS'); stat(W * 5 / 6, String(R.champs.length), 'CHAMPIONS'); y += 160;
  if (R.up.length) {
    g.font = '700 24px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText('PLUS GROSSES MONTÉES', W / 2, y); y += 30;
    g.textAlign = 'left';
    R.up.forEach((x, k) => { const cy = y + k * 130; g.fillStyle = 'rgba(255,255,255,.05)'; rrect(g, 90, cy, W - 180, 116, 14); g.fill(); drawCover(g, ims[k], 104, cy + 10, TY.sq ? 96 : 64, 96, F[x.i].t); g.font = '800 34px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; wrapText(g, F[x.i].t, 104 + (TY.sq ? 96 : 64) + 24, cy + 52, W - 420, 36, 1); g.font = '700 26px Inter, sans-serif'; g.fillStyle = '#86C98A'; g.fillText('▲ ' + x.d + ' places', 104 + (TY.sq ? 96 : 64) + 24, cy + 92); });
    g.textAlign = 'center';
  }
  g.font = '600 20px Inter, sans-serif'; g.fillStyle = '#6E6759'; g.fillText((ls.get('ringcine-name', '') ? 'classé par ' + ls.get('ringcine-name', '') + ' · ' : '') + 'fait avec Ring', W / 2, H - 60);
  await savePng(cv, `ring-recap-${recapMonth}-${fileSafe(C.label)}.png`);
}

/* ---------- À deux : défi par code + image de compatibilité ---------- */
const DEFI_PREFIX = 'RINGDEFI:';
const encD = o => DEFI_PREFIX + btoa(unescape(encodeURIComponent(JSON.stringify(o))));
const decD = s => JSON.parse(decodeURIComponent(escape(atob(String(s).trim().slice(DEFI_PREFIX.length)))));
function defiPanel(){
  return `<div class="panel defi"><h3>⚔ Duel à deux (à distance)</h3>
    <p class="note" style="margin:-4px 0 12px">Tu réponds à 20 duels, Ring te donne un code à envoyer à ton pote (Discord, SMS…). Il colle le code dans son Ring, répond aux mêmes duels, et vous voyez vos désaccords. Il n’a pas besoin d’avoir les mêmes ${TY.many} : tout est dans le code.</p>
    <div class="fx" style="gap:8px;flex-wrap:wrap"><button class="btn primary" id="dfnew">Créer un défi (20 duels)</button><input class="input" id="dfin" placeholder="…ou colle ici un code RINGDEFI: reçu"><button class="btn" id="dfgo">Ouvrir</button></div></div>`;
}
function bindDefi(){
  $('dfnew').onclick = () => {
    const top = ranking().order.slice(0, Math.min(N, 160)); if (top.length < 4) return toast('Il faut au moins 4 ' + TY.many + '.');
    const pairs = [], used = new Set();
    for (let t = 0; pairs.length < 20 && t < 400; t++) { const a = top[Math.floor(Math.random() * top.length)], b = top[Math.floor(Math.random() * top.length)]; const k = a < b ? a + '-' + b : b + '-' + a; if (a !== b && !used.has(k)) { used.add(k); pairs.push([a, b]); } }
    const ids = [...new Set(pairs.flat())], map = new Map(ids.map((i, n) => [i, n]));
    const pack = {v:1, from: ls.get('ringcine-name', '') || 'Ton pote', label: C.label, type: C.type, sq: TY.sq ? 1 : 0, items: ids.map(i => [F[i].t, C.type === 'films' ? (F[i].y || '') : (F[i].sub || ''), F[i].img || '']), pairs: pairs.map(([a, b]) => [map.get(a), map.get(b)])};
    playDefi(pack, 'a');
  };
  const open = () => { const v = $('dfin').value.trim(); if (!v.startsWith(DEFI_PREFIX)) return toast('Colle un code qui commence par RINGDEFI:'); openDefiCode(v); };
  $('dfgo').onclick = open; $('dfin').onkeydown = e => { if (e.key === 'Enter') open(); };
}
function openDefiCode(code){
  let p; try { p = decD(code); } catch(e) { return toast('Code de défi illisible.'); }
  if (p.a && p.b) return showDefiResult(p);
  if (p.a) return playDefi(p, 'b');
  toast('Code de défi incomplet.');
}
function playDefi(p, who){
  const ans = []; let k = 0;
  const item = (n, side) => { const it = p.items[n]; return `<button class="dcard ${side}" data-n="${n}">${it[2] && safeUrl(it[2]) ? `<img src="${esc(hiRes(it[2]))}" data-lo="${esc(it[2])}" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}" class="${p.sq ? 'sq' : ''}" alt="">` : `<div class="noposter ${p.sq ? 'sq' : ''}">${esc(it[0])}</div>`}<b>${esc(it[0])}</b><span>${esc(String(it[1] || ''))}</span></button>`; };
  const step = () => {
    if (k >= p.pairs.length) {
      const out = Object.assign({}, p); out[who] = ans; if (who === 'b') out.bn = ls.get('ringcine-name', '') || 'Ton pote';
      if (who === 'a') { const code = encD(out); openModal(`<div class="sheethead"><h2>Défi prêt !</h2><button class="x" aria-label="Fermer">✕</button></div><p class="note">Envoie ce code à ton pote. Il le colle dans Ring (onglet « À deux », ou juste Ctrl+V).</p><textarea readonly id="dcode">${esc(code)}</textarea><div><button class="btn primary" id="dcopy">Copier le code</button></div>`, () => { $('dcopy').onclick = async () => { if (await copyText(code)) toast('Code copié !'); else { $('dcode').select(); document.execCommand('copy'); toast('Code copié !'); } }; }); }
      else showDefiResult(out);
      return;
    }
    const [a, b] = p.pairs[k];
    openModal(`<div class="sheethead"><h2>Défi · ${k + 1} / ${p.pairs.length}</h2><button class="x" aria-label="Fermer">✕</button></div>
      <p class="note" style="margin:0">${who === 'b' ? `Défi de <b>${esc(p.from)}</b> · ` : ''}« ${esc(p.label)} » · lequel tu préfères ?</p>
      <div class="dpair">${item(a, 'l')}<span class="dvs">VS</span>${item(b, 'r')}</div><div class="bar"><i style="width:${k / p.pairs.length * 100}%"></i></div>`, () => {
      $('sheet').querySelectorAll('.dcard').forEach(c => c.onclick = () => { ans.push(+c.dataset.n === a ? 0 : 1); k++; sfx('tick'); step(); });
    });
  };
  step();
}
function showDefiResult(p){
  ls.set('ringcine-defis', ls.get('ringcine-defis', 0) + 1); trophyTick();
  const same = p.pairs.map((_, k) => p.a[k] === p.b[k]), pct = Math.round(same.filter(Boolean).length / p.pairs.length * 100);
  const nm = n => esc(p.items[n][0]);
  const dis = p.pairs.map((pr, k) => ({pr, k})).filter(x => !same[x.k]);
  const me = ls.get('ringcine-name', '');
  const code = encD(p);
  openModal(`<div class="sheethead"><h2>Résultat du défi</h2><button class="x" aria-label="Fermer">✕</button></div>
    <div class="compat"><div class="cring" style="--p:${pct}"><b>${pct} %</b><span>d’accord</span></div><div><div class="kicker">${esc(p.from)} × ${esc(p.bn || 'ton pote')}</div><p class="note">${pct >= 80 ? 'Âmes sœurs cinéphiles.' : pct >= 60 ? 'Vous vous entendez bien.' : pct >= 40 ? 'Des goûts assez différents.' : 'Presque opposés !'} ${same.filter(Boolean).length} duels sur ${p.pairs.length} choisis pareil.</p></div></div>
    ${dis.length ? `<div class="h3" style="margin-top:6px">Vos désaccords</div><div class="feed">${dis.map(({pr, k}) => `<div class="fight" style="grid-template-columns:minmax(0,1fr) auto minmax(0,1fr)"><span class="nm">${esc(p.from)} : <b>${nm(pr[p.a[k]])}</b></span><span class="x">≠</span><span class="nm">${esc(p.bn || 'pote')} : <b>${nm(pr[p.b[k]])}</b></span></div>`).join('')}</div>` : ''}
    ${p.bn && p.bn === (me || 'Ton pote') ? `<p class="note">Renvoie ce code à <b>${esc(p.from)}</b> pour qu’il voie le résultat aussi :</p><textarea readonly id="dcode">${esc(code)}</textarea><div><button class="btn primary" id="dcopy">Copier le code réponse</button></div>` : ''}`, () => {
    if ($('dcopy')) $('dcopy').onclick = async () => { if (await copyText(code)) toast('Code copié !'); };
  });
  if (pct >= 60) { sfx('win'); confetti(90); }
}
document.addEventListener('paste', e => {
  const t = (e.clipboardData && e.clipboardData.getData('text')) || '';
  if (t.trim().startsWith(DEFI_PREFIX) && !e.target.matches('#dfin')) { e.preventDefault(); openDefiCode(t.trim()); }
});
async function pngCompat(A, B, agree, both, dis){
  toast('Création de l’image…'); await pngFonts();
  const W = 1600, H = 1000, cv = document.createElement('canvas'); cv.width = W; cv.height = H; const g = cv.getContext('2d');
  pngFrame(g, W, H, 'Compatibilité', `${A.col.label} × ${B.col.label}`);
  g.save(); g.translate(300, 580); g.lineWidth = 34; g.strokeStyle = 'rgba(255,255,255,.08)'; g.beginPath(); g.arc(0, 0, 170, 0, Math.PI * 2); g.stroke();
  g.strokeStyle = '#D8B46A'; g.lineCap = 'round'; g.beginPath(); g.arc(0, 0, 170, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * (agree || 0) / 100); g.stroke();
  g.textAlign = 'center'; g.fillStyle = '#F3EDE2'; g.font = '900 96px Archivo, Inter, sans-serif'; g.fillText((agree == null ? '—' : agree) + '%', 0, 30); g.font = '700 22px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText("D'ACCORD", 0, 76); g.restore();
  const list = (x, title, arr, snapI) => { g.textAlign = 'left'; g.font = '700 22px Inter, sans-serif'; g.fillStyle = '#D8B46A'; g.fillText(title, x, 380); arr.slice(0, 6).forEach((c, k) => { g.font = '700 30px Archivo, Inter, sans-serif'; g.fillStyle = '#F3EDE2'; wrapText(g, A.items[c.i].t, x, 440 + k * 72, 480, 32, 1); g.font = '500 20px Inter, sans-serif'; g.fillStyle = '#A69E8F'; g.fillText(`#${A.rank[c.i]} chez ${A.col.label}  ·  #${B.rank[c.j]} chez ${B.col.label}`.slice(0, 60), x, 468 + k * 72); }); };
  list(560, 'VOUS ADOREZ TOUS LES DEUX', both); list(1090, 'VOS PLUS GROS DÉSACCORDS', dis);
  await savePng(cv, `ring-compatibilite-${fileSafe(A.col.label)}-${fileSafe(B.col.label)}.png`);
}

/* ---------- Jeux en plus : Devine l'année, Réplique culte, Casting ---------- */
const QUOTES = new Map(Object.entries(QUOTES_RAW).map(([k, v]) => { const [t, y] = k.split('|'); return [keyHash(`${t} (${y})`), v]; }));
const castCache = new Map();
/* Photos des acteurs : une seule requête Wikipédia pour tout le casting */
/* Casting Wikidata (P161) avec photos (P18) : une petite requête SPARQL */
async function wdCast(qid){
  try {
    const q = `SELECT ?a ?aLabel ?img WHERE { wd:${qid} p:P161 ?st . ?st ps:P161 ?a . OPTIONAL { ?a wdt:P18 ?img } SERVICE wikibase:label { bd:serviceParam wikibase:language "fr,en". } }`;
    const r = await (await fetch('https://query.wikidata.org/sparql?format=json&query=' + encodeURIComponent(q))).json();
    const seen = new Set(), out = [];
    (r.results && r.results.bindings || []).forEach(b => { const n = b.aLabel && b.aLabel.value; if (!n || /^Q\d+$/.test(n) || seen.has(n)) return; seen.add(n); let img = b.img ? b.img.value.replace(/^http:/, 'https:') : ''; if (img) img += (img.includes('?') ? '&' : '?') + 'width=320'; out.push({n, img: safeUrl(img)}); });
    return out;
  } catch(e){ return []; }
}
async function castPhotos(names, lang){
  const out = names.map(n => ({n, img:''}));
  try {
    const j = await (await fetch(`https://${lang}.wikipedia.org/w/api.php?format=json&origin=*&action=query&redirects=1&prop=pageimages|pageprops&piprop=thumbnail&pithumbsize=320&titles=${encodeURIComponent(names.join('|'))}`)).json();
    const q = j.query || {}, alias = new Map();
    (q.normalized || []).forEach(x => alias.set(x.to, x.from)); (q.redirects || []).forEach(x => alias.set(x.to, alias.get(x.from) || x.from));
    Object.values(q.pages || {}).forEach(pg => {
      if (!pg.thumbnail || (pg.pageprops && 'disambiguation' in pg.pageprops)) return;
      const orig = alias.get(pg.title) || pg.title, o = out.find(x => x.n === orig || x.n === pg.title);
      if (o) o.img = safeUrl(pg.thumbnail.source);
    });
    // essai en anglais pour ceux sans photo
    const miss = out.filter(x => !x.img);
    if (miss.length && lang !== 'en') { const e = await castPhotos(miss.map(x => x.n), 'en'); e.forEach(x => { const o = out.find(y => y.n === x.n); if (o && x.img) o.img = x.img; }); }
  } catch(e){}
  return out;
}
async function wikiCast(it){
  const key = it.t + '|' + it.y; if (castCache.has(key)) return castCache.get(key);
  const J = async u => (await fetch(u)).json();
  const api = (lang, q) => J(`https://${lang}.wikipedia.org/w/api.php?format=json&origin=*&${q}`);
  const ext = async (lang, title) => { const e = await api(lang, `action=query&prop=extracts|langlinks|pageprops&lllang=fr&explaintext=1&exsectionformat=wiki&redirects=1&titles=${encodeURIComponent(title)}`); const pg = Object.values((e.query && e.query.pages) || {})[0] || {}; return {txt: pg.extract || '', fr: pg.langlinks && pg.langlinks[0] && pg.langlinks[0]['*'], qid: pg.pageprops && pg.pageprops.wikibase_item}; };
  const isFilm = txt => /film|movie|long métrage|animated|animation/i.test(txt.slice(0, 700)) && (!it.y || txt.slice(0, 2000).includes(String(it.y)));
  const parse = (txt, lang) => {
    const m = txt.match(lang === 'fr' ? /\n==\s*(Distribution|Casting|Distribution des rôles)\s*==\s*\n([\s\S]*?)(?=\n==[^=]|$)/i : /\n==\s*(Cast|Voice cast|Cast and characters)\s*==\s*\n([\s\S]*?)(?=\n==[^=]|$)/i);
    if (!m) return [];
    const bad = /^(voix|version|source|note|légende|crédits|et |avec )/i;
    return m[2].split('\n').map(l => l.trim()).filter(l => l && !/^=/.test(l)).map(l => l.split(lang === 'fr' ? /\s+[:(]|\s+—\s+|\s+–\s+|\s+-\s+/ : /\s+as\s+|\s+[:(]/)[0].trim()).map(n => n.replace(/[,;.]+$/, '')).filter(n => n.length >= 4 && n.length <= 40 && /^[\p{Lu}]/u.test(n) && !bad.test(n) && n.split(' ').length <= 5 && n.split(' ').every(w => /^[\p{Lu}]/u.test(w) || /^(de|da|del|della|di|du|van|von|der|den|le|la|y|bin|al|el|dos|das|d'|'t)$/i.test(w))).slice(0, 8);
  };
  const res = (async () => {
    for (const [lang, q] of [['en', `${it.en || it.t} ${it.y || ''} film`], ['fr', `${it.t} film ${it.y || ''}`]]) {
      try {
        const s2 = await api(lang, `action=query&list=search&srsearch=${encodeURIComponent(q)}&srlimit=3`);
        for (const r of (s2.query && s2.query.search) || []) {
          const e = await ext(lang, r.title); if (!isFilm(e.txt)) continue;
          let names = parse(e.txt, lang), nl = lang;
          if (names.length < 3 && lang === 'en' && e.fr) { const f = await ext('fr', e.fr); names = parse(f.txt, 'fr'); nl = 'fr'; }
          const [photos, wd] = await Promise.all([names.length ? castPhotos(names, nl) : [], e.qid ? wdCast(e.qid) : []]);
          const list = photos.slice(), byN = new Map(list.map(x => [norm(x.n), x]));
          wd.forEach(w => { const o = byN.get(norm(w.n)); if (o) { if (!o.img) o.img = w.img; } else if (list.length < 14) { const x = {n: w.n, img: w.img}; list.push(x); byN.set(norm(w.n), x); } });
          const withImg = list.filter(x => x.img), noImg = list.filter(x => !x.img);
          const cast = withImg.concat(noImg).slice(0, 8);
          if (cast.length >= 3) return cast;
        }
      } catch(e){}
    }
    return null;
  })();
  castCache.set(key, res); return res;
}
Object.assign(GAMES, {
  year:  {name:'Devine l’année', icon:'📅', types:['films'], kind:'year', steps:[0], desc:'L’affiche s’affiche, tu donnes l’année de sortie. Pile la bonne année : 5 points, à 10 ans près : 1 point.'},
  quote: {name:'Réplique culte', icon:'💬', types:['films'], kind:'quote', steps:[0,1,2,3], desc:'Une réplique culte en VO, puis sa traduction en français, puis l’année et le réalisateur.'},
  cast:  {name:'Casting', icon:'🎭', types:['films'], kind:'cast', steps:[0,1,2,3,4], desc:'Les acteurs du film apparaissent un par un. Trouve le film avec le moins de noms possible.'},
});
function yearPts(d){ d = Math.abs(d); return d === 0 ? 5 : d === 1 ? 4 : d === 2 ? 3 : d <= 5 ? 2 : d <= 10 ? 1 : 0; }

/* ================= v12 : Plus ou moins, Roulette, Scène du film ================= */

/* ---------- Notes Rotten Tomatoes / Metacritic via Wikidata (cache permanent) ---------- */
const RT_KEY = 'ringcine-rt';
async function fetchScores(idx){
  const cache = ls.get(RT_KEY, {}), todo = idx.filter(i => F[i].t && cache[F[i].key] === undefined);
  for (let p = 0; p < todo.length; p += 50) {
    const part = todo.slice(p, p + 50);
    const vals = [...new Set(part.map(i => JSON.stringify(F[i].en || F[i].t) + '@en'))].join(' ');
    const q = `SELECT ?t ?y ?score ?by WHERE { VALUES ?t { ${vals} } ?film rdfs:label ?t ; p:P444 ?st . ?st ps:P444 ?score ; pq:P447 ?by . VALUES ?by { wd:Q105584 wd:Q150248 } OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`;
    try {
      const r = await (await fetch('https://query.wikidata.org/sparql?format=json&query=' + encodeURIComponent(q))).json();
      const found = new Map();
      (r.results && r.results.bindings || []).forEach(b => {
        const t = b.t.value, y = b.y ? +b.y.value : 0, v = b.score.value, rt = /Q105584$/.test(b.by.value);
        let n = null, weak = false; const m1 = String(v).match(/^(\d{1,3})\s*%$/), m2 = String(v).match(/^(\d{1,3})\s*\/\s*100$/), m3 = String(v).match(/^(\d+(?:\.\d+)?)\s*\/\s*10$/);
        if (m1) n = +m1[1]; else if (m2) n = +m2[1]; else if (m3 && rt) { n = Math.round(+m3[1] * 10); weak = true; } if (n == null) return;
        part.forEach(i => { if ((F[i].en || F[i].t) === t && (!F[i].y || !y || Math.abs(F[i].y - y) <= 1)) { const o = found.get(i) || {}; if (rt) { if (!weak) o.rt = Math.max(o.rt ?? -1, n); else o.rtw = n; } else o.mc = Math.max(o.mc ?? -1, n); found.set(i, o); } });
      });
      part.forEach(i => { const o = found.get(i); cache[F[i].key] = o ? [o.rt ?? o.rtw ?? -1, o.mc ?? -1] : 0; });
      ls.set(RT_KEY, cache);
    } catch(e){ break; }
  }
  return ls.get(RT_KEY, {});
}

/* ---------- Plus ou moins (le fameux « Higher or Lower ») ---------- */
const HLM = {
  rt:   {name:'Note Rotten Tomatoes', short:'Rotten Tomatoes', unit:'%', films:true},
  mc:   {name:'Note Metacritic', short:'Metacritic', unit:'/100', films:true},
  year: {name:'Année de sortie', short:'Année', unit:'', films:true, q:'est sorti plus récemment ou avant ?', up:'Plus récent', down:'Plus ancien'},
  lb:   {name:'Ta note Letterboxd', short:'Ta note', unit:'★', films:true},
  elo:  {name:'Ton classement Ring', short:'Ton classement', unit:'', q:'est mieux ou moins bien classé chez toi ?', up:'Mieux classé', down:'Moins bien classé'},
};
const HL = {metric:null, pool:null, a:null, b:null, streak:0, over:false, reveal:false, loading:false, scores:null, used:null};
let hlMode = 'hl';
function hlVal(i){
  const m = HL.metric;
  if (m === 'year') return F[i].y || null;
  if (m === 'lb') return F[i].r ? F[i].r / 2 : null;
  if (m === 'elo') return -ranking().rank[i];
  if (m === 'bo') { const b = HL.bo && HL.bo[F[i].key]; return b > 0 ? b : null; }
  const s = HL.scores && HL.scores[F[i].key]; if (!s) return null;
  const v = m === 'rt' ? s[0] : s[1]; return v >= 0 ? v : null;
}
function hlShow(i){
  const v = hlVal(i), m = HL.metric; if (v == null) return '?';
  if (m === 'elo') return '#' + (-v); if (m === 'lb') return starStr(F[i].r); if (m === 'year') return String(v); if (m === 'bo') return fmtMoney(v);
  return v + (HLM[m].unit === '%' ? ' %' : ' /100');
}
function hlPick(exclude){
  const P = HL.pool.filter(i => i !== exclude && !HL.used.has(i)); if (!P.length) { HL.used.clear(); return HL.pool.find(i => i !== exclude); }
  const i = P[Math.floor(Math.random() * P.length)]; HL.used.add(i); return i;
}
async function hlStart(metric){
  HL.metric = metric; HL.streak = 0; HL.over = false; HL.reveal = false; HL.used = new Set(); HL.loading = true; renderSwipe();
  if (metric === 'rt' || metric === 'mc') {
    const sample = shuffle([...Array(N).keys()]).slice(0, 400);
    HL.scores = await fetchScores(sample);
  }
  if (metric === 'bo') HL.bo = await fetchBO(shuffle([...Array(N).keys()]).slice(0, 450));
  HL.pool = [...Array(N).keys()].filter(i => hlVal(i) != null);
  HL.loading = false;
  if (HL.pool.length < 5) { HL.metric = null; toast(metric === 'bo' ? 'Pas assez de chiffres de box office trouvés (connexion ?). Essaie un autre mode.' : metric === 'rt' || metric === 'mc' ? 'Pas assez de notes trouvées sur Wikidata pour ce ring (connexion ?). Essaie un autre mode.' : 'Pas assez de données pour ce mode.'); renderSwipe(); return; }
  HL.a = hlPick(-1); HL.b = hlPick(HL.a); renderSwipe();
}
function hlGuess(up){
  if (HL.reveal || HL.over || HL.a == null) return;
  const va = hlVal(HL.a), vb = hlVal(HL.b), ok = vb === va || (up ? vb > va : vb < va);
  HL.reveal = true; HL.lastOk = ok; renderSwipe();
  const el = document.querySelector('.hl-card.b .hl-val'); if (el) el.classList.add(ok ? 'ok' : 'ko');
  sfx(ok ? 'win' : 'lose');
  setTimeout(() => {
    if (ok) { HL.streak++; HL.a = HL.b; HL.b = hlPick(HL.a); HL.reveal = false; if (HL.streak % 10 === 0) confetti(90); }
    else { HL.over = true; const rec = ls.get('ringcine-hl', {}), k = C.id + ':' + HL.metric; if (HL.streak > (rec[k] || 0)) { rec[k] = HL.streak; ls.set('ringcine-hl', rec); HL.newRec = true; } else HL.newRec = false; trophyTick(); }
    renderSwipe();
  }, ok ? 1100 : 1400);
}
function renderHL(){
  const tabs = `<div class="ptabs"><button data-hm="hl" aria-selected="${hlMode === 'hl'}">⬆⬇ Plus ou moins</button><button data-hm="swipe" aria-selected="${hlMode === 'swipe'}">♥ Garder / jeter</button></div>`;
  const bindTabs = () => view.querySelectorAll('[data-hm]').forEach(b => b.onclick = () => { hlMode = b.dataset.hm; renderSwipe(); });
  const rec = ls.get('ringcine-hl', {});
  if (!HL.metric || HL.loading) {
    const ms = Object.entries(HLM).filter(([k, m]) => !m.films || C.type === 'films');
    view.innerHTML = `${tabs}<section class="hl-intro"><span class="kicker">Le jeu du plus ou moins</span><h2>Plus ou moins ?</h2>
      <p>Un ${TY.one} est affiché avec sa note. Le suivant a-t-il une note <b>plus haute</b> ou <b>plus basse</b> ? Si tu as bon, il prend la place et un nouveau arrive. Une erreur et c’est fini : fais la plus longue série possible !</p>
      ${HL.loading ? `<div class="gload"><span class="spin"></span>${HL.metric === 'bo' ? 'Récupération des chiffres du box office…' : 'Récupération des notes…'}</div>` : `<div class="modes hl-modes">${ms.map(([k, m]) => `<button class="mode" data-m="${k}"><em>${k === 'bo' ? '💰' : k === 'rt' ? '🍅' : k === 'mc' ? 'Ⓜ' : k === 'year' ? '📅' : k === 'lb' ? '★' : '🏆'}</em><strong>${m.name}</strong><span>${k === 'bo' ? 'Combien le film a rapporté dans le monde (chiffres Box Office Mojo, via Wikidata).' : k === 'rt' || k === 'mc' ? 'Notes de la critique (via Wikidata).' : k === 'year' ? 'Lequel est sorti le plus récemment ?' : k === 'lb' ? 'Les notes que tu as mises sur Letterboxd.' : 'Ton propre classement Ring.'}</span>${rec[C.id + ':' + k] ? `<span class="gst">Record : ${rec[C.id + ':' + k]} d’affilée</span>` : ''}</button>`).join('')}</div>`}
      <p class="note">IMDb ne donne pas ses notes aux applis gratuites : Ring utilise Rotten Tomatoes et Metacritic à la place.</p></section>`;
    bindTabs(); view.querySelectorAll('.mode[data-m]').forEach(b => b.onclick = () => hlStart(b.dataset.m)); return;
  }
  const M = HLM[HL.metric];
  if (HL.over) {
    view.innerHTML = `${tabs}<section class="hl-over"><div class="big">${HL.streak}</div><h2>${HL.newRec ? '🏆 Nouveau record !' : 'Perdu !'}</h2><p class="note">${HL.streak} bonne${HL.streak > 1 ? 's' : ''} réponse${HL.streak > 1 ? 's' : ''} d’affilée · record : ${rec[C.id + ':' + HL.metric] || HL.streak}</p>
      <p class="note">${T(HL.b)} : <b>${hlShow(HL.b)}</b> contre ${T(HL.a)} : <b>${hlShow(HL.a)}</b></p>
      <div class="fx" style="gap:8px;justify-content:center"><button class="btn primary" id="hlagain">↻ Rejouer <kbd>Entrée</kbd></button><button class="btn" id="hlmenu">Changer de mode</button></div></section>`;
    bindTabs(); $('hlagain').onclick = () => hlStart(HL.metric); $('hlmenu').onclick = () => { HL.metric = null; renderSwipe(); }; return;
  }
  const card = (i, side) => `<div class="hl-card ${side}"><div class="hl-bg">${F[i].img ? `<img src="${esc(tinyRes(F[i].img))}" alt="">` : ''}</div>${imgHi(i)}<div class="hl-t">${T(i)}</div><div class="cmeta">${hlMeta(i, side === 'b' && !HL.reveal)}</div>
    <div class="hl-val">${side === 'a' || HL.reveal ? hlShow(i) : '?'}</div><div class="hl-lab">${M.short}</div></div>`;
  view.innerHTML = `${tabs}<section class="hl">
    <div class="hl-head"><span class="pill">Série <b>${HL.streak}</b></span><span class="pill">Record <b>${Math.max(rec[C.id + ':' + HL.metric] || 0, HL.streak)}</b></span><span class="pill">${M.name}</span><button class="btn sm ghost" id="hlmenu">Changer de mode</button></div>
    <div class="hl-arena">${card(HL.a, 'a')}<div class="hl-mid"><div class="vs">VS</div>
      <button class="btn primary hl-up" id="hlup" ${HL.reveal ? 'disabled' : ''}>▲ ${M.up || 'Plus haut'} <kbd>↑</kbd></button>
      <button class="btn hl-down" id="hldown" ${HL.reveal ? 'disabled' : ''}>▼ ${M.down || 'Plus bas'} <kbd>↓</kbd></button>
      <p class="note">${T(HL.b)} ${M.q || 'a une note plus haute ou plus basse ?'}</p></div>${card(HL.b, 'b')}</div></section>`;
  bindTabs();
  $('hlmenu').onclick = () => { HL.metric = null; renderSwipe(); };
  $('hlup').onclick = () => hlGuess(true); $('hldown').onclick = () => hlGuess(false);
  const nb = hlPickPreview(); if (nb != null && F[nb].img) { const im = new Image(); im.src = hiRes(F[nb].img); }
}
function hlPickPreview(){ return null; }
function hlMeta(i, hide){
  const it = F[i]; if (C.type === 'music') return metaLine(i);
  const m = HL.metric, showY = !(hide && m === 'year'), showR = m !== 'lb' || !hide;
  return `${showY && it.y ? `<span>${it.y}</span>` : ''}${it.sub ? `<span>${esc(it.sub)}</span>` : ''}${showR && it.r ? `<span class="stars" title="Note Letterboxd">${starStr(it.r)}</span>` : ''}`;
}
function hlKey(e){
  if (curView !== 'swipe' || hlMode !== 'hl' || e.target.matches('input,textarea,select')) return false;
  if (HL.over && e.key === 'Enter') { e.preventDefault(); hlStart(HL.metric); return true; }
  if (!HL.metric || HL.over) return false;
  if (e.key === 'ArrowUp') { e.preventDefault(); hlGuess(true); return true; }
  if (e.key === 'ArrowDown') { e.preventDefault(); hlGuess(false); return true; }
  return false;
}

/* ---------- Roulette (Ce soir) ---------- */
const WH = {items:null, sn:null, angle:0, spinning:false, n:12};
function renderWheel(){
  const sn = WH.sn, n = WH.items.length;
  view.innerHTML = `<section class="wheel-wrap">
    <div class="stagehead" style="width:100%"><div class="round"><b>🎡 Roulette</b> · ${esc(sn.col.label)} · ${n} ${colType(sn.col).many}</div><div class="fx" style="gap:8px"><button class="btn sm" id="whnew">↻ Autres ${colType(sn.col).many}</button><button class="btn sm ghost" id="whquit">Retour</button></div></div>
    <div class="wheel"><div class="wh-pointer"></div><canvas id="whc" width="720" height="720"></canvas><button class="wh-center" id="whspin">TOURNER</button></div>
    <div class="khint"><span><kbd>Espace</kbd> tourner</span></div></section>`;
  drawWheel();
  $('whspin').onclick = spinWheel;
  $('whquit').onclick = () => { TN.round = null; TN.champ = null; TN.wheel = false; renderTonight(); };
  $('whnew').onclick = () => { WH.items = shuffle([...Array(sn.n).keys()]).slice(0, Math.min(WH.n, sn.n)); WH.angle = 0; renderWheel(); };
}
function drawWheel(){
  const cv = $('whc'); if (!cv) return; const g = cv.getContext('2d'), n = WH.items.length, R = 350, cx = 360, cy = 360, seg = Math.PI * 2 / n;
  const cs = getComputedStyle(document.documentElement), acc = cs.getPropertyValue('--gold').trim() || '#D8B46A';
  const cols = [acc, '#1C1A22', '#C8404F', '#15131A', '#5584DD', '#1C1A22'];
  g.clearRect(0, 0, 720, 720); g.save(); g.translate(cx, cy); g.rotate(WH.angle);
  WH.items.forEach((i, k) => {
    g.beginPath(); g.moveTo(0, 0); g.arc(0, 0, R, k * seg, (k + 1) * seg); g.closePath();
    g.fillStyle = k % 2 ? '#17151C' : ['#2A2418', '#2A1519', '#15203A'][k % 3]; g.fill();
    g.strokeStyle = 'rgba(216,180,106,.35)'; g.lineWidth = 2; g.stroke();
    g.save(); g.rotate(k * seg + seg / 2); g.textAlign = 'right'; g.fillStyle = '#F3EDE2'; g.font = `700 ${n > 14 ? 17 : 20}px Inter, sans-serif`;
    let t = WH.sn.items[i].t; while (g.measureText(t).width > R - 90 && t.length > 3) t = t.slice(0, -2); if (t !== WH.sn.items[i].t) t += '…';
    g.fillText(t, R - 22, 7); g.restore();
  });
  g.beginPath(); g.arc(0, 0, R, 0, Math.PI * 2); g.lineWidth = 10; g.strokeStyle = acc; g.stroke();
  g.restore();
}
function spinWheel(){
  if (WH.spinning) return; WH.spinning = true; $('whspin').disabled = true;
  const n = WH.items.length, seg = Math.PI * 2 / n, start = WH.angle, target = start + Math.PI * 2 * (5 + Math.random() * 3) + Math.random() * Math.PI * 2, dur = 4800 + Math.random() * 1200, t0 = performance.now();
  let lastSeg = -1;
  const ease = t => 1 - Math.pow(1 - t, 4);
  const step = now => {
    const t = Math.min(1, (now - t0) / dur); WH.angle = start + (target - start) * ease(t); drawWheel();
    const at = Math.floor((((-Math.PI / 2 - WH.angle) % (Math.PI * 2)) + Math.PI * 4) % (Math.PI * 2) / seg);
    if (at !== lastSeg) { lastSeg = at; sfx('tick'); }
    if (t < 1) requestAnimationFrame(step);
    else { WH.spinning = false; const win = WH.items[at]; setTimeout(() => { TN.items = WH.sn; TN.champ = win; TN.round = null; TN.wheel = false; renderTonight(); sfx('bell'); confetti(); }, 500); }
  };
  requestAnimationFrame(step);
}

/* ---------- Jeu : Scène du film (images de la bande-annonce) ---------- */
Object.assign(GAMES, {
  scene: {name:'Scène du film', icon:'🎞', types:['films'], kind:'scene', steps:[0,1,2,3,4], server:true, desc:'Une scène du film, puis une 2e, une 3e, une 4e et une 5e : que des images du film, prises dans ses bandes-annonces.'},
});
const sceneOrder = [2, 1, 3];
const sceneImg = (yt, n) => `<img src="https://i.ytimg.com/vi/${yt}/maxres${n}.jpg" data-n="${n}" alt="Scène du film" referrerpolicy="no-referrer" onerror="if(!this.dataset.f){this.dataset.f=1;this.src='https://i.ytimg.com/vi/${yt}/hq${n}.jpg'}">`;

/* ================= v13 : Chrono-Quiz, Ciné-Connexions, Intrus, Battles, Genres, Trophées ================= */

/* ---------- Petits utilitaires ---------- */
const pick1 = a => a[Math.floor(Math.random() * a.length)];
const peopleOf = it => (it.sub || '').split(/,\s*/).map(x => x.trim()).filter(Boolean);
function peopleMap(){ const m = new Map(); F.forEach((it, i) => peopleOf(it).forEach(p => { if (!m.has(p)) m.set(p, []); m.get(p).push(i); })); return m; }
const decOf = y => y ? Math.floor(y / 10) * 10 : 0;
const decName = d => d >= 2000 ? `Années ${d}` : `Années ${String(d).slice(2)}`;
function customHead(g, extra){ return `<div class="stagehead"><div class="round"><b>${g.icon} ${g.name}</b>${extra ? ' · ' + extra : ''}</div><div class="fx" style="gap:8px"><button class="btn sm ghost" id="gquit">✕ Quitter <kbd>Échap</kbd></button></div></div>`; }
function bindQuit(){ $('gquit').onclick = gQuit; }

/* ---------- Chrono-Quiz (frise chronologique) ---------- */
const CH = {tl:[], center:null, next:null, streak:0, over:false, reveal:false, ok:null};
function chPool(){ return [...Array(N).keys()].filter(i => F[i].y > 1800); }
function chNext(){ const inT = new Set(CH.tl), P = chPool().filter(i => !inT.has(i) && F[i].y !== F[CH.center].y); return P.length ? pick1(P) : pick1(chPool().filter(i => !inT.has(i))); }
function chStart(){ const P = chPool(); CH.center = pick1(P); CH.tl = [CH.center]; CH.streak = 0; CH.over = false; CH.reveal = false; CH.next = chNext(); renderGame(); }
function chGuess(after){
  if (CH.over || CH.reveal || CH.next == null) return;
  const a = F[CH.center].y, b = F[CH.next].y, ok = a === b || (after ? b > a : b < a);
  CH.reveal = true; CH.ok = ok; renderGame(); sfx(ok ? 'win' : 'lose');
  setTimeout(() => {
    if (ok) { CH.tl.push(CH.next); CH.tl.sort((x, y) => F[x].y - F[y].y); CH.center = CH.next; CH.streak++; CH.next = chNext(); CH.reveal = false; if (CH.streak % 10 === 0) confetti(90); }
    else { CH.over = true; const rec = ls.get('ringcine-chrono', {}); if (CH.streak > (rec[C.id] || 0)) { rec[C.id] = CH.streak; ls.set('ringcine-chrono', rec); CH.rec = true; } else CH.rec = false; trophyTick(); }
    renderGame();
  }, ok ? 900 : 1300);
}
function renderChrono(){
  const g = GAMES.chrono, rec = (ls.get('ringcine-chrono', {})[C.id]) || 0;
  if (CH.center == null) return chStart();
  const card = (i, hide, cls) => `<div class="ch-card ${cls}">${imgHi(i)}<b>${T(i)}</b><span class="ch-y${hide ? ' q' : ''}${!hide && cls === 'next' && CH.reveal ? (CH.ok ? ' ok' : ' ko') : ''}">${hide ? '????' : F[i].y}</span></div>`;
  const frise = `<div class="frise">${CH.tl.map(i => `<div class="fr-it${i === CH.center ? ' cur' : ''}">${img(i, 'th')}<b>${F[i].y}</b><span>${T(i)}</span></div>`).join('<i class="fr-line"></i>')}</div>`;
  view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g, `série ${CH.streak} · record ${rec}`)}
    ${CH.over ? `<div class="ch-over"><div class="big">${CH.streak}</div><h2>${CH.rec ? '🏆 Nouveau record !' : 'Perdu !'}</h2><p class="note">${T(CH.next)} est sorti en <b>${F[CH.next].y}</b>, ${T(CH.center)} en <b>${F[CH.center].y}</b>.</p><button class="btn primary" id="chagain">↻ Rejouer <kbd>Entrée</kbd></button></div>` : `
    <div class="ch-arena">${card(CH.center, false, 'center')}
      <div class="ch-mid"><button class="btn primary" id="chaft" ${CH.reveal ? 'disabled' : ''}>⬆ Après <kbd>↑</kbd></button><button class="btn" id="chbef" ${CH.reveal ? 'disabled' : ''}>⬇ Avant <kbd>↓</kbd></button><p class="note">${T(CH.next)} est sorti avant ou après ?</p></div>
      ${card(CH.next, !CH.reveal, 'next')}</div>`}
    <div class="h3" style="margin-top:18px">Ta frise · ${CH.tl.length} ${TY.many}</div>${frise}</section>`;
  bindQuit();
  if ($('chagain')) $('chagain').onclick = chStart;
  if ($('chaft')) { $('chaft').onclick = () => chGuess(true); $('chbef').onclick = () => chGuess(false); }
  const fr = view.querySelector('.fr-it.cur'); if (fr) fr.scrollIntoView({inline:'center', block:'nearest'});
}

/* ---------- Ciné-Connexions ---------- */
const CX = {a:null, b:null, links:[], tries:0, done:false, won:false, solved:0, streak:0, casts:null, msg:''};
function cxRound(){
  const pm = peopleMap(), dirs = [...pm].filter(([, l]) => l.length >= 2);
  if (!dirs.length) { CX.a = null; return renderGame(); }
  const [d, list] = pick1(dirs); const [a, b] = shuffle(list.slice()).slice(0, 2);
  CX.a = a; CX.b = b; CX.tries = 0; CX.done = false; CX.won = false; CX.msg = ''; CX.guesses = [];
  CX.links = peopleOf(F[a]).filter(p => peopleOf(F[b]).includes(p));
  CX.casts = null;
  const tok = G.tok; Promise.all([wikiCast(F[a]), wikiCast(F[b])]).then(([ca, cb]) => { if (tok !== G.tok || CX.a !== a) return; const nb = new Set((cb || []).map(x => norm(x.n))); CX.casts = (ca || []).filter(x => nb.has(norm(x.n))); }).catch(() => {});
  renderGame();
}
function cxGuess(v){
  if (CX.done || !v.trim()) return; const n = norm(v);
  const dirOk = CX.links.some(p => norm(p) === n || (n.length >= 4 && norm(p).split(' ').pop() === n));
  const actOk = CX.casts && CX.casts.some(x => norm(x.n) === n || (n.length >= 4 && norm(x.n).split(' ').pop() === n));
  CX.guesses.push(v.trim());
  if (dirOk || actOk) { CX.done = true; CX.won = true; CX.solved++; CX.streak++; CX.msg = dirOk ? 'Bien vu : même réalisateur !' : 'Bien vu : même acteur !'; sfx('win'); const rec = ls.get('ringcine-cnx-' + C.id, {solved:0, best:0}); rec.solved++; rec.best = Math.max(rec.best, CX.streak); ls.set('ringcine-cnx-' + C.id, rec); trophyTick(); }
  else { CX.tries++; sfx('lose'); if (CX.tries >= 3) { CX.done = true; CX.streak = 0; CX.msg = 'Raté…'; } else CX.msg = CX.casts === null ? 'Pas de lien avec ce nom (le casting est encore en chargement, réessaie un acteur dans 2 s).' : 'Aucun lien avec ce nom. Encore ' + (3 - CX.tries) + ' essai' + (CX.tries === 2 ? '' : 's') + '.'; }
  renderGame();
}
function renderCnx(){
  const g = GAMES.cnx;
  if (CX.a == null) return cxRound();
  const card = i => `<div class="ch-card">${imgHi(i)}<b>${T(i)}</b><span class="note">${F[i].y || ''}</span></div>`;
  const answer = CX.done ? `<div class="greveal ${CX.won ? 'ok' : 'ko'}"><div class="gres">${esc(CX.msg)}</div><p class="note" style="text-align:center">Réalisateur en commun : <b>${CX.links.map(esc).join(', ')}</b>${CX.casts && CX.casts.length ? ` · Acteurs en commun : <b>${CX.casts.slice(0, 4).map(x => esc(x.n)).join(', ')}</b>` : ''}</p><div style="text-align:center"><button class="btn primary" id="cxnext">Suivant <kbd>Entrée</kbd></button></div></div>` : '';
  view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g, `trouvés ${CX.solved} · série ${CX.streak}`)}
    <div class="ch-arena">${card(CX.a)}<div class="ch-mid cx-mid"><div class="cx-link">🔗</div><p class="note">Qu’est-ce qui relie ces deux films ? Donne un <b>réalisateur</b> ou un <b>acteur</b> en commun.</p></div>${card(CX.b)}</div>
    ${answer || `<div class="gguess"><input class="input" id="cxin" autocomplete="off" placeholder="Réalisateur ou acteur en commun…"><div class="gsug" id="cxsug"></div></div>
      ${CX.msg ? `<p class="note" style="text-align:center;color:#FF8A94">${esc(CX.msg)}</p>` : ''}<div class="gctl"><button class="btn ghost" id="cxskip">Je donne ma langue au chat</button></div>`}</section>`;
  bindQuit();
  if ($('cxnext')) { $('cxnext').onclick = cxRound; $('cxnext').focus(); }
  if ($('cxskip')) $('cxskip').onclick = () => { CX.done = true; CX.streak = 0; CX.msg = 'La réponse :'; renderGame(); };
  const inp = $('cxin');
  if (inp) {
    const names = [...new Set([...peopleMap().keys()])];
    let hits = [], sel = 0;
    const draw = () => { const q = norm(inp.value); const extra = CX.casts ? [] : []; hits = q.length < 2 ? [] : names.concat(extra).filter(n => norm(n).includes(q)).slice(0, 8); sel = Math.min(sel, Math.max(0, hits.length - 1)); $('cxsug').innerHTML = hits.map((n, k) => `<button class="${k === sel ? 'on' : ''}" data-n="${esc(n)}"><span>${esc(n)}</span></button>`).join(''); $('cxsug').querySelectorAll('button').forEach(b => b.onmousedown = e => { e.preventDefault(); cxGuess(b.dataset.n); }); };
    inp.oninput = () => { sel = 0; draw(); };
    inp.onkeydown = e => { if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(sel + 1, hits.length - 1); draw(); } else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); draw(); } else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); cxGuess(hits.length && norm(hits[sel]).startsWith(norm(inp.value)) ? hits[sel] : inp.value); } };
    setTimeout(() => inp.focus(), 30);
  }
}

/* ---------- L'intrus (4 cartes, 1 règle cachée) ---------- */
const IN = {round:0, score:0, cards:null, odd:null, rule:'', t0:0, done:false, total:10, over:false};
function inRules(){
  const R = [];
  const add = (name, keyFn, label) => { const m = new Map(); for (let i = 0; i < N; i++) { const k = keyFn(i); if (k == null || k === '') continue; if (!m.has(k)) m.set(k, []); m.get(k).push(i); } const ok = [...m].filter(([, l]) => l.length >= 3); if (ok.length) R.push({name, m, ok, label}); };
  if (C.type === 'films') {
    add('decade', i => decOf(F[i].y) || null, k => `3 films des ${decName(+k).toLowerCase()}`);
    add('dir', i => peopleOf(F[i])[0] || null, k => `3 films de ${k}`);
    add('rating', i => F[i].r || null, k => `3 films notés ${starStr(+k)}`);
  } else if (C.type === 'music') add('artist', i => F[i].first || null, k => `3 sons de ${k}`);
  else add('sub', i => F[i].sub || null, k => `3 × « ${k} »`);
  return R;
}
function inNext(){
  const R = inRules(); if (!R.length) { IN.cards = null; return; }
  const r = pick1(R), [k, list] = pick1(r.ok), three = shuffle(list.slice()).slice(0, 3);
  const others = [...Array(N).keys()].filter(i => { const v = r.name === 'decade' ? decOf(F[i].y) : r.name === 'dir' ? peopleOf(F[i])[0] : r.name === 'rating' ? F[i].r : r.name === 'artist' ? F[i].first : F[i].sub; return v && String(v) !== String(k) && (r.name !== 'dir' || !peopleOf(F[i]).includes(k)); });
  if (!others.length) { IN.cards = null; return; }
  IN.odd = pick1(others); IN.cards = shuffle(three.concat(IN.odd)); IN.rule = r.label(k); IN.rname = r.name; IN.done = false; IN.t0 = performance.now(); IN.round++;
}
function inStart(){ IN.round = 0; IN.score = 0; IN.over = false; inNext(); renderGame(); }
function inPick(i){
  if (IN.done || !IN.cards) return; IN.done = true;
  const ok = i === IN.odd, sec = (performance.now() - IN.t0) / 1000, pts = ok ? Math.max(1, Math.round(10 - sec)) : 0;
  IN.score += pts; IN.last = {ok, pts, sec, i}; sfx(ok ? 'win' : 'lose');
  if (ok) { const rec = ls.get('ringcine-intrus-' + C.id, {found:0, best:0}); rec.found++; ls.set('ringcine-intrus-' + C.id, rec); }
  renderGame();
  setTimeout(() => { if (curView !== 'game' || G.id !== 'intrus') return; if (IN.round >= IN.total) { IN.over = true; const rec = ls.get('ringcine-intrus-' + C.id, {found:0, best:0}); if (IN.score > (rec.best || 0)) { rec.best = IN.score; ls.set('ringcine-intrus-' + C.id, rec); IN.rec = true; } else IN.rec = false; trophyTick(); if (IN.score >= 60) confetti(); } else inNext(); renderGame(); }, ok ? 1300 : 2000);
}
function renderIntrus(){
  const g = GAMES.intrus;
  if (!IN.cards && !IN.over) { if (IN.round === 0) inStart(); if (!IN.cards) { view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g)}<div class="empty" style="text-align:center;padding:60px">Pas assez de données dans ce ring pour ce jeu.</div></section>`; bindQuit(); return; } }
  const rec = ls.get('ringcine-intrus-' + C.id, {found:0, best:0});
  if (IN.over) { view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g)}<div class="ch-over"><div class="big">${IN.score}</div><h2>${IN.rec ? '🏆 Nouveau record !' : 'Partie terminée'}</h2><p class="note">sur ${IN.total} manches · record ${rec.best}</p><button class="btn primary" id="inagain">↻ Rejouer <kbd>Entrée</kbd></button></div></section>`; bindQuit(); $('inagain').onclick = inStart; return; }
  view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g, `manche ${IN.round}/${IN.total} · ${IN.score} pts`)}
    <p class="note" style="text-align:center;margin:0 0 14px">Trois cartes ont un point commun (${C.type === 'films' ? 'décennie, réalisateur ou ta note' : C.type === 'music' ? 'même artiste' : 'même détail'}). Clique vite sur l’intrus ! <kbd>1</kbd>–<kbd>4</kbd></p>
    <div class="in-grid">${IN.cards.map((i, k) => `<button class="in-card${IN.done ? (i === IN.odd ? ' odd' : ' same') : ''}${IN.done && IN.last.i === i && !IN.last.ok ? ' wrong' : ''}" data-i="${i}" ${IN.done ? 'disabled' : ''}><kbd>${k + 1}</kbd>${imgHi(i)}<b>${T(i)}</b><span>${IN.done ? esc(C.type === 'films' ? [F[i].y, peopleOf(F[i])[0], F[i].r ? starStr(F[i].r) : ''].filter(Boolean).join(' · ') : F[i].sub || '') : ''}</span></button>`).join('')}</div>
    ${IN.done ? `<div class="in-res ${IN.last.ok ? 'ok' : 'ko'}">${IN.last.ok ? `Trouvé en ${IN.last.sec.toFixed(1)} s ! +${IN.last.pts}` : 'Raté !'} · La règle : <b>${esc(IN.rule)}</b></div>` : ''}</section>`;
  bindQuit();
  view.querySelectorAll('.in-card').forEach(b => b.onclick = () => inPick(+b.dataset.i));
}

/* ---------- Enregistrement des jeux « spéciaux » ---------- */
Object.assign(GAMES, {
  chrono: {name:'Chrono-Quiz', icon:'⏳', types:['films'], custom:true, render: renderChrono, desc:'Un film au centre, un autre arrive : il est sorti avant ou après ? Chaque bonne réponse l’ajoute à ta frise chronologique.'},
  cnx:    {name:'Ciné-Connexions', icon:'🔗', types:['films'], custom:true, render: renderCnx, desc:'Deux de tes films : trouve le réalisateur ou l’acteur qui les relie.'},
  intrus: {name:'L’intrus', icon:'🃏', types:['films','music','items'], custom:true, render: renderIntrus, desc:'4 cartes, 3 ont un point commun caché. Trouve l’intrus le plus vite possible. 10 manches.'},
});
function customKey(e){
  if (curView !== 'game' || !G.id || !GAMES[G.id] || !GAMES[G.id].custom) return false;
  if (e.target.matches('input,textarea,select')) return false;
  if (e.key === 'Escape') { e.preventDefault(); gQuit(); return true; }
  if (G.id === 'path' && PT.over && e.key === 'Enter') { e.preventDefault(); PT.start = null; renderGame(); return true; }
  if (G.id === 'chrono') { if (CH.over && e.key === 'Enter') { e.preventDefault(); chStart(); return true; } if (e.key === 'ArrowUp') { e.preventDefault(); chGuess(true); return true; } if (e.key === 'ArrowDown') { e.preventDefault(); chGuess(false); return true; } }
  if (G.id === 'cnx' && CX.done && e.key === 'Enter') { e.preventDefault(); cxRound(); return true; }
  if (G.id === 'intrus') { if (IN.over && e.key === 'Enter') { e.preventDefault(); inStart(); return true; } const k = '1234'.indexOf(e.key) >= 0 ? '1234'.indexOf(e.key) : '&é"\''.indexOf(e.key); if (k >= 0 && IN.cards && !IN.done) { e.preventDefault(); inPick(IN.cards[k]); return true; } }
  return false;
}

/* ---------- Battles de duels (réalisateurs, artistes, décennies) ---------- */
function battleSides(){
  const b = S.battle; if (!b || !b.a || !b.b) return null;
  const inSide = (i, v) => b.type === 'dec' ? decOf(F[i].y) === +v : peopleOf(F[i]).includes(v);
  const A = [], B = []; for (let i = 0; i < N; i++) { if (inSide(i, b.a)) A.push(i); else if (inSide(i, b.b)) B.push(i); }
  return A.length && B.length ? [A, B] : null;
}
function battlePanel(){
  const b = S.battle || {type:'', a:'', b:''}, pm = [...peopleMap()].filter(([, l]) => l.length >= 2).sort((x, y) => y[1].length - x[1].length);
  const decs = [...new Set(F.map(it => decOf(it.y)).filter(Boolean))].sort();
  const opts = b.type === 'dec' ? decs.map(d => [String(d), decName(d)]) : pm.map(([p, l]) => [p, `${p} (${l.length})`]);
  const sel = (id, v) => `<select id="${id}"><option value="">—</option>${opts.map(([k, l]) => `<option value="${esc(k)}" ${String(v) === k ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>`;
  return `<div class="battle"><label>Battle<select id="btype"><option value="">Aucune</option><option value="ppl" ${b.type === 'ppl' ? 'selected' : ''}>${C.type === 'films' ? 'Réalisateur contre réalisateur' : 'Artiste contre artiste'}</option>${C.type === 'films' ? `<option value="dec" ${b.type === 'dec' ? 'selected' : ''}>Décennie contre décennie</option>` : ''}</select></label>
    ${b.type ? `<label>Rouge${sel('ba', b.a)}</label><span class="bvs">VS</span><label>Bleu${sel('bb', b.b)}</label>` : ''}
    ${C.type === 'films' ? `<label>Année précise<input class="input" id="fxyear" type="number" min="1890" max="2100" placeholder="ex. 1999" value="${S.fx && S.fx.y1 && S.fx.y1 === S.fx.y2 ? S.fx.y1 : ''}"></label>` : ''}</div>`;
}
function bindBattle(){
  const upd = () => { save(); pair = null; nextPair = null; renderDuel(); };
  if ($('btype')) $('btype').onchange = e => { S.battle = {type: e.target.value, a:'', b:''}; upd(); };
  if ($('ba')) $('ba').onchange = e => { S.battle.a = e.target.value; upd(); };
  if ($('bb')) $('bb').onchange = e => { S.battle.b = e.target.value; upd(); };
  if ($('fxyear')) $('fxyear').onchange = e => { const v = +e.target.value || 0; const f = fxOf(); f.y1 = v; f.y2 = v; upd(); };
}

/* ---------- Genres des films (Wikidata) ---------- */
const GENRES = [
  ['Horreur', /horreur|horrifique|épouvante|slasher|zombie|vampire|gore/i, '👻'], ['Comédie', /comédie|humour|comique|parodie|satiri/i, '😂'],
  ['Animation', /animation|animé/i, '🎨'], ['Science-fiction', /science-fiction|dystop|apocalyp|space opera|cyberpunk/i, '🚀'],
  ['Action', /action|arts martiaux|casse|super-héros|espionnage/i, '💥'], ['Thriller', /thriller|policier|néo-noir|film noir|crim|gangster|mafia|énigme/i, '🔪'],
  ['Drame', /drame|dramatique|mélodrame/i, '🎭'], ['Romance', /amour|romanti|romance/i, '💘'], ['Aventure', /aventure/i, '🗺'],
  ['Fantastique', /fantastique|fantasy|fantôme|surnaturel/i, '🧙'], ['Histoire & guerre', /guerre|historique|épique|biographi/i, '⚔'],
  ['Musical', /musical|comédie musicale/i, '🎵'], ['Ados & teen', /adolescen|passage à l'âge adulte|high school|teen/i, '🎒'], ['Sport', /sport|boxe|football|basket|course automobile/i, '🏆'],
];
const GENRE_KEY = 'ringcine-genres';
async function fetchGenres(onProg){
  const films = allCols().filter(c => c.type === 'films'), items = new Map();
  films.forEach(c => colSnapshot(c).items.forEach(it => { if (!items.has(it.key)) items.set(it.key, it); }));
  const cache = ls.get(GENRE_KEY, {}), todo = [...items.values()].filter(it => cache[it.key] === undefined);
  const cls = 'wd:Q11424 wd:Q202866 wd:Q24869 wd:Q506240 wd:Q29168811 wd:Q17517379';
  for (let p = 0; p < todo.length; p += 50) {
    const part = todo.slice(p, p + 50);
    const q = `SELECT ?t ?y ?cls ?gLabel WHERE { VALUES ?t { ${[...new Set(part.map(it => JSON.stringify(it.en || it.t) + '@en'))].join(' ')} } VALUES ?cls { ${cls} } ?film rdfs:label ?t ; wdt:P31 ?cls ; wdt:P136 ?g . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } SERVICE wikibase:label { bd:serviceParam wikibase:language "fr,en". } }`;
    try {
      const r = await (await fetch('https://query.wikidata.org/sparql?format=json&query=' + encodeURIComponent(q))).json();
      const got = new Map();
      (r.results && r.results.bindings || []).forEach(b => { const t = b.t.value, y = b.y ? +b.y.value : 0, lab = b.gLabel ? b.gLabel.value : '', anim = /Q202866|Q29168811|Q17517379/.test(b.cls.value);
        part.forEach(it => { if ((it.en || it.t) !== t || (it.y && y && Math.abs(it.y - y) > 1)) return; const s = got.get(it.key) || new Set(); GENRES.forEach(([n, re]) => { if (re.test(lab)) s.add(n); }); if (anim) s.add('Animation'); got.set(it.key, s); }); });
      part.forEach(it => { cache[it.key] = got.has(it.key) ? [...got.get(it.key)] : 0; });
      ls.set(GENRE_KEY, cache);
    } catch(e){ return false; }
    if (onProg) onProg(Math.min(todo.length, p + 50), todo.length);
  }
  return true;
}
function genreCounts(items){ const cache = ls.get(GENRE_KEY, {}), m = new Map(); let known = 0; items.forEach(it => { const g = cache[it.key]; if (g === undefined) return; known++; (g || []).forEach(n => m.set(n, (m.get(n) || 0) + 1)); }); return {m, known}; }

/* ---------- Trophées ---------- */
const TIERS_T = [['bronze', 'Bronze', '🥉'], ['silver', 'Argent', '🥈'], ['gold', 'Or', '🥇'], ['plat', 'Platine', '💎']];
/* Chaque ring (chaque lien Ring Sync) a ses propres trophées */
function trophyCtx(col){
  col = col || C;
  const sn = colSnapshot(col), items = sn.items, pre = col.id + ':';
  const ppl = new Map(); items.forEach(it => (it.sub || '').split(/,\s*/).filter(Boolean).forEach(p => ppl.set(p, (ppl.get(p) || 0) + 1)));
  const st = col.id === (C && C.id) ? S : ls.get(stateKey(col), null);
  const gsAll = gStats(), gs = Object.fromEntries(Object.entries(gsAll).filter(([k]) => k.startsWith(pre)));
  const gsum = f => Object.entries(gs).reduce((a, [k, v]) => a + f(k.slice(pre.length), v), 0);
  const hl = Object.fromEntries(Object.entries(ls.get('ringcine-hl', {})).filter(([k]) => k.startsWith(pre)));
  return {col, type: col.type, items, ppl, duels: st ? st.total || 0 : 0, champs: st ? (st.champs || []).length : 0, gs, gsum, hl,
    chrono: ls.get('ringcine-chrono', {})[col.id] || 0, path: ls.get('ringcine-path-' + col.id, {solved:0, perfect:0}), cnx: ls.get('ringcine-cnx-' + col.id, {solved:0, best:0}), intr: ls.get('ringcine-intrus-' + col.id, {found:0, best:0}),
    tier: tierPlaced(col), swipe: (ls.get('ringcine-swipe-' + col.id, {}).keep || []).length, genres: col.type === 'films' ? genreCounts(items) : {m:new Map(), known:0}};
}
function tierPlaced(col){ const d = ls.get('ringcine-tier-' + col.id, {}) || {}; return ['S','A','B','C','D'].reduce((a, t) => a + ((d[t] || []).length), 0); }
const FI = ['films'], MU = ['music'], ALL = ['films', 'music', 'items'];
const TROPHIES = [
  // Films (profil Letterboxd, watchlist, liste…)
  {cat:'films', types:FI, id:'f-seen', icon:'🎬', name:'Cinéphile', desc:'Films dans ce ring', goals:[250,750,1500,3000], v:x => x.items.length},
  {cat:'films', types:FI, id:'f-rated', icon:'⭐', name:'Critique', desc:'Films notés sur Letterboxd', goals:[200,600,1200,2500], v:x => x.items.filter(it => it.r).length},
  {cat:'films', types:FI, id:'f-five', icon:'🌟', name:'Coups de cœur', desc:'Films notés ★★★★★', goals:[20,50,100,200], v:x => x.items.filter(it => it.r === 10).length},
  {cat:'films', types:FI, id:'f-old', icon:'📽', name:'Old school', desc:'Films sortis avant 1980', goals:[15,40,100,200], v:x => x.items.filter(it => it.y && it.y < 1980).length},
  {cat:'films', types:FI, id:'f-new', icon:'🆕', name:'À la page', desc:'Films sortis depuis 2020', goals:[50,150,300,600], v:x => x.items.filter(it => it.y >= 2020).length},
  {cat:'films', types:FI, id:'f-dec', icon:'🕰', name:'Voyageur du temps', desc:'Décennies différentes', goals:[6,8,10,12], v:x => new Set(x.items.map(it => decOf(it.y)).filter(Boolean)).size},
  {cat:'films', types:FI, id:'f-dir', icon:'🎥', name:'Réalisateur fétiche', desc:'Films d’un même réalisateur', goals:[8,12,18,25], v:x => Math.max(0, ...x.ppl.values())},
  {cat:'films', types:FI, id:'f-dirs', icon:'🎞', name:'Curieux', desc:'Réalisateurs différents', goals:[250,600,1000,1800], v:x => x.ppl.size},
  ...GENRES.map(([n, , ic]) => ({cat:'genres', types:FI, id:'g-' + n, icon:ic, name:n, desc:`Films ${n.toLowerCase()}`, goals:[25,75,150,300], v:x => x.genres.m.get(n) || 0})),
  // Musique (playlist Spotify, YouTube…)
  {cat:'music', types:MU, id:'m-tracks', icon:'🎵', name:'Mélomane', desc:'Sons dans ce ring', goals:[250,600,1200,2500], v:x => x.items.length},
  {cat:'music', types:MU, id:'m-arts', icon:'🎤', name:'Éclectique', desc:'Artistes différents', goals:[100,250,500,900], v:x => x.ppl.size},
  {cat:'music', types:MU, id:'m-fav', icon:'💿', name:'Fan absolu', desc:'Sons d’un même artiste', goals:[15,30,50,80], v:x => Math.max(0, ...x.ppl.values())},
  {cat:'music', types:MU, id:'m-feat', icon:'🤝', name:'Roi des feats', desc:'Sons avec plusieurs artistes', goals:[75,200,400,700], v:x => x.items.filter(it => (it.sub || '').includes(',')).length},
  // Autres listes
  {cat:'items', types:['items'], id:'i-count', icon:'📚', name:'Collectionneur', desc:'Éléments dans ce ring', goals:[50,150,400,1000], v:x => x.items.length},
  // Ce ring : duels, tournois, outils
  {cat:'ring', types:ALL, id:'r-duels', icon:'⚔', name:'Combattant', desc:'Duels joués dans ce ring', goals:[500,2500,10000,25000], v:x => x.duels},
  {cat:'ring', types:ALL, id:'r-champs', icon:'🏆', name:'Organisateur', desc:'Tournois terminés dans ce ring', goals:[3,10,30,75], v:x => x.champs},
  {cat:'ring', types:ALL, id:'r-tier', icon:'🔠', name:'Tier-lister', desc:'Éléments placés dans la tier list', goals:[30,80,150,300], v:x => x.tier},
  {cat:'ring', types:ALL, id:'r-keep', icon:'♥', name:'Sélectionneur', desc:'Gardés dans « Garder / jeter »', goals:[30,100,250,500], v:x => x.swipe},
  // Jeux joués avec ce ring
  {cat:'games', types:ALL, id:'j-played', icon:'🎮', name:'Joueur', desc:'Manches jouées avec ce ring', goals:[50,250,1000,3000], v:x => x.gsum((g, s) => s.played || 0)},
  {cat:'games', types:MU, id:'j-blind', icon:'🎧', name:'Blind-testeur', desc:'Meilleure série au blind test', goals:[5,10,20,40], v:x => (x.gs[x.col.id + ':blind'] || {}).best || 0},
  {cat:'games', types:MU, id:'j-ear', icon:'👂', name:'Oreille absolue', desc:'Sons trouvés dès la 1re seconde', goals:[3,15,40,100], v:x => x.gsum((g, s) => g === 'blind' ? s.perfect || 0 : 0)},
  {cat:'games', types:FI, id:'j-year', icon:'📅', name:'Almanach', desc:'Années trouvées pile', goals:[3,15,40,100], v:x => x.gsum((g, s) => g === 'year' ? s.perfect || 0 : 0)},
  {cat:'games', types:FI, id:'j-cast', icon:'🎭', name:'Physionomiste', desc:'Films trouvés avec 1 seul acteur', goals:[3,15,40,100], v:x => x.gsum((g, s) => g === 'cast' ? s.perfect || 0 : 0)},
  {cat:'games', types:FI, id:'j-quote', icon:'💬', name:'Mémoire de répliques', desc:'Répliques trouvées en VO seule', goals:[3,15,35,70], v:x => x.gsum((g, s) => g === 'quote' ? s.perfect || 0 : 0)},
  {cat:'games', types:ALL, id:'j-zoom', icon:'🔍', name:'Œil de lynx', desc:'Trouvés au zoom maximum', goals:[3,15,40,100], v:x => x.gsum((g, s) => (g === 'poster' || g === 'cover') ? s.perfect || 0 : 0)},
  {cat:'games', types:ALL, id:'j-hl', icon:'⬆', name:'Plus ou moins', desc:'Meilleure série au plus ou moins', goals:[10,20,40,75], v:x => Math.max(0, ...Object.values(x.hl))},
  {cat:'games', types:FI, id:'j-path', icon:'🧭', name:'Pisteur', desc:'Chemins trouvés au jeu Le Chemin', goals:[5,15,40,100], v:x => x.path.solved},
  {cat:'games', types:FI, id:'j-path2', icon:'🗺', name:'Cartographe', desc:'Chemins parfaits (le plus court, sans aide ni erreur)', goals:[3,10,25,60], v:x => x.path.perfect},
  {cat:'games', types:FI, id:'j-cnx', icon:'🔗', name:'Connecteur', desc:'Ciné-Connexions trouvées', goals:[15,50,120,250], v:x => x.cnx.solved || 0},
  {cat:'games', types:ALL, id:'j-intrus', icon:'🃏', name:'Détective', desc:'Intrus trouvés', goals:[50,200,500,1200], v:x => x.intr.found || 0},
];
const TCATS = [['films', '🎬 Films'], ['genres', '🎭 Genres'], ['music', '🎵 Musique'], ['items', '📚 Collection'], ['ring', '⚔ Duels & outils'], ['games', '🎮 Jeux']];
const trophiesFor = col => TROPHIES.filter(t => t.types.includes(col.type));
function tierOf(t, v){ let k = -1; t.goals.forEach((g, n) => { if (v >= g) k = n; }); return k; }
var trophyT = null;
function trophyTick(){ clearTimeout(trophyT); trophyT = setTimeout(checkTrophies, 900); }
function checkTrophies(silent){
  if (!C || EXT.on) return;
  let x; try { x = trophyCtx(C); } catch(e){ return; }
  const all = ls.get('ringcine-trophies2', {}) || {};
  const legacy = Object.keys(all).some(k => /^[a-z]-/.test(k)); const store = legacy ? {} : all;
  const first = store[C.id] === undefined, cur = store[C.id] || {}, news = [];
  trophiesFor(C).forEach(t => { const k = tierOf(t, t.v(x)); if (k > (cur[t.id] ?? -1)) { if (!first && !silent) news.push([t, k]); cur[t.id] = k; } });
  if (first || news.length || silent || legacy) { store[C.id] = cur; ls.set('ringcine-trophies2', store); }
  if (first && !silent) { const n = Object.values(cur).reduce((t, k) => t + k + 1, 0); if (n) setTimeout(() => toast(`🏆 ${n} paliers de trophées débloqués pour « ${C.label} » (onglet Trophées)`), 1200); }
  news.slice(0, 3).forEach(([t, k], n) => setTimeout(() => { toast(`${TIERS_T[k][2]} Trophée ${TIERS_T[k][1]} · ${C.label} : ${t.icon} ${t.name}`); sfx('bell'); if (k >= 2) confetti(80); }, n * 2800));
}
let genreBusy = false, trophyCol = null;
function trophySummary(col){ const x = trophyCtx(col), list = trophiesFor(col); let got = 0, plat = 0; list.forEach(t => { const k = tierOf(t, t.v(x)); got += k + 1; if (k === 3) plat++; }); return {got, max: list.length * 4, plat}; }
function renderTrophies(){
  if (!trophyCol || !colById(trophyCol)) trophyCol = C.id;
  const col = colById(trophyCol), x = trophyCtx(col), list = trophiesFor(col);
  const all = list.map(t => { const v = t.v(x), k = tierOf(t, v); return {t, v, k}; });
  const got = all.reduce((a, o) => a + (o.k + 1), 0), max = list.length * 4;
  const cols = allCols();
  view.innerHTML = `<div class="tr-rings">${cols.map(c => { const s2 = trophySummary(c); return `<button class="tr-ring${c.id === col.id ? ' on' : ''}" data-id="${esc(c.id)}"><span class="rs-ico">${colIcon(c)}</span><span><b>${esc(c.label)}</b><small>${typeName(c.type)} · ${s2.got}/${s2.max}${s2.plat ? ` · 💎 ${s2.plat}` : ''}</small></span></button>`; }).join('')}</div>
    <section class="tr-hero"><div><span class="kicker">Trophées · ${esc(col.label)}</span><h2>${got} / ${max}</h2><p class="note">paliers débloqués dans ce ring · ${all.filter(o => o.k === 3).length} en platine</p></div>
    <div class="tr-medals">${TIERS_T.map(([, l, ic], n) => `<div><b>${ic} ${all.filter(o => o.k >= n).length}</b><span>${l}</span></div>`).join('')}</div></section>
    ${TCATS.map(([cat, title]) => { const lst = all.filter(o => o.t.cat === cat); if (!lst.length) return '';
      return `<section class="tr-sec"><div class="sech"><h2>${title}</h2>${cat === 'genres' ? `<button class="btn sm${x.genres.known < x.items.length * .5 ? ' primary' : ''}" id="gfetch">${genreBusy ? 'Analyse en cours…' : x.genres.known ? `↻ Mettre à jour les genres (${x.genres.known}/${x.items.length})` : '🔎 Analyser les genres de ces films'}</button>` : ''}</div>
        ${cat === 'genres' && !x.genres.known ? '<p class="note" style="margin:-4px 0 12px">Ring va chercher le genre de chaque film sur Wikidata (quelques secondes par centaine de films, une seule fois).</p>' : ''}
        <div class="tr-grid">${lst.map(({t, v, k}) => { const next = t.goals[Math.min(3, k + 1)], prev = k >= 0 ? t.goals[k] : 0, pct = k === 3 ? 100 : Math.min(100, Math.round((v - prev) / (next - prev) * 100));
          return `<div class="tr-card tier${k}"><div class="tr-ic">${t.icon}</div><div class="tr-body"><b>${esc(t.name)}</b><span class="note">${esc(t.desc)}</span>
            <div class="tr-steps">${t.goals.map((g, n) => `<i class="${n <= k ? 'on t' + n : ''}" title="${TIERS_T[n][1]} : ${fmt(g)}">${TIERS_T[n][2]}</i>`).join('')}</div>
            <div class="bar"><i style="width:${Math.max(0, pct)}%"></i></div><span class="tr-v">${fmt(v)} / ${fmt(k === 3 ? t.goals[3] : next)}${k >= 0 ? ` · ${TIERS_T[k][1]}` : ''}</span></div></div>`; }).join('')}</div></section>`; }).join('')}`;
  view.querySelectorAll('.tr-ring').forEach(b => b.onclick = () => { trophyCol = b.dataset.id; renderTrophies(); });
  const gb = $('gfetch');
  if (gb) gb.onclick = async () => {
    if (genreBusy) return; genreBusy = true; gb.textContent = 'Analyse en cours… 0 %'; gb.disabled = true;
    const ok = await fetchGenres((d, n) => { const b = $('gfetch'); if (b) b.textContent = `Analyse en cours… ${Math.round(d / n * 100)} %`; });
    genreBusy = false; if (!ok) toast('Wikidata ne répond pas pour l’instant, réessaie plus tard.'); else toast('Genres analysés !');
    checkTrophies(); if (curView === 'trophy') renderTrophies();
  };
  if (col.id === C.id) checkTrophies(true);
}
/* ================= v14 : Roulette verticale (tout le ring) + roulette perso ================= */
const RL = {mode:null, list:null, label:'', strip:null, spinning:false, win:null, off:0};
const RL_CUSTOM = 'ringcine-roulette';
const rlObj = it => ({t: it.t, sub: it.sub || '', y: it.y || 0, img: it.img || '', link: it.link || '', key: it.key});
const RL_H = 214;
function rlCard(o, k){ return `<div class="rl-it" data-k="${k}">${o.img ? `<img src="${esc(o.img)}" alt="" loading="eager" decoding="async" referrerpolicy="no-referrer" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'noposter',textContent:''}))">` : `<div class="noposter">${esc(o.t)}</div>`}<span>${esc(o.t)}</span></div>`; }
function rlBuild(){
  const L = RL.list, n = L.length, winI = Math.floor(Math.random() * n);
  const len = 70, at = 60, strip = [];
  for (let k = 0; k < len; k++) strip.push(k === at ? L[winI] : L[Math.floor(Math.random() * n)]);
  // évite que le gagnant apparaisse juste à côté (plus lisible)
  if (n > 1) [at - 1, at + 1].forEach(k => { let g = 0; while (strip[k] === L[winI] && g++ < 10) strip[k] = L[Math.floor(Math.random() * n)]; });
  RL.strip = strip; RL.at = at; RL.win = L[winI];
  strip.forEach(o => { if (o.img) { const im = new Image(); im.referrerPolicy = 'no-referrer'; im.src = o.img; } });
}
function renderReel(){
  if (!RL.strip) rlBuild();
  view.innerHTML = `<section class="rl-wrap">
    <div class="stagehead" style="width:100%"><div class="round"><b>🎰 Roulette</b> · ${esc(RL.label)} · ${fmt(RL.list.length)} ${RL.list.length > 1 ? 'éléments' : 'élément'}</div>
      <div class="fx" style="gap:8px">${RL.mode === 'custom' ? '<button class="btn sm" id="rledit">✏️ Modifier la roulette</button>' : ''}<button class="btn sm ghost" id="rlquit">Retour</button></div></div>
    <div class="rl-reel"><div class="rl-mark"></div><div class="rl-strip" id="rlstrip">${RL.strip.map(rlCard).join('')}</div><div class="rl-fade top"></div><div class="rl-fade bot"></div></div>
    <button class="btn primary rl-go" id="rlgo">🎰 Lancer <kbd>Espace</kbd></button>
    <p class="note">Ring tire au sort parmi <b>tous</b> les ${fmt(RL.list.length)} éléments. La roulette tourne 5 à 10 secondes avant de s’arrêter.</p></section>`;
  const st = $('rlstrip'), win = view.querySelector('.rl-reel').clientHeight;
  RL.off = Math.max(0, 3 * RL_H - (win / 2 - RL_H / 2)); st.style.transform = `translateY(${-RL.off}px)`;
  $('rlgo').onclick = rlSpin;
  $('rlquit').onclick = () => { TN.reel = false; RL.strip = null; renderTonight(); };
  if ($('rledit')) $('rledit').onclick = () => { TN.reel = false; TN.edit = true; RL.strip = null; renderTonight(); };
}
function rlSpin(){
  if (RL.spinning) return;
  if (RL.done) { RL.done = false; rlBuild(); renderReel(); }
  const st = $('rlstrip'); if (!st) return;
  RL.spinning = true; $('rlgo').disabled = true;
  const win = view.querySelector('.rl-reel').clientHeight;
  const from = RL.off, to = RL.at * RL_H - (win / 2 - RL_H / 2) + (Math.random() - .5) * RL_H * .5;
  const dur = 5000 + Math.random() * 5000, t0 = performance.now();
  const ease = t => 1 - Math.pow(1 - t, 4.2);
  let last = -1;
  const step = now => {
    const t = Math.min(1, (now - t0) / dur), y = from + (to - from) * ease(t);
    st.style.transform = `translateY(${-y}px)`;
    const idx = Math.floor((y + win / 2) / RL_H); if (idx !== last) { last = idx; sfx('tick'); }
    if (t < 1) return requestAnimationFrame(step);
    const fix = RL.at * RL_H - (win / 2 - RL_H / 2); st.style.transition = 'transform .35s ease'; st.style.transform = `translateY(${-fix}px)`; RL.off = fix;
    setTimeout(() => { st.style.transition = ''; const el = st.querySelector(`.rl-it[data-k="${RL.at}"]`); if (el) el.classList.add('win'); sfx('bell'); confetti(); RL.spinning = false; RL.done = true;
      setTimeout(() => rlReveal(), 1100); }, 380);
  };
  requestAnimationFrame(step);
}
function rlReveal(){
  const it = RL.win, q = encodeURIComponent(`${it.t} ${it.y || ''} bande annonce vostfr`);
  view.innerHTML = `<section class="tn-win"><div class="tn-bg">${it.img ? `<img src="${esc(tinyRes(it.img))}" alt="" referrerpolicy="no-referrer">` : ''}</div>
    <div class="tn-in"><span class="kicker">La roulette a choisi</span>${it.img ? `<img class="poster" src="${esc(hiRes(it.img))}" data-lo="${esc(it.img)}" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}" alt="">` : `<div class="noposter poster">${esc(it.t)}</div>`}<h2>${esc(it.t)}</h2><div class="cmeta">${esc([it.y || '', it.sub].filter(Boolean).join(' · '))}</div>
    <div class="row"><a class="btn primary" href="https://www.youtube.com/results?search_query=${q}" target="_blank" rel="noopener">▶ Bande-annonce</a>${it.link ? `<a class="btn" href="${esc(it.link)}" target="_blank" rel="noopener">Ouvrir la page ↗</a>` : ''}<button class="btn" id="rlagain">🎰 Relancer</button>${RL.mode === 'custom' ? `<button class="btn" id="rlrm">✕ Retirer « ${esc(it.t.slice(0, 24))} » et relancer</button>` : ''}<button class="btn ghost" id="rlback">Retour</button></div></div></section>`;
  $('rlagain').onclick = () => { RL.done = false; RL.strip = null; TN.reel = true; renderTonight(); setTimeout(rlSpin, 250); };
  if ($('rlrm')) $('rlrm').onclick = () => { const L = ls.get(RL_CUSTOM, []).filter(o => o.key !== it.key); ls.set(RL_CUSTOM, L); RL.list = L; if (L.length < 2) { TN.reel = false; TN.edit = true; renderTonight(); return; } RL.done = false; RL.strip = null; TN.reel = true; renderTonight(); setTimeout(rlSpin, 250); };
  $('rlback').onclick = () => { TN.reel = false; RL.strip = null; renderTonight(); };
}
function rlStartRing(colId){
  const col = colById(colId), sn = colSnapshot(col);
  RL.mode = 'ring'; RL.label = col.label; RL.list = sn.items.map(rlObj); RL.strip = null; RL.done = false; TN.reel = true; renderTonight();
}
function rlStartCustom(){
  const L = ls.get(RL_CUSTOM, []); if (L.length < 2) { toast('Ajoute au moins 2 éléments dans ta roulette.'); return; }
  RL.mode = 'custom'; RL.label = 'Ma roulette'; RL.list = L; RL.strip = null; RL.done = false; TN.reel = true; TN.edit = false; renderTonight();
}
let rlQ = '';
function renderRlEdit(){
  const L = ls.get(RL_CUSTOM, []), inL = new Set(L.map(o => o.key));
  const pool = new Map(); allCols().forEach(c => colSnapshot(c).items.forEach(it => { if (!pool.has(it.key)) pool.set(it.key, Object.assign(rlObj(it), {ring: c.label})); }));
  const q = norm(rlQ), res = q.length < 2 ? [] : [...pool.values()].filter(o => norm(o.t + ' ' + o.sub).includes(q)).sort((a, b) => (norm(b.t).startsWith(q)) - (norm(a.t).startsWith(q)) || a.t.length - b.t.length).slice(0, 30);
  view.innerHTML = `<section class="rl-edit"><div class="stagehead"><div class="round"><b>✏️ Ma roulette perso</b> · ${L.length} élément${L.length > 1 ? 's' : ''}</div><div class="fx" style="gap:8px"><button class="btn sm ghost" id="rlback2">Retour</button></div></div>
    <p class="note">Choisis toi-même ce qui va dans la roulette (2, 4, 5… ou autant que tu veux), dans tous tes rings : films, watchlist, sons…</p>
    <div class="rl-cols"><div class="panel"><h3>Ajouter</h3><input class="input" id="rlq" placeholder="Chercher un film, un son…" value="${esc(rlQ)}" autocomplete="off" style="width:100%">
      <div class="rl-res">${res.map(o => `<button class="rl-row${inL.has(o.key) ? ' in' : ''}" data-k="${esc(o.key)}">${o.img ? `<img src="${esc(o.img)}" alt="" referrerpolicy="no-referrer">` : '<i></i>'}<span><b>${esc(o.t)}</b><small>${esc([o.y || '', o.sub, o.ring].filter(Boolean).join(' · '))}</small></span><em>${inL.has(o.key) ? '✓' : '＋'}</em></button>`).join('') || `<p class="note">${q.length < 2 ? 'Tape au moins 2 lettres.' : 'Aucun résultat.'}</p>`}</div></div>
      <div class="panel"><h3>Dans ta roulette</h3><div class="rl-mine">${L.map(o => `<div class="rl-chip">${o.img ? `<img src="${esc(o.img)}" alt="" referrerpolicy="no-referrer">` : ''}<span>${esc(o.t)}</span><button data-rm="${esc(o.key)}" title="Retirer">✕</button></div>`).join('') || '<p class="note">Vide pour l’instant.</p>'}</div>
        <div class="fx" style="gap:8px;margin-top:12px;flex-wrap:wrap"><button class="btn primary" id="rlgo2" ${L.length < 2 ? 'disabled' : ''}>🎰 Lancer la roulette</button>${L.length ? '<button class="btn ghost" id="rlclear">Tout vider</button>' : ''}</div></div></div></section>`;
  const qi = $('rlq'); qi.oninput = () => { rlQ = qi.value; clearTimeout(qT); qT = setTimeout(() => { renderRlEdit(); const n = $('rlq'); n.focus(); n.setSelectionRange(n.value.length, n.value.length); }, 120); };
  setTimeout(() => { const n = $('rlq'); if (n && document.activeElement !== n) n.focus(); }, 30);
  view.querySelectorAll('.rl-row').forEach(b => b.onclick = () => { const k = b.dataset.k, cur = ls.get(RL_CUSTOM, []); if (cur.some(o => o.key === k)) ls.set(RL_CUSTOM, cur.filter(o => o.key !== k)); else { const o = pool.get(k); if (o) { const {ring, ...x} = o; cur.push(x); ls.set(RL_CUSTOM, cur); } } sfx('tick'); renderRlEdit(); });
  view.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => { ls.set(RL_CUSTOM, ls.get(RL_CUSTOM, []).filter(o => o.key !== b.dataset.rm)); renderRlEdit(); });
  $('rlgo2').onclick = rlStartCustom;
  if ($('rlclear')) $('rlclear').onclick = () => { ls.set(RL_CUSTOM, []); renderRlEdit(); };
  $('rlback2').onclick = () => { TN.edit = false; renderTonight(); };
}


/* ================= v15 : Box office, Musique du film, Scène culte ================= */
const FILM_SONGS_RAW = {"Pulp Fiction|1994": [["Dick Dale", "Misirlou"], ["Chuck Berry", "You Never Can Tell"], ["Urge Overkill", "Girl, You'll Be a Woman Soon"]], "Reservoir Dogs|1992": [["Stealers Wheel", "Stuck in the Middle with You"], ["George Baker Selection", "Little Green Bag"]], "Guardians of the Galaxy|2014": [["Blue Swede", "Hooked on a Feeling"], ["Redbone", "Come and Get Your Love"]], "Guardians of the Galaxy Vol. 2|2017": [["Electric Light Orchestra", "Mr. Blue Sky"], ["Fleetwood Mac", "The Chain"]], "Guardians of the Galaxy Vol. 3|2023": [["Radiohead", "Creep"], ["Florence + the Machine", "Dog Days Are Over"]], "Shrek|2001": [["Smash Mouth", "All Star"]], "Wayne's World|1992": [["Queen", "Bohemian Rhapsody"]], "Saturday Night Fever|1977": [["Bee Gees", "Stayin' Alive"]], "Scarface|1983": [["Paul Engemann", "Push It to the Limit"]], "The Breakfast Club|1985": [["Simple Minds", "Don't You (Forget About Me)"]], "Ferris Bueller's Day Off|1986": [["The Beatles", "Twist and Shout"]], "Back to the Future|1985": [["Chuck Berry", "Johnny B. Goode"]], "Donnie Darko|2001": [["Gary Jules", "Mad World"]], "American Psycho|2000": [["Huey Lewis and the News", "Hip to Be Square"]], "Mean Girls|2004": [["Bobby Helms", "Jingle Bell Rock"]], "10 Things I Hate About You|1999": [["Frankie Valli", "Can't Take My Eyes Off You"]], "Iron Man|2008": [["AC/DC", "Back in Black"]], "Thor: Ragnarok|2017": [["Led Zeppelin", "Immigrant Song"]], "Joker|2019": [["Gary Glitter", "Rock and Roll Part 2"]], "Home Alone|1990": [["Brenda Lee", "Rockin' Around the Christmas Tree"]], "Kill Bill: Vol. 1|2003": [["Tomoyasu Hotei", "Battle Without Honor or Humanity"], ["Nancy Sinatra", "Bang Bang (My Baby Shot Me Down)"]], "Drive|2011": [["Kavinsky", "Nightcall"]], "Baby Driver|2017": [["The Jon Spencer Blues Explosion", "Bellbottoms"], ["Queen", "Brighton Rock"]], "Deadpool|2016": [["Juice Newton", "Angel of the Morning"], ["DMX", "X Gon' Give It to Ya"], ["Salt-N-Pepa", "Shoop"]], "8 Mile|2002": [["Eminem", "Lose Yourself"]], "Whiplash|2014": [["Duke Ellington", "Caravan"], ["Hank Levy", "Whiplash"]], "Captain Marvel|2019": [["No Doubt", "Just a Girl"]], "Spider-Man: Homecoming|2017": [["Ramones", "Blitzkrieg Bop"]], "Forrest Gump|1994": [["Creedence Clearwater Revival", "Fortunate Son"]], "GoodFellas|1990": [["Derek and the Dominos", "Layla"]], "The Wolf of Wall Street|2013": [["Umberto Tozzi", "Gloria"]], "Rocky III|1982": [["Survivor", "Eye of the Tiger"]], "Zombieland|2009": [["Metallica", "For Whom the Bell Tolls"]], "Kingsman: The Secret Service|2014": [["Lynyrd Skynyrd", "Free Bird"]], "Saltburn|2023": [["Sophie Ellis-Bextor", "Murder on the Dancefloor"]], "Barbie|2023": [["Matchbox Twenty", "Push"]], "Once Upon a Time... in Hollywood|2019": [["Deep Purple", "Hush"]], "Django Unchained|2012": [["Jim Croce", "I Got a Name"]], "Inglourious Basterds|2009": [["David Bowie", "Cat People (Putting Out Fire)"]], "Lost in Translation|2003": [["The Jesus and Mary Chain", "Just Like Honey"]], "Fight Club|1999": [["Pixies", "Where Is My Mind?"]], "The Big Lebowski|1998": [["Creedence Clearwater Revival", "Lookin' Out My Back Door"]], "Magnolia|1999": [["Aimee Mann", "Wise Up"]], "La La Land|2016": [["a-ha", "Take On Me"]], "Thor: Love and Thunder|2022": [["Guns N' Roses", "Welcome to the Jungle"]], "Spider-Man: Into the Spider-Verse|2018": [["Post Malone & Swae Lee", "Sunflower"]], "The Suicide Squad|2021": [["Pixies", "Hey"]], "Get Out|2017": [["Childish Gambino", "Redbone"]], "Us|2019": [["Luniz", "I Got 5 on It"], ["Minnie Riperton", "Les Fleurs"]], "Parasite|2019": [["Gianni Morandi", "In ginocchio da te"]], "Taxi Driver|1976": [["Jackson Browne", "Late for the Sky"]], "Knives Out|2019": [["Nat King Cole", "Sweet Lorraine"]], "Atomic Blonde|2017": [["David Bowie", "Cat People (Putting Out Fire)"]], "Deadpool 2|2018": [["Celine Dion", "Ashes"]], "Deadpool & Wolverine|2024": [["NSYNC", "Bye Bye Bye"]], "Bullet Train|2022": [["Carmen Sevilla", "Stayin' Alive"]], "The Social Network|2010": [["The Beatles", "Baby, You're a Rich Man"]], "Sinners|2025": [["Miles Caton", "I Lied to You"]], "Anora|2024": [["Take That", "Greatest Day"]], "The Substance|2024": [["Pat Benatar", "Hit Me with Your Best Shot"]], "The Batman|2022": [["Nirvana", "Something in the Way"]], "Avengers: Endgame|2019": [["The Kinks", "Supersonic Rocket Ship"]], "The Intouchables|2011": [["Earth, Wind & Fire", "Boogie Wonderland"]], "Superbad|2007": [["Rick James", "Super Freak"]], "Bad Boys|1995": [["Inner Circle", "Bad Boys"]], "Bad Boys II|2003": [["Inner Circle", "Bad Boys"]], "Spider-Man 3|2007": [["James Brown", "People Get Up and Drive Your Funky Soul"]], "The Hangover|2009": [["Kanye West", "Can't Tell Me Nothing"]], "Project X|2012": [["Kid Cudi", "Pursuit of Happiness"]], "Slumdog Millionaire|2008": [["M.I.A.", "Paper Planes"]], "The Lion King|1994": [["Elton John", "Circle of Life"]], "Coco|2017": [["Anthony Gonzalez", "Remember Me"]], "Toy Story|1995": [["Randy Newman", "You've Got a Friend in Me"]], "Shrek 2|2004": [["Jennifer Saunders", "Holding Out for a Hero"]], "Megamind|2010": [["AC/DC", "Highway to Hell"]], "Hotel Transylvania|2012": [["Andy Samberg", "The Zing"]], "Despicable Me 2|2013": [["Pharrell Williams", "Happy"]], "Inception|2010": [["Édith Piaf", "Non, je ne regrette rien"]], "2001: A Space Odyssey|1968": [["Richard Strauss", "Also sprach Zarathustra"]], "Snatch|2000": [["Klint", "Diamond"]], "Scream|1996": [["Nick Cave and the Bad Seeds", "Red Right Hand"]], "Twilight|2008": [["Muse", "Supermassive Black Hole"]], "Fast Five|2011": [["Don Omar", "Danza Kuduro"]], "Furious 7|2015": [["Wiz Khalifa", "See You Again"]], "2 Fast 2 Furious|2003": [["Ludacris", "Act a Fool"]], "The Fast and the Furious: Tokyo Drift|2006": [["Teriyaki Boyz", "Tokyo Drift (Fast & Furious)"]], "Straight Outta Compton|2015": [["N.W.A", "Straight Outta Compton"]], "La Haine|1995": [["Bob Marley", "Burnin' and Lootin'"]], "Death Proof|2007": [["Joe Tex", "The Love You Save"]], "Joker: Folie à Deux|2024": [["Lady Gaga", "That's Entertainment"]]};
const FILM_SONGS = new Map(Object.entries(FILM_SONGS_RAW).map(([k, v]) => { const [t, y] = k.split('|'); return [keyHash(`${t} (${y})`), v]; }));

/* ---------- Box office mondial via Wikidata (qui reprend Box Office Mojo) ---------- */
const BO_KEY = 'ringcine-bo';
async function fetchBO(idx){
  const cache = ls.get(BO_KEY, {}), todo = idx.filter(i => F[i].t && cache[F[i].key] === undefined);
  for (let p = 0; p < todo.length; p += 50) {
    const part = todo.slice(p, p + 50);
    const vals = [...new Set(part.map(i => JSON.stringify(F[i].en || F[i].t) + '@en'))].join(' ');
    const q = `SELECT ?t ?y ?bo WHERE { VALUES ?t { ${vals} } VALUES ?cls { wd:Q11424 wd:Q202866 wd:Q29168811 wd:Q24869 } ?film rdfs:label ?t ; wdt:P31 ?cls ; p:P2142 ?st . ?st psv:P2142 ?v . ?v wikibase:quantityAmount ?bo ; wikibase:quantityUnit wd:Q4917 . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`;
    try {
      const r = await (await fetch('https://query.wikidata.org/sparql?format=json&query=' + encodeURIComponent(q))).json();
      const found = new Map();
      (r.results && r.results.bindings || []).forEach(b => {
        const t = b.t.value, y = b.y ? +b.y.value : 0, v = Math.round(+b.bo.value); if (!(v > 1000)) return;
        part.forEach(i => { if ((F[i].en || F[i].t) === t && (!F[i].y || !y || Math.abs(F[i].y - y) <= 1)) found.set(i, Math.max(found.get(i) || 0, v)); });
      });
      part.forEach(i => { cache[F[i].key] = found.get(i) || 0; });
      ls.set(BO_KEY, cache);
    } catch(e){ break; }
  }
  return ls.get(BO_KEY, {});
}
function fmtMoney(v){
  if (v >= 1e9) return (v / 1e9).toFixed(2).replace('.', ',').replace(/,?0+$/, '') + ' Md $';
  if (v >= 1e6) return (v >= 1e8 ? Math.round(v / 1e6) : (v / 1e6).toFixed(1).replace('.', ',').replace(/,0$/, '')) + ' M $';
  return Math.round(v / 1e3) + ' k $';
}
HLM.bo = {name:'Box office mondial', short:'Box office', unit:'$', films:true, q:'a rapporté plus ou moins au box office ?', up:'Plus d’argent', down:'Moins d’argent'};

/* ---------- Scènes cultes (images choisies par Letterboxd pour chaque film) ---------- */
const BD_KEY = 'ringcine-backdrops';
const bdAll = () => ls.get(BD_KEY, {});
function bdOf(i, all){ all = all || bdAll(); const v = all[F[i].key] || all[keyHash(`${F[i].en || F[i].t} (${F[i].y})`)] || all[keyHash(F[i].en || F[i].t)]; return v ? 'https://a.ltrbxd.com/resized/' + v : ''; }
function saveBD(list){
  if (!Array.isArray(list) || !list.length) return 0;
  const all = bdAll(); let n = 0;
  list.forEach(([name, path]) => { if (!name) return; path = String(path || ''); if (path && !/^[\w\/.\-]+\.jpg(\?v=[\w]+)?$/.test(path)) return; const k = keyHash(name); if (path) { if (!all[k]) n++; all[k] = path; } else if (!(k in all)) all[k] = ''; });
  ls.set(BD_KEY, all); return n;
}
function bdKnown(){ return Object.keys(bdAll()).join(','); }

Object.assign(GAMES, {
  fsong:  {name:'Musique du film', icon:'🎶', types:['films'], kind:'clip', visible:false, steps:[2,5,10,20], unit:'s', server:true, desc:'Une chanson qu’on entend PENDANT le film (pas la B.O. composée ni l’album) : devine de quel film elle vient. 2 s, 5 s, 10 s puis 20 s + le titre du son.'},
  iconic: {name:'Scène culte', icon:'🌟', types:['films'], kind:'iconic', steps:[0,1,2,3,4], desc:'L’image culte du film (celle choisie par Letterboxd, pas une image de bande-annonce) : d’abord un gros zoom, puis elle se dévoile. Puis l’année et le réalisateur.'},
});
const ICZ = [3.2, 1.9, 1];
GAMES.fsong.avail = () => { const n = F.filter(it => FILM_SONGS.has(it.key)).length; return n ? `${n} films de ce ring ont une chanson culte` : 'Aucun film de ce ring dans la liste'; };
GAMES.iconic.avail = () => { const all = bdAll(); const n = F.filter((_, i) => bdOf(i, all)).length; return n ? `${n} scènes cultes récupérées · relance Ring Sync pour en avoir plus` : 'À activer : relance Ring Sync sur ta page Letterboxd'; };


/* ================= v16 : titres originaux des films (Wikidata / Wikipédia) ================= */
const OT_KEY = 'ringcine-ot';
let otBusy = false; var otReady = true;
const otLatin = s => /^[\p{Script=Latin}\p{N}\p{P}\p{Zs}\p{S}]+$/u.test(s);
function otPick(rows, en){
  // rows : [{ot, lang, ol, y}] pour un film ; on garde le titre dans la langue originale du film
  const ol = (rows.find(r => r.ol) || {}).ol || '';
  let r = ol ? rows.find(x => x.lang && (x.lang === ol || x.lang.split('-')[0] === ol.split('-')[0])) : null;
  if (!r && new Set(rows.map(x => x.ot)).size === 1) r = rows[0];
  if (!r || !r.ot || /^en\b/.test(r.lang || '') || !otLatin(r.ot)) return '';
  const o = r.ot.trim(); return norm(o) === norm(en) ? '' : o;
}
async function otSparql(q){ const r = await (await fetch('https://query.wikidata.org/sparql?format=json&query=' + encodeURIComponent(q))).json(); return (r.results && r.results.bindings) || []; }
const OT_CLS = 'wd:Q11424 wd:Q202866 wd:Q29168811 wd:Q24869 wd:Q506240';
async function fetchOT(items){
  if (otBusy) return false; otBusy = true;
  const cache = ls.get(OT_KEY, {}); let changed = false;
  try {
    const todo = items.filter(it => it.en && cache[it.key] === undefined);
    const miss = [];
    // 1) par le titre anglais exact
    for (let p = 0; p < todo.length; p += 50) {
      const part = todo.slice(p, p + 50);
      const vals = [...new Set(part.map(it => JSON.stringify(it.en) + '@en'))].join(' ');
      const B = await otSparql(`SELECT ?t ?y ?ot ?ol WHERE { VALUES ?t { ${vals} } VALUES ?cls { ${OT_CLS} } ?film rdfs:label ?t ; wdt:P31 ?cls ; wdt:P1476 ?ot . OPTIONAL { ?film wdt:P364 ?L . ?L wdt:P424 ?ol } OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`);
      part.forEach(it => {
        const rows = B.filter(b => b.t.value === it.en && (!it.y || !b.y || Math.abs(+b.y.value - it.y) <= 1)).map(b => ({ot: b.ot.value, lang: b.ot['xml:lang'] || '', ol: b.ol ? b.ol.value : '', y: b.y ? +b.y.value : 0}));
        if (!rows.length) { miss.push(it); return; }
        cache[it.key] = otPick(rows, it.en); changed = true;
      });
    }
    // 2) les autres : via l'article Wikipédia anglais (« Titre (2008 film) », « Titre (film) », « Titre »)
    for (let p = 0; p < miss.length; p += 16) {
      const part = miss.slice(p, p + 16), titles = [];
      part.forEach(it => titles.push(`${it.en} (${it.y} film)`, `${it.en} (film)`, it.en));
      const j = await (await fetch('https://en.wikipedia.org/w/api.php?format=json&origin=*&action=query&redirects=1&prop=pageprops&ppprop=wikibase_item|disambiguation&titles=' + encodeURIComponent(titles.join('|')))).json();
      const q = j.query || {}, al = new Map(), qidOf = new Map();
      (q.normalized || []).forEach(x => al.set(x.to, x.from)); (q.redirects || []).forEach(x => al.set(x.to, al.get(x.from) || x.from));
      Object.values(q.pages || {}).forEach(pg => { if (pg.pageprops && pg.pageprops.wikibase_item && !('disambiguation' in pg.pageprops)) qidOf.set(al.get(pg.title) || pg.title, pg.pageprops.wikibase_item); });
      const cand = new Map(); part.forEach(it => cand.set(it.key, [`${it.en} (${it.y} film)`, `${it.en} (film)`, it.en].map(t => qidOf.get(t)).filter(Boolean)));
      const qids = [...new Set([...cand.values()].flat())];
      const B = qids.length ? await otSparql(`SELECT ?film ?y ?ot ?ol WHERE { VALUES ?film { ${qids.map(x => 'wd:' + x).join(' ')} } VALUES ?cls { ${OT_CLS} } ?film wdt:P31 ?cls ; wdt:P1476 ?ot . OPTIONAL { ?film wdt:P364 ?L . ?L wdt:P424 ?ol } OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`) : [];
      part.forEach(it => {
        let val = '';
        for (const qid of cand.get(it.key)) {
          const rows = B.filter(b => b.film.value.endsWith('/' + qid) && (!it.y || !b.y || Math.abs(+b.y.value - it.y) <= 1)).map(b => ({ot: b.ot.value, lang: b.ot['xml:lang'] || '', ol: b.ol ? b.ol.value : ''}));
          if (rows.length) { val = otPick(rows, it.en); break; }
        }
        cache[it.key] = val; changed = true;
      });
    }
  } catch(e){}
  if (changed) ls.set(OT_KEY, cache);
  otBusy = false; return changed;
}
async function otRun(){
  if (!C || C.type !== 'films') return;
  const colId = C.id, before = ls.get(OT_KEY, {});
  if (!F.some(it => it.en && before[it.key] === undefined)) return;
  const ok = await fetchOT(F.slice());
  if (!ok || !C || C.id !== colId) return;
  const OT = ls.get(OT_KEY, {}); let n = 0;
  F.forEach(it => { const o = OT[it.key]; if (o && it.t !== o) { it.t = o; n++; } });
  if (n && !(curView === 'game' && G.id) && curView !== 'duel') go(curView);
}


/* ================= v17 : Le Chemin (acteurs ↔ films), Scène culte en vidéo, B.O. pour tous les films ================= */

/* ---------- Films → Wikidata (identifiant QID), en cache ---------- */
const QID_KEY = 'ringcine-qid';
async function wdResolve(items){
  const cache = ls.get(QID_KEY, {}), todo = items.filter(it => (it.en || it.t) && cache[it.key] === undefined), miss = [];
  const tt = it => it.en || it.t;
  for (let p = 0; p < todo.length; p += 50) {
    const part = todo.slice(p, p + 50);
    const vals = [...new Set(part.map(it => JSON.stringify(tt(it)) + '@en'))].join(' ');
    const B = await otSparql(`SELECT ?t ?y ?film WHERE { VALUES ?t { ${vals} } VALUES ?cls { ${OT_CLS} } ?film rdfs:label ?t ; wdt:P31 ?cls . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`);
    part.forEach(it => {
      const rows = B.filter(b => b.t.value === tt(it)).map(b => ({q: b.film.value.split('/').pop(), dy: it.y && b.y ? Math.abs(+b.y.value - it.y) : 0})).filter(r => r.dy <= 1).sort((a, b) => a.dy - b.dy);
      if (rows.length) cache[it.key] = rows[0].q; else miss.push(it);
    });
    ls.set(QID_KEY, cache);
  }
  for (let p = 0; p < miss.length; p += 16) {
    const part = miss.slice(p, p + 16), titles = [];
    part.forEach(it => titles.push(`${tt(it)} (${it.y} film)`, `${tt(it)} (film)`, tt(it)));
    const j = await (await fetch('https://en.wikipedia.org/w/api.php?format=json&origin=*&action=query&redirects=1&prop=pageprops&ppprop=wikibase_item|disambiguation&titles=' + encodeURIComponent(titles.join('|')))).json();
    const q = j.query || {}, al = new Map(), qidOf = new Map();
    (q.normalized || []).forEach(x => al.set(x.to, x.from)); (q.redirects || []).forEach(x => al.set(x.to, al.get(x.from) || x.from));
    Object.values(q.pages || {}).forEach(pg => { if (pg.pageprops && pg.pageprops.wikibase_item && !('disambiguation' in pg.pageprops)) qidOf.set(al.get(pg.title) || pg.title, pg.pageprops.wikibase_item); });
    const cand = new Map(); part.forEach(it => cand.set(it.key, [`${tt(it)} (${it.y} film)`, `${tt(it)} (film)`, tt(it)].map(t => qidOf.get(t)).filter(Boolean)));
    const qids = [...new Set([...cand.values()].flat())];
    const B = qids.length ? await otSparql(`SELECT ?film ?y WHERE { VALUES ?film { ${qids.map(x => 'wd:' + x).join(' ')} } VALUES ?cls { ${OT_CLS} } ?film wdt:P31 ?cls . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`) : [];
    part.forEach(it => {
      const ok = cand.get(it.key).find(qid => B.some(b => b.film.value.endsWith('/' + qid) && (!it.y || !b.y || Math.abs(+b.y.value - it.y) <= 1)));
      cache[it.key] = ok || '';
    });
    ls.set(QID_KEY, cache);
  }
  // 3) derniers essais : titre original / français dans toutes les langues, puis la recherche Wikipédia
  const tried = ls.get('ringcine-qid3', {}), left = items.filter(it => cache[it.key] === '' && !tried[it.key]), found = [];
  const okYear = (it, b) => !it.y || !b.y || Math.abs(+b.y.value - it.y) <= 2;
  for (let p = 0; p < left.length; p += 25) {
    const part = left.slice(p, p + 25), vals = new Set();
    part.forEach(it => [...new Set([it.t, it.en].filter(Boolean))].forEach(t => ['fr', 'en', 'es', 'it', 'de', 'pt', 'nl', 'sv', 'da', 'no', 'pl', 'tr'].forEach(l => vals.add(JSON.stringify(t) + '@' + l))));
    try {
      const B = await otSparql(`SELECT ?t ?y ?film WHERE { VALUES ?t { ${[...vals].join(' ')} } VALUES ?cls { ${OT_CLS} } ?film rdfs:label ?t ; wdt:P31 ?cls . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`);
      part.forEach(it => { const b = B.find(b => (b.t.value === it.t || b.t.value === it.en) && okYear(it, b)); if (b) { cache[it.key] = b.film.value.split('/').pop(); found.push(it.key); } });
    } catch(e){}
  }
  for (const it of left.filter(it => cache[it.key] === '')) {
    try {
      for (const lang of ['en', 'fr']) {
        const j = await (await fetch(`https://${lang}.wikipedia.org/w/api.php?format=json&origin=*&action=query&generator=search&gsrlimit=3&gsrsearch=${encodeURIComponent(`${lang === 'fr' ? it.t : (it.en || it.t)} ${it.y || ''} film`)}&prop=pageprops&ppprop=wikibase_item`)).json();
        const qs = Object.values((j.query && j.query.pages) || {}).sort((a, b) => a.index - b.index).map(pg => pg.pageprops && pg.pageprops.wikibase_item).filter(Boolean);
        if (!qs.length) continue;
        const B = await otSparql(`SELECT ?film ?y WHERE { VALUES ?film { ${qs.map(x => 'wd:' + x).join(' ')} } VALUES ?cls { ${OT_CLS} } ?film wdt:P31 ?cls . OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`);
        const q = qs.find(q => B.some(b => b.film.value.endsWith('/' + q) && okYear(it, b)));
        if (q) { cache[it.key] = q; found.push(it.key); break; }
      }
    } catch(e){}
  }
  left.forEach(it => { tried[it.key] = 1; });
  if (left.length) { ls.set('ringcine-qid3', tried); ls.set(QID_KEY, cache); }
  if (found.length) { const cast = ls.get(CAST_KEY, {}), ct = ls.get(CTRY_KEY, {}); found.forEach(k => { delete cast[k]; delete ct[k]; }); ls.set(CAST_KEY, cast); ls.set(CTRY_KEY, ct); }
  return cache;
}

/* ---------- Castings de tous les films du ring (Wikidata P161 + photos P18) ---------- */
const CAST_KEY = 'ringcine-castg', ACT_KEY = 'ringcine-actors';
const actImg = f => f ? 'https://commons.wikimedia.org/wiki/Special:FilePath/' + encodeURIComponent(f) + '?width=240' : '';
let castBusy = null;
function fetchCastGraph(onProg){
  if (castBusy) return castBusy;
  castBusy = (async () => {
    const items = F.filter(it => it.t);
    if (onProg) onProg('Recherche des films sur Wikidata…');
    const qid = await wdResolve(items);
    const cast = ls.get(CAST_KEY, {}), act = ls.get(ACT_KEY, {});
    const todo = items.filter(it => qid[it.key] && cast[it.key] === undefined);
    items.forEach(it => { if (!qid[it.key] && cast[it.key] === undefined) cast[it.key] = 0; });
    for (let p = 0; p < todo.length; p += 40) {
      const part = todo.slice(p, p + 40), byQ = new Map(part.map(it => [qid[it.key], it]));
      const B = await otSparql(`SELECT ?film ?a ?an ?af ?img WHERE { VALUES ?film { ${[...byQ.keys()].map(x => 'wd:' + x).join(' ')} } ?film wdt:P161 ?a . OPTIONAL { ?a rdfs:label ?an FILTER(LANG(?an) = "en") } OPTIONAL { ?a rdfs:label ?af FILTER(LANG(?af) = "fr") } OPTIONAL { ?a wdt:P18 ?img } }`);
      const got = new Map();
      B.forEach(b => {
        const f = b.film.value.split('/').pop(), a = b.a.value.split('/').pop(), name = (b.an || b.af || {}).value; if (!name || /^Q\d+$/.test(name)) return;
        const it = byQ.get(f); if (!it) return;
        const L = got.get(it.key) || []; if (!L.includes(a) && L.length < 45) L.push(a); got.set(it.key, L);
        if (!act[a]) act[a] = [name, b.img ? decodeURIComponent(b.img.value.split('/').pop()) : ''];
        else if (!act[a][1] && b.img) act[a][1] = decodeURIComponent(b.img.value.split('/').pop());
      });
      part.forEach(it => { cast[it.key] = got.get(it.key) || 0; });
      ls.set(CAST_KEY, cast); ls.set(ACT_KEY, act);
      if (onProg) onProg(`Récupération des castings… ${Math.min(todo.length, p + 40)}/${todo.length}`);
    }
    return true;
  })().catch(() => false).finally(() => { castBusy = null; });
  return castBusy;
}

/* ---------- Graphe films ↔ acteurs (films de ta liste uniquement) ---------- */
function ptGraph(){
  const cast = ls.get(CAST_KEY, {}), act = ls.get(ACT_KEY, {});
  const fa = new Map(), af = new Map();
  F.forEach((it, i) => { const L = cast[it.key]; if (!L || !L.length) return; fa.set(i, L); L.forEach(a => { if (!af.has(a)) af.set(a, []); af.get(a).push(i); }); });
  return {fa, af, act};
}
const ptId = n => n.f != null ? 'f' + n.f : 'a' + n.a;
function ptNeighbors(G2, n){ return n.f != null ? (G2.fa.get(n.f) || []).map(a => ({a})) : (G2.af.get(n.a) || []).map(f => ({f})); }
function ptBFS(G2, s){
  const dist = new Map([[ptId(s), 0]]), par = new Map(), Q = [s];
  for (let k = 0; k < Q.length; k++) { const n = Q[k], d = dist.get(ptId(n)); if (d >= 6) continue;
    for (const m of ptNeighbors(G2, n)) { const id = ptId(m); if (dist.has(id)) continue; dist.set(id, d + 1); par.set(id, n); Q.push(m); } }
  return {dist, par};
}
function ptPath(bfs, t){ const out = [t]; let id = ptId(t); while (bfs.par.has(id)) { const p = bfs.par.get(id); out.unshift(p); id = ptId(p); } return out; }

const PT = {g:null, start:null, target:null, chain:[], best:[], over:false, won:false, err:0, hints:0, loading:false, msg:'', q:'', showFilms:false};
function ptNew(){
  const G2 = PT.g = ptGraph();
  const films = [...G2.fa.keys()].filter(i => G2.fa.get(i).some(a => G2.af.get(a).length >= 2));
  const actors = [...G2.af.keys()].filter(a => G2.af.get(a).length >= 3 && G2.act[a]);
  if (films.length < 10) return false;
  for (let tries = 0; tries < 60; tries++) {
    const s = Math.random() < .3 && actors.length ? {a: pick1(actors)} : {f: pick1(films)};
    const bfs = ptBFS(G2, s), want = Math.random() < .5 ? 'f' : 'a';
    const cands = [];
    bfs.dist.forEach((d, id) => { if (id[0] !== want) return; const dd = s.f != null ? (want === 'f' ? 4 : 3) : (want === 'f' ? 3 : 4); if (d === dd) cands.push(id); });
    if (!cands.length) continue;
    const id = pick1(cands), t = id[0] === 'f' ? {f: +id.slice(1)} : {a: id.slice(1)};
    if (t.a && !G2.act[t.a]) continue;
    Object.assign(PT, {start: s, target: t, chain: [s], best: ptPath(bfs, t), over: false, won: false, err: 0, hints: 0, msg: '', q: '', showFilms: false});
    return true;
  }
  return false;
}
const ptName = n => n.f != null ? F[n.f].t : (PT.g.act[n.a] || ['?'])[0];
function ptFace(a, cls = ''){
  const A = PT.g.act[a] || ['?', ''], ini = A[0].split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase();
  return A[1] ? `<img class="pt-face ${cls}" src="${esc(actImg(A[1]))}" alt="" referrerpolicy="no-referrer" loading="lazy" onerror="this.replaceWith(Object.assign(document.createElement('i'),{className:'pt-face noface ${cls}',textContent:'${esc(ini)}'}))">` : `<i class="pt-face noface ${cls}">${esc(ini)}</i>`;
}
function ptNode(n, cls = ''){ return n.f != null ? `<div class="pt-node film ${cls}">${img(n.f, 'th')}<span>${T(n.f)}</span></div>` : `<div class="pt-node actor ${cls}">${ptFace(n.a)}<span>${esc(ptName(n))}</span></div>`; }
function ptSame(a, b){ return a && b && ptId(a) === ptId(b); }
function ptAdd(n){
  if (PT.over) return;
  PT.chain.push(n); PT.showFilms = false; PT.q = ''; PT.msg = ''; sfx('tick');
  if (ptSame(n, PT.target)) ptFinish(true); else if (PT.chain.length > 13) ptFinish(false); else renderGame();
}
function ptFinish(won){
  PT.over = true; PT.won = won; sfx(won ? 'win' : 'lose'); if (won) confetti(PT.chain.length <= PT.best.length ? 110 : 60);
  const k = 'ringcine-path-' + C.id, st = ls.get(k, {solved:0, perfect:0, played:0});
  st.played++; if (won) { st.solved++; if (PT.chain.length <= PT.best.length && !PT.hints && !PT.err) st.perfect++; }
  ls.set(k, st); trophyTick(); renderGame();
}
function renderPath(){
  const g = GAMES.path, st = ls.get('ringcine-path-' + C.id, {solved:0, perfect:0, played:0});
  if (PT.loading) { view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g)}<div class="gload"><span class="spin"></span>${esc(PT.msg || 'Chargement…')}</div><p class="note" style="text-align:center">La première fois, Ring récupère le casting de tous tes films (une minute environ). Ensuite c’est instantané.</p></section>`; bindQuit(); return; }
  if (!PT.start || PT.g == null) {
    const cast = ls.get(CAST_KEY, {});
    if (F.some(it => cast[it.key] === undefined)) {
      PT.loading = true; PT.msg = 'Récupération des castings…'; renderPath();
      fetchCastGraph(m => { PT.msg = m; const el = view.querySelector('.gload'); if (el && G.id === 'path') el.innerHTML = `<span class="spin"></span>${esc(m)}`; }).then(() => { PT.loading = false; if (G.id !== 'path' || curView !== 'game') return; if (!ptNew()) { view.innerHTML = `<section class="stage game full">${customHead(g)}<div class="empty">Pas assez de castings trouvés pour ce ring (connexion ?).</div></section>`; bindQuit(); return; } renderGame(); });
      return;
    }
    if (!ptNew()) { view.innerHTML = `<section class="stage game full">${customHead(g)}<div class="empty">Pas assez de castings trouvés pour ce ring.</div></section>`; bindQuit(); return; }
  }
  const cur = PT.chain[PT.chain.length - 1], G2 = PT.g, tgtIsFilm = PT.target.f != null;
  const chainHtml = PT.chain.map((n, k) => ptNode(n, k === PT.chain.length - 1 ? 'cur' : '')).join('<i class="pt-link">→</i>');
  let panel = '';
  if (PT.over) {
    panel = `<div class="pt-over ${PT.won ? 'ok' : 'ko'}"><h2>${PT.won ? (PT.chain.length <= PT.best.length ? '🏆 Chemin parfait !' : '✅ Trouvé !') : 'Raté…'}</h2>
      <p class="note">${PT.won ? `Ton chemin : ${PT.chain.length - 1} étapes · le plus court : ${PT.best.length - 1}` : 'Le chemin le plus court était :'}</p>
      <div class="pt-chain best">${PT.best.map(n => ptNode(n)).join('<i class="pt-link">→</i>')}</div>
      <div class="fx" style="gap:8px;justify-content:center;margin-top:14px"><button class="btn primary" id="ptnext">Nouveau chemin <kbd>Entrée</kbd></button></div></div>`;
  } else if (cur.f != null) {
    const L = (G2.fa.get(cur.f) || []).filter(a => G2.act[a]).sort((a, b) => (G2.af.get(b).length > 1) - (G2.af.get(a).length > 1) || (!!G2.act[b][1]) - (!!G2.act[a][1]));
    panel = `<div class="pt-ask">Choisis un <b>acteur</b> de <b>${T(cur.f)}</b></div><div class="pt-cast">${L.slice(0, 30).map(a => `<button class="pt-act" data-a="${esc(a)}">${ptFace(a)}<span>${esc(G2.act[a][0])}</span></button>`).join('') || '<p class="note">Aucun acteur connu pour ce film.</p>'}</div>`;
  } else {
    const mine = G2.af.get(cur.a) || [];
    panel = `<div class="pt-ask">Donne un <b>film de ta liste</b> avec <b>${esc(ptName(cur))}</b></div>
      <div class="gguess"><input class="input" id="ptin" autocomplete="off" placeholder="Nom du film…" value="${esc(PT.q)}"><div class="gsug" id="ptsug"></div></div>
      ${PT.msg ? `<div class="pt-msg">${esc(PT.msg)}</div>` : ''}
      ${PT.showFilms ? `<div class="pt-films">${mine.map(i => `<button class="pt-f" data-f="${i}">${img(i, 'th')}<span>${T(i)}</span></button>`).join('')}</div>` : `<button class="btn sm ghost" id="pthint">💡 Voir ses films dans ta liste (${mine.length})</button>`}`;
  }
  view.innerHTML = `<section class="stage game full" id="gstage">${customHead(g, `${st.solved} chemin${st.solved > 1 ? 's' : ''} trouvé${st.solved > 1 ? 's' : ''} · ${st.perfect} parfait${st.perfect > 1 ? 's' : ''}`)}
    <div class="pt-goal">${ptNode(PT.start)}<div class="pt-goalmid"><span class="kicker">Relie</span><b>${PT.best.length - 1} étapes suffisent</b><span class="note">en passant par tes films et leurs acteurs</span></div>${ptNode(PT.target, 'target')}</div>
    <div class="pt-chain">${chainHtml}</div>
    ${panel}
    ${PT.over ? '' : `<div class="gctl"><button class="btn ghost" id="ptundo" ${PT.chain.length < 2 ? 'disabled' : ''}>↩ Annuler</button><button class="btn ghost" id="ptnew">↻ Autre chemin</button><button class="btn ghost" id="ptgive">Voir la solution</button></div><p class="note" style="text-align:center">${PT.err ? `${PT.err} erreur${PT.err > 1 ? 's' : ''} · ` : ''}Objectif : ${tgtIsFilm ? 'arriver au film' : 'arriver à l’acteur'} « ${esc(ptName(PT.target))} »</p>`}
  </section>`;
  bindQuit();
  if ($('ptnext')) { $('ptnext').onclick = () => { PT.start = null; renderGame(); }; $('ptnext').focus(); }
  if ($('ptundo')) $('ptundo').onclick = () => { if (PT.chain.length > 1) { PT.chain.pop(); PT.msg = ''; PT.showFilms = false; renderGame(); } };
  if ($('ptnew')) $('ptnew').onclick = () => { PT.start = null; renderGame(); };
  if ($('ptgive')) $('ptgive').onclick = () => ptFinish(false);
  if ($('pthint')) $('pthint').onclick = () => { PT.showFilms = true; PT.hints++; renderGame(); };
  view.querySelectorAll('.pt-act').forEach(b => b.onclick = () => ptAdd({a: b.dataset.a}));
  view.querySelectorAll('.pt-f').forEach(b => b.onclick = () => ptAdd({f: +b.dataset.f}));
  const inp = $('ptin');
  if (inp) {
    const titles = F.flatMap((it, j) => { const a = [[j, norm(it.t + ' ' + (it.en || '') + ' ' + (it.fr || '') + ' ' + (it.sub || '')), norm(it.t)]]; if (it.en && it.en !== it.t) a.push([j, a[0][1], norm(it.en)]); if (it.fr) a.push([j, a[0][1], norm(it.fr)]); return a; });
    let sel = 0, hits = [];
    const choose = j => { const actorFilms = G2.af.get(cur.a) || []; if (actorFilms.includes(j)) ptAdd({f: j}); else { PT.err++; PT.q = ''; PT.msg = `✗ ${ptName(cur)} ne joue pas dans ${F[j].t} (d’après Wikidata).`; sfx('lose'); renderGame(); } };
    const draw = () => { const q = norm(inp.value); PT.q = inp.value; hits = q.length < 1 ? [] : gSuggest(q, titles).slice(0, 8); sel = Math.min(sel, Math.max(0, hits.length - 1));
      $('ptsug').innerHTML = hits.map((j, k) => `<button class="${k === sel ? 'on' : ''}" data-j="${j}">${img(j, 'th')}<span>${esc(F[j].t)}<small>${F[j].y || ''}</small></span></button>`).join('');
      $('ptsug').querySelectorAll('button').forEach(b => b.onmousedown = e => { e.preventDefault(); choose(+b.dataset.j); }); };
    inp.oninput = draw;
    inp.onkeydown = e => { if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(sel + 1, hits.length - 1); draw(); } else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); draw(); } else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (hits[sel] != null) choose(hits[sel]); } else if (e.key === 'Escape') { inp.blur(); } };
    if (PT.q) draw();
    setTimeout(() => { inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length); }, 30);
  }
}

/* ---------- Scène culte en vidéo : un extrait de la scène (pas la bande-annonce) ---------- */
async function sceneClipFind(it){
  const rel = relTitle(it);
  const bad = /trailer|teaser|bande[- ]annonce|\bvf\b|reaction|réaction|review|critique|explained|expliqu|recap|résumé|making of|behind the scenes|interview|ending explained|fan[- ]?made|parody|parodie|edit\b|tiktok|shorts|compilation/i;
  const good = /scene|scène|clip|movieclips|extrait|moment/i;
  for (const q of [`${it.en || it.t} ${it.y || ''} scene`, `${it.t} ${it.y || ''} scène culte`, `${it.en || it.t} movie clip`]) {
    const L = (await ytList(q)).filter(x => !bad.test(x.t) && rel(x));
    const v = L.find(x => good.test(x.t)) || null;
    if (v) return v.id;
  }
  return '';
}
/* ---------- Musique composée (B.O.) pour les films sans chanson connue ---------- */
async function ostFind(it){
  const rel = relTitle(it);
  const bad = /trailer|teaser|bande[- ]annonce|reaction|review|piano (cover|tutorial)|tutorial|cover|remix|slowed|reverb|1 hour|10 hours|extended|full album|mix\b/i;
  const good = /soundtrack|\bost\b|theme|score|main title|b\.o|musique|suite|end credits|opening/i;
  for (const q of [`${it.en || it.t} ${it.y || ''} soundtrack main theme`, `${it.t} ${it.y || ''} OST`]) {
    const L = (await ytList(q)).filter(x => !bad.test(x.t) && good.test(x.t) && rel(x));
    if (L[0]) return L[0];
  }
  return null;
}

Object.assign(GAMES, {
  path: {name:'Le Chemin', icon:'🧭', types:['films'], custom:true, render: renderPath, desc:'Un film ou un acteur de départ, un film ou un acteur à trouver : relie-les en passant d’acteur en film, uniquement avec les films que tu as vus.'},
  sceneclip: {name:'Scène culte', icon:'🎬', types:['films'], kind:'clip', visible:true, steps:[3,6,12,25], unit:'s', server:true, desc:'Un extrait vidéo d’une scène du film trouvée sur internet (pas la bande-annonce) : 3 s, 6 s, 12 s puis 25 s.'},
});
delete GAMES.chrono;
delete GAMES.iconic;
GAMES.fsong.desc = 'Un son qu’on entend dans le film : une chanson culte quand Ring en connaît une, sinon la musique composée pour le film (la B.O.). 2 s, 5 s, 10 s puis 20 s.';
GAMES.fsong.avail = () => { const n = F.filter(it => FILM_SONGS.has(it.key)).length; return `Tous tes films · ${n} avec une chanson culte, les autres avec leur B.O.`; };

const WORLD_MAP = {"100":["BG","M535.3,132.5L536.1,133.8L537,133.6L539,134L542.6,134.2L543.7,133.4L546.5,132.7L548.4,133.8L549.9,134.2L548.8,135.4L548.1,137.7L549.1,139.4L546.9,139L544.5,140L544.6,141.5L542.4,141.8L540.5,140.7L538.6,141.6L536.8,141.5L536.5,139.4L535.1,138.5L535.5,138L535.2,137.6L535.5,136.7L536.4,135.7L535.1,134.4L534.8,133.2Z","Bulgaria"],"104":["MM","M745,207.2L743.6,207.9L742.2,209.2L740.4,209.4L739.7,212.8L738.7,213.3L740.3,216.1L742.3,218.4L743.7,220.4L743.1,223.2L742.2,223.8L743,225.3L745.1,227.8L745.6,229.6L745.7,231L747,233.9L745.8,236.8L744.8,240L744.3,237.7L745,235.3L743.9,233.4L743.8,230L742.5,228.4L741.2,224.6L740.3,220.7L738.8,218.1L737.2,219.7L734.5,221.9L732.9,221.6L731.2,220.9L731.6,217L730.7,214.1L728.1,210.5L728.2,209.3L726.6,208.9L724.3,206.4L723.8,203.8L724.8,204.3L724.4,202.1L725.6,201.3L725.1,200L725.5,198.9L725,195.7L727.2,196.4L727.9,193.8L727.7,192.3L728.6,189.6L728.2,187.8L731.1,185.6L733.1,186.2L732.4,184.3L733.2,183.7L732.8,182.5L734.2,182.3L735.5,184.1L736.8,184.9L737.4,187.3L737.9,189.9L736,192.5L736.4,196.2L739,195.7L740.2,198.6L742,199.2L741.7,201.8L743.9,203L745.1,203.6L746.9,202.7L747.2,204L745.3,206Z","Myanmar"],"108":["BI","M562.2,278.6L562.4,279.8L562.9,280.5L563,281.5L562.3,282.2L561.2,283.8L560.2,284.9L559.1,285.1L559,281.3L558.3,279.9L560,280.1L560.8,278.4Z","Burundi"],"112":["BY","M544,96.5L546.6,97.3L547,98L548.1,97.7L550.5,98.4L550.9,99.7L550.6,100.5L552.3,102.5L553.3,103L553.3,103.5L554.9,104.1L555.7,104.9L554.9,105.5L553,105.4L552.6,105.7L553.3,106.7L554.2,108.6L552.2,108.8L551.6,109.4L551.7,110.9L550.7,110.6L548.6,110.8L547.9,110.1L547.1,110.6L546.2,110.2L544.3,110.1L541.6,109.4L539.2,109.1L537.4,109.2L536.2,110L535.1,110.1L534.9,108.8L534,107.4L535.4,106.8L535.2,105.6L534.5,104.5L534.2,103.2L536.4,103.2L538.8,102.1L539.1,100.4L540.8,99.5L540.4,98.2L541.8,97.7Z","Belarus"],"116":["KH","M755,232.9L753.9,229.2L755.4,226.6L758.7,226L761.3,226.4L763.7,227.6L764.6,225.5L767.1,226.6L768,228.7L768.1,232.5L763.8,234.9L765.2,236.8L762.4,237L760.2,238.3L757.9,237.8L756.7,236.2Z","Cambodia"],"120":["CM","M518.8,230.8L519.9,232.8L520.1,234.9L520.1,237L521.6,239.8L520.1,239.8L519.3,240L518.1,239.7L517.5,241.2L519.1,243L520.3,243.5L520.7,244.8L521.5,247L521.1,247.8L519.8,251L519.2,251.6L519,254L519.3,255.3L519,256.2L520.3,257.9L520.6,259L521.6,260.6L522.8,261.6L522.9,263L523.2,263.9L523,265.6L520.9,264.9L518.7,264.1L515.3,263.9L514.9,263.8L513.4,264.2L511.7,263.8L510.4,264L506,263.9L506.4,261.4L505.4,259.4L504.1,258.8L503.6,257.4L502.9,257L502.9,256.1L503.6,253.9L504.9,250.9L505.7,250.9L507.2,249L508.3,249L509.8,250.3L511.6,249.2L511.9,247.9L512.5,246.7L512.9,245.1L514.3,243.8L514.8,241.6L515.4,240.9L515.7,239.3L516.4,237.3L518.7,234.9L518.8,233.8L519.1,233.3L518,232L518.1,231Z","Cameroon"],"124":["CA","M187.8,117.9L187.5,117.9L184.6,114.9L183.6,113.6L180.1,112.4L180.4,109.7L181.9,107.9L179.8,106.6L180.9,104.2L179.6,102.1L180.5,100.6L182.8,99.1L184,97.3L181.5,95.4L181.6,92.1L181.7,90L180.7,88.7L180.1,87.6L180.1,86.1L177.1,87L173.7,88.6L173.2,86.7L172.7,85.5L171.2,84.7L169.1,84.6L183.1,68.8L192.8,58.8L195.9,59.5L197.9,60.7L199.8,61L202.7,59.9L205.9,59.1L208.7,59.4L212.8,58.2L216.7,57.6L217.1,58.7L219.2,58L220.8,56.8L221.9,57.1L223.2,59.4L227.5,57.7L226,59.7L228.9,59.2L230.4,58.5L232.7,58.6L234.9,59.7L238.9,60.7L241.3,61.1L243.5,61L245.2,62.3L241.2,63.6L244.5,64.2L250.3,63.9L252.5,63.4L253.5,65L256.7,63.7L255.5,62.5L257.5,61.6L260.1,61.5L261.9,61.2L263.1,61.9L264.1,63.3L266.6,63.1L269.4,64.3L272.9,63.9L275.9,64L276.8,62.3L278.9,61.8L281.5,62.7L279.8,65.3L282.6,63.1L284.2,63.2L286.9,60.5L285.8,58.9L284.1,57.8L286.3,55L290,53.1L292.4,53.5L293.6,54.6L294.4,57.6L291.7,58.9L295.2,59.4L293.4,62.1L297.5,60L298.9,61.7L297,63.7L298,65.5L301.3,63.6L304.2,61.3L306,58.4L308.8,58.6L311.6,59L313.6,60.3L312.9,61.6L310.6,63L311.3,64.5L310.3,65.8L305.1,67.7L302,68.1L300.3,67.3L298.9,68.6L295.5,70.9L294.2,72.1L290.7,74L287.5,74.2L285.1,75.3L284,77.1L281.3,77.5L277.3,79.8L273.1,82.9L271,85.2L269.1,88.5L272.1,89L271.7,91.7L271.6,93.9L275,93.3L278.6,94.6L280.3,95.7L281.3,97L283.8,97.9L285.6,99.1L289.3,99.3L291.7,99.5L290.2,102.1L289.7,105.1L290,108.4L292.4,111.3L294.6,110.3L297,107.2L297.7,102.5L296.7,101L300.9,99.6L304.4,97.5L306.5,95.5L307.1,93.5L306.6,91.1L304.9,88.9L308.9,85.9L309.1,83.3L310.4,78.9L312.3,78.3L315.6,79.1L317.7,79.3L319.9,78.6L321.5,79.5L323.4,81.2L323.6,82.3L327.4,82.5L326.4,84.9L325.6,88.5L327.5,88.9L328.5,90.6L332.3,89L335.6,85.9L337.6,84.5L338.4,87.1L340,90.7L341.2,94.2L339.7,96.1L342.2,97.7L343.7,99.4L347.1,100.1L348.3,101.1L348.5,103.6L350.2,104L350.8,105.1L350,108.4L348,109.6L346.1,110.6L341.9,111.7L338.2,114.2L334.1,114.7L329.2,114L325.7,114L323.2,114.2L320.5,116.4L317.1,117.7L312.4,121.7L308.8,124.6L311,124.1L316,120.1L321.8,117.5L325.4,117.2L327.1,118.7L324.3,120.8L324.1,124L324.3,126.4L327,127.9L331.1,127.4L334.4,124L334,126.2L335.3,127.3L331.8,129.3L325.9,131.2L323.2,132.4L319.9,134.7L318.1,134.4L318.7,131.8L323.6,129.3L319.7,129.4L316.9,129.7L315.8,128L317,123.8L316.2,122.9L314.4,123.5L313.8,122.7L311.3,125L309.9,127.3L308.6,128.8L307.4,129.2L306.6,129.4L306.2,130.1L301.7,130.1L298,130.2L296.7,130.7L293.5,133L293.1,133.2L291.9,134.4L289.7,134.4L287.3,134.4L286,134.9L286.2,135.5L286.2,136.5L286,136.8L282.3,138.3L279.7,138.8L276.3,140.5L275.7,140.5L275,140L274.8,139.5L275,139.2L275.9,138.1L277.6,136.4L278.9,134.6L279.2,131.9L279.7,129.1L277.6,127.7L278.1,127.1L277.9,126.7L277.2,126.7L276.9,126.2L277,125.5L276.5,125.8L275.8,125.7L276.1,125.4L275.6,125.1L275.7,124.3L274.2,123.4L272.6,122.3L270.7,121.1L268.9,120L266.4,120.9L265.7,120.9L263,120.1L260.9,120.5L259,119.6L256.8,119.1L255.2,118.9L254.7,118.4L255,116.7L254.1,116.8L253.6,117.9L248.7,117.9L240.6,117.9L232.5,117.9L225.3,117.9L218.2,117.9L211.2,117.9L203.9,117.9L201.6,117.9L194.5,117.9ZM297.9,78.6L300.1,77.3L303.1,77.3L302.8,77.8L299.4,79.4L297.9,79.3ZM322.2,50.8L320.9,49.5L321.5,48.6L322.6,48.4L326.9,48.7L329.4,50.1L329.2,50.8L327.1,50.7L325,50.6L322.7,51ZM305.3,79.6L306.6,78.8L307.4,78.8L307.7,79.4L306.1,80.9L305.3,80.6L305.1,79.8ZM298.9,45.4L297.1,46.3L294.4,46.1L292.6,45.5L294.5,44.4L297.8,43.7L298.8,44.6ZM303.4,39.2L302.5,39.3L299.1,39.1L299.2,38.5L302.9,38.5L303.9,38.9ZM300.6,36.3L302.1,37.1L300.8,38L297.6,38.4L296.6,37.9L296.6,37L297.4,36.1L299.7,36.2ZM308.4,46.8L305.5,46.5L300.9,45.7L301.3,44.4L302,43.1L300.9,42.1L297.2,41.8L295.7,41L297.2,40.1L301,40.2L302.4,41L306.2,41L307.2,41.8L306,42.7L307.8,43.2L308.6,43.8L311.1,43.9L313.8,44.1L317.2,43.6L321.3,43.4L324.3,43.5L325.7,44.5L325.4,45.5L323.8,46.2L320.6,46.7L318.3,46.4L312.4,46.8ZM272.2,37.7L274.4,38.1L273.1,38.8L268.9,39.5L266.9,38.7L269.2,38ZM274.4,36.2L276.3,36.7L273.5,37.1L270.4,37.1L270.8,36.8L273.5,36.1ZM349.5,110.9L347.8,112.8L345.5,115.5L347.3,114.4L348.8,115.1L347.7,116.1L349.6,117L350.8,116.2L353,117.2L351.7,119.4L353.5,118.9L353.4,120.5L353.7,122.4L352.1,125.1L351,125.2L349.5,124.6L350.6,122.1L350.1,121.7L346.6,124.4L345.2,124.3L347.3,122.8L345.1,122.1L342.5,122.3L337.9,122.2L337.8,121.3L339.5,120.2L338.7,119.4L341.2,117.5L344.9,112.7L346.9,111L349.2,110L350.2,110.1ZM302,71.2L303.8,72.1L305.8,73L305.3,74.3L307,74.1L308.1,75L305.7,75.9L302.7,75.2L302.2,74L299.3,75.5L295.4,76.9L295.6,75.3L292.5,75.5L295.1,74.2L296.6,72L298.7,69.5L300.1,69.7L299.9,70.9L301.2,70.5ZM323.5,52L326,51L329.6,52.3L331.7,53.5L331.3,54.6L335.3,54L336.6,55.7L340.9,56.7L342.2,57.8L342.9,60.2L338.5,61.5L342.6,63.2L345.6,63.8L347.5,66.3L350.7,66.4L349.3,68.3L344.3,71.5L342.1,70.3L340,67.7L337.1,68.1L336.1,69.6L337.7,71.2L340,72.5L340.6,73.2L340.8,75.9L339.3,77.9L336.9,77.2L332.4,75L334.4,77.4L336,79L335.9,80L330.5,78.9L326.6,77.3L324.5,75.9L325.7,75.1L323.1,73.7L320.6,72.4L320.3,73.2L313.9,73.6L312.6,72.7L315,70.7L319,70.6L323.5,70.3L323.3,69.3L324.7,67.9L328.7,65.3L328.7,64.1L328.4,63.2L325.9,61.9L322.2,61L323.9,60.3L322.6,58.7L320.9,58.5L319.8,57.6L318.3,58.4L314.4,58.8L307.3,58.2L303.5,57.4L300.5,57L299.4,56.1L302.3,54.9L299.4,54.9L300.6,52.3L303.6,50L306.4,49L311.9,48.3L309.4,49.9L309.9,51.5L313,49.5L318.7,48.4L320.4,51L319.1,52.7ZM295.5,47.5L299.5,47.5L302.8,48.2L298.3,50.4L295.6,50.9L292.1,52.8L289.9,52.7L290.3,50.5L291.3,49.2L293.1,48.1ZM245.2,42.6L250.3,40.8L255.9,39.2L258.7,39.3L261.7,38.9L259.5,40.7L257.2,41.6L255.3,41.7L250.7,42.7L247.2,43.1ZM174,102.8L176.4,102.6L173.4,105.9L173.9,108.3L172.9,108.3L172.4,107L172.5,105.6L171.9,104.7L172.4,103.4L173.2,102.4ZM285.7,35.1L289,35.4L293.1,36.2L293.5,37.3L293.3,38.3L290.5,38L288.2,37.3L284.1,37.2L286.6,36.5L284.9,36ZM185.4,119.4L183.9,119.8L180.8,118.5L180.7,117.4L179.2,116.3L179.2,115.5L177.1,114.9L177.2,113.3L177.8,112.6L179.9,113.2L181.1,113.7L183.1,114L183.3,115L183.7,116.5L185.3,117.7ZM243.5,46.7L245.8,47.2L250.7,47.3L251.9,48.1L253,49.1L250,49.8L243.5,51.5L239.4,53.3L238.4,54.5L232,55.7L232,54.6L228.6,53.2L230.5,52.1L233.6,50.3L237,48.6L236.6,47.1ZM273.3,43.2L275.4,42.8L277.3,42.9L276.6,44.1L274.4,45.3L267.5,45.7L261.6,46.8L258.6,46.8L259.1,46L264.1,44.9L255.1,45.2L252.8,44.8L257.8,42.4L260.3,41.7L264.9,42.5L266.9,44L270.1,44.1L269.5,41.8L272.1,40.9L273.8,41.2L273.4,42.4ZM269.8,50.1L271.2,51.2L270.5,53.7L269.7,55.5L272.1,56.8L274.9,58L273.8,59.2L270.3,59.4L270.9,60.4L269.5,61.4L266.1,61L263.1,60.2L260.6,60.4L256,61.3L250.5,61.7L246.7,61.9L246.5,60.7L244.3,60L242.3,60.3L241.5,58.2L243.1,57.9L246.6,57.5L249.3,57.6L252.4,57.1L248.9,56.5L244.4,56.7L241.6,56.7L241.4,55.7L246.9,54.7L243.8,54.7L240.9,54L244.3,52.1L246.6,51.1L253.3,49.5L254.9,50L252.8,51.2L257.9,50.4L259.6,51.7L262.9,50.4L264,51.3L263.6,53.8L265.4,52.7L266.2,50.1L268.2,49.7ZM281.1,51.1L280.2,49.4L283.5,48.2L285.5,48.7L289.2,48.4L289.1,49.1L286.4,50.3L288.6,51.4L286.5,53.8L282.5,54.8L280.7,54.5L280.1,53.6L276.7,51.6L277.3,50.8ZM270.8,48.8L273.5,48.7L274.5,49.3L271.5,50.9L269.8,49.2ZM293,41.1L293.5,42.2L292.5,43.5L290.1,45.3L286.7,45.6L285,45.2L286.2,43.7L282.9,43.9L284.4,42L286.4,42.1L290,41.3L292.6,41.4ZM306.1,32.2L308.1,31.6L310.1,31.4L309.9,30.9L314.2,30.8L315.2,32L317.8,32.4L320.4,32.8L320.5,34.3L322,35L318.9,35.7L314,37.4L310.5,37.6L306.9,37.3L305.8,36.4L306.6,35.5L308.6,34.9L305.2,34.9L303.9,34.2L303.8,33.2ZM317.1,29.5L320.2,29.1L322.4,29.1L326.2,28.8L329.7,28L331.7,28.1L333,28.7L335.6,27.6L338.2,27.3L341.6,27.1L347,27L347.7,27.2L353.1,26.9L356.8,27L360.4,27.1L365,27.3L368.5,27.5L371.2,28.1L370.7,28.6L365.6,29.5L361,29.9L359,30.3L362.9,30.3L357.6,31.6L354.2,32.2L349.7,34L345.7,34.4L344.1,34.8L338.4,35.1L340.7,35.3L339.1,35.7L339.8,36.9L337.5,37.7L334.1,38.3L332.5,39.2L329.4,39.9L329.3,40.5L332.6,40.4L332.2,41L326.1,42.4L321.6,41.8L315.7,42.1L313.1,41.8L309.6,41.7L310.3,40.6L314.2,40L314.7,38.3L315.9,38.2L320.1,39.2L318.8,37.7L316.1,37.2L318.4,36.3L322.2,35.8L323.4,35L321.5,34.1L321.8,33L326.7,33.1L327.9,33.3L331.5,32.5L327.7,32.3L321.2,32.4L318.7,31.7L318.1,30.8L316.7,30.2ZM323.6,64.9L321.8,65.7L319.4,65.8L319.6,64.5L321.3,63L323.4,62.6L324.6,63.3L324,64.5ZM283.5,59.4L284,60.4L282.1,61.4L279.9,60.6L278.1,60.8L276.1,59.7L278.5,58.8L280.7,57.7L282.3,58.4L283.2,58.9ZM327.3,115.3L328.2,115L331.1,115.8L333.1,117.1L333.1,117.6L331.9,117.7L329.1,116.7ZM326,123.9L326.5,125.4L328.1,125.8L330.4,125.7L328.8,127L327.9,127.2L325.2,125.9L324.9,124.9Z","Canada"],"140":["CF","M553.8,254.7L552.9,255L551.2,254.9L549.1,254.6L548.1,254.9L547.8,255.6L546.9,255.7L545.8,255.1L542.8,256.6L541.6,256.3L541.2,256.6L540.4,258.4L538.4,257.8L536.4,257.5L534.7,256.4L532.5,255.3L531,256.3L530,257.9L529.8,260.1L528,259.9L526.2,259.4L524.6,261L523.2,263.9L522.9,263L522.8,261.6L521.6,260.6L520.6,259L520.3,257.9L519,256.2L519.3,255.3L519,254L519.2,251.6L519.8,251L521.1,247.8L523.4,247.6L523.9,246.8L524.3,246.9L525,247.6L528.4,246.4L529.5,245.2L530.9,244.1L530.6,243L531.3,242.7L533.9,242.9L536.4,241.4L538.3,238L539.7,236.7L541.4,236.2L541.7,237.5L543.3,239.5L543.3,240.8L542.9,242.1L543.1,243.1L544,244L546.1,245.3L547.6,246.6L547.6,247.6L549.5,249.2L550.6,250.6L551.3,252.4L553.4,253.7Z","Central African Rep."],"144":["LK","M700.2,247.5L699.9,250.8L698.8,251.7L696.5,252.4L695.1,249.9L694.4,245.4L695.4,240.3L697.3,242.1L698.7,244.3Z","Sri Lanka"],"148":["TD","M543.2,209.8L543.7,222.2L541.4,222L540.3,224.3L539.6,226.2L540.2,227L539.3,227.9L539.7,229.2L539,230.5L538.8,231.7L539.7,231.5L540.3,232.7L540.4,234.5L541.4,235.5L541.4,236.2L539.7,236.7L538.3,238L536.4,241.4L533.9,242.9L531.3,242.7L530.6,243L530.9,244.1L529.5,245.2L528.4,246.4L525,247.6L524.3,246.9L523.9,246.8L523.4,247.6L521.1,247.8L521.5,247L520.7,244.8L520.3,243.5L519.1,243L517.5,241.2L518.1,239.7L519.3,240L520.1,239.8L521.6,239.8L520.1,237L520.1,234.9L519.9,232.8L518.8,230.8L519.1,229.4L517.4,229.3L517.3,227.3L516.2,226.1L517.3,222L520.6,219L520.7,215L521.6,208.6L522.1,207.2L521,206.2L520.9,205.2L519.9,204.4L519.1,199.5L521.7,197.8L532.4,203.8Z","Chad"],"152":["CL","M320.3,435.1L322.6,441.7L325.1,441.7L326.5,441.8L326.1,443L324.5,443.9L323.4,443.8L321.9,443.5L319.9,442.6L317.4,442.2L313.9,440.6L310.9,439L306.5,435.7L308.6,436.3L312.6,438.3L316.1,439.3L316.8,438L316.8,435.9L318.5,434.7ZM294.9,326L296.4,328.1L297,330.4L298.5,331.7L298,334.7L299.9,338.3L301.4,342.6L303.3,342.2L303.7,343L303.2,346.2L300.6,347.8L301.4,353L301,354L302,355.3L300.4,357.2L299.2,360.2L298.8,363L299.5,366.1L298.5,369.3L300.8,374.7L301.5,375.3L302.1,378.2L301.3,381.2L301.9,383.9L300.5,385.9L301.1,388.8L302.6,391.8L301.4,393L301.4,395.8L301.6,399L303,402.8L302.2,403.4L303.7,407L305.2,408.1L304.7,409.4L306.1,410L306.6,411.2L305.7,411.8L306.5,413.6L306.9,417.7L306.4,420.3L307.2,421.8L307.1,423.7L305.7,425.1L307,428.3L308.2,429.4L309.7,429.2L310.4,431.4L312,433.2L317.8,433.6L320.1,434.1L318,434L317.1,434.8L315.4,435.8L316.1,438.6L315.1,438.7L312.1,437.7L308.7,435.6L305.2,433.9L303.8,432L303.8,430.3L301.9,428.3L299.8,423.1L299.8,420.2L301.6,417.8L297.7,416.9L299.1,414.2L298.4,409.1L301.4,410.2L300.9,403.8L299,403L299.3,406.8L297.7,406.4L297.2,402L296.5,396.2L297.1,394.1L295.6,391L294.6,387.5L295.6,387.4L296,382.3L296.7,377.3L296.9,372.6L295.4,367.9L295.7,365.3L294.7,361.4L295.5,357.6L295.1,351.5L295,345L294.9,337.9L294.1,332.8L293,328.4L294.3,327.6Z","Chile"],"156":["CN","M770.9,214.1L768.6,213.1L768.1,210.4L769.1,209L771.9,208.1L773.4,208.2L774.2,209.4L773.3,210.8L773,212.6ZM677.7,138.4L677,136.6L678.4,135.8L674.5,130.4L678.9,129.2L679.9,128.5L679.7,123L684.9,124L685.7,122.6L684.7,119.6L686.5,119.3L687.6,117.3L688.4,117L689.9,119.1L692.5,120.8L696.4,121.9L699,124.4L699.4,127.9L700.8,129.3L703.9,129.8L707.3,130.2L711,132.2L712.6,132.5L714.8,135.4L716.9,137.2L719.6,137.1L724.9,137.8L728,137.4L730.6,137.8L735,139.7L738,139.7L739.5,140.7L741.7,139L745.2,137.9L748.9,137.8L751.3,136.7L752.4,135.1L753.6,134L752.8,133L751.5,131.8L751.9,129.8L753.3,130.1L756.1,130.8L757.8,129.1L760.9,127.9L761.7,125.9L763,125L766.3,124.6L768.4,125L768.1,123.9L764.8,121.7L762.4,120.8L761.1,121.9L758.5,121.4L757.3,121.8L756.1,120.6L756.2,117.5L756.1,115.2L759.6,116.4L761.9,114.5L761.1,113.1L761.4,109.9L762.1,109L761.1,107.3L759.4,106.6L760.5,105.1L763,104.6L766,104.5L770,105.4L772.8,106.5L776.1,109.5L777.8,110.8L779.7,112.7L782.3,115.6L787,116.6L791.1,118.7L793.7,121.6L797.4,121.6L798.8,120.4L802.2,119.5L802.5,122.3L802.3,123.4L803.3,126.7L803.4,129.7L800.1,129.2L798.6,130.3L800.6,132.9L802.2,136.6L800.9,136.6L801.7,138.2L799.2,136.4L799.1,138.1L796,139.5L797.1,141.1L794.9,141L793.3,140L792.6,142.2L790.6,143.9L789.5,145.9L786.4,146.8L785.2,148.3L782.8,149.1L783.6,147.7L782.5,146.5L783.6,144.4L781.6,142.7L779.9,143.8L778,146L777.3,148L774.9,148.2L774.2,149.6L776.4,151.7L778.6,152.2L779.3,153.6L781.6,154.6L783.6,152.3L786.3,153.5L787.9,153.6L789,155.3L785.7,156.1L785.2,157.8L783.3,159.4L782.8,161.6L786.2,163.3L788.2,166.4L790.8,169.3L793.3,171.7L794,174.1L792.7,174.9L793.8,176.6L795.6,177.6L796,180.1L796,182.6L794.7,182.9L793.7,186.3L792.7,190.4L791.2,194.2L788.2,197.1L785.2,199.7L782.3,200.1L781,201.5L779.8,200.5L778.7,202L775.3,203.6L772.6,204.1L772.3,207.4L770.9,207.6L769.8,205.3L770.2,204.1L766.4,203.1L765.3,203.6L762.5,202.8L761,201.5L761,199.7L758.5,199.1L757,197.9L755.1,199.6L752.6,200L750.5,200L749.2,200.7L748,201.2L749,204.8L747.6,204.7L747.2,204L746.9,202.7L745.1,203.6L743.9,203L741.7,201.8L742,199.2L740.2,198.6L739,195.7L736.4,196.2L736,192.5L737.9,189.9L737.4,187.3L736.8,184.9L735.5,184.1L734.2,182.3L732.8,182.5L729.9,182L730.4,180.7L728.8,178.8L727.2,180.1L724.9,179.3L722.3,181.3L720.5,183.7L718.5,184L717.2,183.2L715.8,183.1L713.8,182.4L712.5,183.2L711.3,185.5L710.6,183.1L709.1,183.7L706,183.4L702.9,182.7L700.5,181.3L698.4,180.7L697.2,179.2L695.7,178.7L692.6,176.7L690.4,175.7L689.5,176.5L685.4,174.3L682.5,172.3L681,168.8L682.9,169.2L682.7,167.6L681.3,166L681,163.4L677.4,159.8L672.9,158.5L671.6,156.1L669.4,154.6L668.7,153.7L667.9,152L667.7,150.7L666,150L665.2,150.3L663.9,147.4L664.4,146.7L663.9,146L665.9,144.5L667.4,143.9L670.2,144.3L670.6,142.3L673.6,142L674.2,140.7L677.6,139.1Z","China"],"158":["TW","M799.5,194.7L799.1,199.7L798.5,202.3L796.6,199.6L795.7,197.3L796.5,194.2L798,191.8L799.5,192.8Z","Taiwan"],"170":["CO","M299.5,267.1L299,267.5L298.5,265.6L297.7,264.7L296.8,265.7L291.6,265.7L291.6,267.6L293.2,267.9L293.1,269.1L292.5,268.8L291,269.3L291,271.6L292.2,272.7L292.6,274.5L292.6,275.9L291.5,284.4L290.1,282.8L289.3,282.7L291,279.5L288.9,278.1L287.3,278.3L286.3,277.8L284.8,278.6L282.8,278.2L281.2,275L279.9,274.2L279.1,272.7L277.3,271.2L276.6,271.5L275.4,270.8L274.1,269.7L273.3,270.2L271,269.8L270.4,268.4L269.9,268.5L267.2,266.7L266.8,265.7L267.8,265.5L267.7,263.9L268.4,262.8L269.7,262.6L270.9,260.6L272,259L271,258.3L271.5,256.4L271,253.6L271.6,252.8L271.3,250.1L270.3,248.5L270.7,246.9L271.6,247.2L272.1,246.2L271.6,244.4L271.9,243.9L273.3,244L275.5,241.9L276.6,241.5L276.7,240.5L277.3,237.8L279,236.4L280.7,236.3L280.9,235.7L283,235.9L285.2,234.4L286.3,233.7L287.7,232.2L288.6,232.3L289.3,233.2L288.7,234.2L286.9,234.8L286.2,236.3L285.1,237.2L284.2,238.4L283.8,240.6L282.9,242.4L284.3,242.6L284.6,244.1L285.1,244.8L285.3,246L284.9,247.2L285,247.8L285.6,248.1L286.2,249.2L289.7,248.9L291.2,249.3L293,252L294.1,251.6L296.1,251.8L297.6,251.4L298.6,252L298,253.7L297.4,254.7L297.1,257L297.6,259L298.4,260L298.4,260.7L297,262.2L298,262.9L298.7,264Z","Colombia"],"178":["CG","M529.8,260.1L529.6,262L528.8,263.6L528.3,265.6L528,268.3L528.1,270.1L527.7,271.2L527.6,272.3L527.3,273.3L525.5,274.9L524.3,276.5L523.1,279.5L523.2,282.1L522.5,283.1L520.9,284.6L519.3,286.5L518.3,286L518.1,285.1L516.7,285.1L515.7,286.3L515,285.9L514,284.9L513.2,285.4L512.1,286.8L509.9,283.4L512,281.7L511,279.7L511.9,278.9L513.7,278.5L513.9,277.1L515.4,278.6L517.8,278.7L518.6,277.3L518.9,275.2L518.6,272.7L517.4,270.9L518.5,267.3L517.9,266.7L515.8,266.9L515.1,265.3L515.3,263.9L518.7,264.1L520.9,264.9L523,265.6L523.2,263.9L524.6,261L526.2,259.4L528,259.9Z","Congo"],"180":["CD","M559.1,285.1L559.6,287.9L559.3,289.6L559.8,291.4L561.3,293.1L562.7,297.1L561.7,296.8L558,297.3L557.3,297.7L556.5,299.6L557.1,301L556.5,304.7L556.1,307.9L556.8,308.4L558.6,309.6L559.4,309.1L559.5,312.4L557.5,312.4L556.4,310.7L555.5,309.4L553.4,308.9L552.9,307.3L551.2,308.3L549.1,307.8L548.2,306.4L546.5,306.1L545.2,306.2L545.1,305.2L544.2,305.2L543,305L541.3,305.4L540.1,305.4L539.5,305.6L539.7,301.9L538.8,300.8L538.6,298.8L539,297L538.5,295.8L538.5,293.8L535.2,293.8L535.5,292.7L534.1,292.7L534,293.2L532.3,293.4L531.6,295.2L531.2,296L529.7,295.5L528.8,296L527,296.2L526,294.6L525.4,293.6L524.6,291.7L524,289.4L516,289.3L515.1,289.7L514.3,289.6L513.2,290.1L512.8,289.1L513.5,288.8L513.6,287.4L514.1,286.6L515,285.9L515.7,286.3L516.7,285.1L518.1,285.1L518.3,286L519.3,286.5L520.9,284.6L522.5,283.1L523.2,282.1L523.1,279.5L524.3,276.5L525.5,274.9L527.3,273.3L527.6,272.3L527.7,271.2L528.1,270.1L528,268.3L528.3,265.6L528.8,263.6L529.6,262L529.8,260.1L530,257.9L531,256.3L532.5,255.3L534.7,256.4L536.4,257.5L538.4,257.8L540.4,258.4L541.2,256.6L541.6,256.3L542.8,256.6L545.8,255.1L546.9,255.7L547.8,255.6L548.1,254.9L549.1,254.6L551.2,254.9L552.9,255L553.8,254.7L555.5,257.3L556.7,257.6L557.4,257.1L558.6,257.3L560.1,256.7L560.8,258L563.2,260.1L563,263.7L564.1,264.1L563.3,265.2L562.2,266.1L561.2,267.7L560.6,269.2L560.5,271.7L559.9,272.9L559.8,275.2L559.1,276.1L558.9,277.9L558.6,278.2L558.3,279.9L559,281.3Z","Dem. Rep. Congo"],"188":["CR","M258.1,241.1L257.1,241.4L257,242.7L257.6,243.1L257.1,243.5L257.2,244.1L256.9,244.7L256.8,245.3L255.3,244.6L254.8,244L255.2,243.4L255.1,242.8L254.4,242L253.4,241.4L252.5,241L252.4,240.1L251.7,239.5L251.8,240.4L251.3,241.2L250.7,240.3L249.8,240L249.5,239.4L249.6,238.4L250,237.4L249.3,237L250,236.4L250.4,236L252.1,236.8L252.8,236.4L253.6,236.7L254,237.3L254.8,237.5L255.5,236.8L256,238.5L257,239.8Z","Costa Rica"],"191":["HR","M520,125.5L520.8,125.9L522.7,127.2L524.7,127.8L525.6,127.4L526.2,128.6L527.1,129.4L526.2,130.6L525.1,129.9L523.4,130L521.3,129.4L520.2,129.5L519.7,130.2L518.8,129.4L518.3,130.7L519.6,132.2L520.2,133.1L521.4,134.3L522.4,135L523.4,136.3L525.7,137.4L525.4,138L523,136.8L521.5,135.7L519.2,134.8L517,132.5L517.5,132.3L516.3,131L516.2,129.9L514.6,129.4L514,130.8L513.2,129.7L513.2,128.7L513.3,128.6L515,128.7L515.4,128.2L516.2,128.7L517.2,128.8L517.1,127.9L517.9,127.6L518.1,126.4Z","Croatia"],"192":["CU","M263.6,198.5L265.8,198.7L267.9,198.7L270.2,199.8L271,200.9L273.6,200.6L274.4,201.3L276.4,203.3L277.8,204.7L278.7,204.6L280.2,205.3L279.9,206.2L281.8,206.3L283.6,207.6L283.2,208.3L281.4,208.7L279.6,208.9L277.8,208.6L274,208.9L276,207.2L275,206.3L273.3,206.1L272.6,205.2L272.2,203.4L270.7,203.6L268.3,202.7L267.6,202.1L264.3,201.6L263.4,201L264.5,200.2L262,200L259.8,201.7L258.7,201.7L258.2,202.5L256.9,202.8L255.8,202.5L257.3,201.5L258.1,200.4L259.4,199.7L260.8,199.1L262.9,198.8Z","Cuba"],"196":["CY","M563.1,160.9L563.6,161L564.3,160.8L564.8,160.8L565,161L565,161.3L565.2,161.2L565.6,161.3L566,161L566.3,161.1L566.4,161.4L563.9,162.7L562.6,162.3L561.9,161Z","Cyprus"],"203":["CZ","M515.3,111.6L516.5,112.5L518.2,112.8L518.2,113.6L519.5,114.2L519.8,113.5L521.4,113.8L521.7,114.7L523.5,114.9L524.7,116.4L524,116.4L523.7,117L523.2,117.1L523.1,117.8L522.6,117.9L522.6,118.2L521.8,118.5L520.7,118.5L520.4,119.2L519.3,118.6L518.2,118.7L516.3,117.8L515.5,118L514.2,119.3L512.4,118.3L510.9,117L509.7,116.3L509.4,115L508.9,114.1L510.6,113.4L511.4,112.7L513.1,112.1L513.6,111.5L514.3,111.9Z","Czechia"],"204":["BJ","M487.3,251.5L485,251.8L484.4,249.7L484.5,242.5L483.9,241.9L483.8,240.3L482.9,239.2L482.1,238.3L482.4,236.7L483.3,236.3L483.9,234.9L485.2,234.6L485.8,233.7L486.7,232.8L487.6,232.8L489.7,234.6L489.6,235.6L490.2,237.5L489.7,238.7L490,239.6L488.7,241.5L487.8,242.5L487.3,244.4L487.4,246.4Z","Benin"],"208":["DK","M502.7,100L501.3,100.5L499.5,100.1L498.5,98.5L498.3,95.5L498.7,94.7L499.3,93.8L501.3,93.6L502,92.8L503.8,92L503.8,93.5L503.2,94.4L503.5,95.3L504.8,95.7L504.3,96.8L503.6,96.5L502,98.6ZM508.1,96.7L508.9,98.2L507.7,100.6L505.2,98.9L504.8,97.7Z","Denmark"],"214":["DO","M289.4,214.6L289.5,213.7L289,212.8L289.7,212.3L290,211.1L290,209.4L290.3,208.8L292.4,208.8L293.9,209.6L294.6,209.6L295,210.7L296.4,210.6L296.2,211.6L297.4,211.7L298.6,212.8L297.5,214.1L296.3,213.4L295,213.5L294.2,213.4L293.6,214L292.6,214.2L292.3,213.4L291.3,213.8L290.1,216L289.4,215.5Z","Dominican Rep."],"218":["EC","M276.6,271.5L276.9,273.9L276.1,275.9L273.2,279.2L270,280.4L268.4,283.1L267.9,285.2L266.5,286.5L265.3,284.9L264.2,284.6L263.1,284.8L263,283.7L263.7,283L263.4,281.7L264.8,279.3L264.2,278L263.1,279.4L261.5,278L262,277.2L261.6,274.3L262.5,273.9L263,271.9L264,269.9L263.8,268.6L265.3,268L267.2,266.7L269.9,268.5L270.4,268.4L271,269.8L273.3,270.2L274.1,269.7L275.4,270.8Z","Ecuador"],"222":["SV","M241.2,225.9L241.9,226.2L242.4,226.8L243.2,227.3L243.2,227.8L244.5,227.4L245,227.6L245.3,227.9L245,229.2L244.6,229.9L243.1,229.9L242.2,229.6L241.1,229L239.6,228.8L239,228.1L239.1,227.6L240.1,226.9L240.6,226.5L240.5,226.1Z","El Salvador"],"226":["GQ","M506,263.9L510.4,264L510.5,267.7L506.5,267.7L505.6,267.9L505.1,267.4Z","Eq. Guinea"],"231":["ET","M608.6,246L601.2,255.4L597.7,255.5L595.3,257.7L593.6,257.8L592.9,258.8L591,258.8L589.9,257.7L587.5,259L586.7,260.3L584.9,260.1L584.3,259.7L583.7,259.8L582.8,259.8L579.4,257.1L577.5,257.1L576.6,256.1L576.6,254.3L575.1,253.8L573.5,250.4L572.2,249.7L571.8,248.5L570.4,246.9L568.7,246.7L569.6,244.9L571,244.8L571.4,243.9L571.3,241.1L572,237.8L573.2,236.9L573.5,235.7L574.5,233.3L576.1,231.7L577.1,228.6L577.4,225.9L580.5,226.6L581.2,224.3L582.9,225.7L584.5,224.9L585.1,225.6L587,225.6L589.4,226.9L590.1,228L591.3,229L592.5,230.8L593.5,231.8L592.6,233.2L591.7,234.7L592,235.5L592.1,236.5L593.6,236.5L594.2,236.3L594.8,236.9L594.3,238L595.3,239.7L596.4,241.2L597.4,242.3L606.3,246Z","Ethiopia"],"232":["ER","M577.4,225.9L577,224.7L578,220.1L578.1,218L578.9,217L580.9,216.5L582.1,214.7L583.8,218.4L584.7,221.2L586.3,222.8L590.1,225.7L591.6,227.5L593.2,229.3L594.1,230.4L595.4,231.3L594.6,232.1L593.5,231.8L592.5,230.8L591.3,229L590.1,228L589.4,226.9L587,225.6L585.1,225.6L584.5,224.9L582.9,225.7L581.2,224.3L580.5,226.6Z","Eritrea"],"233":["EE","M542.1,87L542.5,87.5L541.2,89.1L542.3,91.8L541.4,92.7L539.6,92.7L537.5,91.7L536.5,91.3L534.6,91.8L534.6,90.1L533.9,90.5L532.3,89.5L531.9,87.8L534.6,87L537.3,86.6L539.8,87.1Z","Estonia"],"238":["FK","M336.9,432.7L339.2,430.9L341.4,431.7L342.4,430.5L344.7,431.8L344.3,432.9L341.4,433.8L340,432.7L338.5,434.1Z","Falkland Is."],"242":["FJ","M953.9,325.8L954.7,325.2L955.4,326.1L954.5,327.8L952.8,328.2L951.4,327.8L951.5,326.4L952.8,325.4ZM959.6,322.8L957.8,323.5L955.9,324.2L955.8,323L957.3,322.4L958.2,322.2L960,321.2L960,321.2L959.6,322.8ZM0,321.2L0,321.2L0,321.2L0.5,321.1L0.5,322.6L0.4,322.8L0.4,322.8L0,321.2Z","Fiji"],"246":["FI","M538.6,60.5L538.7,62.4L542.2,64.2L540.7,66.2L543.7,69.3L542.8,71.6L545.1,73.7L544.6,75.5L548.1,77.4L547.6,78.8L545.9,80.5L541.8,84.1L537.8,84.3L534.1,85.3L530.6,85.9L529.1,84.4L526.9,83.4L527,80.7L525.6,78.1L526.4,76.5L528.1,74.8L532.6,71.8L533.9,71.2L533.5,70L530.3,68.8L529.5,67.7L528.7,63.5L525.2,61.7L522.3,60.4L523.4,59.7L525.9,61.1L528.6,61L530.9,61.6L532.6,60.5L533.3,58.5L536.3,57.6L539.1,58.7Z","Finland"],"250":["FR","M340.7,258L339,260.9L338.2,263.2L337.1,264.4L335.8,264.6L335.5,263.7L334.9,263.6L334,264.4L332.9,263.8L333.6,262.5L333.8,261.1L334.3,259.7L333.3,257.9L333.1,255.7L334.6,253L335.5,253.4L337.5,254.1L340.3,256.8ZM494.7,116.5L495.8,117.3L499.3,117.9L498.1,120L497.9,122.1L497.3,122.6L496.2,122.4L496.3,123.1L494.6,124.9L494.5,126.2L495.7,125.8L496.5,127.1L496.5,128L497.2,129.1L496.4,130.1L497.1,132.5L498.4,132.9L498.2,134.2L496,135.9L491.2,135.1L487.6,136.1L487.4,138L484.5,138.4L481.7,137L480.8,137.6L476.3,136.2L475.3,135L476.6,133.2L477.1,127L474.6,123.8L472.9,122.3L469.3,121.1L469.1,118.9L472.2,118.2L476.1,119L475.4,115.6L477.7,116.9L483.2,114.5L483.9,112L485.9,111.4L486.3,112.5L487.4,112.5L488.5,113.8L490.1,115.2L491.4,114.9L493.5,116.3L494,116.6ZM501.5,137.5L503.1,136.3L503.6,139L502.8,141.4L501.7,140.7L501.1,138.6Z","France"],"260":["TF","M644.3,423L645.6,423.9L647.7,424.3L647.6,424.9L646.5,426.3L642.8,426.5L643.2,424.9L644,423.6Z","Fr. S. Antarctic Lands"],"262":["DJ","M593.5,231.8L594.6,232.1L595.4,231.3L596.1,232.3L596.1,233.6L594.6,234.4L595.7,235.2L594.8,236.9L594.2,236.3L593.6,236.5L592.1,236.5L592,235.5L591.7,234.7L592.6,233.2Z","Djibouti"],"266":["GA","M510.4,264L511.7,263.8L513.4,264.2L514.9,263.8L515.3,263.9L515.1,265.3L515.8,266.9L517.9,266.7L518.5,267.3L517.4,270.9L518.6,272.7L518.9,275.2L518.6,277.3L517.8,278.7L515.4,278.6L513.9,277.1L513.7,278.5L511.9,278.9L511,279.7L512,281.7L509.9,283.4L507.2,280.3L505.4,277.7L503.7,274.5L503.8,273.5L504.4,272.5L505.1,270.2L505.6,267.9L506.5,267.7L510.5,267.7Z","Gabon"],"268":["GE","M577.9,135L578.2,134.6L580.3,135.2L584,135.7L587.6,137.1L588.1,137.7L589.5,137.2L591.9,137.9L592.9,139.2L594.6,139.9L594,140.3L595.5,142L595.2,142.4L593.9,142.2L591.9,141.3L591.4,141.8L588,142.3L585.4,140.7L582.7,140.9L582.9,139.6L582,137.4L580.4,136.3L579,135.9Z","Georgia"],"270":["GM","M435.3,228.5L438.2,228.4L438.8,227.7L439.7,227.7L440.7,228.4L441.5,228.4L442.4,227.9L442.9,228.8L441.8,229.5L440.6,229.5L439.5,228.8L438.5,229.5L438,229.6L437.3,230L434.9,229.9Z","Gambia"],"275":["PS","M571,172.4L569.9,172.8L569.9,171.9L570.5,171.5L569.8,171.2L570.2,169.1L571.1,169.5L571.3,171.4Z","Palestine"],"276":["DE","M512.6,103.7L513.3,105.2L512.7,106L513.6,107L514.3,108.6L514.2,109.6L515.3,111.6L514.3,111.9L513.6,111.5L513.1,112.1L511.4,112.7L510.6,113.4L508.9,114.1L509.4,115L509.7,116.3L510.9,117L512.4,118.3L511.6,119.7L510.8,120.1L511.2,122.1L511,122.6L510.2,122L509.1,121.9L507.4,122.4L505.3,122.3L505,123.1L503.7,122.2L503,122.4L500.4,121.5L499.9,122.1L497.9,122.1L498.1,120L499.3,117.9L495.8,117.3L494.7,116.5L494.8,115.2L494.3,114.5L494.5,112.5L494,109.3L495.4,109.3L496,108.2L496.4,105.5L496,104.5L496.4,103.8L498.3,103.7L498.8,104.3L500.3,102.9L499.7,101.8L499.5,100.1L501.3,100.5L502.7,100L502.8,101.2L505.2,101.9L505.2,102.9L507.5,102.3L508.8,101.5L511.5,102.7Z","Germany"],"288":["GH","M480.1,236.6L479.9,237.6L481,239.2L481,241.5L481.2,243.9L481.9,245.1L481.3,247.9L481.5,249.4L482.3,251.4L482.9,252.5L478.6,254.3L477.1,255.4L474.7,256.3L472.3,255.4L472.4,254.2L471.3,251.5L472,248L473.1,245.3L472.4,240.9L472,238.5L472.1,236.8L476.8,236.6L478,236.9L478.8,236.3Z","Ghana"],"300":["GR","M546.7,160.4L546.5,161.3L542.8,161.6L542.8,161.1L539.7,160.4L540.1,159.1L541.5,160.2L543.5,160L545.4,160.2L545.4,160.8ZM536.8,141.5L538.6,141.6L540.5,140.7L542.4,141.8L544.6,141.5L544.5,140L545.8,140.8L545.2,142.8L544.6,143.1L543.1,143L541.8,142.7L538.9,143.5L540.7,145.3L539.5,145.8L538.1,145.8L536.7,144.2L536.3,144.9L537,146.7L538.3,148.2L537.5,148.9L539,150.3L540.3,151.2L540.4,153L538.1,152.2L538.9,153.8L537.4,154.1L538.5,156.9L536.8,156.9L534.7,155.5L533.6,153L533,150.9L531.9,149.5L530.5,147.7L530.3,146.8L531.3,145.3L531.4,144.3L532.2,143.9L532.1,143L533.7,142.8L534.6,142.1L536,142.2L536.3,141.6Z","Greece"],"304":["GL","M397.8,28.1L404.4,26.9L410.4,27L413.1,26.3L419.3,26.1L433,26.4L443.4,27.9L439.9,28.6L433.1,28.7L423.5,28.9L424.3,29.3L430.6,29L435.7,29.7L439.4,29.1L440.7,29.9L438.4,31.1L443.1,30.3L452,29.5L457.2,29.9L458.1,30.8L450.5,32.3L449.4,32.8L443.5,33.2L447.7,33.3L445.2,34.9L443.5,36.3L443,38.9L445,40.5L442.1,40.6L438.8,41.3L442.1,42.6L442.2,44.7L440.1,44.9L442.2,47.1L437.9,47.2L440,48.3L439.2,49.1L436.4,49.5L433.6,49.5L435.8,51.3L435.6,52.4L431.9,51.3L430.7,52L433.3,52.7L435.6,54.2L436.1,56.3L432.4,56.8L431,55.8L428.8,54.3L429.1,56.1L426.5,57.5L431.9,57.6L434.6,57.7L428.8,60L422.8,62.1L416.6,63L414.3,63.1L411.9,64.1L408.4,66.9L403.4,68.8L402,68.9L399,69.6L395.8,70.3L393.5,71.9L393,73.9L391.4,75.7L387.3,77.9L387.6,80.1L386,82.4L384.2,85.2L381,85.4L378.4,83.1L374,83.1L372.4,81.5L371.7,78.8L369.1,75.3L368.6,73.5L369.1,71L367.1,68.5L368.6,66.5L367.5,65.6L370.7,62.4L374.2,61.4L375.4,60.3L376.6,58.3L373.9,59.2L372.6,59.6L370.7,60L368.5,59.1L369,57.3L370.4,55.9L372.3,55.9L376.1,56.6L373.3,54.9L371.9,54L369.7,54.4L368.3,53.8L371.5,51.4L370.7,50.4L369.9,48.7L368.8,46L366.8,45.1L367.3,44L362.9,42.6L358.9,42.4L353.7,42.5L349,42.7L347.2,41.9L344.9,40.4L350.3,39.7L354.2,39.6L346.5,38.9L342.9,38L343.8,37.1L351.6,36L359.1,34.9L360.4,34.1L356,33.3L358.3,32.4L365.6,30.9L368.4,30.7L368.4,29.8L373,29.2L378.7,28.9L384.2,28.9L385.7,29.5L391.1,28.4L394.8,29.2L397.2,29.3L400.6,30L397,28.9Z","Greenland"],"320":["GT","M233.5,225.6L233.7,224.7L234.1,223.9L233.8,223.3L235.3,220.8L238.8,220.8L239,219.7L238.6,219.5L238.3,218.9L237.4,218.1L236.6,217.1L237.8,217.1L238,215.3L240.5,215.3L243,215.3L242.6,217.8L242,221.4L242.8,221.4L243.6,221.9L243.9,221.5L244.6,221.9L243.3,223.1L241.9,223.9L241.7,224.5L241.8,225.1L241.2,225.9L240.5,226.1L240.6,226.5L240.1,226.9L239.1,227.6L239,228.1L237.6,227.6L236,227.5L234.8,226.9Z","Guatemala"],"324":["GN","M443.3,231.7L444.6,231.7L446.5,232.5L447.1,232.4L447.3,232.1L448.8,232.3L449.1,232.1L449.3,233.3L449.7,233.3L450.4,232.9L450.9,233L451.6,233.8L452.7,234L453.5,233.3L454.4,232.9L455,232.5L455.5,232.6L456.1,233.3L456.4,234.1L457.5,235.4L457,236.2L456.9,237.2L457.4,236.9L457.8,237.3L457.6,238.2L458.4,239.1L457.9,239.4L457.7,240.4L458.3,241.7L458.9,244.2L457.9,244.6L457.7,245L457.9,245.6L457.7,247L457.3,247L456.5,246.9L456,248.2L455.2,248.2L454.7,247.5L454.9,246.3L453.8,244.3L453.1,244.7L452.5,244.8L451.7,244.9L451.8,243.8L451.4,243L451.4,242.1L450.9,240.8L450.1,239.6L448,239.6L447.3,240.2L446.6,240.3L446.1,241L445.8,241.8L444.4,243.2L443.2,241.4L442.2,240.1L441.5,239.7L440.8,239.1L440.5,237.7L440.2,237L439.4,236.5L440.6,235L441.4,235.1L442.1,234.5L442.7,234.5L443.1,234.1L442.9,233.1L443.2,232.8Z","Guinea"],"328":["GY","M327.4,265.1L326.8,265.2L325.3,264.9L324.4,265.8L323.2,266.3L322.3,266.4L322,267.1L320.7,266.9L319,265.4L318.8,264L318.2,262.4L318.6,259.8L319.4,258.7L318.8,257.2L317.9,256.7L318.3,255.4L317.7,254.6L316.3,254.8L314.5,252.4L315.3,251.6L315.3,250.1L316.9,249.6L317.6,249L316.8,247.9L317,246.7L319.2,244.9L321,246L322.5,248.1L322.6,249.7L323.6,249.8L325,251.3L326,252.4L325.5,255.2L323.8,256L324,256.7L323.4,258.3L324.6,260.6L325.5,260.6L325.8,262.4Z","Guyana"],"332":["HT","M290,209.4L290,211.1L289.7,212.3L289,212.8L289.5,213.7L289.4,214.6L287.7,214.1L286.4,214.3L284.8,214.1L283.5,214.6L282.2,213.7L282.5,212.7L284.9,213.1L286.9,213.3L287.9,212.6L286.9,211.3L287,210.1L285.4,209.6L286.1,208.7L287.7,208.9Z","Haiti"],"340":["HN","M257.9,224.1L257,224.1L256.6,224.5L255.6,224.9L255,224.9L254.3,225.3L253.8,225.2L253.4,224.7L253.1,224.8L252.7,225.5L252.4,225.5L252.3,226.2L251.3,227L250.8,227.4L250.5,227.8L249.7,227.1L249.1,228L248.5,228L247.9,228L247.8,229.6L247.4,229.6L247,230.3L246.2,230.4L245.8,229.5L245,229.2L245.3,227.9L245,227.6L244.5,227.4L243.2,227.8L243.2,227.3L242.4,226.8L241.9,226.2L241.2,225.9L241.8,225.1L241.7,224.5L241.9,223.9L243.3,223.1L244.6,221.9L244.9,222L245.5,221.4L246.3,221.4L246.5,221.6L246.9,221.5L248.2,221.8L249.4,221.7L250.3,221.3L250.6,221L251.5,221.2L252.1,221.4L252.8,221.3L253.4,221L254.5,221.5L254.9,221.5L255.7,222.1L256.4,222.8L257.3,223.3Z","Honduras"],"348":["HU","M532.7,119.7L534.1,120.5L534.4,121.3L533,122L532,124L530.8,126.1L528.9,126.7L527.4,126.6L525.6,127.4L524.7,127.8L522.7,127.2L520.8,125.9L520,125.5L519.4,124.5L519,124.5L519.7,122.5L519.2,121.8L520.5,121.8L520.6,120.6L521.9,121.4L522.8,121.7L524.8,121.3L524.9,120.7L525.8,120.6L527,120.2L527.2,120.3L528.3,120L528.8,119.3L529.6,119.1L532.2,120Z","Hungary"],"352":["IS","M449.6,67.5L448.9,69.3L451.1,71.2L448.2,73.3L441.8,75.2L439.9,75.7L437.1,75.2L431.2,74.4L433.5,73.2L429.1,71.8L432.9,71.3L432.9,70.5L428.6,69.8L430.3,68.1L433.6,67.7L436.6,69.5L440,68L442.5,68.8L446.1,67.3Z","Iceland"],"356":["IN","M732.8,182.5L733.2,183.7L732.4,184.3L733.1,186.2L731.1,185.6L728.2,187.8L728.6,189.6L727.7,192.3L727.9,193.8L727.2,196.4L725,195.7L725.5,198.9L725.1,200L725.6,201.3L724.4,202.1L722.2,197.1L721.5,197.1L721.4,199.1L719.7,197.5L720.2,195.7L721.3,195.5L722,192.8L720.4,192.3L718,192.3L715.4,191.9L714.8,189.7L713.5,189.6L711.1,188.2L710.6,190.3L712.8,192L711.4,193.2L711,194.3L712.8,195.2L712.7,197.1L714,199.4L714.8,202L714.6,203.2L712.8,203.1L709.7,203.8L710.2,206.1L709,208L705.5,210.1L703,213.8L701.3,215.8L698.9,217.8L699,219.3L697.8,220L695.5,221.2L694.3,221.3L693.7,223.7L694.6,227.8L695,230.4L694.1,233.3L694.5,238.7L693.1,238.8L692,241.2L692.9,242.2L690.5,243.1L689.7,245.2L688.7,246.1L686,243.2L684.5,238.8L683.2,235.7L682.2,234.2L680.5,231.2L679.6,227.3L678.9,225.3L676.1,221L674.4,215L673.2,210.9L672.7,207.1L671.8,204.2L668.2,206.1L666.3,205.7L662.4,201.9L663.5,200.8L662.6,199.5L659.2,196.9L660.6,194.8L666.4,194.8L665.5,192.1L663.8,190.5L663.1,188.1L661.2,186.7L663.5,183.4L666.6,183.6L668.7,180.3L669.8,177.1L671.7,174L671.2,171.7L673,169.9L670.7,168.3L669.3,166.2L667.8,163.5L668.8,162.1L672.8,162.9L675.5,162.4L677.4,159.8L681,163.4L681.3,166L682.7,167.6L682.9,169.2L681,168.8L682.5,172.3L685.4,174.3L689.5,176.5L688.1,177.9L687.7,180.8L690.4,182L693.2,183.6L696.9,185.3L700.5,185.7L702.3,187.3L704.4,187.6L707.7,188.4L709.9,188.3L709.9,187.1L709.2,185.1L709.1,183.7L710.6,183.1L711.3,185.5L711.5,186.2L714.1,187.4L715.6,186.9L717.8,187.1L720,187L719.7,185.1L718.5,184L720.5,183.7L722.3,181.3L724.9,179.3L727.2,180.1L728.8,178.8L730.4,180.7L729.9,182Z","India"],"360":["ID","M860.5,279.1L860,289.3L859.2,299.5L857.1,296.9L854.4,296.3L853.6,297.2L850.2,297.3L851.6,294.7L853.4,293.9L852.9,290.5L851.8,287.9L846.7,285.2L844.5,285L840.6,282.1L839.7,283.6L838.7,283.9L838.1,282.7L838.1,281.4L836.1,279.8L839.1,278.7L841,278.8L840.8,277.9L836.8,277.9L835.8,276.1L833.4,275.5L832.3,273.9L835.9,273.2L837.3,272.2L841.6,273.5L842,274.6L842.7,279.7L845.4,281.5L847.8,278.2L850.9,276.3L853.3,276.3L855.6,277.4L857.6,278.5ZM816.1,298.8L816.3,299.4L816.2,300.4L814.3,302.7L811.9,303.4L811.6,303L812,301.9L813.3,300ZM841.5,292.6L841.4,290.2L841.9,289.1L842.5,288L843.1,288.9L843,290.4ZM797.9,258.1L796.5,260.9L798.5,263.9L798.1,265.3L801.2,268.2L798,268.6L797.1,270.7L797.2,273.5L794.6,275.7L794.5,278.8L793.3,283.5L792.9,282.4L789.8,283.8L788.8,281.9L786.9,281.8L785.5,280.8L782.3,281.9L781.4,280.4L779.6,280.5L777.4,280.2L777.1,276L775.7,275.1L774.4,272.5L774.1,269.7L774.4,266.8L775.9,264.8L776.4,266.8L778.3,268.6L780,268L781.7,268.2L783.3,266.6L784.6,266.3L787.2,267.2L789.3,266.6L790.6,262.2L791.7,261.1L792.5,257.6L795.6,257.6ZM829.1,279.8L832,280.7L832.9,283.1L830.7,281.8L828.4,281.5L826.9,281.7L825,281.6L825.7,279.9ZM822.2,282.9L820.4,282.3L819.9,280.9L822.6,280.8L823.3,281.8ZM825.2,264.2L825.5,265.9L827.1,266.2L827.3,267.5L827.2,270.2L825.8,269.9L825.4,271.8L826.5,273.5L825.7,273.8L824.7,271.9L823.8,267.9L824.4,265.4ZM811.8,268.3L814.9,268.2L817.5,265.9L818,266.6L815.9,269.7L813.8,270.3L811.2,269.7L806.7,269.8L804.4,270.3L804,272.6L806.4,275.4L807.9,274L812.9,272.9L812.7,274.4L811.5,273.9L810.3,275.8L807.9,277L810.4,281L809.8,282L812.1,285.6L812,287.7L810.5,288.6L809.5,287.5L810.9,285L808.2,286.2L807.6,285.3L808,284.1L806.1,282.3L806.4,279.2L804.6,280.2L804.7,283.8L804.6,288.3L802.9,288.7L801.8,287.8L802.7,284.9L802.4,281.9L801.2,281.9L800.4,279.8L801.6,277.7L802,275.2L803.4,270.5L804,269.3L806.3,266.9L808.4,267.9ZM803.1,303.1L799.8,300.9L802.3,300.3L803.6,301.2L804.5,302.2L804.2,303ZM806.4,297.7L808.2,297.4L810.7,296.3L810.2,298L806.1,298.9L802.5,298.5L802.6,297.4L804.8,296.7ZM798.2,297.1L799.8,296.9L800.4,298.2L797.2,298.8L795.3,299.3L793.9,299.2L795,297.4L796.5,297.4L797.3,296.3ZM772.3,291.1L772.6,292.2L777.7,292.5L778.4,291.2L783.3,292.7L784.1,294.7L788.1,295.3L791.3,297.2L788.1,298.4L785.3,297.1L782.8,297.2L780.1,296.9L777.6,296.4L774.5,295.2L772.6,294.9L771.4,295.3L766.6,294L766.2,292.6L763.8,292.4L765.8,289.4L769,289.6L771.2,290.8ZM761.7,274.4L762.1,276.6L763,278.3L765,278.6L766.3,280.6L765.5,284.5L765.2,289.3L762.2,289.4L760,286.7L756.7,284.2L755.6,282.3L753.6,279.8L752.3,277.4L750.3,273.1L747.9,270.4L747.1,267.8L746.1,265.3L743.6,263.4L742.2,260.7L740.1,258.9L737.1,255.5L736.9,253.9L738.6,254L742.8,254.6L745.3,257.7L747.4,259.8L749,261.1L751.6,264.5L754.3,264.5L756.6,266.7L758.2,269.3L760.3,270.7L759.2,273.2L760.7,274.3Z","Indonesia"],"364":["IR","M605.5,177.3L603.9,175.6L603.7,173.9L602.8,173.9L603,171.7L601.3,169.3L598,167.6L595.8,164.6L596.1,162.1L597.2,161L596.8,159.2L595,158.3L592.8,154.5L591.1,152L591.4,151L590.1,147.5L591.7,146.6L592.2,147.7L593.7,149.2L595.5,149.6L596.4,149.5L599,147.2L599.9,147L600.8,147.9L600.2,149.4L602,151.1L602.6,150.9L603.8,153.2L606.2,153.9L608.2,155.4L611.9,156L615.7,155.2L615.8,154.4L617.9,153.8L619.4,152L621.1,152.1L622.1,151.5L623.9,151.8L627,153.4L629.1,153.8L632.5,156.5L634.4,156.6L635.1,159.3L634.8,163.2L634.5,165.5L635.7,165.9L634.9,167.7L636.2,170.2L636.7,172.2L638.7,172.7L639.3,174.7L637.4,177.6L638.9,179.2L640.2,181.1L642.9,182.5L643.4,185.3L644.7,185.8L645.1,187.2L641.6,188.9L641.1,192.5L636,191.6L633.1,190.8L630.1,190.4L628.5,186.6L627.2,186L625.2,186.6L622.8,188.1L619.5,187.1L616.6,184.6L614,183.8L611.9,180.8L609.4,176.6L608.1,177.1L606.3,176Z","Iran"],"368":["IQ","M580.6,170.2L579.1,166.4L584.4,163.1L584.9,159.3L584.4,157.1L585.6,156.3L586.7,154.3L587.7,153.8L590.7,154.3L591.7,155L592.8,154.5L595,158.3L596.8,159.2L597.2,161L596.1,162.1L595.8,164.6L598,167.6L601.3,169.3L603,171.7L602.8,173.9L603.7,173.9L603.9,175.6L605.5,177.3L604,177.1L602.2,176.9L600.6,179.9L595.8,179.6L587.8,173.3L583.8,171.1Z","Iraq"],"372":["IE","M465.7,103.3L466,105.4L464.2,108.1L460,109.9L456.7,109.4L458.7,106.3L457.6,103.3L460.9,101L462.7,99.6L463.1,101.2L462.5,102.8L464,102.7Z","Ireland"],"376":["IL","M571.5,168.5L571.1,169.5L570.2,169.1L569.8,171.2L570.5,171.5L569.9,171.9L569.9,172.8L571,172.4L571.2,173.6L570.4,178.6L570,177.8L568.2,173.2L568.8,172.2L568.7,172L569.2,170.5L569.5,168.1L569.8,167.4L569.9,167.3L570.7,167.3L570.9,166.8L571.6,166.7L571.7,168L571.4,168.5Z","Israel"],"380":["IT","M505.1,124.3L506.6,124.8L506.9,124.2L509.2,123.7L509.8,124.7L513.3,125.5L513.1,127L513.8,128.3L511.8,127.9L509.9,129L510.1,130.5L509.9,131.4L510.7,133L513.1,134.5L514.5,137.1L517.4,139.6L519.3,139.6L519.9,140.3L519.3,140.9L521.6,142L523.5,142.9L525.7,144.6L526,145.1L525.6,146.3L524.1,144.8L521.9,144.3L521,146.3L522.9,147.5L522.7,149.1L521.6,149.3L520.4,152L519.4,152.2L519.4,151.2L519.8,149.6L520.3,148.9L519.2,147.1L518.4,145.5L517.3,145.1L516.5,143.8L514.9,143.2L513.8,142L511.9,141.8L509.9,140.4L507.6,138.3L505.8,136.6L504.9,133.5L503.7,133.1L501.7,132.1L500.6,132.5L499.2,134L498.2,134.2L498.4,132.9L497.1,132.5L496.4,130.1L497.2,129.1L496.5,128L496.5,127.1L497.6,127.8L498.8,127.6L500.1,126.6L500.5,127.1L501.7,127L502.2,125.7L504,126.1L505,125.6ZM517,151.5L518.9,151.2L518.2,153.7L518.6,154.6L518.1,156.2L516.1,155.1L514.8,154.7L511.3,153.1L511.5,151.5L514.5,151.8ZM501.6,142.9L502.8,141.9L504.4,144.1L504.2,148.2L503,148L502,149.1L501.1,148.3L500.9,144.5L500.2,142.7Z","Italy"],"384":["CI","M458.4,239.1L458.8,238.8L459.5,239.3L461.6,239.3L462.1,238.4L462.6,238.5L463.3,238.1L463.7,239.5L464.4,239.1L465.5,238.6L466.7,239.3L467.2,240.3L468.4,241L469.3,240.2L470.6,240.1L472.4,240.9L473.1,245.3L472,248L471.3,251.5L472.4,254.2L472.3,255.4L471.1,255.5L469.2,254.8L467.5,254.9L464.3,255.4L462.4,256.3L459.7,257.5L459.2,257.4L459.4,254.8L459.7,254.4L459.6,253.2L458.5,251.9L457.6,251.7L456.8,250.8L457.4,249.4L457.1,247.9L457.3,247L457.7,247L457.9,245.6L457.7,245L457.9,244.6L458.9,244.2L458.3,241.7L457.7,240.4L457.9,239.4Z","Côte d'Ivoire"],"388":["JM","M274,213.2L275.7,213.5L277.1,214.2L277.4,215.1L275.5,215.1L274.7,215.7L273.2,215.2L271.8,214L272.2,213.3L273.4,213.1Z","Jamaica"],"392":["JP","M834.5,148.2L833.7,151.4L835.2,154.6L835.4,157.1L836.5,158.7L836.1,160.9L833.5,162.4L829.1,162.6L826.9,166.1L824.7,164.9L823.7,162.6L819.5,163.3L817.1,164.8L814.1,164.8L817.6,167.1L817.8,172.5L816.6,173.8L814.9,172.6L814.6,169.7L812.6,168.8L810.8,166.7L812.8,165.7L813.4,163.7L815.4,162.1L816.4,160L821,159L824,159.7L824.3,154.1L826.6,155.6L828.9,152.5L829.8,151.2L829.6,147.4L827.4,143.9L827.5,141.9L829.8,141.4L833.4,145.7ZM833.4,133.4L834.4,132.1L837,135.5L833.8,136.4L833.3,139.5L828.3,137.3L828.7,140.7L826,140.8L824.1,137.7L824,135.3L826.5,135.1L824.8,130.9L824.2,128.5L828.9,131.7L831.4,132.7ZM818.2,166.1L818.9,164.3L820.5,164.6L821,163.3L823.1,164L823.9,165.1L823.2,167L821.7,166L820.7,166.7L820.7,168.5L818.7,167.6Z","Japan"],"398":["KZ","M687.6,117.3L686.5,119.3L684.7,119.6L685.7,122.6L684.9,124L679.7,123L679.9,128.5L678.9,129.2L674.5,130.4L678.4,135.8L677,136.6L677.7,138.4L676.1,137.9L674.5,136.8L670.7,136.5L666.6,136.4L665.9,136.7L662,135.4L660.8,136.1L660.9,137.9L656.6,136.8L655.1,137.3L654.9,138.6L653.6,139.2L650.9,141.4L650.4,143.6L649.5,143.6L648.4,142.1L645.2,142L644.1,139.5L642.9,139.5L642.3,136.3L638.8,134.1L634.7,134.3L631.9,134.8L628.9,132L626.6,130.8L622.3,128.6L621.8,128.4L616,130.2L618.5,141.6L617.3,141.7L615.1,139.3L613.2,138.4L610.6,139.1L609.7,140.1L609.4,139.4L609.7,138.1L609.1,137L606,135.9L604.3,133.2L602.8,132.4L602.6,131.4L605,131.7L604.6,129.4L606.6,128.9L608.8,129.4L608.6,126.4L607.7,124.5L605.3,124.6L603.1,123.9L600.6,125.2L598.5,125.9L597.2,125.4L597.1,123.8L595.1,121.7L593.4,121.8L590.9,119.8L591.8,117.5L591,116.8L592.2,113.5L595,115.3L594.8,113.1L598.8,109.8L602.5,109.7L608.2,111.8L611.3,113L613.4,111.8L617.1,111.7L620.6,113.3L621,112.4L624.4,112.5L624.5,111.1L620.1,109L621.9,107.5L621.3,106.7L623.3,106L621,103.9L621.7,102.9L630,101.9L630.9,101.2L636.2,100.1L637.8,98.8L642.2,99.5L644,102.5L646.2,101.8L649.5,102.8L649.9,104.4L652.1,104.3L656.8,101.5L656.3,102.4L660.1,104.7L668.3,112.3L668.9,110.7L672.9,112.4L675.9,111.7L677.5,112.2L679.3,114L681.2,114.5L682.7,115.8L685.6,115.4Z","Kazakhstan"],"400":["JO","M571.1,169.5L571.5,168.5L574.5,169.8L579.1,166.4L580.6,170.2L580.1,170.7L575.2,172.3L578,175.4L577.2,176L576.9,177L575,177.5L574.5,178.6L573.4,179.6L570.5,179.1L570.4,178.6L571.2,173.6L571,172.4L571.3,171.4Z","Jordan"],"404":["KE","M585.7,285.6L581.9,282.5L581.7,280.7L572,274.3L571.5,274L571.5,270.7L572.3,269.4L573.6,267.3L574.6,265.1L573.3,261.5L573,259.9L571.7,257.7L573.3,255.9L575.1,253.8L576.6,254.3L576.6,256.1L577.5,257.1L579.4,257.1L582.8,259.8L583.7,259.8L584.3,259.7L584.9,260.1L586.7,260.3L587.5,259L589.9,257.7L591,258.8L592.9,258.8L590.6,262.3L590.6,273.7L592.2,276.3L590.3,277.5L589.7,278.8L588.6,279.1L588.2,281.3L587.4,282.5L586.8,284.6Z","Kenya"],"408":["KP","M802.3,138.8L802.3,138.8L802.3,138.8ZM801.7,138.2L802.3,138.8L801.3,138.6L800.8,139.6L800.5,140.7L801.7,142.9L800.7,143.6L800.5,144.2L800,145.1L798.6,145.6L797.9,146.4L798.4,147.8L798.2,148.1L799.5,148.6L801.5,150L801.4,150.8L800.5,151L798.7,151.1L798.4,152.5L797.2,152.4L797.2,152.7L795.7,152.1L795.6,152.7L795,153L794.7,152.4L793.9,152.1L793,151.6L793.1,150.2L793.6,149.8L793.1,149.3L793,147.6L792.6,147.1L791,146.7L789.5,145.9L790.6,143.9L792.6,142.2L793.3,140L794.9,141L797.1,141.1L796,139.5L799.1,138.1L799.2,136.4Z","North Korea"],"410":["KR","M797.2,152.7L797.2,152.4L798.4,152.5L798.7,151.1L800.5,151L801.4,150.8L801.5,150L805.2,153.7L806.7,155.7L808.1,159.3L807.9,161.1L805.8,161.7L804.3,163L802.1,163.2L801.1,161.5L800.7,159.2L798.3,155.9L800,155.4Z","South Korea"],"414":["KW","M604,177.1L604.7,178.5L604.5,179.2L605.6,181.6L603.8,181.7L603,180.2L600.6,179.9L602.2,176.9Z","Kuwait"],"417":["KG","M654.9,138.6L655.1,137.3L656.6,136.8L660.9,137.9L660.8,136.1L662,135.4L665.9,136.7L666.6,136.4L670.7,136.5L674.5,136.8L676.1,137.9L677.7,138.4L677.6,139.1L674.2,140.7L673.6,142L670.6,142.3L670.2,144.3L667.4,143.9L665.9,144.5L663.9,146L664.4,146.7L663.9,147.4L659.3,147.9L656,146.9L653.3,147.1L653.1,145.4L656,145.9L656.6,144.9L658.6,145.2L661.2,143L657.8,141.3L656.3,142.1L654.1,140.9L655.7,138.9Z","Kyrgyzstan"],"418":["LA","M767.1,226.6L764.6,225.5L763.7,227.6L761.3,226.4L762,225L761.8,222.4L759.3,219.6L758.6,216.5L756.2,214L754.2,213.8L753.8,214.9L752.3,214.9L751.4,214.4L748.9,216.3L748.4,213.5L748.5,210.1L746.7,210L746.3,208.1L745,207.2L745.3,206L747.2,204L747.6,204.7L749,204.8L748,201.2L749.2,200.7L751.2,203.2L752.9,206.1L756.2,206.1L757.7,208.8L756.1,209.6L755.6,210.8L759,212.6L761.8,216.4L763.9,219.1L766.2,221.3L767.2,223.5Z","Laos"],"422":["LB","M571.6,166.7L570.9,166.8L570.7,167.3L569.9,167.3L570.5,164.8L571.5,162.5L571.6,162.4L572.7,162.6L573.3,163.8L572,165Z","Lebanon"],"426":["LS","M555.1,361.7L555.9,362.7L555,364.2L554.5,365.2L553,365.7L552.5,366.7L551.6,367L549.8,364.6L551.3,362.6L552.8,361.4L554,360.8Z","Lesotho"],"428":["LV","M541.4,92.7L542.6,93.4L543,94.8L544,96.5L541.8,97.7L540.4,98.2L538.1,96.7L536.8,96.6L536.4,96L534.2,96.2L530.4,96.1L527.9,97L527.7,94.8L528.6,92.9L530.6,91.9L532.7,94.1L534.5,94L534.6,91.8L536.5,91.3L537.5,91.7L539.6,92.7Z","Latvia"],"430":["LR","M457.3,247L457.1,247.9L457.4,249.4L456.8,250.8L457.6,251.7L458.5,251.9L459.6,253.2L459.7,254.4L459.4,254.8L459.2,257.4L458.5,257.4L455.7,255.9L453.3,253.6L451,251.8L449.2,249.8L449.8,248.8L450,247.9L451.2,246.2L452.5,244.8L453.1,244.7L453.8,244.3L454.9,246.3L454.7,247.5L455.2,248.2L456,248.2L456.5,246.9Z","Liberia"],"434":["LY","M545.9,202.2L546.2,208.5L543.2,208.5L543.2,209.8L532.4,203.8L521.7,197.8L519.1,199.5L517.3,200.6L515.7,198.9L511.6,197.6L510.4,195.6L508.3,194.1L507,194.7L506.1,193L505.9,191.6L504.3,189.3L505.4,188L505.1,186L505.4,184.3L505.2,182.9L505.6,180.3L505.4,178.8L504.5,176.1L505.7,175.3L505.9,174L505.6,172.7L507.3,171.5L508.1,170.5L509.3,169.6L509.4,167.2L512.4,168.3L513.5,168L515.7,168.5L519.1,169.9L520.4,172.7L522.8,173.3L526.4,174.6L529.3,176.2L530.5,175.4L531.7,173.9L530.9,171.5L531.6,170L533.4,168.5L535.2,168.1L538.7,168.7L539.6,170.1L540.6,170.2L541.4,170.7L544,171.1L544.7,172.1L543.9,173.6L544.4,175L543.8,176.9L544.7,179.4L545.4,190.6Z","Libya"],"440":["LT","M540.4,98.2L540.8,99.5L539.1,100.4L538.8,102.1L536.4,103.2L534.2,103.2L533.5,102.3L532.3,102L532,101.2L532.2,100.4L531.1,99.9L528.7,99.4L527.9,97L530.4,96.1L534.2,96.2L536.4,96L536.8,96.6L538.1,96.7Z","Lithuania"],"442":["LU","M494.3,114.5L494.8,115.2L494.7,116.5L494,116.6L493.5,116.3L493.7,114.6Z","Luxembourg"],"450":["MG","M612.8,310L613.4,311.3L614,313.4L614.2,317.1L614.8,318.6L614.4,320.1L613.9,321L613.1,319.2L612.5,320.1L612.9,322.4L612.6,323.8L611.8,324.5L611.4,327.2L610.1,330.8L608.5,335.1L606.3,341.1L604.9,345.4L603.4,349.1L601.2,349.8L598.8,351.2L597.3,350.4L595.4,349.2L594.8,347.6L594.9,344.8L594.1,342.3L594.1,340L594.7,337.8L596,337.2L596.1,336.2L597.5,333.8L597.9,331.8L597.4,330.3L597,328.3L597,325.5L598,323.7L598.5,321.7L599.8,321.6L601.4,321L602.4,320.4L603.6,320.3L605.2,318.6L607.5,316.6L608.4,315.1L608.1,313.7L609.2,314.1L610.8,311.9L610.9,310L611.9,308.6Z","Madagascar"],"454":["MW","M568.1,299.9L570.7,300.4L571.2,301.3L572.1,302.8L572.7,307L571.9,309.4L572.5,313.5L573.4,313.4L574.3,314.4L575.4,316.7L575.4,320.7L574.2,321.4L573.3,323.5L571.7,321.6L571.6,319.4L572.2,317.9L572.1,316.7L571.1,315.9L570.3,316.2L568.8,314.7L567.5,313.9L568.4,311L569.3,309.9L568.8,307.3L569.4,304.7L569.9,303.9L569.3,301.2Z","Malawi"],"458":["MY","M749.6,250.8L750.1,250.3L752.3,251.6L752.6,253.2L754.4,252.9L755.2,251.6L755.8,251.9L757.5,253.8L758.7,255.9L759,258L758.7,259.4L759,260.5L759.3,262.3L760.2,263.2L761.3,265.9L761.3,267L759.4,267.2L756.8,264.9L753.6,262.4L753.2,260.8L751.6,258.7L751.1,256.1L750.1,254.4L750.3,252.2ZM797.9,258.1L795.6,257.6L792.5,257.6L791.7,261.1L790.6,262.2L789.3,266.6L787.2,267.2L784.6,266.3L783.3,266.6L781.7,268.2L780,268L778.3,268.6L776.4,266.8L775.9,264.8L777.9,265.8L780,265.2L780.5,262.6L781.6,262L784.9,261.3L786.7,258.9L788,256.9L789.2,258.5L789.8,257.4L791.1,257.5L791.1,255.5L791.2,254L793.1,251.8L794.4,249.4L795.4,249.4L796.9,251L797.1,252.3L799,253.2L801.2,254.1L801.1,255.4L799.3,255.5L799.9,257Z","Malaysia"],"466":["ML","M449.1,232.1L449.3,231.2L449.1,230L448.1,229.1L447.6,227.3L447.5,225.3L448.4,224.8L448.9,222.9L449.7,222.8L451.6,223.7L453.1,223.1L454.1,223.3L454.5,222.6L465.2,222.6L465.8,220.4L465.4,220L464.2,206.5L463.1,192.9L467.1,192.8L475.9,199.7L484.8,206.5L485.5,208L487.1,208.9L488.3,209.4L488.4,211.4L491.3,211.1L491.4,218.3L489.9,220.4L489.7,222.4L487.3,222.9L483.7,223.1L482.7,224.2L481,224.4L479.3,224.4L478.6,223.8L477.1,224.2L474.7,225.5L474.1,226.5L472.1,227.9L471.7,228.7L470.6,229.3L469.3,228.9L468.5,229.7L468.1,231.8L466,234.4L466.1,235.5L465.3,236.8L465.5,238.6L464.4,239.1L463.7,239.5L463.3,238.1L462.6,238.5L462.1,238.4L461.6,239.3L459.5,239.3L458.8,238.8L458.4,239.1L457.6,238.2L457.8,237.3L457.4,236.9L456.9,237.2L457,236.2L457.5,235.4L456.4,234.1L456.1,233.3L455.5,232.6L455,232.5L454.4,232.9L453.5,233.3L452.7,234L451.6,233.8L450.9,233L450.4,232.9L449.7,233.3L449.3,233.3Z","Mali"],"478":["MR","M434.9,205.3L435.5,204.3L445.8,204.3L445.4,199.8L446.1,198.1L448.6,197.9L448.7,189.8L457.3,190L457.4,185.2L467.1,192.8L463.1,192.9L464.2,206.5L465.4,220L465.8,220.4L465.2,222.6L454.5,222.6L454.1,223.3L453.1,223.1L451.6,223.7L449.7,222.8L448.9,222.9L448.4,224.8L447.5,225.3L445.7,223.2L444.2,220.9L442.4,220.1L441.2,219.1L439.7,219.2L438.4,219.8L437,219.6L436.1,220.6L435.9,218.9L436.7,217.3L437.1,214.4L436.9,211.3L436.6,209.7L436.9,208.2L436.2,206.7Z","Mauritania"],"484":["MX","M179.8,169.1L182.8,168.8L186.2,168.5L185.7,169.1L189.1,170.6L194.3,172.8L199.5,172.8L201.5,172.8L201.9,171.5L206.3,171.5L207,172.6L208,173.6L209.2,175L209.6,176.7L209.8,178.4L210.9,179.3L212.8,180.3L215,177.8L217.2,177.7L218.7,179L219.4,181.1L219.9,183L221,184.8L221.1,187L221.5,188.5L223.3,189.4L225,190.1L226.1,190L224.5,192.8L223.6,195L222.6,199.3L222.1,200.8L222.2,202.5L222.8,204L222.9,206.5L224.3,208.8L224.6,210.6L225.4,212.1L228.1,213L229,214.3L231.5,213.4L233.6,213.1L235.6,212.5L237.4,212L239.3,210.7L240.2,208.9L240.8,206.2L241.4,205.3L243.3,204.5L246.2,203.8L248.5,203.9L250.2,203.6L250.7,204.3L250.4,205.8L248.7,207.7L247.8,209.6L248.2,210.1L247.6,211.5L246.6,213.9L246,213.1L245.5,213.2L245,213.2L243.8,215.1L243.3,214.7L243,214.9L243,215.3L240.5,215.3L238,215.3L237.8,217.1L236.6,217.1L237.4,218.1L238.3,218.9L238.6,219.5L239,219.7L238.8,220.8L235.3,220.8L233.8,223.3L234.1,223.9L233.7,224.7L233.5,225.6L230.9,222.2L229.6,221.2L227.5,220.4L226,220.6L223.7,221.8L222.4,222.1L220.6,221.3L218.6,220.7L216.3,219.2L214.4,218.8L211.6,217.3L209.6,215.8L209,215L207.6,214.8L205,213.8L204.1,212.4L201.6,210.6L200.6,208.6L200.2,207.1L201.1,206.8L201,205.9L201.8,205.1L202,204L201.4,202.6L201.4,201.3L200.8,199.8L199.1,196.6L197,194.2L196.1,192.2L194.2,190.9L193.9,190.2L194.7,188.2L193.6,187.5L192.4,186L192.3,183.8L191,183.5L189.9,181.9L189.1,180.3L189.3,179.3L188.6,177L188.3,174.6L188.7,173.4L187.2,172.1L186.3,172.2L185.1,171.4L184.3,172.7L184.3,174.2L183.9,176.5L184.4,177.8L185.7,180L185.9,180.7L186.2,181L186.3,182L186.8,182L186.8,184L187.3,184.8L187.6,185.9L188.8,187.5L189,190.5L189.5,191.8L189.9,193.3L189.6,195L190.9,195.1L191.6,196.5L192.3,197.9L192.1,198.5L190.7,199.6L190.3,199.6L190,197.7L188.7,195.9L187.1,194.4L185.9,193.6L186.5,191.3L186.6,189.6L185.6,188.6L184.1,187.2L183.7,187.6L183.2,186.8L181.8,186L180.7,184.2L181,184L182,184.1L183.3,183L183.8,181.5L182.4,179.3L181.1,178.4L180.7,176.5L180.4,174.4L180,171.9Z","Mexico"],"496":["MN","M688.4,117L690.7,116.5L694.1,113.9L697.1,112.5L699.5,113.4L702,113.4L704.2,114.9L706.6,115L710.4,115.7L711.7,113.6L710,111.8L710.9,108.7L714.1,110L716.4,110.3L719.6,111.1L721.1,113.4L725.1,114.6L727,114.1L729.8,113.7L732.4,114.1L735.4,115.5L737.6,117.1L739.8,117L743.1,117.5L744.9,116.8L747.7,116.3L750.1,114.2L751.7,114.5L753.4,115.5L756.1,115.2L756.2,117.5L756.1,120.6L757.3,121.8L758.5,121.4L761.1,121.9L762.4,120.8L764.8,121.7L768.1,123.9L768.4,125L766.3,124.6L763,125L761.7,125.9L760.9,127.9L757.8,129.1L756.1,130.8L753.3,130.1L751.9,129.8L751.5,131.8L752.8,133L753.6,134L752.4,135.1L751.3,136.7L748.9,137.8L745.2,137.9L741.7,139L739.5,140.7L738,139.7L735,139.7L730.6,137.8L728,137.4L724.9,137.8L719.6,137.1L716.9,137.2L714.8,135.4L712.6,132.5L711,132.2L707.3,130.2L703.9,129.8L700.8,129.3L699.4,127.9L699,124.4L696.4,121.9L692.5,120.8L689.9,119.1Z","Mongolia"],"498":["MD","M543.6,120.3L544.1,119.8L545.7,119.5L547.5,120.5L548.6,120.6L549.7,121.4L549.7,122.5L550.6,123L551.1,124.2L552.1,125L552,125.5L552.5,125.8L551.8,126L550.4,125.9L550.1,125.5L549.6,125.7L549.9,126.3L549.3,127.3L549,128.3L548.5,128.7L547.9,127.3L548,125.9L547.7,124.6L546.1,122.8L545.2,121.5L544.4,120.6Z","Moldova"],"499":["ME","M529.4,137.6L528.7,137.9L528.5,137.3L527.6,138.8L527.8,139.8L527.3,139.6L526.5,138.6L525.4,138L525.7,137.4L525.9,135.7L526.6,135L527.1,134.7L527.8,135.3L528.2,135.7L529,136L530,136.7L529.8,136.9Z","Montenegro"],"504":["MA","M474.5,160.8L475.4,162.8L475.6,164.7L476.4,168L477.1,168.7L476.6,169.9L473.3,170.4L472.1,171.6L470.6,171.9L470.5,174.2L467.5,175.5L466.5,177L464.3,177.9L461.7,178.4L457.5,180.7L457.5,184.4L457.1,184.4L457.1,186.1L455.5,186.2L454.6,186.9L453.4,186.9L452.5,186.5L450.3,186.8L449.4,189.3L448.6,189.5L447.2,193.5L443.5,196.9L442.5,201.2L441.4,202.6L441,203.8L435.1,204L435.1,204L435.2,202.5L436.3,201.7L437.2,200.1L437,199L438,196.8L439.5,194.8L440.4,194.3L441.2,192.4L441.3,190.8L442.3,188.8L444.1,187.7L445.8,184.5L445.9,184.4L447.2,183.2L449.6,182.9L451.7,180.7L453.1,179.9L455.3,177.2L454.7,173.3L455.8,170.6L456.2,169L457.9,166.8L460.5,165.4L462.4,164.1L464.1,160.9L465,158.9L466.8,159L468.3,160.3L470.8,160.1L473.4,160.8Z","Morocco"],"508":["MZ","M572.7,307L574.7,306.8L577.9,307.6L578.6,307.2L580.5,307.2L581.5,306.2L583.1,306.3L586.1,305.1L588.3,303.2L588.7,304.7L588.4,307.8L588.7,310.5L588.6,315.4L589,316.9L588,319.2L586.9,321.4L585.1,323.3L582.6,324.5L579.5,326L576.3,329.4L575.3,329.9L573.3,332.2L572.2,332.9L571.8,335.1L572.9,337.5L573.3,339.4L573.3,340.3L573.8,340.1L573.5,343.2L573,344.7L573.6,345.2L573.1,346.5L571.9,347.6L569.7,348.7L566.4,350.4L565.2,351.6L565.3,352.9L566,353.1L565.6,354.8L563.6,354.7L563.5,353.3L563.2,351.9L563.1,350.8L563.8,347.3L563.2,345.1L562.2,340.6L565.2,337.1L566,334.8L566.5,334.5L566.9,332.7L566.5,331.8L566.7,329.4L567.3,327.2L567.5,323.3L566.2,322.3L564.9,322L564.4,321.3L563.2,320.6L560.9,320.7L560.8,319.5L560.6,317.3L568.8,314.7L570.3,316.2L571.1,315.9L572.1,316.7L572.2,317.9L571.6,319.4L571.7,321.6L573.3,323.5L574.2,321.4L575.4,320.7L575.4,316.7L574.3,314.4L573.4,313.4L572.5,313.5L571.9,309.4Z","Mozambique"],"512":["OM","M625.4,200L625.3,198.7L626,197.4L625.8,196.1L627,195.5L626.4,195.1L626.4,193L627.8,193L629.2,195.1L630.8,196.3L632.8,196.7L634.4,197.3L635.8,199.1L636.6,200.1L637.6,200.5L637.7,201.2L636.9,203.1L636.6,204L635.6,205L634.8,207.1L633.6,207L633.1,207.7L632.8,209.3L633.3,211.4L633.1,211.8L631.9,211.8L630.3,212.9L630.2,214.5L629.7,215.1L628,215.1L627,215.9L627.1,217.2L625.9,218L624.4,217.7L622.7,218.8L621.5,219L620.5,216.8L618,211.6L625.7,208.5L626.8,202.2ZM627.1,190.5L626.5,189.4L627.1,188.4L627.5,188.6L627.4,189.9Z","Oman"],"516":["NA","M532.1,348.6L531.6,360.2L529.3,361.8L527.8,362L526.2,361.4L525.1,361.2L524.7,359.8L523.7,359L522.4,360.5L520.6,358.2L519.6,355.9L519.2,352.8L518.6,350.5L517.9,345.7L517.9,341.9L517.6,340.2L516.6,338.9L515.3,336.3L514,332.6L513.5,330.6L511.4,327.5L511.2,325.1L512.5,324.5L514.1,324L515.8,324.1L517.4,325.5L517.8,325.3L528.6,325.1L530.4,326.6L536.8,327.1L541.8,325.8L544,325.1L545.7,325.3L546.7,326L546.7,326.2L545.2,326.9L544.4,327L542.6,328.2L541.7,326.9L537.5,328L535.6,328.1L535.1,339.3L532.5,339.4Z","Namibia"],"524":["NP","M709.1,183.7L709.2,185.1L709.9,187.1L709.9,188.3L707.7,188.4L704.4,187.6L702.3,187.3L700.5,185.7L696.9,185.3L693.2,183.6L690.4,182L687.7,180.8L688.1,177.9L689.5,176.5L690.4,175.7L692.6,176.7L695.7,178.7L697.2,179.2L698.4,180.7L700.5,181.3L702.9,182.7L706,183.4Z","Nepal"],"528":["NL","M496,104.5L496.4,105.5L496,108.2L495.4,109.3L494,109.3L494.5,112.5L493.2,111.8L491.7,110.5L489.5,111.1L487.8,110.8L489,110L490.9,105.6L494.1,104.4Z","Netherlands"],"540":["NC","M918.1,337L919.7,338.9L920.7,340.4L919.5,341.1L918.3,340.3L916.8,338.8L915.6,337.2L914.4,335L914.4,333.9L915.5,334L916.7,335L917.5,336.1Z","New Caledonia"],"548":["VU","M926,320.7L927.3,322.5L926.3,322.9L925.8,321.5ZM925,320L924.9,319.1L925.3,316.7L926.4,317.7L926.3,320.2L925.6,319.8Z","Vanuatu"],"554":["NZ","M920.3,396.6L918.3,398.3L915.7,400.4L913,401.6L913.1,400.8L912.4,400.4L915.4,397.8L915.6,396.1L913.7,394.8L914.5,393.7L916.9,392.6L918.7,390.2L919.8,388.2L919.9,386.1L920.3,385.5L919.8,384.2L919.3,381.5L919.3,379.2L920.4,379L920.9,380.7L922.5,381.6L921.7,384.3L921.7,387.6L922.9,385.5L923.6,386.4L922.6,388.7L924.1,389.7L925.6,390L927.8,388.8L928.8,389.2L926.6,391.9L924.7,393.8L922.8,393.7L921.6,394.6L921,396ZM895.5,407.4L898.7,405.8L901.2,404.2L903.8,401.9L905.2,401.1L906.7,399.3L909.3,397.9L909,399.2L908.8,400.5L911.3,399.3L911.2,400.6L910.4,401.9L908.5,403.3L905.4,405.6L903.3,406.9L903.3,408.3L901.3,408.4L898.5,409.5L896.4,411.6L892.9,414.7L890,416L888.2,416.9L886,416.9L885.1,415.8L882.7,415.6L883,414.5L885.9,412.2L891,409.2L893,408.6Z","New Zealand"],"558":["NI","M255.5,236.8L254.8,237.5L254,237.3L253.6,236.7L252.8,236.4L252.1,236.8L250.4,236L250,236.4L249.1,235.4L248,234.1L247.5,233.1L246.4,232.1L245.2,230.7L245.5,230.2L245.9,230.7L246.2,230.4L247,230.3L247.4,229.6L247.8,229.6L247.9,228L248.5,228L249.1,228L249.7,227.1L250.5,227.8L250.8,227.4L251.3,227L252.3,226.2L252.4,225.5L252.7,225.5L253.1,224.8L253.4,224.7L253.8,225.2L254.3,225.3L255,224.9L255.6,224.9L256.6,224.5L257,224.1L257.9,224.1L257.7,224.4L257.5,225.2L257.6,226.3L256.9,227.4L256.5,228.6L256.3,230L256.4,230.8L256.3,232.2L255.9,232.5L255.5,233.9L255.6,234.7L255,235.5L255.1,236.3Z","Nicaragua"],"562":["NE","M519.1,199.5L519.9,204.4L520.9,205.2L521,206.2L522.1,207.2L521.6,208.6L520.7,215L520.6,219L517.3,222L516.2,226.1L517.3,227.3L517.4,229.3L519.1,229.4L518.8,230.8L518.1,231L518,232L517.5,232.1L515.6,228.7L515,228.5L512.9,230.3L510.9,229.4L509.4,229.2L508.6,229.6L507.1,229.5L505.5,230.9L504.1,230.9L500.9,229.3L499.6,230.1L498.3,230L497.3,228.9L494.6,227.7L491.7,228.1L491,228.7L490.6,230.5L489.9,231.8L489.7,234.6L487.6,232.8L486.7,232.8L485.8,233.7L485.8,231.6L482.7,230.9L482.7,229.3L481.2,227.3L480.8,225.9L481,224.4L482.7,224.2L483.7,223.1L487.3,222.9L489.7,222.4L489.9,220.4L491.4,218.3L491.3,211.1L495.1,209.7L502.6,203.6L511.6,197.6L515.7,198.9L517.3,200.6Z","Niger"],"566":["NG","M487.3,251.5L487.4,246.4L487.3,244.4L487.8,242.5L488.7,241.5L490,239.6L489.7,238.7L490.2,237.5L489.6,235.6L489.7,234.6L489.9,231.8L490.6,230.5L491,228.7L491.7,228.1L494.6,227.7L497.3,228.9L498.3,230L499.6,230.1L500.9,229.3L504.1,230.9L505.5,230.9L507.1,229.5L508.6,229.6L509.4,229.2L510.9,229.4L512.9,230.3L515,228.5L515.6,228.7L517.5,232.1L518,232L519.1,233.3L518.8,233.8L518.7,234.9L516.4,237.3L515.7,239.3L515.4,240.9L514.8,241.6L514.3,243.8L512.9,245.1L512.5,246.7L511.9,247.9L511.6,249.2L509.8,250.3L508.3,249L507.2,249L505.7,250.9L504.9,250.9L503.6,253.9L502.9,256.1L500.1,257.2L499.1,257.1L498.1,257.8L495.9,257.7L494.5,255.8L493.6,253.5L491.7,251.4L489.6,251.5Z","Nigeria"],"578":["NO","M507.8,34.3L508.3,33.5L511,33.4L513.4,34.2L519.9,35.9L515.4,36.8L514.6,38.5L513.1,38.9L512.5,40.9L510.2,41L505.9,39.5L507.5,38.7L504.6,38L500.8,36.1L499.2,34.3L504,33.5L505.2,34.3ZM543.5,59.2L540.2,60.3L538.6,60.5L539.1,58.7L536.3,57.6L533.3,58.5L532.6,60.5L530.9,61.6L528.6,61L525.9,61.1L523.4,59.7L522.3,60.4L521,60.5L521,62.3L517,61.9L516.7,63.3L514.7,63.3L513.5,65.3L511.8,68.3L508.8,72.1L509.7,73L509,74.1L506.9,74.1L505.7,76.7L506.1,80.4L507.6,81.8L507.2,85.2L505.5,87.1L504.6,88.8L503,87L498.8,90.3L495.8,91L492.7,89.5L491.8,86.5L490.9,79.9L492.8,78.1L498.4,75.8L502.5,72.9L506,69.1L510.6,63.9L513.8,61.9L519,58.6L523.3,57.4L526.7,57.5L529.4,55.4L533.1,55.5L536.6,55L543.3,56.9L540.9,57.6ZM530,33.4L527.6,34.6L522.4,34.9L516.9,34.5L516.4,33.9L513.8,33.9L511.6,32.8L517,32.2L519.8,32.8L521.5,32.1L526.2,32.7ZM526.3,38.4L522.4,39.4L518.9,38.8L520.1,38.2L518.8,37.5L522.6,37L523.5,37.9Z","Norway"],"586":["PK","M677.4,159.8L675.5,162.4L672.8,162.9L668.8,162.1L667.8,163.5L669.3,166.2L670.7,168.3L673,169.9L671.2,171.7L671.7,174L669.8,177.1L668.7,180.3L666.6,183.6L663.5,183.4L661.2,186.7L663.1,188.1L663.8,190.5L665.5,192.1L666.4,194.8L660.6,194.8L659.2,196.9L657.1,196.1L656,193.8L653.7,191.4L648.9,192L644.7,192.1L641.1,192.5L641.6,188.9L645.1,187.2L644.7,185.8L643.4,185.3L642.9,182.5L640.2,181.1L638.9,179.2L637.4,177.6L641.9,179.2L644.5,178.7L646.1,179.1L646.5,178.4L648.3,178.7L651.5,177.4L651.1,174.7L652.2,172.9L654.2,172.9L654.3,172.1L656.2,171.6L657.2,171.9L658,171.1L657.5,169.2L658.2,167.3L659.7,166.5L658.3,164.4L660.7,164.5L661.2,163.4L660.8,162.2L661.8,160.8L661.2,159.3L660.3,158L661.5,156.6L664,155.9L666.9,155.6L668,155L669.4,154.6L671.6,156.1L672.9,158.5Z","Pakistan"],"591":["PA","M271.9,243.9L271.6,244.4L272.1,246.2L271.6,247.2L270.7,246.9L270.3,248.5L269.4,247.6L268.9,245.9L269.6,245L269,244.8L268.5,243.8L267.2,242.9L266.1,243.1L265.5,244.2L264.3,245L263.7,245.1L263.4,245.8L264.6,247.4L263.9,247.8L263.5,248.3L262.2,248.5L261.8,246.6L261.5,247.1L260.6,246.9L260.1,245.7L259,245.5L258.3,245.1L257.2,245.1L257.1,245.8L256.8,245.3L256.9,244.7L257.2,244.1L257.1,243.5L257.6,243.1L257,242.7L257.1,241.4L258.1,241.1L259,242.3L258.9,242.9L260,243.1L260.3,242.8L261,243.6L262.3,243.4L263.5,242.6L265.2,241.9L266.1,241L267.6,241.2L267.5,241.5L269,241.6L270.2,242.1L271,243.1Z","Panama"],"598":["PG","M860.5,279.1L865.1,281.3L870,283.1L871.8,284.7L873.2,286.2L873.5,288.1L877.8,290L878.4,291.7L875.9,292L876.3,294.1L878.5,296.1L879.9,299.5L881.5,299.4L881.2,300.7L883.2,301.3L882.3,301.9L885,303.2L884.6,304.1L882.8,304.3L882.3,303.5L880,303.1L877.3,302.7L875.5,300.7L874.1,299L873,296.2L869.6,294.8L867.3,295.7L865.5,296.8L865.6,299.1L863.4,300.2L862,299.6L859.2,299.5L860,289.3ZM891.7,282.4L892.7,283.4L893,285.1L892.1,285.9L891.7,284.1L891.1,282.9L889.9,281.8L888.4,280.5L886.5,279.6L887.3,278.8L888.7,279.7L889.6,280.4L890.7,281.1ZM887.7,289.3L886.2,290L884.8,290.8L883.3,290.7L881.2,289.8L879.7,289L880,288L882.4,288.5L883.9,288.2L884.4,286.7L884.8,286.6L884.9,288.3L886.5,288.1L887.3,287L888.9,285.9L888.7,284L890.3,284L890.8,284.5L890.7,286.2L889.7,288.1L888.2,288.4ZM897.2,287.7L897.9,288.4L899.1,290.4L900.3,291.4L899.8,292.3L899,292.6L898,291.4L897,289.4L896.5,287.1L896.9,286.8Z","Papua New Guinea"],"600":["PY","M326,334.1L326.9,335.9L327.2,340.1L330,340.7L331.1,340.1L332.9,341L333.5,341.9L334.1,344.8L334.5,346L335.5,346.1L336.4,345.6L337.4,346.2L337.6,347.9L337.5,349.8L337.2,351.6L337.1,354.4L335,356.8L333,357.3L330,356.8L327.3,356L329.2,351.2L328.7,349.8L325.9,348.6L322.4,346.2L320.2,345.8L314.7,340.6L315.4,336.9L315.3,335.2L316.2,332.4L320.8,331.5L323.2,331.6L325.9,333.2Z","Paraguay"],"604":["PE","M291.5,284.4L289.1,284.3L288.7,284.8L286.5,285.4L283.5,287.5L283.4,288.9L282.7,290L283,291.7L281.5,292.6L281.5,293.9L280.8,294.5L282.1,297.3L283.7,299.2L283.2,300.6L285,300.8L286.1,302.4L288.4,302.5L290.6,300.7L290.7,305.4L291.9,305.8L293.4,305.2L296,310.3L295.5,311.3L295.6,313.5L295.7,316.2L294.8,317.8L295.4,318.9L294.9,320L296.2,322.6L294.9,326L294.3,327.6L293,328.4L290.2,326.6L289.8,325.3L284.2,322.2L279.1,318.7L276.9,316.8L275.6,314.2L275.9,313.3L273.3,309.2L270.3,303.4L267.4,297.2L266.2,295.8L265.2,293.5L263,291.4L261.1,290.2L261.9,288.8L260.5,285.8L261.3,283.6L263.4,281.7L263.7,283L263,283.7L263.1,284.8L264.2,284.6L265.3,284.9L266.5,286.5L267.9,285.2L268.4,283.1L270,280.4L273.2,279.2L276.1,275.9L276.9,273.9L276.6,271.5L277.3,271.2L279.1,272.7L279.9,274.2L281.2,275L282.8,278.2L284.8,278.6L286.3,277.8L287.3,278.3L288.9,278.1L291,279.5L289.3,282.7L290.1,282.8Z","Peru"],"608":["PH","M803.7,231.3L802,228.9L804.3,229.1L805.4,230.2L805,232.9ZM809.3,239.8L809.9,239L810,237L811.5,236.8L811.3,238.9L812.9,235.9L813,238.9L812.1,239.9L811.5,241.9L810.7,242.8L808.9,240.7ZM820,244.7L820.4,246.8L820.7,248.6L820,251.4L818.8,248.2L817.6,249.8L818.7,252.1L818,253.6L814.7,251.8L813.8,249.5L814.5,248L812.7,246.6L811.9,247.8L810.7,247.7L808.8,249.5L808.3,248.6L809.1,245.9L810.8,245L812.1,243.9L813.2,245.3L815.2,244.4L815.5,243L817.4,243L817,240.5L819.3,242L819.7,243.6ZM798.6,241.9L795.2,244.9L796.4,242.7L798.1,240.8L799.6,238.6L800.6,235.5L801.4,238.1L799.8,239.8ZM805.1,214L804.9,215.3L806.2,217.6L805.9,220.2L804.5,221.2L804.5,223.7L805.4,226.2L806.9,226.6L808,226.2L811.6,228L811.6,229.7L812.5,230.4L812.5,231.8L810.2,230.3L809,228.7L808.4,229.8L806.5,227.9L804.1,228.4L802.7,227.7L802.6,226.4L803.4,225.6L802.5,224.9L802.3,226L800.7,224.2L800.1,222.9L799.5,219.9L800.8,220.9L800.3,216L800.6,213.2L802.2,213.2L804,214.1L804.7,213.2ZM807.4,235.4L806.8,233.9L808.5,234.8L810.2,234.8L810.3,236.1L809.2,237.5L807.6,238.4L807.4,236.9ZM816.4,233L817.6,236.5L815.4,235.7L815.6,236.7L816.5,238.7L815.2,239.4L814.9,237.2L814.1,237L813.5,235.1L815.1,235.4L814.9,234.2L813,231.8L815.5,231.9Z","Philippines"],"616":["PL","M534.2,103.2L534.5,104.5L535.2,105.6L535.4,106.8L534,107.4L534.9,108.8L535.1,110.1L536.6,112.8L536.4,113.6L535.3,114L533.4,116.5L534.2,117.8L533.6,117.7L531.3,116.5L529.6,116.9L528.4,116.6L527.1,117.3L525.8,116.2L524.9,116.6L524.7,116.4L523.5,114.9L521.7,114.7L521.4,113.8L519.8,113.5L519.5,114.2L518.2,113.6L518.2,112.8L516.5,112.5L515.3,111.6L514.2,109.6L514.3,108.6L513.6,107L512.7,106L513.3,105.2L512.6,103.7L514.1,102.8L517.6,101.4L520.4,100.4L522.8,100.9L523,101.6L525.2,101.7L528.1,102L532.3,102L533.5,102.3Z","Poland"],"620":["PT","M457.7,139.8L458.6,139L459.6,138.6L460.2,140.1L461.7,140.1L462.1,139.7L463.5,139.8L464.2,141.4L463,142.2L462.9,144.6L462.5,145.1L462.4,146.6L461.3,146.8L462.3,148.7L461.5,150.8L462.4,151.7L462,152.5L461,153.7L461.2,154.7L460.2,155.6L458.9,155.1L457.6,155.5L458,153L457.8,151.1L456.7,150.8L456.1,149.6L456.4,147.6L457.4,146.4L457.7,145.2L458.2,143.3L458.2,142L457.8,140.9Z","Portugal"],"624":["GW","M435.3,232.3L436.7,231.8L437.6,231.9L438.3,231.6L443.3,231.7L443.2,232.8L442.9,233.1L443.1,234.1L442.7,234.5L442.1,234.5L441.4,235.1L440.6,235L439.4,236.5L438,235.2L436.8,235L436.3,234.1L436.3,233.7L435.5,233Z","Guinea-Bissau"],"626":["TL","M816.1,298.8L816.4,298.1L818.8,297.4L820.7,297.2L821.6,296.9L822.6,297.2L821.5,298.1L818.6,299.5L816.2,300.4L816.3,299.4Z","Timor-Leste"],"630":["PR","M304,213.1L305.3,213.4L305.7,214L305,214.8L303,214.8L301.4,214.9L301.4,213.6L301.8,213.1Z","Puerto Rico"],"634":["QA","M613.2,193.5L612.8,191.2L613.3,189.6L614,189.3L614.9,190.2L615.1,192.1L614.7,193.9L614,194.2Z","Qatar"],"642":["RO","M548.5,128.7L549.6,129.2L550.7,128.7L551.9,129.3L552,130.1L550.9,130.7L550.1,130.4L549.9,134.2L548.4,133.8L546.5,132.7L543.7,133.4L542.6,134.2L539,134L537,133.6L536.1,133.8L535.3,132.5L534.8,132L535.3,131.5L534.7,131.1L534,131.8L532.5,130.9L532.2,129.6L530.6,128.9L530.3,127.9L528.9,126.7L530.8,126.1L532,124L533,122L534.4,121.3L535.3,120.7L536.9,121L538.4,121L539.6,121.8L540.3,121.3L542.1,121L542.6,120.3L543.6,120.3L544.4,120.6L545.2,121.5L546.1,122.8L547.7,124.6L548,125.9L547.9,127.3Z","Romania"],"643":["RU","M648.9,31.3L652.2,30.9L656.9,31.9L663.4,34L665,36.1L661.3,36.3L655.5,35.7L651.6,34.8L648.6,33.2L645.7,32.8ZM669.5,35.1L675.5,36.4L675.9,37.4L666.2,38.3L666.7,35.3L667.9,35ZM745.3,42.5L750.5,42.6L759,43.9L759.7,45.7L752.4,45.7L749.9,46.3L744.2,44.7L743.3,43ZM765.7,44.5L771.3,45.1L770.3,46.1L766.9,45.9L762.1,44.9L761.6,44.1ZM755.1,49.4L755.9,48.4L758.1,48.2L761.9,49.1L762.9,49.8L760,49.8L755.6,49.5ZM561.2,32.3L564.6,31.9L567.3,31.8L568,32.4L568.7,31.9L570.2,31.6L573.2,32L572.7,32.4L570.4,32.6L568.9,32.8L568.8,33.2L566.9,33.5L564.6,33L565.3,32.3ZM532.3,102L528.1,102L525.2,101.7L525.6,100.4L528.7,99.4L531.1,99.9L532.2,100.4L532,101.2ZM584.9,48.4L588.6,46.2L587.5,45.1L591.2,43.8L596.7,42.2L602.9,41.8L605.6,40.9L609.1,40.6L611,41.5L610.2,42.3L604.1,43.5L598.8,44.7L593.9,47L592.1,49.5L590.1,51.9L591.4,54.1L596.1,56.2L595,56.4L588.3,56.1L587.3,54.9L583.4,54.2L582.6,52.8L584.4,52.3L583.8,50.9L586.8,48.7ZM810.3,103.8L813.1,106.7L815.1,109.6L818.2,112.6L824.2,118L820,117L821.3,121.4L825.6,124.5L826.8,126.7L823.9,124.8L823.7,127.2L821.7,124.6L820.2,121.6L817.8,118.4L816.9,116.1L814.3,112L810.9,109.1L808.3,105L809.4,103.6L807.5,102.3L808.2,101.8ZM110.8,60.8L110.8,60.8L113.3,62.8L115.5,65.5L113.3,67.2L113.9,67.9L115.8,65.9L121,66.3L122.2,68.8L118.7,70L115,70.3L111.9,73L110.4,73.6L108.5,73.5L107.9,72.5L106,71.7L106.9,70.5L105.3,70.1L102.5,70.4L102.4,69.5L104.1,68.5L100.8,69.1L100.2,70.4L97.7,71.6L97.7,71.6L110.8,60.8ZM862.3,71.6L862.3,71.6L861,72.8L858,72.6L861.6,74.1L865.5,76.3L867.3,77.1L868.8,78.2L869.1,79L864.4,78.4L860.6,80.5L859,80.8L857.7,82.8L856.3,84.5L856.8,85.8L851.7,83.9L848.2,86.1L846.1,85L845.2,86.3L841.8,85.9L842.9,87.7L842.8,90.5L844,91.7L847.1,92.3L850.6,96.6L848.6,96.7L849.8,99.1L851.8,100.4L849,101.9L851,105.3L848.1,106L849.8,109.1L848.6,111.8L846.1,109.8L841.8,105.4L835.2,98.9L832.9,94.8L833.3,93.1L832.2,91.7L835.1,91.1L835.8,87.4L836.9,84.5L838.6,82.3L836.4,78.3L834,78.5L835,80.8L832.5,83.9L827.3,80.5L822.6,81.4L821.5,86.2L824.9,87.9L820.6,88.7L817.4,89L815.8,86.9L811.9,86.5L810.4,87.9L803.2,87.4L796.6,88.2L793.8,93.9L790.1,100.8L794,101.1L796.5,103L799.2,103.7L799.6,102.2L802.3,102.4L807.9,105.6L809.8,108.2L810,111.2L812.2,114.8L814.2,119.6L813.3,124L813.8,126.1L812.5,129.7L811.2,133.3L810.6,135.1L808.2,136.9L806.7,137L804.4,135.5L802.2,137.7L802.3,138.8L802.3,138.8L801.7,138.2L800.9,136.6L802.2,136.6L800.6,132.9L798.6,130.3L800.1,129.2L803.4,129.7L803.3,126.7L802.3,123.4L802.5,122.3L802.2,119.5L798.8,120.4L797.4,121.6L793.7,121.6L791.1,118.7L787,116.6L782.3,115.6L779.7,112.7L777.8,110.8L776.1,109.5L772.8,106.5L770,105.4L766,104.5L763,104.6L760.5,105.1L759.4,106.6L761.1,107.3L762.1,109L761.4,109.9L761.1,113.1L761.9,114.5L759.6,116.4L756.1,115.2L753.4,115.5L751.7,114.5L750.1,114.2L747.7,116.3L744.9,116.8L743.1,117.5L739.8,117L737.6,117.1L735.4,115.5L732.4,114.1L729.8,113.7L727,114.1L725.1,114.6L721.1,113.4L719.6,111.1L716.4,110.3L714.1,110L710.9,108.7L710,111.8L711.7,113.6L710.4,115.7L706.6,115L704.2,114.9L702,113.4L699.5,113.4L697.1,112.5L694.1,113.9L690.7,116.5L688.4,117L687.6,117.3L685.6,115.4L682.7,115.8L681.2,114.5L679.3,114L677.5,112.2L675.9,111.7L672.9,112.4L668.9,110.7L668.3,112.3L660.1,104.7L656.3,102.4L656.8,101.5L652.1,104.3L649.9,104.4L649.5,102.8L646.2,101.8L644,102.5L642.2,99.5L637.8,98.8L636.2,100.1L630.9,101.2L630,101.9L621.7,102.9L621,103.9L623.3,106L621.3,106.7L621.9,107.5L620.1,109L624.5,111.1L624.4,112.5L621,112.4L620.6,113.3L617.1,111.7L613.4,111.8L611.3,113L608.2,111.8L602.5,109.7L598.8,109.8L594.8,113.1L595,115.3L592.2,113.5L591,116.8L591.8,117.5L590.9,119.8L593.4,121.8L595.1,121.7L597.1,123.8L597.2,125.4L598.5,125.9L597.8,127.7L595.5,128.2L593.7,131.4L596.5,134.3L596.6,136.4L600,140L598.7,141.3L598.4,142.1L597.3,141.9L595.3,140L594.6,139.9L592.9,139.2L591.9,137.9L589.5,137.2L588.1,137.7L587.6,137.1L584,135.7L580.3,135.2L578.2,134.6L577.9,135L574.4,132.4L571.4,131.2L569.1,129.4L570.7,128.9L572.4,126.3L570.8,125.1L574.2,123.9L574,123.2L571.9,123.7L571.8,122.4L572.8,121.5L575.1,121.3L575.3,120.3L574.5,118.6L575.2,117L575,116.1L571.3,115.1L569.9,115.2L568.2,113.7L566.5,114.2L563.3,113.2L563.3,112.6L562.2,111.3L560.3,111.1L560,110.2L560.5,109.6L558.7,107.9L556.3,108.2L555.6,108L555.1,108.7L554.2,108.6L553.3,106.7L552.6,105.7L553,105.4L554.9,105.5L555.7,104.9L554.9,104.1L553.3,103.5L553.3,103L552.3,102.5L550.6,100.5L550.9,99.7L550.5,98.4L548.1,97.7L547,98L546.6,97.3L544,96.5L543,94.8L542.6,93.4L541.4,92.7L542.3,91.8L541.2,89.1L542.5,87.5L542.1,87L544.3,85.4L541.8,84.1L545.9,80.5L547.6,78.8L548.1,77.4L544.6,75.5L545.1,73.7L542.8,71.6L543.7,69.3L540.7,66.2L542.2,64.2L538.7,62.4L538.6,60.5L540.2,60.3L543.5,59.2L545.3,58.3L549.1,59.9L554.8,60.5L563.4,63.6L565.4,64.8L566,66.6L564.1,68.1L560.8,68.8L551,66.7L549.5,67.1L553.4,69L553.8,70.3L554.6,73.1L557.5,74L559.4,74.7L559.3,73.3L557.7,72.2L558.9,71.1L564.4,72.8L566,72.2L564.1,70.1L568.3,67.5L570.3,67.6L572.5,68.6L573.2,66.7L570.9,65.1L571.5,63.5L569.5,61.9L575.5,62.7L577.1,64.2L574.6,64.5L575.1,66L577,67L580.1,66.4L580,64.7L583.9,63.4L590.3,61.1L591.9,61.2L590.5,62.8L593.1,63.1L594.3,62.2L598.1,62.1L600.7,61L603.7,62.6L605.3,60.9L602.5,59.3L603.2,58.5L609.6,59.3L612.8,60.1L621.6,63.1L622.4,61.7L619.6,60.3L619.3,59.8L616.7,59.5L616.8,58.3L614.7,56.2L614.2,55.4L616.7,53L616.8,50.7L618,50.2L623.6,50.9L624.8,52.3L624.1,54.4L625.8,55.2L627.4,57.1L628.8,60.7L631.9,62.3L631.9,64.1L629.7,67.9L632.3,68.3L632.6,67.3L634.6,66.6L634.5,65.3L635.6,64L633.6,62.5L633.7,60.7L631.3,60.5L630.1,59.1L630.3,56.4L626.5,54.3L629.1,52.6L627.6,50.7L628.6,50.7L630.5,52.1L631.1,54.6L633.5,55.1L631.5,53.2L634.3,52.2L638.3,52.1L642.9,53.5L639.8,51.4L637.9,48.7L641,48.2L645.8,48.3L649.8,48L647.3,46.6L648.4,45L650.6,45L653.4,43.7L658.2,43.4L658.3,42.7L663.2,42.5L665.2,43.1L668.4,41.8L671.9,41.8L671.5,40.8L672.4,39.8L675.9,38.8L679.9,39.6L677.9,40.1L682.5,40.5L684.2,41.7L685.4,41.1L690.9,41.1L696.4,42.3L698.8,43.2L699.5,44.5L698.1,45.2L694.2,46.6L693.4,47.3L696.2,47.7L699.6,48.3L701,47.9L703.4,49.5L703.7,48.8L706.5,48.4L713.1,48.8L714.7,50L723.3,50.4L721.6,48.5L726.2,48.9L729.3,48.9L733.8,50.2L736.3,51.9L736.2,52.9L740.6,55L744.8,56L744.1,53.3L748.5,54.5L751.2,53.8L755.9,54.6L756.6,53.8L760.3,54.2L756.3,51.8L757.7,50.7L777.5,52.4L780.9,53.9L788.4,55.9L796,55.4L800.5,55.8L803.4,56.9L805.4,58.8L808.7,59.6L810.8,59L814.4,58.9L818.8,59.5L822.4,59.2L828.7,61.5L830.3,60.7L826.6,59L826,57.8L833.4,58.6L837.5,58.4L844.9,59.7L849.2,60.8L862.3,71.6ZM842.9,55.9L840.9,56L839.4,55.2L840.6,54.1L842.9,55.9ZM119.4,54.1L119.4,54.1L119.4,54.1L119.8,54L121.5,54L123.4,54.8L122.8,55.1L119.9,55.7L117.1,55.9L117.1,55.9L119.4,54.1ZM560.9,127.2L561.4,126.4L563.2,127.1L564,127.2L564.4,127.8L564.8,127.9L564.9,128.2L566.1,128.9L568.6,128.7L568.3,129.8L565.7,130.3L562.6,132.1L561.2,131.5L561.5,130.1L558.8,129.2L559.1,128.6L561.3,127.5Z","Russia"],"646":["RW","M562.1,274.6L563.2,276.3L563,278.2L562.2,278.6L560.8,278.4L560,280.1L558.3,279.9L558.6,278.2L558.9,277.9L559.1,276.1L559.8,275.2L560.5,275.5Z","Rwanda"],"682":["SA","M570.5,179.1L573.4,179.6L574.5,178.6L575,177.5L576.9,177L577.2,176L578,175.4L575.2,172.3L580.1,170.7L580.6,170.2L583.8,171.1L587.8,173.3L595.8,179.6L600.6,179.9L603,180.2L603.8,181.7L605.6,181.6L607,184.3L608.3,185L608.9,186.1L610.8,187.4L611.1,188.7L611,189.8L611.4,190.9L612.3,191.7L612.7,192.8L613.2,193.5L614,194.2L614.7,193.9L615.4,195.1L615.5,195.9L616.9,199L624.9,200.6L625.4,200L626.8,202.2L625.7,208.5L618,211.6L610.4,212.8L608.1,214.2L606.4,217.5L605.2,218L604.4,217L603.4,217.1L600.8,216.8L600.3,216.5L597.2,216.6L596.5,216.9L595.4,216.1L594.8,217.6L595.1,218.9L594,219.9L593.6,218.6L592.8,217.6L592.5,216.4L591,215.3L589.5,212.6L588.5,210.1L586.6,207.9L585.3,207.4L583.4,204.4L582.9,202.2L582.9,200.4L581.2,196.9L579.8,195.7L578.4,195L577.4,193.2L577.5,192.5L576.6,190.9L575.8,190.2L574.6,187.8L572.8,185.3L571.3,183.1L570,183.1L570.3,181.4L570.3,180.3Z","Saudi Arabia"],"686":["SN","M435.3,228.5L434.2,226.1L432.9,225L434.1,224.4L435.4,222.2L436.1,220.6L437,219.6L438.4,219.8L439.7,219.2L441.2,219.1L442.4,220.1L444.2,220.9L445.7,223.2L447.5,225.3L447.6,227.3L448.1,229.1L449.1,230L449.3,231.2L449.1,232.1L448.8,232.3L447.3,232.1L447.1,232.4L446.5,232.5L444.6,231.7L443.3,231.7L438.3,231.6L437.6,231.9L436.7,231.8L435.3,232.3L434.9,229.9L437.3,230L438,229.6L438.5,229.5L439.5,228.8L440.6,229.5L441.8,229.5L442.9,228.8L442.4,227.9L441.5,228.4L440.7,228.4L439.7,227.7L438.8,227.7L438.2,228.4Z","Senegal"],"688":["RS","M525.6,127.4L527.4,126.6L528.9,126.7L530.3,127.9L530.6,128.9L532.2,129.6L532.5,130.9L534,131.8L534.7,131.1L535.3,131.5L534.8,132L535.3,132.5L534.8,133.2L535.1,134.4L536.4,135.7L535.5,136.7L535.2,137.6L535.5,138L535.1,138.5L534,138.5L533.2,138.7L533.1,138.5L533.3,138.1L533.6,137.3L533.2,137.3L532.7,136.8L532.3,136.6L531.9,136.1L531.4,135.9L531,135.5L530.6,135.7L530.4,136.7L529.8,136.9L530,136.7L529,136L528.2,135.7L527.8,135.3L527.1,134.7L527.6,134.6L527.9,133.1L526.6,131.9L527.1,130.6L526.2,130.6L527.1,129.4L526.2,128.6Z","Serbia"],"694":["SL","M444.4,243.2L445.8,241.8L446.1,241L446.6,240.3L447.3,240.2L448,239.6L450.1,239.6L450.9,240.8L451.4,242.1L451.4,243L451.8,243.8L451.7,244.9L452.5,244.8L451.2,246.2L450,247.9L449.8,248.8L449.2,249.8L448.5,249.6L446.5,248.3L445.2,246.7L444.7,245.5Z","Sierra Leone"],"703":["SK","M533.6,117.7L533.1,118.5L532.7,119.7L532.2,120L529.6,119.1L528.8,119.3L528.3,120L527.2,120.3L527,120.2L525.8,120.6L524.9,120.7L524.8,121.3L522.8,121.7L521.9,121.4L520.6,120.6L520.3,119.5L520.4,119.2L520.7,118.5L521.8,118.5L522.6,118.2L522.6,117.9L523.1,117.8L523.2,117.1L523.7,117L524,116.4L524.7,116.4L524.9,116.6L525.8,116.2L527.1,117.3L528.4,116.6L529.6,116.9L531.3,116.5Z","Slovakia"],"704":["VN","M760.2,238.3L762.4,237L765.2,236.8L763.8,234.9L768.1,232.5L768,228.7L767.1,226.6L767.2,223.5L766.2,221.3L763.9,219.1L761.8,216.4L759,212.6L755.6,210.8L756.1,209.6L757.7,208.8L756.2,206.1L752.9,206.1L751.2,203.2L749.2,200.7L750.5,200L752.6,200L755.1,199.6L757,197.9L758.5,199.1L761,199.7L761,201.5L762.5,202.8L765.3,203.6L762.3,206.3L760.6,209.2L760.4,211.4L762.9,214.7L766,218.8L768.7,220.8L770.7,223.3L772.6,229.1L772.9,234.6L770.8,236.6L768,238.6L766,241.2L762.9,244.2L761.7,242.2L762.3,240Z","Vietnam"],"705":["SI","M513.3,125.5L515.3,125.8L516.5,125.1L518.6,125L519,124.5L519.4,124.5L520,125.5L518.1,126.4L517.9,127.6L517.1,127.9L517.2,128.8L516.2,128.7L515.4,128.2L515,128.7L513.3,128.6L513.8,128.3L513.1,127Z","Slovenia"],"706":["SO","M592.2,276.3L590.6,273.7L590.6,262.3L592.9,258.8L593.6,257.8L595.3,257.7L597.7,255.5L601.2,255.4L608.6,246L610.4,243.4L611.5,241.5L611.5,239.9L611.3,236.7L611.3,235.4L611.3,235.4L612.2,235.3L613.4,234.8L614.8,234.5L616,233.5L617,233.5L617.1,234.3L617,236.1L617.1,237.8L616.5,238.9L615.9,242.3L614.7,245.8L613.2,249.8L611,254.3L608.8,257.8L605.6,262.1L603,264.6L598.9,267.7L596.4,270.1L593.5,273.9L592.8,275.5Z","Somalia"],"710":["ZA","M522.4,360.5L523.7,359L524.7,359.8L525.1,361.2L526.2,361.4L527.8,362L529.3,361.8L531.6,360.2L532.1,348.6L532.8,349L534.3,352L533.9,353.9L534.5,355L536.3,354.7L537.7,353.3L539,352.4L539.7,350.9L541,350.1L542.1,350.5L543.3,351.4L545.4,351.5L547.2,350.8L547.5,349.8L548,348.3L549.5,348.1L550.3,346.9L551.3,344.8L553.8,342.5L557.6,340.1L558.7,340.2L559.9,340.7L560.8,340.3L562.2,340.6L563.2,345.1L563.8,347.3L563.1,350.8L563.2,351.9L561.9,351.4L561.2,351.6L560.9,352.5L560.1,353.7L560,354.8L561.5,356.5L563,356.1L563.6,354.7L565.6,354.8L564.8,357L564.3,359.7L563.5,361.1L561.6,362.7L561.1,363.1L559.9,364.7L559,366.3L557.4,368.6L554.2,371.8L552.3,373.7L550.2,375.2L547.5,376.4L546.1,376.5L545.8,377.4L544.2,376.9L542.9,377.5L540.2,376.9L538.6,377.3L537.6,377.2L534.9,378.4L532.7,378.9L531,380.1L529.9,380.1L528.9,379L528,379L527,377.6L526.8,378L526.5,377.2L526.7,375.3L525.9,373.2L526.8,372.6L526.8,370.2L525.3,367.3L524.1,364.6L524.1,364.6ZM555.1,361.7L554,360.8L552.8,361.4L551.3,362.6L549.8,364.6L551.6,367L552.5,366.7L553,365.7L554.5,365.2L555,364.2L555.9,362.7Z","South Africa"],"716":["ZW","M562.2,340.6L560.8,340.3L559.9,340.7L558.7,340.2L557.6,340.1L556,338.7L554,338.2L553.3,336.2L553.4,335.1L552.2,334.8L549.4,331.4L548.6,329.5L548.1,329L547.2,326.5L550.2,326.8L551,327.2L551.9,327.1L553.5,325.1L555.9,322.5L556.8,322.3L557.2,321.2L558.8,319.9L560.8,319.5L560.9,320.7L563.2,320.6L564.4,321.3L564.9,322L566.2,322.3L567.5,323.3L567.3,327.2L566.7,329.4L566.5,331.8L566.9,332.7L566.5,334.5L566,334.8L565.2,337.1Z","Zimbabwe"],"724":["ES","M461.2,154.7L461,153.7L462,152.5L462.4,151.7L461.5,150.8L462.3,148.7L461.3,146.8L462.4,146.6L462.5,145.1L462.9,144.6L463,142.2L464.2,141.4L463.5,139.8L462.1,139.7L461.7,140.1L460.2,140.1L459.6,138.6L458.6,139L457.7,139.8L457.9,137.6L456.9,136.3L460.5,134L463.5,134.6L466.7,134.6L469.3,135.1L471.4,134.9L475.3,135L476.3,136.2L480.8,137.6L481.7,137L484.5,138.4L487.4,138L487.5,139.8L485.2,141.9L482,142.5L481.8,143.6L480.3,145.3L479.3,147.8L480.3,149.6L478.8,151L478.3,153L476.4,153.7L474.6,156.1L471.4,156.1L469,156.1L467.4,157.2L466.4,158.4L465.2,158.1L464.2,157L463.6,155.2Z","Spain"],"728":["SS","M563.2,260.1L560.8,258L560.1,256.7L558.6,257.3L557.4,257.1L556.7,257.6L555.5,257.3L553.8,254.7L553.4,253.7L551.3,252.4L550.6,250.6L549.5,249.2L547.6,247.6L547.6,246.6L546.1,245.3L544.3,244.1L545.1,243.8L546,243.2L546.6,240.4L547.3,238.9L549.3,238.5L549.7,239.4L551.2,241.2L551.9,241.4L552.9,240.9L554.8,241L555.2,241.7L557.9,241.7L557.9,241L559.3,240.4L559.6,239.5L560.6,238.9L562.9,240.7L564.3,240.4L565.5,238.1L566.9,236.4L566.7,234.5L566,233.6L567.6,233.5L567.8,232.8L569,233L568.8,235.3L569.2,237.5L570.6,238.8L570.9,239.8L570.9,241.4L571.3,241.5L571.4,243.9L571,244.8L569.6,244.9L568.7,246.7L570.4,246.9L571.8,248.5L572.2,249.7L573.5,250.4L575.1,253.8L573.3,255.9L571.7,257.7L570.1,259.2L568.2,259.2L566,259.9L564.3,259.2Z","S. Sudan"],"729":["SD","M546.1,245.3L544,244L543.1,243.1L542.9,242.1L543.3,240.8L543.3,239.5L541.7,237.5L541.4,236.2L541.4,235.5L540.4,234.5L540.3,232.7L539.7,231.5L538.8,231.7L539,230.5L539.7,229.2L539.3,227.9L540.2,227L539.6,226.2L540.3,224.3L541.4,222L543.7,222.2L543.2,209.8L543.2,208.5L546.2,208.5L545.9,202.2L556.6,202.2L566.8,202.2L577.2,202.2L578.3,205.3L577.8,205.8L578.3,209.1L579.5,212.8L580.6,213.6L582.1,214.7L580.9,216.5L578.9,217L578.1,218L578,220.1L577,224.7L577.4,225.9L577.1,228.6L576.1,231.7L574.5,233.3L573.5,235.7L573.2,236.9L572,237.8L571.3,241.1L571.4,243.9L571.3,241.5L570.9,241.4L570.9,239.8L570.6,238.8L569.2,237.5L568.8,235.3L569,233L567.8,232.8L567.6,233.5L566,233.6L566.7,234.5L566.9,236.4L565.5,238.1L564.3,240.4L562.9,240.7L560.6,238.9L559.6,239.5L559.3,240.4L557.9,241L557.9,241.7L555.2,241.7L554.8,241L552.9,240.9L551.9,241.4L551.2,241.2L549.7,239.4L549.3,238.5L547.3,238.9L546.6,240.4L546,243.2L545.1,243.8L544.3,244.1Z","Sudan"],"732":["EH","M457.5,184.4L457.5,184.6L457.4,185.2L457.3,190L448.7,189.8L448.6,197.9L446.1,198.1L445.4,199.8L445.8,204.3L435.5,204.3L434.9,205.3L435.1,204L435.1,204L441,203.8L441.4,202.6L442.5,201.2L443.5,196.9L447.2,193.5L448.6,189.5L449.4,189.3L450.3,186.8L452.5,186.5L453.4,186.9L454.6,186.9L455.5,186.2L457.1,186.1L457.1,184.4Z","W. Sahara"],"740":["SR","M332.9,263.8L331.3,263.1L330.1,263.5L329,263.2L328.7,264.1L329.1,264.7L328.9,265.3L327.4,265.1L325.8,262.4L325.5,260.6L324.6,260.6L323.4,258.3L324,256.7L323.8,256L325.5,255.2L326,252.4L329.2,253L329.5,252.4L331.7,252.2L334.6,253L333.1,255.7L333.3,257.9L334.3,259.7L333.8,261.1L333.6,262.5Z","Suriname"],"748":["SZ","M563.6,354.7L563,356.1L561.5,356.5L560,354.8L560.1,353.7L560.9,352.5L561.2,351.6L561.9,351.4L563.2,351.9L563.5,353.3Z","eSwatini"],"752":["SE","M504.6,88.8L505.5,87.1L507.2,85.2L507.6,81.8L506.1,80.4L505.7,76.7L506.9,74.1L509,74.1L509.7,73L508.8,72.1L511.8,68.3L513.5,65.3L514.7,63.3L516.7,63.3L517,61.9L521,62.3L521,60.5L522.3,60.4L525.2,61.7L528.7,63.5L529.5,67.7L530.3,68.8L526.8,69.5L525,71.4L525.6,73.1L522.5,75.3L518.6,77.7L517.5,81.7L519.2,83.7L521.5,85.3L519.8,88.5L517.6,89.2L517.2,94L516.1,96.7L513.3,96.5L512.2,98.8L509.6,98.9L508.7,96.1L506.6,92.8Z","Sweden"],"756":["CH","M503,122.4L503.1,123L502.8,123.7L503.9,124.3L505.1,124.3L505,125.6L504,126.1L502.2,125.7L501.7,127L500.5,127.1L500.1,126.6L498.8,127.6L497.6,127.8L496.5,127.1L495.7,125.8L494.5,126.2L494.6,124.9L496.3,123.1L496.2,122.4L497.3,122.6L497.9,122.1L499.9,122.1L500.4,121.5Z","Switzerland"],"760":["SY","M571.5,168.5L571.4,168.5L571.7,168L571.6,166.7L572,165L573.3,163.8L572.7,162.6L571.6,162.4L571.1,160L571.6,158.7L572.2,158.1L572.8,157.4L572.7,155.6L573.6,156.2L576.3,155.4L577.7,156L579.8,155.9L582.5,154.8L583.9,154.8L586.7,154.3L585.6,156.3L584.4,157.1L584.9,159.3L584.4,163.1L579.1,166.4L574.5,169.8Z","Syria"],"762":["TJ","M650.9,154.6L651.6,151.4L650.5,149.1L648.5,148.4L648.9,147L651,147.1L651.8,145.4L652.1,143.4L655.2,142.7L655,144.1L655.6,145L656.6,144.9L656,145.9L653.1,145.4L653.3,147.1L656,146.9L659.3,147.9L663.9,147.4L665.2,150.3L666,150L667.7,150.7L667.9,152L668.7,153.7L666.1,153.7L664.3,153.5L663.1,154.9L662,155.2L661.3,155.9L660.1,154.8L659.7,152.2L658.9,152.1L659,151.1L657.4,150.4L656.6,151.5L656.6,152.8L656.4,153.2L654.8,153.1L654.3,154.6L653.4,154L651.8,155Z","Tajikistan"],"764":["TH","M761.3,226.4L758.7,226L755.4,226.6L753.9,229.2L755,232.9L752.4,231.5L750.1,231.6L750.3,229.1L747.9,229.1L748.1,232.6L747,237.1L746.4,239.9L746.8,242.2L748.5,242.3L749.8,245.1L750.5,247.8L752.1,249.6L753.7,250L755.2,251.6L754.4,252.9L752.6,253.2L752.3,251.6L750.1,250.3L749.6,250.8L748.5,249.6L747.9,248.1L746.4,246.3L745,244.8L744.7,246.7L744.1,244.9L744.2,243L744.8,240L745.8,236.8L747,233.9L745.7,231L745.6,229.6L745.1,227.8L743,225.3L742.2,223.8L743.1,223.2L743.7,220.4L742.3,218.4L740.3,216.1L738.7,213.3L739.7,212.8L740.4,209.4L742.2,209.2L743.6,207.9L745,207.2L746.3,208.1L746.7,210L748.5,210.1L748.4,213.5L748.9,216.3L751.4,214.4L752.3,214.9L753.8,214.9L754.2,213.8L756.2,214L758.6,216.5L759.3,219.6L761.8,222.4L762,225Z","Thailand"],"768":["TG","M482.4,236.7L482.1,238.3L482.9,239.2L483.8,240.3L483.9,241.9L484.5,242.5L484.4,249.7L485,251.8L482.9,252.5L482.3,251.4L481.5,249.4L481.3,247.9L481.9,245.1L481.2,243.9L481,241.5L481,239.2L479.9,237.6L480.1,236.6Z","Togo"],"780":["TT","M314.4,237.4L316,237L316.5,237.1L316.3,239.4L314,239.8L313.6,239.5L314.4,238.6Z","Trinidad and Tobago"],"784":["AE","M615.4,195.1L615.8,195L616,195.8L618,195.3L620.2,195.4L621.8,195.5L623.4,193.4L625.1,191.4L626.5,189.4L627.1,190.5L627.8,193L626.4,193L626.4,195.1L627,195.5L625.8,196.1L626,197.4L625.3,198.7L625.4,200L624.9,200.6L616.9,199L615.5,195.9Z","United Arab Emirates"],"788":["TN","M504.5,176.1L503.2,170.4L501.6,169.2L501.6,168.4L499.5,166.5L499.2,164.2L500.7,162.4L501.2,159.8L500.8,156.8L501.2,155.2L503.9,154L505.7,154.3L505.7,155.9L507.8,154.8L508,155.4L506.8,156.9L506.8,158.4L507.7,159.1L507.5,161.8L505.9,163.4L506.4,165.1L507.7,165.2L508.4,166.7L509.4,167.2L509.3,169.6L508.1,170.5L507.3,171.5L505.6,172.7L505.9,174L505.7,175.3Z","Tunisia"],"792":["TR","M592.8,154.5L591.7,155L590.7,154.3L587.7,153.8L586.7,154.3L583.9,154.8L582.5,154.8L579.8,155.9L577.7,156L576.3,155.4L573.6,156.2L572.7,155.6L572.8,157.4L572.2,158.1L571.6,158.7L570.5,157.3L571.3,156.1L569.8,156.4L567.6,155.7L566,157.5L562.3,157.8L560,156.2L557.3,156.1L556.8,157.4L555.1,157.7L552.5,156.1L549.8,156.1L548,153L546,151.3L547,148.8L545.3,147.3L547.8,144.4L551.6,144.2L552.4,141.9L557.2,142.3L559.9,140.3L562.7,139.4L566.8,139.3L571.4,141.5L575.1,142.7L577.9,142.2L580.1,142.5L582.7,140.9L585.4,140.7L588,142.3L588.6,143.4L588.6,144.9L590.5,145.7L591.7,146.6L590.1,147.5L591.4,151L591.1,152ZM544.5,140L546.9,139L549.1,139.4L549.5,140.6L551.8,141.6L551.4,142.4L548.5,142.6L547.5,143.5L545.6,145.2L544.7,143.7L544.6,143.1L545.2,142.8L545.8,140.8Z","Turkey"],"795":["TM","M609.7,140.1L610.6,139.1L613.2,138.4L615.1,139.3L617.3,141.7L618.5,141.6L621.3,141.6L620.6,140L622.5,138.9L624.1,137.1L627.8,138.8L628.6,141.2L629.7,141.9L632.4,141.7L633.3,142.3L635.3,145.5L638.6,147.7L640.5,149.1L643.5,150.7L647.1,152L647.5,153.9L646.7,153.8L645.3,153L645.2,154.1L643.2,154.7L643.2,157.2L641.9,158.2L640,158.6L639.8,160.1L637.9,160.5L635.1,159.3L634.4,156.6L632.5,156.5L629.1,153.8L627,153.4L623.9,151.8L622.1,151.5L621.1,152.1L619.4,152L617.9,153.8L615.8,154.4L615,152.2L614.8,148.9L612.6,147.9L612.9,145.7L611.2,145.6L611.2,142.9L613.7,143.7L615.7,142.7L613.5,140.8L612.5,139.1L610.6,139.9L610.8,142.1Z","Turkmenistan"],"800":["UG","M571.5,274L566,274.2L563.1,274.2L562.1,274.6L560.5,275.5L559.8,275.2L559.9,272.9L560.5,271.7L560.6,269.2L561.2,267.7L562.2,266.1L563.3,265.2L564.1,264.1L563,263.7L563.2,260.1L564.3,259.2L566,259.9L568.2,259.2L570.1,259.2L571.7,257.7L573,259.9L573.3,261.5L574.6,265.1L573.6,267.3L572.3,269.4L571.5,270.7Z","Uganda"],"804":["UA","M554.2,108.6L555.1,108.7L555.6,108L556.3,108.2L558.7,107.9L560.5,109.6L560,110.2L560.3,111.1L562.2,111.3L563.3,112.6L563.3,113.2L566.5,114.2L568.2,113.7L569.9,115.2L571.3,115.1L575,116.1L575.2,117L574.5,118.6L575.3,120.3L575.1,121.3L572.8,121.5L571.8,122.4L571.9,123.7L570,124L568.6,124.9L566.3,125.1L564.4,126.2L564.8,127.9L564.4,127.8L564,127.2L563.2,127.1L561.4,126.4L560.9,127.2L560.5,126.8L556.6,126.1L556.3,124.9L554.1,125.3L553.5,127L551.9,129.3L550.7,128.7L549.6,129.2L548.5,128.7L549,128.3L549.3,127.3L549.9,126.3L549.6,125.7L550.1,125.5L550.4,125.9L551.8,126L552.5,125.8L552,125.5L552.1,125L551.1,124.2L550.6,123L549.7,122.5L549.7,121.4L548.6,120.6L547.5,120.5L545.7,119.5L544.1,119.8L543.6,120.3L542.6,120.3L542.1,121L540.3,121.3L539.6,121.8L538.4,121L536.9,121L535.3,120.7L534.4,121.3L534.1,120.5L532.7,119.7L533.1,118.5L533.6,117.7L534.2,117.8L533.4,116.5L535.3,114L536.4,113.6L536.6,112.8L535.1,110.1L536.2,110L537.4,109.2L539.2,109.1L541.6,109.4L544.3,110.1L546.2,110.2L547.1,110.6L547.9,110.1L548.6,110.8L550.7,110.6L551.7,110.9L551.6,109.4L552.2,108.8Z","Ukraine"],"807":["MK","M535.1,138.5L536.5,139.4L536.8,141.5L536.3,141.6L536,142.2L534.6,142.1L533.7,142.8L532.1,143L531.1,142.3L530.6,141L530.8,139.9L531.2,139.9L531.2,139.3L532.6,138.8L533.2,138.7L534,138.5Z","Macedonia"],"818":["EG","M577.2,202.2L566.8,202.2L556.6,202.2L545.9,202.2L545.4,190.6L544.7,179.4L543.8,176.9L544.4,175L543.9,173.6L544.7,172.1L548.1,172.1L550.7,172.9L553.3,173.8L554.5,174.3L556.4,173.3L557.4,172.4L559.6,172.1L561.5,172.5L562.3,174.1L562.9,173.1L565,173.8L567,174L568.2,173.2L570,177.8L570.4,178.6L569.7,179.9L569.4,182.2L568.8,183.9L568.2,184.4L567.3,183.4L566,182L563.8,177.5L563.6,177.8L564.9,181.1L566.7,184.3L569.1,189.2L570.2,190.9L571.1,192.7L573.7,196.1L573.3,196.7L573.5,198.7L576.7,201.5Z","Egypt"],"826":["GB","M465.7,103.3L464,102.7L462.5,102.8L463.1,101.2L462.7,99.6L464.6,99.5L467,101.3ZM472.8,104.7L472.8,104.7L473.2,103L471.7,101.2L471.7,101.1L468.9,100.6L468.4,99.8L469.2,98.5L468.5,97.7L467.2,99.1L467.2,96.2L466.1,94.8L467,91.8L468.8,89.4L470.6,89.6L473.3,89.4L470.8,92.5L473.1,92.1L475.6,92.1L475,94.5L472.9,97.1L475.3,97.3L475.4,97.6L477.4,101.1L479,101.6L480.4,104.9L481.1,106.1L483.9,106.7L483.6,108.6L482.5,109.5L483.4,111L481.3,112.6L478.1,112.6L474.1,113.4L473,112.8L471.5,114.2L469.3,113.9L467.6,115L466.4,114.4L469.9,111.2L472,110.6L472,110.6L468.3,110.1L467.7,108.9L470.2,108L468.9,106.4L469.4,104.4Z","United Kingdom"],"834":["TZ","M571.5,274L572,274.3L581.7,280.7L581.9,282.5L585.7,285.6L584.4,289.5L584.5,291.2L586.2,292.4L586.3,293.2L585.5,295.1L585.6,296L585.4,297.5L586.3,299.5L587.3,302.6L588.3,303.2L586.1,305.1L583.1,306.3L581.5,306.2L580.5,307.2L578.6,307.2L577.9,307.6L574.7,306.8L572.7,307L572.1,302.8L571.2,301.3L570.7,300.4L568.1,299.9L566.6,298.9L564.9,298.4L563.8,297.9L562.7,297.1L561.3,293.1L559.8,291.4L559.3,289.6L559.6,287.9L559.1,285.1L560.2,284.9L561.2,283.8L562.3,282.2L563,281.5L562.9,280.5L562.4,279.8L562.2,278.6L563,278.2L563.2,276.3L562.1,274.6L563.1,274.2L566,274.2Z","Tanzania"],"840":["US","M187.8,117.9L194.5,117.9L201.6,117.9L203.9,117.9L211.2,117.9L218.2,117.9L225.3,117.9L232.5,117.9L240.6,117.9L248.7,117.9L253.6,117.9L254.1,116.8L255,116.7L254.7,118.4L255.2,118.9L256.8,119.1L259,119.6L260.9,120.5L263,120.1L265.7,120.9L266.4,120.9L268.9,120L270.7,121.1L272.6,122.3L274.2,123.4L275.7,124.3L275.6,125.1L276.1,125.4L275.8,125.7L276.5,125.8L277,125.5L276.9,126.2L277.2,126.7L277.9,126.7L278.1,127.1L277.6,127.7L279.7,129.1L279.2,131.9L278.9,134.6L277.6,136.4L275.9,138.1L275,139.2L274.8,139.5L275,140L275.7,140.5L276.3,140.5L279.7,138.8L282.3,138.3L286,136.8L286.2,136.5L286.2,135.5L286,134.9L287.3,134.4L289.7,134.4L291.9,134.4L293.1,133.2L293.5,133L296.7,130.7L298,130.2L301.7,130.1L306.2,130.1L306.6,129.4L307.4,129.2L308.6,128.8L309.9,127.3L311.3,125L313.8,122.7L314.4,123.5L316.2,122.9L317,123.8L315.8,128L316.9,129.7L317,130.8L314,132.2L311.2,133.3L308.4,134.2L306.6,136.1L306,136.8L305.5,138.4L305.9,140.1L306.9,140.1L306.9,139L307.5,139.7L307.1,140.6L305.3,141.1L304.1,141L302.1,141.6L301,141.7L299.5,141.9L297.2,142.8L301,142.2L301.6,142.8L297.9,143.7L296.3,143.7L296.5,143.3L295.5,144.2L296.2,144.3L295.1,146.6L292.6,149L292.7,148.2L292.2,148L291.5,147.2L291.6,148.9L292.1,149.5L291.8,150.7L290.7,151.9L288.7,154.4L288.5,154.2L289.8,152.1L288.8,150.9L289.2,148.3L288.4,149.7L288.4,151.7L286.9,151.2L288.3,152.2L287.7,155.2L288.4,155.4L288.4,156.5L288,159.6L285.9,161.9L283,162.9L280.9,164.7L279.6,164.9L278,166.1L277.5,167.1L274.2,169.1L272.4,170.6L270.8,172.5L269.9,174.7L269.9,176.9L270.2,179.6L271,181.8L270.7,183.2L271.3,186.8L270.8,189L270.5,190.2L269.5,192.1L268.7,192.5L267.5,192.1L267.3,190.8L266.4,190L265.5,187.3L264.7,184.9L264.6,183.7L265.5,181.6L265.2,179.9L263.7,177.2L262.8,176.8L259.9,178.2L259.4,178L258.5,176.6L257,175.8L254,176.2L251.8,175.8L249.8,176L248.6,176.5L248.9,177.4L248.6,178.6L249,179.3L248.4,179.7L247.5,179.2L246.4,179.8L244.6,179.7L243,178.1L240.7,178.4L239,177.7L237.3,177.9L235,178.7L232.1,181L229.2,182.4L227.4,183.9L226.5,185.3L226,187.4L225.8,189L226.1,190L225,190.1L223.3,189.4L221.5,188.5L221.1,187L221,184.8L219.9,183L219.4,181.1L218.7,179L217.2,177.7L215,177.8L212.8,180.3L210.9,179.3L209.8,178.4L209.6,176.7L209.2,175L208,173.6L207,172.6L206.3,171.5L201.9,171.5L201.5,172.8L199.5,172.8L194.3,172.8L189.1,170.6L185.7,169.1L186.2,168.5L182.8,168.8L179.8,169.1L179.9,167.5L178.9,165.7L177.8,165.3L177.8,164.4L176.5,164.2L175.8,163.4L173.6,163.1L173.1,162.6L173.4,160.8L172.1,157.7L171.7,153.3L172.1,152.6L171.4,151.6L170.5,148.9L171.3,146.4L170.7,144.7L172.4,142.1L173.5,139.4L173.8,137.1L176.2,134.1L177.9,131.3L179.6,128.6L181.3,124.4L181.9,121.8L182,120.4L182.6,119.8L185.5,120.8L185.2,123.7L186.3,122.9L187.2,120.4ZM68.5,208.2L68.9,208.5L69.2,208.9L69.6,210L69.5,210.2L68.3,210.8L67.3,211.3L66.8,211.9L66.3,211.4L66.5,210.5L66.4,209.4L66.6,209L67.2,208.5L67.2,207.9L67.4,207.6L67.6,207.7ZM67.5,206.1L67.1,206.4L66.2,206.7L65.9,206L65.7,205.8L65.7,205.6L66,205.3L66.9,205.6ZM65.8,204.8L65.6,205.1L64.2,205L64.5,204.6ZM62.9,203.1L63.1,203.3L63.5,204.3L63.3,204.5L63.2,204.5L62.3,204.3L62.1,203.6L62.1,203.5ZM59.8,201.5L59.6,202.2L59.2,202.6L58.5,202L58.7,201.8L59.2,201.4ZM113.1,84.4L114.6,84.7L113.8,85.7L112,86.2L111,85.7L110.5,84.9ZM136.2,91.3L137.5,91.5L137.7,92.4L134.6,93.8L131.4,94.9L130.8,94.1L131.7,92.8L134.6,91.8ZM192.8,58.8L183.1,68.8L169.1,84.6L171.2,84.7L172.7,85.5L173.2,86.7L173.7,88.6L177.1,87L180.1,86.1L180.1,87.6L180.7,88.7L181.7,90L181.6,92.1L181.5,95.4L184,97.3L182.8,99.1L180.5,100.6L180,99.4L178.7,98.5L179.8,96L178.6,93.6L179.5,90.9L177.5,90.7L174,90.6L172,89.8L169.8,86.8L168.1,86.3L165.1,85.3L161.8,85.5L158.6,84.2L157,83L154.1,83.6L152.8,85.6L151.4,85.7L148.3,86.3L145.5,87.3L142.5,87.9L143.7,86.2L147.2,83.4L150.3,82.6L150.4,81.8L146.1,83.4L142.9,85.3L137.9,87.3L138.3,88.7L134.4,90.8L130.9,92L127.9,92.9L126.2,94.2L121.4,95.7L119.5,97.1L115.7,98.3L114.4,98.1L111.5,98.9L108.4,99.9L105.6,100.9L100.9,101.7L101,101.2L104.7,99.9L107.7,99L111.6,97.3L114.7,97L116.8,95.8L121.5,94.1L122.5,93.5L125.1,92.5L127.4,90.3L130.1,88.6L126.7,89.5L126.4,89L124.3,90L124.2,88.5L122.6,89.6L123.1,88.1L119.8,89.3L118.4,89.3L119.8,87.6L121.2,86.5L120.8,85.5L117.4,86.1L116.8,84.7L115.9,84L117.5,82.4L117,81.2L119.5,79.6L122.9,78.1L125.1,76.6L127.1,76.4L128.1,76.9L131.2,75.5L132.5,75.8L135.1,74.9L136,73.6L135.3,73.2L138,72.1L136.6,72.1L133.7,72.7L132.4,73.3L131.4,72.7L128.1,73L125.6,72.4L125.9,71.3L125,69.7L129.2,68.5L135.4,67.2L137.1,67.2L135.3,68.6L139.9,68.5L140,66.8L138.6,65.8L138.6,64.4L137.9,63.3L136,62.4L138.8,61L142.5,60.9L146.5,59.7L148.5,58.5L152,57.2L154.3,56.9L159.5,55.7L161.2,55.9L165.9,54.5L168.3,55.1L168.4,56.3L169.9,55.7L173.1,55.9L172.3,56.5L174.9,57L177.3,56.7L180.7,57.5L184.3,57.8L185.5,58.1L188.6,57.7L190.9,58.5ZM111.6,74.9L112.3,75.4L114,75.1L114.9,75.8L116.7,76.2L116.2,76.5L113.9,77.1L112.9,76.5L112.6,76L110.6,76.2L110.3,75.9Z","United States of America"],"854":["BF","M465.5,238.6L465.3,236.8L466.1,235.5L466,234.4L468.1,231.8L468.5,229.7L469.3,228.9L470.6,229.3L471.7,228.7L472.1,227.9L474.1,226.5L474.7,225.5L477.1,224.2L478.6,223.8L479.3,224.4L481,224.4L480.8,225.9L481.2,227.3L482.7,229.3L482.7,230.9L485.8,231.6L485.8,233.7L485.2,234.6L483.9,234.9L483.3,236.3L482.4,236.7L480.1,236.6L478.8,236.3L478,236.9L476.8,236.6L472.1,236.8L472,238.5L472.4,240.9L470.6,240.1L469.3,240.2L468.4,241L467.2,240.3L466.7,239.3Z","Burkina Faso"],"858":["UY","M331.2,365.7L332.8,365.3L335.8,367.8L336.7,367.7L339.7,369.7L341.9,371.4L343.7,373.6L342.8,375.1L343.8,376.8L343,378.8L340.4,380.6L338.4,379.9L337.1,380.3L334.5,378.9L332.8,379L331,377.3L330.8,375.3L331.3,374.6L330.8,371.4L330.9,368.2Z","Uruguay"],"860":["UZ","M618.5,141.6L616,130.2L621.8,128.4L622.3,128.6L626.6,130.8L628.9,132L631.9,134.8L634.7,134.3L638.8,134.1L642.3,136.3L642.9,139.5L644.1,139.5L645.2,142L648.4,142.1L649.5,143.6L650.4,143.6L650.9,141.4L653.6,139.2L654.9,138.6L655.7,138.9L654.1,140.9L656.3,142.1L657.8,141.3L661.2,143L658.6,145.2L656.6,144.9L655.6,145L655,144.1L655.2,142.7L652.1,143.4L651.8,145.4L651,147.1L648.9,147L648.5,148.4L650.5,149.1L651.6,151.4L650.9,154.6L648.9,153.9L647.5,153.9L647.1,152L643.5,150.7L640.5,149.1L638.6,147.7L635.3,145.5L633.3,142.3L632.4,141.7L629.7,141.9L628.6,141.2L627.8,138.8L624.1,137.1L622.5,138.9L620.6,140L621.3,141.6Z","Uzbekistan"],"862":["VE","M316.3,254.8L316.6,255.7L315.6,256.9L312.6,258L310.6,258.5L309.8,259.2L307.7,258.5L305.7,258.1L305.2,258.4L306.4,259.2L306.2,261.3L306.6,263.2L308.9,263.5L309,264.1L307.1,265L306.7,266.4L305.6,266.9L303.6,267.6L303.1,268.6L301,268.8L299.5,267.1L298.7,264L298,262.9L297,262.2L298.4,260.7L298.4,260L297.6,259L297.1,257L297.4,254.7L298,253.7L298.6,252L297.6,251.4L296.1,251.8L294.1,251.6L293,252L291.2,249.3L289.7,248.9L286.2,249.2L285.6,248.1L285,247.8L284.9,247.2L285.3,246L285.1,244.8L284.6,244.1L284.3,242.6L282.9,242.4L283.8,240.6L284.2,238.4L285.1,237.2L286.2,236.3L286.9,234.8L288.7,234.2L288.6,235L287,235.3L287.8,236.7L287.6,238.4L286.3,240.2L287.2,242.7L288.4,242.5L289.1,240.2L288.3,239.1L288.4,236.8L291.8,235.5L291.5,234L292.5,233L293.3,235.2L295.2,235.3L296.8,237L296.9,238L299.3,238.1L302.2,237.8L303.6,239.2L305.7,239.5L307.2,238.6L307.3,237.8L310.6,237.6L313.9,237.5L311.5,238.5L312.4,239.9L314.5,240.2L316.5,241.7L316.8,244.2L318.2,244.2L319.2,244.9L317,246.7L316.8,247.9L317.6,249L316.9,249.6L315.3,250.1L315.3,251.6L314.5,252.4Z","Venezuela"],"887":["YE","M618,211.6L620.5,216.8L621.5,219L619.6,219.8L619.2,221.2L619.2,222.3L616.6,223.6L612.5,225L610.2,227.3L609,227.4L608.2,227.2L606.7,228.5L605,229.2L602.8,229.3L602.1,229.5L601.6,230.3L600.9,230.5L600.5,231.3L599.2,231.3L598.4,231.7L596.5,231.5L595.7,229.7L595.7,228L595.2,227.1L594.6,224.8L593.8,223.5L594.3,223.3L593.9,221.9L594.2,221.3L594,219.9L595.1,218.9L594.8,217.6L595.4,216.1L596.5,216.9L597.2,216.6L600.3,216.5L600.8,216.8L603.4,217.1L604.4,217L605.2,218L606.4,217.5L608.1,214.2L610.4,212.8Z","Yemen"],"894":["ZM","M562.7,297.1L563.8,297.9L564.9,298.4L566.6,298.9L568.1,299.9L569.3,301.2L569.9,303.9L569.4,304.7L568.8,307.3L569.3,309.9L568.4,311L567.5,313.9L568.8,314.7L560.6,317.3L560.8,319.5L558.8,319.9L557.2,321.2L556.8,322.3L555.9,322.5L553.5,325.1L551.9,327.1L551,327.2L550.2,326.8L547.2,326.5L546.7,326.2L546.7,326L545.7,325.3L544,325.1L541.8,325.8L540.1,323.8L538.4,321.3L538.7,311.3L544.3,311.4L544.1,310.3L544.5,309.1L544.1,307.6L544.4,306.1L544.2,305.2L545.1,305.2L545.2,306.2L546.5,306.1L548.2,306.4L549.1,307.8L551.2,308.3L552.9,307.3L553.4,308.9L555.5,309.4L556.4,310.7L557.5,312.4L559.5,312.4L559.4,309.1L558.6,309.6L556.8,308.4L556.1,307.9L556.5,304.7L557.1,301L556.5,299.6L557.3,297.7L558,297.3L561.7,296.8Z","Zambia"],"032":["AR","M320.3,435.1L321.7,436.4L323.6,438.7L327.2,440.4L330.7,441.2L330.1,442.7L328,442.8L326.5,441.8L325.1,441.7L322.6,441.7ZM331.2,365.7L330.9,368.2L330.8,371.4L331.3,374.6L330.8,375.3L331,377.3L331.1,378.9L334.8,381.6L334.8,383.8L336.6,385.1L336.8,386.7L335.1,390.7L331.7,392.4L326.8,393L324,392.7L324.9,394.6L324.9,396.9L325.7,398.5L324.5,399.6L322.1,400L319.4,398.9L318.6,399.7L319.7,402.8L321.6,403.7L322.7,402.7L323.8,404.3L321.8,405.3L320.3,407.2L320.8,410.3L320.6,412L318.3,412L316.9,413.6L316.8,415.9L319.8,418.1L322.3,418.7L322.3,421.5L319.9,423.2L319.5,426.7L317.7,427.9L317.2,429.4L319,432.5L321.1,434.2L320.1,434.1L317.8,433.6L312,433.2L310.4,431.4L309.7,429.2L308.2,429.4L307,428.3L305.7,425.1L307.1,423.7L307.2,421.8L306.4,420.3L306.9,417.7L306.5,413.6L305.7,411.8L306.6,411.2L306.1,410L304.7,409.4L305.2,408.1L303.7,407L302.2,403.4L303,402.8L301.6,399L301.4,395.8L301.4,393L302.6,391.8L301.1,388.8L300.5,385.9L301.9,383.9L301.3,381.2L302.1,378.2L301.5,375.3L300.8,374.7L298.5,369.3L299.5,366.1L298.8,363L299.2,360.2L300.4,357.2L302,355.3L301,354L301.4,353L300.6,347.8L303.2,346.2L303.7,343L303.3,342.2L305.1,339.3L308.7,340.1L310.5,342.4L311.2,339.8L314.2,340L314.7,340.6L320.2,345.8L322.4,346.2L325.9,348.6L328.7,349.8L329.2,351.2L327.3,356L330,356.8L333,357.3L335,356.8L337.1,354.4L337.2,351.6L338.4,351L339.9,352.8L340.2,355.3L338.2,357.1L336.6,358.3L334.1,361.4Z","Argentina"],"044":["BS","M274.1,187.1L275.3,186.9L277,187L277,187.8L274,188.3ZM277.3,186.3L279.1,187.8L278.3,190L277.9,189.6L278.2,188L277.2,186.7ZM275.3,192.1L276,192.2L276.5,194.8L276.3,196.7L275.6,196.8L275.2,195L274.4,194.1Z","Bahamas"],"076":["BR","M343.8,376.8L342.8,375.1L343.7,373.6L341.9,371.4L339.7,369.7L336.7,367.7L335.8,367.8L332.8,365.3L331.2,365.7L334.1,361.4L336.6,358.3L338.2,357.1L340.2,355.3L339.9,352.8L338.4,351L337.2,351.6L337.5,349.8L337.6,347.9L337.4,346.2L336.4,345.6L335.5,346.1L334.5,346L334.1,344.8L333.5,341.9L332.9,341L331.1,340.1L330,340.7L327.2,340.1L326.9,335.9L326,334.1L326.8,333.5L326.3,331.7L326.9,330.3L327.2,327.8L326.4,325.9L324.9,325L324.5,323.8L324.8,322L319.6,321.8L318.3,318.2L319.1,318.1L319,316.8L318.4,315.9L318.1,314.1L316.5,313.1L314.8,313.2L313.7,312.3L311.8,311.6L310.7,310.5L307.7,310L304.6,307.2L304.7,305.1L304.3,303.9L304.4,301.5L300.9,302L299.6,303.2L297.3,304.5L296.8,305.4L295.4,305.5L293.4,305.2L291.9,305.8L290.7,305.4L290.6,300.7L288.4,302.5L286.1,302.4L285,300.8L283.2,300.6L283.7,299.2L282.1,297.3L280.8,294.5L281.5,293.9L281.5,292.6L283,291.7L282.7,290L283.4,288.9L283.5,287.5L286.5,285.4L288.7,284.8L289.1,284.3L291.5,284.4L292.6,275.9L292.6,274.5L292.2,272.7L291,271.6L291,269.3L292.5,268.8L293.1,269.1L293.2,267.9L291.6,267.6L291.6,265.7L296.8,265.7L297.7,264.7L298.5,265.6L299,267.5L299.5,267.1L301,268.8L303.1,268.6L303.6,267.6L305.6,266.9L306.7,266.4L307.1,265L309,264.1L308.9,263.5L306.6,263.2L306.2,261.3L306.4,259.2L305.2,258.4L305.7,258.1L307.7,258.5L309.8,259.2L310.6,258.5L312.6,258L315.6,256.9L316.6,255.7L316.3,254.8L317.7,254.6L318.3,255.4L317.9,256.7L318.8,257.2L319.4,258.7L318.6,259.8L318.2,262.4L318.8,264L319,265.4L320.7,266.9L322,267.1L322.3,266.4L323.2,266.3L324.4,265.8L325.3,264.9L326.8,265.2L327.4,265.1L328.9,265.3L329.1,264.7L328.7,264.1L329,263.2L330.1,263.5L331.3,263.1L332.9,263.8L334,264.4L334.9,263.6L335.5,263.7L335.8,264.6L337.1,264.4L338.2,263.2L339,260.9L340.7,258L341.6,257.9L342.2,259.6L343.7,265.1L345.1,265.6L345.2,267.8L343.2,270.3L344,271.3L348.8,271.8L348.9,274.9L350.9,272.8L354.3,274L358.8,275.9L360.1,277.7L359.7,279.4L362.8,278.5L368.1,280.1L372.1,280L376.1,282.6L379.6,286.1L381.7,287L384,287.1L385,288.1L386,292.1L386.5,294L385.5,299.1L384.2,301.2L380.6,305.5L379,309L377.1,311.8L376.4,311.8L375.8,314.1L376.3,320L375.8,324.8L375.6,326.9L374.8,328.1L374.6,332.3L372.2,336.4L372,339.7L369.9,341L369.5,342.9L366.6,342.9L362.6,344.1L360.9,345.5L358,346.4L355.1,348.9L353.2,352L353.1,354.4L353.7,356.1L353.6,359.3L353.2,360.8L351.6,362.6L349.4,368.1L347.5,370.6L345.9,372.1L345.2,375.1Z","Brazil"],"068":["BO","M293.4,305.2L295.4,305.5L296.8,305.4L297.3,304.5L299.6,303.2L300.9,302L304.4,301.5L304.3,303.9L304.7,305.1L304.6,307.2L307.7,310L310.7,310.5L311.8,311.6L313.7,312.3L314.8,313.2L316.5,313.1L318.1,314.1L318.4,315.9L319,316.8L319.1,318.1L318.3,318.2L319.6,321.8L324.8,322L324.5,323.8L324.9,325L326.4,325.9L327.2,327.8L326.9,330.3L326.3,331.7L326.8,333.5L326,334.1L325.9,333.2L323.2,331.6L320.8,331.5L316.2,332.4L315.3,335.2L315.4,336.9L314.7,340.6L314.2,340L311.2,339.8L310.5,342.4L308.7,340.1L305.1,339.3L303.3,342.2L301.4,342.6L299.9,338.3L298,334.7L298.5,331.7L297,330.4L296.4,328.1L294.9,326L296.2,322.6L294.9,320L295.4,318.9L294.8,317.8L295.7,316.2L295.6,313.5L295.5,311.3L296,310.3Z","Bolivia"],"084":["BZ","M243,215.3L243,214.9L243.3,214.7L243.8,215.1L245,213.2L245.5,213.2L245.4,213.6L245.9,213.6L245.8,214.5L245.2,215.9L245.3,216.3L244.9,217.5L245.1,217.8L244.6,219.3L243.9,220.2L243.4,220.3L242.8,221.4L242,221.4L242.6,217.8Z","Belize"],"072":["BW","M557.6,340.1L553.8,342.5L551.3,344.8L550.3,346.9L549.5,348.1L548,348.3L547.5,349.8L547.2,350.8L545.4,351.5L543.3,351.4L542.1,350.5L541,350.1L539.7,350.9L539,352.4L537.7,353.3L536.3,354.7L534.5,355L533.9,353.9L534.3,352L532.8,349L532.1,348.6L532.5,339.4L535.1,339.3L535.6,328.1L537.5,328L541.7,326.9L542.6,328.2L544.4,327L545.2,326.9L546.7,326.2L547.2,326.5L548.1,329L548.6,329.5L549.4,331.4L552.2,334.8L553.4,335.1L553.3,336.2L554,338.2L556,338.7Z","Botswana"],"024":["AO","M515,285.9L514.1,286.6L513.6,287.4L513.5,288.8L512.8,289.1L512.1,286.8L513.2,285.4L514,284.9ZM513.2,290.1L514.3,289.6L515.1,289.7L516,289.3L524,289.4L524.6,291.7L525.4,293.6L526,294.6L527,296.2L528.8,296L529.7,295.5L531.2,296L531.6,295.2L532.3,293.4L534,293.2L534.1,292.7L535.5,292.7L535.2,293.8L538.5,293.8L538.5,295.8L539,297L538.6,298.8L538.8,300.8L539.7,301.9L539.5,305.6L540.1,305.4L541.3,305.4L543,305L544.2,305.2L544.4,306.1L544.1,307.6L544.5,309.1L544.1,310.3L544.3,311.4L538.7,311.3L538.4,321.3L540.1,323.8L541.8,325.8L536.8,327.1L530.4,326.6L528.6,325.1L517.8,325.3L517.4,325.5L515.8,324.1L514.1,324L512.5,324.5L511.2,325.1L511,323.1L511.4,320.4L512.4,317.5L512.5,316.2L513.5,313.4L514.1,312.1L515.7,310L516.6,308.6L516.9,306.3L516.7,304.5L516,303.4L515.3,301.5L514.6,299.7L514.8,299L515.6,297.8L514.8,294.7L514.3,292.7L512.9,290.7Z","Angola"],"012":["DZ","M457.4,185.2L457.5,184.6L457.5,184.4L457.5,180.7L461.7,178.4L464.3,177.9L466.5,177L467.5,175.5L470.5,174.2L470.6,171.9L472.1,171.6L473.3,170.4L476.6,169.9L477.1,168.7L476.4,168L475.6,164.7L475.4,162.8L474.5,160.8L476.9,159.1L479.7,158.5L481.3,157.2L483.7,156.3L488,155.7L492.1,155.5L493.4,155.9L495.8,154.7L498.5,154.7L499.5,155.4L501.2,155.2L500.8,156.8L501.2,159.8L500.7,162.4L499.2,164.2L499.5,166.5L501.6,168.4L501.6,169.2L503.2,170.4L504.5,176.1L505.4,178.8L505.6,180.3L505.2,182.9L505.4,184.3L505.1,186L505.4,188L504.3,189.3L505.9,191.6L506.1,193L507,194.7L508.3,194.1L510.4,195.6L511.6,197.6L502.6,203.6L495.1,209.7L491.3,211.1L488.4,211.4L488.3,209.4L487.1,208.9L485.5,208L484.8,206.5L475.9,199.7L467.1,192.8Z","Algeria"],"050":["BD","M724.4,202.1L724.8,204.3L723.8,203.8L724.3,206.4L723.3,204.7L722.9,203.1L722.2,201.6L720.7,199.8L718.3,199.7L718.7,201L718.2,202.7L717,202.1L716.7,202.6L715.9,202.3L714.8,202L714,199.4L712.7,197.1L712.8,195.2L711,194.3L711.4,193.2L712.8,192L710.6,190.3L711.1,188.2L713.5,189.6L714.8,189.7L715.4,191.9L718,192.3L720.4,192.3L722,192.8L721.3,195.5L720.2,195.7L719.7,197.5L721.4,199.1L721.5,197.1L722.2,197.1Z","Bangladesh"],"064":["BT","M718.5,184L719.7,185.1L720,187L717.8,187.1L715.6,186.9L714.1,187.4L711.5,186.2L711.3,185.5L712.5,183.2L713.8,182.4L715.8,183.1L717.2,183.2Z","Bhutan"],"004":["AF","M647.5,153.9L648.9,153.9L650.9,154.6L651.8,155L653.4,154L654.3,154.6L654.8,153.1L656.4,153.2L656.6,152.8L656.6,151.5L657.4,150.4L659,151.1L658.9,152.1L659.7,152.2L660.1,154.8L661.3,155.9L662,155.2L663.1,154.9L664.3,153.5L666.1,153.7L668.7,153.7L669.4,154.6L668,155L666.9,155.6L664,155.9L661.5,156.6L660.3,158L661.2,159.3L661.8,160.8L660.8,162.2L661.2,163.4L660.7,164.5L658.3,164.4L659.7,166.5L658.2,167.3L657.5,169.2L658,171.1L657.2,171.9L656.2,171.6L654.3,172.1L654.2,172.9L652.2,172.9L651.1,174.7L651.5,177.4L648.3,178.7L646.5,178.4L646.1,179.1L644.5,178.7L641.9,179.2L637.4,177.6L639.3,174.7L638.7,172.7L636.7,172.2L636.2,170.2L634.9,167.7L635.7,165.9L634.5,165.5L634.8,163.2L635.1,159.3L637.9,160.5L639.8,160.1L640,158.6L641.9,158.2L643.2,157.2L643.2,154.7L645.2,154.1L645.3,153L646.7,153.8Z","Afghanistan"],"051":["AM","M596.4,149.5L595.5,149.6L594.2,147.8L594.1,147.3L593,147.3L592.2,146.5L591.7,146.6L590.5,145.7L588.6,144.9L588.6,143.4L588,142.3L591.4,141.8L592,142.6L593,143.1L592.7,143.9L594.2,145L593.6,146L594.8,146.8L596,147.3Z","Armenia"],"040":["AT","M520.6,120.6L520.5,121.8L519.2,121.8L519.7,122.5L519,124.5L518.6,125L516.5,125.1L515.3,125.8L513.3,125.5L509.8,124.7L509.2,123.7L506.9,124.2L506.6,124.8L505.1,124.3L503.9,124.3L502.8,123.7L503.1,123L503,122.4L503.7,122.2L505,123.1L505.3,122.3L507.4,122.4L509.1,121.9L510.2,122L511,122.6L511.2,122.1L510.8,120.1L511.6,119.7L512.4,118.3L514.2,119.3L515.5,118L516.3,117.8L518.2,118.7L519.3,118.6L520.4,119.2L520.3,119.5Z","Austria"],"008":["AL","M532.1,143L532.2,143.9L531.4,144.3L531.3,145.3L530.3,146.8L529.8,146.6L529.7,145.9L528.3,144.9L527.9,143.4L528,141.3L528.3,140.3L527.8,139.8L527.6,138.8L528.5,137.3L528.7,137.9L529.4,137.6L530,138.5L530.6,138.8L530.8,139.9L530.6,141L531.1,142.3Z","Albania"],"056":["BE","M494.5,112.5L494.3,114.5L493.7,114.6L493.5,116.3L491.4,114.9L490.1,115.2L488.5,113.8L487.4,112.5L486.3,112.5L485.9,111.4L487.8,110.8L489.5,111.1L491.7,110.5L493.2,111.8Z","Belgium"],"090":["SB","M915.3,303.8L916,304.8L914.1,304.8L913.3,302.9L914.8,303.7ZM914.5,301L914,301.6L912.4,298.9L912,297L912.9,297L913.6,299.5ZM912.2,301.9L911.1,301.9L909.5,301.6L909,301.1L909.4,299.9L911.1,300.4L911.9,301ZM909.6,296.1L910.1,297.1L910.2,297.7L908.2,296.4L906.9,295.2L905.9,294.2L906.4,293.9L907.5,294.6ZM903.2,292.9L904.2,294L903.6,294.1L902.5,293.4L901.5,292.2L901.7,291.6Z","Solomon Is."],"036":["AU","M846.4,398.9L847.8,399.1L845.9,402.8L844.5,403.9L842.8,406.4L842.5,405.5L839.5,407.7L839.1,407.5L837.7,407.4L837.7,404.7L838.4,402.7L838.5,400L839.3,398.6L840.7,398.8L842.6,399.9L844.1,399.5ZM803.6,372L800.4,373.6L797.9,374.3L796.8,376L795.4,377.2L793.2,377.3L791.5,377.6L789.5,377L787.5,377.4L785.7,377.5L783.6,379.2L782.9,379L781.3,379.9L779.8,380.9L778,380.8L776.3,380.8L774.3,378.8L773.1,378.2L773.7,376.4L775.1,376L775.8,375.3L776.1,374.1L777.1,371.9L777.4,370.1L777,366.9L777.1,365.1L777.7,363.3L777.3,361.3L777.4,360.3L776.6,359.1L777,356.6L776.1,354.1L776.1,352.8L776.9,354.1L776.7,351.2L777.8,352.1L778.3,353.4L778.6,351.7L777.9,349.3L777.9,348.3L777.5,347.3L778.2,345.5L778.9,344.8L779.6,343.2L779.7,341.3L781.3,339.1L781,341.5L782.5,339.3L784.9,338.3L786.5,336.9L788.7,335.8L789.9,335.5L790.6,335.9L792.9,334.8L794.6,334.4L795.1,333.7L795.9,333.4L797.3,333.5L800.3,332.6L802,331.2L803,329.5L804.8,327.9L805.2,326.7L805.6,325L807.9,322.3L808.5,325L809.8,324.4L809.1,322.9L810.2,321.4L811.2,322.1L811.9,319.7L813.6,318.1L814.5,316.9L815.9,316.4L816,315.5L817.2,315.9L817.3,315.1L818.6,314.6L819.9,314.2L821.7,315.6L822.9,317.5L824.6,317.5L826.2,317.8L825.9,316.1L827.6,313.6L828.9,312.8L828.6,312L830,310.2L831.7,309.1L833.1,309.5L835.4,308.9L835.6,307.3L833.7,306.2L835.2,305.8L836.9,306.6L838.1,307.8L840.3,308.6L841.1,308.3L842.6,309.3L844.3,308.4L845.3,308.7L846,308.1L847,309.6L846.1,311.3L844.9,312.6L843.9,312.7L844.1,313.9L843,315.5L841.9,317L841.9,317.9L843.7,319.6L845.6,320.6L846.8,321.7L848.4,323.6L849.1,323.6L850.4,324.4L850.6,325.3L852.9,326.4L854.9,325.3L855.7,323.6L856.5,322.3L857.2,320.5L858.4,318L858.3,316.5L858.7,315.6L858.6,313.8L859.4,311.5L860,310.8L859.7,309.8L860.6,308.1L861.3,306.4L861.5,305.5L862.6,304.3L863.2,305.9L863.1,307.8L863.8,308.2L863.7,309.5L864.4,311.1L864.3,312.9L864.1,314L864.6,316.5L866.6,315.3L867.2,316.6L868.3,317.9L867.8,319.2L867.8,321.9L867.9,323.5L868.5,323.9L868.7,326.6L868.1,328.2L868.5,330.3L871,331.9L872.5,333.4L873.9,334.8L873.4,335.6L874.4,337.5L874.5,340.9L875.8,340.2L876.5,341.6L877.3,341.1L876.8,344.4L878.1,346.4L878.9,347.6L880.2,350.1L880.1,352.6L879.5,354.4L878.7,356.4L879,359.1L877.8,361.8L876.8,363.3L875.1,366.1L874.4,367.9L873,370.2L870.7,373L868.1,374.6L866.1,377L864.6,378.6L862.6,381.3L861,382.8L859.2,385.2L857.9,387.3L857.5,388.3L855.6,389.4L852.7,389.5L849.7,390.8L848,392L845.8,393.4L844.4,392L843.2,391.4L844.3,389.8L842.7,390.4L839.4,392.7L837.6,391.8L836.5,391.3L835.1,391.1L833.1,390.2L832.4,388.3L833,385.9L833.1,384.3L832.4,383L830.1,382.6L831.6,381.1L831.9,378.8L829.8,381L827.3,381.5L829.3,379.8L830.4,378L832,376.4L832.7,374.1L829.6,376.8L827.6,377.9L825.6,380.4L824.2,379.1L824.9,377.4L824.2,375.1L823.3,374L824,373.2L821.4,371.3L819.7,371.2L817.7,369.7L813,370L809.3,371.1L806,372.2Z","Australia"],"031":["AZ","M594.6,139.9L595.3,140L597.3,141.9L598.4,142.1L598.7,141.3L600,140L601.6,141.7L603.2,143.9L604.4,144L605.3,144.9L603.3,145.1L603.3,147.5L603.1,148.6L602.3,149.4L602.6,150.9L602,151.1L600.2,149.4L600.8,147.9L599.9,147L599,147.2L596.4,149.5L596,147.3L594.8,146.8L593.6,146L594.2,145L592.7,143.9L593,143.1L592,142.6L591.4,141.8L591.9,141.3L593.9,142.2L595.2,142.4L595.5,142L594,140.3ZM595.5,149.6L593.7,149.2L592.2,147.7L591.7,146.6L592.2,146.5L593,147.3L594.1,147.3L594.2,147.8Z","Azerbaijan"],"096":["BN","M791.2,254L791.1,255.5L791.1,257.5L789.8,257.4L789.2,258.5L788,256.9L789,255.7Z","Brunei"],"xN. Cyprus":["","M563.1,160.9L563.3,160.9L563.6,160.1L565.4,160.2L567.6,159.2L566,160.5L566.3,161.1L566,161L565.6,161.3L565.2,161.2L565,161.3L565,161L564.8,160.8L564.3,160.8L563.6,161Z","N. Cyprus"],"xSomaliland":["","M611.3,235.4L611.3,235.4L611.3,236.7L611.5,239.9L611.5,241.5L610.4,243.4L608.6,246L606.3,246L597.4,242.3L596.4,241.2L595.3,239.7L594.3,238L594.8,236.9L595.7,235.2L596.6,235.8L597.2,237.1L598.5,238.4L599.8,238.4L602.3,237.6L605.2,237.2L607.5,236.3L608.9,236.1L609.8,235.5Z","Somaliland"],"070":["BA","M525.7,137.4L523.4,136.3L522.4,135L521.4,134.3L520.2,133.1L519.6,132.2L518.3,130.7L518.8,129.4L519.7,130.2L520.2,129.5L521.3,129.4L523.4,130L525.1,129.9L526.2,130.6L527.1,130.6L526.6,131.9L527.9,133.1L527.6,134.6L527.1,134.7L526.6,135L525.9,135.7Z","Bosnia and Herz."],"xKosovo":["","M530.8,139.9L530.6,138.8L530,138.5L529.4,137.6L529.8,136.9L530.4,136.7L530.6,135.7L531,135.5L531.4,135.9L531.9,136.1L532.3,136.6L532.7,136.8L533.2,137.3L533.6,137.3L533.3,138.1L533.1,138.5L533.2,138.7L532.6,138.8L531.2,139.3L531.2,139.9Z","Kosovo"]};

/* ================= v18 : cache persistant + préchargement, sync auto Letterboxd, carte du monde, toile des acteurs, soirée quiz, AniList ================= */
const pfSleep = ms => new Promise(r => setTimeout(r, ms));

/* ---------- Cache persistant (YouTube, Wikipédia) : les jeux n'attendent plus ---------- */
const PC = {dirty: new Set(), t: null};
const PC_KEYS = {l:'ringcine-c-ytl', f:'ringcine-c-ytf', p:'ringcine-c-plot', c:'ringcine-c-cast'};
const PC_CAP = {l:1800, f:2500, p:320, c:320};
function pcGet(k){ if (!PC[k]) PC[k] = ls.get(PC_KEYS[k], {}) || {}; return PC[k]; }
function pcPut(k, key, v){
  const o = pcGet(k); delete o[key]; o[key] = v;
  const ks = Object.keys(o); if (ks.length > PC_CAP[k]) ks.slice(0, ks.length - PC_CAP[k]).forEach(x => delete o[x]);
  PC.dirty.add(k); clearTimeout(PC.t); PC.t = setTimeout(pcFlush, 2500);
}
function pcFlush(){ PC.dirty.forEach(k => ls.set(PC_KEYS[k], PC[k])); PC.dirty.clear(); }
window.addEventListener('beforeunload', () => { try { pcFlush(); } catch(e){} });
{
  const _ytList = ytList, _ytFind = ytFind, _wikiPlot = wikiPlot, _wikiCast = wikiCast;
  ytList = async q => { const o = pcGet('l'); if (o[q]) return o[q]; const r = await _ytList(q); if (r && r.length) pcPut('l', q, r.slice(0, 8).map(x => ({id: x.id, t: String(x.t || '').slice(0, 140)}))); return r; };
  ytFind = async q => { const o = pcGet('f'); if (o[q]) return o[q]; const r = await _ytFind(q); if (r) pcPut('f', q, r); return r; };
  wikiPlot = async it => { const k = it.key || (it.t + '|' + it.y), o = pcGet('p'); if (o[k]) return o[k]; const r = await _wikiPlot(it); if (r) pcPut('p', k, r); return r; };
  wikiCast = async it => { const k = it.key || (it.t + '|' + it.y), o = pcGet('c'); if (o[k]) return o[k]; const r = await _wikiCast(it); if (r) pcPut('c', k, r); return r; };
}
/* ---------- Préchargement en arrière-plan ---------- */
const PF = {on:false, done:0, total:0, col:null};
async function prefetchRun(){
  if (PF.on || !SERVER || !C) return;
  PF.on = true; const colId = C.id; PF.col = colId;
  try {
    const top = ranking().order.slice(0, 350), pre = pcGet('p');
    const order = shuffle(top.filter(i => C.type !== 'films' || !pre[F[i].key])).slice(0, C.type === 'films' ? 30 : 60);
    PF.total = order.length; PF.done = 0;
    for (const i of order) {
      if (!C || C.id !== colId) break;
      for (let w = 0; w < 40 && curView === 'game' && G.busy; w++) await pfSleep(1500);
      const it = F[i];
      try {
        if (C.type === 'films') {
          await trailerFind(it); await pfSleep(400);
          await voTrailer(it); await pfSleep(400);
          await sceneClipFind(it); await pfSleep(400);
          await ytList(`${it.t} ${it.y || ''} trailer`); await ytList(`${it.t} ${it.y || ''} clip scene`);
          const L = FILM_SONGS.get(it.key); if (L) { for (const sg of L) await ytFind(`${sg[0]} - ${sg[1]} official audio`); } else await ostFind(it);
          await wikiPlot(it); await wikiCast(it);
        } else if (C.type === 'music' && !it.yt) {
          const y = await ytFind(`${it.first || it.sub || ''} ${it.t}`); if (y) it.yt = y;
        }
      } catch(e){}
      PF.done++; const el = document.getElementById('pfstat'); if (el) el.textContent = pfText();
      await pfSleep(900);
    }
  } finally { PF.on = false; const el = document.getElementById('pfstat'); if (el) el.textContent = pfText(); }
}
function pfText(){
  if (!SERVER) return '';
  if (PF.on && PF.col === (C && C.id)) return `⚡ Préchargement des jeux en arrière-plan : ${PF.done}/${PF.total}`;
  const n = Object.keys(pcGet('p')).length + Object.keys(pcGet('l')).length;
  return n ? `⚡ Jeux préchargés : les manches déjà préparées démarrent tout de suite.` : '';
}

/* ---------- Sync auto Letterboxd (flux RSS de ton profil, au démarrage) ---------- */
async function lbAutoSync(force){
  if (!SERVER) return;
  const last = ls.get('ringcine-lbauto', {}), now = Date.now();
  for (const col of allCols().filter(c => c.type === 'films' && c.user)) {
    if (!force && last[col.id] && now - last[col.id] < 3 * 3600e3) continue;
    try {
      const r = await fetch('/lbrss?u=' + encodeURIComponent(col.user)); if (!r.ok) continue;
      const xml = new DOMParser().parseFromString(await r.text(), 'text/xml');
      const rows = [], seen = new Set();
      [...xml.getElementsByTagName('item')].forEach(n => {
        const g = t => { const e = n.getElementsByTagName(t)[0]; return e ? e.textContent.trim() : ''; };
        const t = g('letterboxd:filmTitle'); if (!t) return;
        const y = +g('letterboxd:filmYear') || 0, name = `${t} (${y})`; if (seen.has(name)) return; seen.add(name);
        const m = g('description').match(/film-poster\/(?:\d\/)+(\d+-[^"?]+?)-0-\d+-0-\d+-crop\.jpg/);
        rows.push({t, y, r: Math.round((+g('letterboxd:memberRating') || 0) * 2), p: m ? m[1] : '', name});
      });
      last[col.id] = now; ls.set('ringcine-lbauto', last);
      if (!rows.length) continue;
      const known = allFilmMap();
      const o = {k:'lb', v:4, user: col.user, name: col.user, all: rows.map(x => [x.name, x.r]), add: rows.filter(x => !known.has(keyHash(x.name))).map(x => [x.t, x.y, '', x.r, x.p, x.name])};
      const res = applySync(JSON.stringify(o));
      if (res.ok && !/déjà à jour/.test(res.msg)) {
        toast('🔄 Letterboxd : ' + res.msg);
        if (C && C.id === col.id && !(curView === 'game' && G.id) && curView !== 'duel') afterSync(col.id);
        else if (C && C.id === col.id) { const v = curView; setTimeout(() => { if (curView === v && !(curView === 'game' && G.id)) afterSync(col.id); }, 60000); }
      }
    } catch(e){}
  }
}

/* ---------- Pays des films (Wikidata P495) ---------- */
const CTRY_KEY = 'ringcine-ctry3';
const CTRY_HIST = {Q15180:'643', Q34266:'643', Q713750:'276', Q16957:'276', Q43287:'276', Q7318:'276', Q41304:'276', Q33946:'203', Q83286:'688', Q174193:'826', Q161885:'826', Q70972:'250', Q172579:'380', Q13426199:'156'};
let ctryBusy = null;
function fetchCountries(onProg){
  if (ctryBusy) return ctryBusy;
  ctryBusy = (async () => {
    if (onProg) onProg('Recherche des films sur Wikidata…');
    const qid = await wdResolve(F.filter(it => it.t));
    const cache = ls.get(CTRY_KEY, {});
    F.forEach(it => { if (!qid[it.key] && cache[it.key] === undefined) cache[it.key] = 0; });
    const todo = F.filter(it => qid[it.key] && cache[it.key] === undefined);
    for (let p = 0; p < todo.length; p += 60) {
      const part = todo.slice(p, p + 60), byQ = new Map(part.map(it => [qid[it.key], it]));
      const vq = [...byQ.keys()].map(x => 'wd:' + x).join(' ');
      const got = new Map(), add = (b, num) => { const it = byQ.get(b.film.value.split('/').pop()); if (!it || !num) return; const n = String(num).padStart(3, '0'); if (!WORLD_MAP[n]) return; const L = got.get(it.key) || []; if (!L.includes(n)) L.push(n); got.set(it.key, L); };
      // pays d'origine ; si Wikidata en donne plusieurs, on garde ceux qui parlent la langue du film (ex. Get Out : États-Unis, pas le Japon)
      const B = await otSparql(`SELECT ?film ?c ?num ?num2 ?ok WHERE { VALUES ?film { ${vq} } ?film wdt:P495 ?c . OPTIONAL { ?c wdt:P299 ?num } OPTIONAL { ?c wdt:P1366 ?c2 . ?c2 wdt:P299 ?num2 } OPTIONAL { ?film wdt:P364 ?l . { ?c wdt:P37 ?l } UNION { VALUES (?c ?l) { (wd:Q30 wd:Q1860) (wd:Q408 wd:Q1860) (wd:Q145 wd:Q1860) (wd:Q16 wd:Q1860) (wd:Q16 wd:Q150) } } BIND(1 AS ?ok) } }`);
      const perF = new Map();
      B.forEach(b => { const f = b.film.value, num = b.num ? b.num.value : b.num2 ? b.num2.value : CTRY_HIST[b.c.value.split('/').pop()]; if (!num) return; const m = perF.get(f) || new Map(); m.set(num, (m.get(num) || false) || !!b.ok); perF.set(f, m); });
      perF.forEach((m, f) => { const anyOk = [...m.values()].some(Boolean); m.forEach((ok, num) => { if (!anyOk || ok) add({film:{value:f}}, num); }); });
      // pas de pays d'origine : pays de la société de production, sinon langue originale
      const miss = [...byQ.entries()].filter(([, it]) => !got.has(it.key)).map(([q]) => 'wd:' + q);
      if (miss.length) {
        const B2 = await otSparql(`SELECT ?film ?num WHERE { VALUES ?film { ${miss.join(' ')} } { ?film wdt:P272 ?co . ?co wdt:P17 ?c . ?c wdt:P299 ?num } UNION { ?film wdt:P1071 ?loc . ?loc wdt:P17 ?c . ?c wdt:P299 ?num } }`).catch(() => []);
        const seen2 = new Set(); B2.forEach(b => { const f = b.film.value; if (seen2.has(f)) return; seen2.add(f); add(b, b.num.value); });
      }
      part.forEach(it => { cache[it.key] = got.get(it.key) || 0; });
      ls.set(CTRY_KEY, cache);
      if (onProg) onProg(`Recherche des pays… ${Math.min(todo.length, p + 60)}/${todo.length}`);
    }
    return true;
  })().catch(() => false).finally(() => { ctryBusy = null; });
  return ctryBusy;
}
let RNAMES = null;
function ctryName(num){
  const W = WORLD_MAP[num]; if (!W) return num;
  try { RNAMES ||= new Intl.DisplayNames(['fr'], {type:'region'}); return W[0] ? RNAMES.of(W[0]) : W[2]; } catch(e){ return W[2]; }
}
let mapSel = null, mapMsg = '';
function renderMap(tabs){
  const cache = ls.get(CTRY_KEY, {});
  if (F.some(it => cache[it.key] === undefined)) {
    view.innerHTML = `${tabs}<div class="panel"><h3>🌍 Carte du monde</h3><div class="gload"><span class="spin"></span><span id="mapmsg">${esc(mapMsg || 'Recherche des pays de tes films…')}</span></div><p class="note">La première fois, Ring cherche le pays de chaque film sur Wikidata (une minute environ).</p></div>`;
    bindStatTabs();
    fetchCountries(m => { mapMsg = m; const el = $('mapmsg'); if (el) el.textContent = m; }).then(() => { if (curView === 'stats' && statsTab === 'map') renderStats(); });
    return;
  }
  const {rank} = ranking(), by = new Map();
  F.forEach((it, i) => (cache[it.key] || []).forEach(n => { if (!by.has(n)) by.set(n, []); by.get(n).push(i); }));
  by.forEach(L => L.sort((a, b) => rank[a] - rank[b]));
  const max = Math.max(1, ...[...by.values()].map(L => L.length)), known = F.filter(it => cache[it.key]).length;
  const shade = n => n ? (0.18 + 0.82 * Math.log(1 + n) / Math.log(1 + max)).toFixed(2) : 0;
  const paths = Object.entries(WORLD_MAP).map(([num, [, d]]) => { const n = (by.get(num) || []).length; return `<path d="${d}" data-c="${num}" class="${n ? 'has' : ''}${mapSel === num ? ' sel' : ''}" style="${n ? `--o:${shade(n)}` : ''}"><title>${esc(ctryName(num))} · ${n} film${n > 1 ? 's' : ''}</title></path>`; }).join('');
  const top = [...by].sort((a, b) => b[1].length - a[1].length);
  const sug = ['392','410','356','380','724','076','484','364','208','752','578','156','344','032','616','643','792','158','566','818'].filter(n => !by.has(n) && WORLD_MAP[n]).slice(0, 8);
  const selL = mapSel ? (by.get(mapSel) || []) : [];
  view.innerHTML = `${tabs}<div class="map-wrap">
    <div class="panel map-panel"><div class="map-head"><h3>🌍 Ta carte du monde</h3><span class="pill"><b>${by.size}</b> pays explorés sur ${Object.keys(WORLD_MAP).length}</span><span class="note">${fmt(known)} films situés sur ${fmt(N)}</span>${known < N ? `<button class="lnk" id="mapmiss">Voir les ${N - known} sans pays</button>` : ''}</div>
      <svg class="wmap" viewBox="0 0 960 470" role="img" aria-label="Carte des pays de tes films">${paths}</svg>
      <div class="map-leg"><span>1 film</span><i></i><span>${max} films</span></div></div>
    <div class="map-side">
      ${mapSel ? `<div class="panel"><h3>${esc(ctryName(mapSel))} · ${selL.length} film${selL.length > 1 ? 's' : ''}</h3>${selL.length ? `<div class="map-films">${selL.slice(0, 40).map(i => `<button class="map-f" data-i="${i}">${img(i, 'th')}<span>${T(i)}<small>#${rank[i]}</small></span></button>`).join('')}</div>` : '<p class="note">Aucun de tes films ne vient de ce pays. Une idée d’exploration !</p>'}</div>` : '<div class="panel"><p class="note">Clique sur un pays pour voir tes films qui en viennent.</p></div>'}
      <div class="panel"><h3>Tes pays</h3><div class="srows">${top.slice(0, 12).map(([n, L]) => `<button class="srow map-row" data-c="${n}"><span class="sname">${esc(ctryName(n))}</span><span class="sbar"><i style="width:${Math.max(4, L.length / max * 100).toFixed(1)}%"></i></span><span class="sval">${L.length}</span></button>`).join('')}</div></div>
      ${sug.length ? `<div class="panel"><h3>À explorer</h3><p class="note">De grands pays de cinéma où tu n’es jamais allé :</p><div class="map-sug">${sug.map(n => `<button class="chip" data-c="${n}">${esc(ctryName(n))}</button>`).join('')}</div></div>` : ''}
    </div></div>`;
  bindStatTabs();
  view.querySelectorAll('[data-c]').forEach(el => el.addEventListener('click', () => { mapSel = mapSel === el.dataset.c ? null : el.dataset.c; renderStats(); }));
  view.querySelectorAll('.map-f').forEach(b => b.onclick = () => { if (typeof openDetail === 'function') openDetail(+b.dataset.i); });
  if ($('mapmiss')) $('mapmiss').onclick = () => { const L = [...Array(N).keys()].filter(i => !cache[F[i].key]); openModal(`<div class="sheethead"><h2>${L.length} films sans pays</h2><button class="x" aria-label="Fermer">✕</button></div><p class="note">Wikidata ne connaît pas (encore) le pays de ces films, ou ne les a pas trouvés : souvent des films très récents ou peu connus.</p><div class="map-films" style="max-height:60vh">${L.map(i => `<div class="map-f">${img(i, 'th')}<span>${T(i)}<small>${F[i].y || ''}</small></span></div>`).join('')}</div>`); };
}
function openDetail(i){ const {rank} = ranking(); openModal(`<div class="sheethead"><h2>${T(i)}</h2><button class="x" aria-label="Fermer">✕</button></div>${detail(i, rank)}`, () => {}); }
function bindStatTabs(){ view.querySelectorAll('.ptabs [data-s]').forEach(b => b.onclick = () => { statsTab = b.dataset.s; renderStats(); }); }

/* ---------- Toile des acteurs (graphe interactif) ---------- */
const WEB = {nodes:null, edges:null, raf:0, sel:null, hover:null, zoom:1, ox:0, oy:0, min:2, q:'', col:null, imgs:new Map(), msg:''};
function webBuild(){
  const G2 = ptGraph(), cand = [...G2.af.entries()].filter(([a, L]) => L.length >= WEB.min && G2.act[a]).sort((x, y) => y[1].length - x[1].length).slice(0, 160);
  const idx = new Map(cand.map(([a], k) => [a, k]));
  const nodes = cand.map(([a, L], k) => { const ang = k * 2.39996, r = 40 + 14 * Math.sqrt(k); return {a, name: G2.act[a][0], img: G2.act[a][1], films: L, n: L.length, x: Math.cos(ang) * r, y: Math.sin(ang) * r, vx: 0, vy: 0}; });
  const em = new Map();
  G2.fa.forEach((acts, f) => { const inN = acts.filter(a => idx.has(a)); for (let x = 0; x < inN.length; x++) for (let y = x + 1; y < inN.length; y++) { const a = idx.get(inN[x]), b = idx.get(inN[y]), k = a < b ? a + ',' + b : b + ',' + a; em.set(k, (em.get(k) || 0) + 1); } });
  const edges = [...em].map(([k, w]) => { const [a, b] = k.split(',').map(Number); return {a, b, w}; });
  Object.assign(WEB, {nodes, edges, col: C.id, sel: null, hover: null, zoom: 1, ox: 0, oy: 0, it: 0, user: false});
}
function webStep(){
  const N2 = WEB.nodes, E = WEB.edges; if (!N2 || WEB.it > 420) return false;
  const alpha = Math.max(0.02, 1 - WEB.it / 420); WEB.it++;
  for (let i = 0; i < N2.length; i++) { const p = N2[i]; for (let j = i + 1; j < N2.length; j++) { const q = N2[j]; let dx = p.x - q.x, dy = p.y - q.y, d2 = dx * dx + dy * dy + 0.01; if (d2 > 90000) continue; const f = 900 / d2 * alpha; dx *= f; dy *= f; p.vx += dx; p.vy += dy; q.vx -= dx; q.vy -= dy; } }
  E.forEach(e => { const p = N2[e.a], q = N2[e.b], dx = q.x - p.x, dy = q.y - p.y, d = Math.sqrt(dx * dx + dy * dy) || 1, f = (d - 70) * 0.012 * Math.min(3, e.w) * alpha; p.vx += dx / d * f; p.vy += dy / d * f; q.vx -= dx / d * f; q.vy -= dy / d * f; });
  N2.forEach(p => { if (p.fix) { p.vx = p.vy = 0; return; } p.vx -= p.x * 0.012 * alpha; p.vy -= p.y * 0.012 * alpha; p.x += Math.max(-20, Math.min(20, p.vx)); p.y += Math.max(-20, Math.min(20, p.vy)); p.vx *= 0.55; p.vy *= 0.55; });
  return true;
}
function webImg(n){
  if (!n.img) return null; let im = WEB.imgs.get(n.a);
  if (!im) { im = new Image(); im.referrerPolicy = 'no-referrer'; im.onload = () => webDraw(); im.src = actImg(n.img).replace('width=240', 'width=96'); WEB.imgs.set(n.a, im); }
  return im.complete && im.naturalWidth ? im : null;
}
function webDraw(){
  const cv = $('webc'); if (!cv || !WEB.nodes) return;
  const dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
  if (cv.width !== Math.round(W * dpr)) { cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
  const g = cv.getContext('2d'), cs = getComputedStyle(document.documentElement), acc = cs.getPropertyValue('--acc').trim() || '#D8B46A', txt = cs.getPropertyValue('--text').trim() || '#eee', line = cs.getPropertyValue('--line2').trim() || '#333';
  g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
  g.translate(W / 2 + WEB.ox, H / 2 + WEB.oy); g.scale(WEB.zoom, WEB.zoom);
  const focus = WEB.sel != null ? WEB.sel : WEB.hover, nb = new Set();
  if (focus != null) WEB.edges.forEach(e => { if (e.a === focus) nb.add(e.b); if (e.b === focus) nb.add(e.a); });
  WEB.edges.forEach(e => { const on = focus != null && (e.a === focus || e.b === focus); if (focus != null && !on) return; const p = WEB.nodes[e.a], q = WEB.nodes[e.b]; g.strokeStyle = on ? acc : line; g.globalAlpha = on ? 0.9 : 0.35; g.lineWidth = (on ? 1.5 : 0.7) * Math.min(3, e.w) / WEB.zoom; g.beginPath(); g.moveTo(p.x, p.y); g.lineTo(q.x, q.y); g.stroke(); });
  g.globalAlpha = 1;
  WEB.nodes.forEach((n, k) => {
    const dim = focus != null && k !== focus && !nb.has(k), r = 8 + Math.sqrt(n.n) * 5;
    g.globalAlpha = dim ? 0.18 : 1;
    const im = webImg(n);
    g.save(); g.beginPath(); g.arc(n.x, n.y, r, 0, Math.PI * 2); g.closePath();
    if (im) { g.clip(); const s = Math.max(2 * r / im.naturalWidth, 2 * r / im.naturalHeight); g.drawImage(im, n.x - im.naturalWidth * s / 2, n.y - r * 1.1, im.naturalWidth * s, im.naturalHeight * s); }
    else { g.fillStyle = '#2a2a33'; g.fill(); g.fillStyle = txt; g.font = `700 ${Math.round(r * 0.8)}px Inter, sans-serif`; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(n.name.split(' ').map(w => w[0]).join('').slice(0, 2), n.x, n.y); }
    g.restore();
    g.beginPath(); g.arc(n.x, n.y, r, 0, Math.PI * 2); g.strokeStyle = k === focus ? acc : nb.has(k) ? acc : 'rgba(255,255,255,.25)'; g.lineWidth = (k === focus ? 3 : 1.2) / WEB.zoom; g.stroke();
    if (!dim && (WEB.zoom > 1.3 || n.n >= 5 || k === focus || nb.has(k))) { g.fillStyle = txt; g.font = `600 ${11 / Math.max(1, WEB.zoom * 0.8)}px Inter, sans-serif`; g.textAlign = 'center'; g.textBaseline = 'top'; g.fillText(n.name, n.x, n.y + r + 3); }
  });
  g.globalAlpha = 1;
}
function webFit(){ const cv = $('webc'); if (!cv || !WEB.nodes || !WEB.nodes.length) return; let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9; WEB.nodes.forEach(n => { x0 = Math.min(x0, n.x); x1 = Math.max(x1, n.x); y0 = Math.min(y0, n.y); y1 = Math.max(y1, n.y); }); const W = cv.clientWidth, H = cv.clientHeight; WEB.zoom = Math.max(0.3, Math.min(2, W / (x1 - x0 + 90), H / (y1 - y0 + 90))); WEB.ox = -(x0 + x1) / 2 * WEB.zoom; WEB.oy = -(y0 + y1) / 2 * WEB.zoom; }
function webLoop(){ cancelAnimationFrame(WEB.raf); const tick = () => { if (!$('webc')) return; const more = webStep() && webStep(); if (!WEB.user) webFit(); webDraw(); if (more) WEB.raf = requestAnimationFrame(tick); }; WEB.raf = requestAnimationFrame(tick); }
function webHit(cv, ev){
  const r = cv.getBoundingClientRect(), x = (ev.clientX - r.left - r.width / 2 - WEB.ox) / WEB.zoom, y = (ev.clientY - r.top - r.height / 2 - WEB.oy) / WEB.zoom;
  let best = null, bd = 1e9; WEB.nodes.forEach((n, k) => { const rr = 8 + Math.sqrt(n.n) * 5, d = (n.x - x) ** 2 + (n.y - y) ** 2; if (d < rr * rr && d < bd) { bd = d; best = k; } });
  return {k: best, x, y};
}
function renderWeb(tabs){
  const cast = ls.get(CAST_KEY, {});
  if (F.some(it => cast[it.key] === undefined)) {
    view.innerHTML = `${tabs}<div class="panel"><h3>🕸 Toile des acteurs</h3><div class="gload"><span class="spin"></span><span id="webmsg">${esc(WEB.msg || 'Récupération des castings…')}</span></div><p class="note">La première fois, Ring récupère le casting de tous tes films (une minute environ). C’est partagé avec le jeu Le Chemin.</p></div>`;
    bindStatTabs();
    fetchCastGraph(m => { WEB.msg = m; const el = $('webmsg'); if (el) el.textContent = m; }).then(() => { WEB.nodes = null; if (curView === 'stats' && statsTab === 'web') renderStats(); });
    return;
  }
  if (!WEB.nodes || WEB.col !== C.id) webBuild();
  const sel = WEB.sel != null ? WEB.nodes[WEB.sel] : null, {rank} = ranking();
  const co = sel ? WEB.edges.filter(e => e.a === WEB.sel || e.b === WEB.sel).map(e => ({n: WEB.nodes[e.a === WEB.sel ? e.b : e.a], w: e.w, k: e.a === WEB.sel ? e.b : e.a})).sort((a, b) => b.w - a.w) : [];
  view.innerHTML = `${tabs}<div class="web-wrap">
    <div class="panel web-panel"><div class="map-head"><h3>🕸 Toile des acteurs</h3><span class="note">${WEB.nodes.length} acteurs présents dans au moins ${WEB.min} de tes films · un trait = ils ont joué ensemble</span>
      <div class="fx" style="gap:8px;margin-left:auto;flex-wrap:wrap"><input class="input sm" id="webq" placeholder="Chercher un acteur…" value="${esc(WEB.q)}" style="width:190px"><div class="seg" id="webmin">${[2, 3, 4, 5].map(m => `<button data-m="${m}" aria-pressed="${WEB.min === m}">${m}+ films</button>`).join('')}</div><button class="btn sm ghost" id="webfit">Recentrer</button></div></div>
      <canvas id="webc" class="webc"></canvas><p class="note">Molette : zoom · glisser le fond : se déplacer · glisser un acteur : le bouger · clic : voir ses films</p></div>
    <div class="web-side">${sel ? `<div class="panel"><div class="web-who">${ptFaceWeb(sel)}<div><h3>${esc(sel.name)}</h3><p class="note">${sel.n} de tes films</p></div></div>
      <div class="map-films">${sel.films.slice().sort((a, b) => rank[a] - rank[b]).map(i => `<button class="map-f" data-i="${i}">${img(i, 'th')}<span>${T(i)}<small>#${rank[i]}</small></span></button>`).join('')}</div>
      ${co.length ? `<h3 style="margin-top:14px">A joué avec</h3><div class="map-sug">${co.slice(0, 16).map(x => `<button class="chip" data-k="${x.k}">${esc(x.n.name)}${x.w > 1 ? ` ×${x.w}` : ''}</button>`).join('')}</div>` : ''}</div>`
      : `<div class="panel"><h3>Les plus présents</h3><div class="srows">${WEB.nodes.slice(0, 12).map((n, k) => `<button class="srow map-row" data-k="${k}"><span class="sname">${esc(n.name)}</span><span class="sbar"><i style="width:${(n.n / WEB.nodes[0].n * 100).toFixed(1)}%"></i></span><span class="sval">${n.n}</span></button>`).join('')}</div></div>`}</div></div>`;
  bindStatTabs();
  const cv = $('webc');
  let drag = null;
  cv.onpointerdown = ev => { WEB.user = true; const h = webHit(cv, ev); drag = {k: h.k, sx: ev.clientX, sy: ev.clientY, ox: WEB.ox, oy: WEB.oy, moved: false}; if (h.k != null) WEB.nodes[h.k].fix = true; cv.setPointerCapture(ev.pointerId); };
  cv.onpointermove = ev => {
    if (!drag) { const h = webHit(cv, ev); if (h.k !== WEB.hover) { WEB.hover = h.k; cv.style.cursor = h.k != null ? 'pointer' : 'grab'; webDraw(); } return; }
    const dx = ev.clientX - drag.sx, dy = ev.clientY - drag.sy; if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
    if (drag.k != null) { const h = webHit(cv, ev); const n = WEB.nodes[drag.k]; n.x = h.x; n.y = h.y; } else { WEB.ox = drag.ox + dx; WEB.oy = drag.oy + dy; }
    webDraw();
  };
  cv.onpointerup = () => { if (!drag) return; const d = drag; drag = null; if (d.k != null) WEB.nodes[d.k].fix = false; if (!d.moved) { WEB.sel = d.k != null && d.k !== WEB.sel ? d.k : null; renderWeb(tabs); } };
  cv.onwheel = ev => { ev.preventDefault(); WEB.user = true; const z = Math.max(0.3, Math.min(4, WEB.zoom * (ev.deltaY < 0 ? 1.15 : 1 / 1.15))); const r = cv.getBoundingClientRect(), mx = ev.clientX - r.left - r.width / 2, my = ev.clientY - r.top - r.height / 2; WEB.ox = mx - (mx - WEB.ox) * z / WEB.zoom; WEB.oy = my - (my - WEB.oy) * z / WEB.zoom; WEB.zoom = z; webDraw(); };
  view.querySelectorAll('[data-k]').forEach(b => b.onclick = () => { WEB.sel = +b.dataset.k; const n = WEB.nodes[WEB.sel]; WEB.ox = -n.x * WEB.zoom; WEB.oy = -n.y * WEB.zoom; renderWeb(tabs); });
  view.querySelectorAll('.map-f').forEach(b => b.onclick = () => { if (typeof openDetail === 'function') openDetail(+b.dataset.i); });
  $('webmin').querySelectorAll('button').forEach(b => b.onclick = () => { WEB.min = +b.dataset.m; webBuild(); renderWeb(tabs); webLoop(); });
  $('webfit').onclick = () => { WEB.sel = null; WEB.user = false; renderWeb(tabs); webFit(); webDraw(); };
  const q = $('webq'); q.oninput = () => { WEB.q = q.value; const nq = norm(q.value); if (nq.length < 2) return; const k = WEB.nodes.findIndex(n => norm(n.name).includes(nq)); if (k >= 0) { WEB.sel = k; const n = WEB.nodes[k]; WEB.zoom = Math.max(WEB.zoom, 1.4); WEB.ox = -n.x * WEB.zoom; WEB.oy = -n.y * WEB.zoom; renderWeb(tabs); const q2 = $('webq'); q2.focus(); q2.setSelectionRange(q2.value.length, q2.value.length); } };
  if (WEB.it < 420) webLoop(); else { if (!WEB.user) webFit(); webDraw(); }
}
function ptFaceWeb(n){ const ini = n.name.split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase(); return n.img ? `<img class="pt-face" src="${esc(actImg(n.img))}" alt="" referrerpolicy="no-referrer" onerror="this.replaceWith(Object.assign(document.createElement('i'),{className:'pt-face noface',textContent:'${esc(ini)}'}))">` : `<i class="pt-face noface">${esc(ini)}</i>`; }

/* ---------- Soirée quiz : plusieurs joueurs sur le même PC ---------- */
const PARTY = {on:false, setup:false, players:[{n:'Joueur 1', s:0}, {n:'Joueur 2', s:0}], turn:0, per:3, played:0, game:null, pending:false, over:false};
function partyGames(){ return Object.entries(GAMES).filter(([id, g]) => !g.custom && g.types.includes(C.type) && !(g.server && !SERVER)); }
function renderPartySetup(){
  const L = partyGames(); if (!PARTY.game || !L.some(([id]) => id === PARTY.game)) PARTY.game = L.length ? L[0][0] : null;
  view.innerHTML = `<section class="party-setup"><div class="sech"><h2>🎉 Soirée quiz</h2><button class="btn sm ghost" id="pback">Retour</button></div>
    <p class="note">Jouez à plusieurs sur ce PC : chacun son tour, le même jeu, les points s’additionnent. Le meilleur score gagne.</p>
    <div class="panel"><h3>Joueurs</h3><div class="party-pl">${PARTY.players.map((p, k) => `<div class="fx" style="gap:8px"><span class="pnum">${k + 1}</span><input class="input" data-p="${k}" value="${esc(p.n)}" maxlength="18">${PARTY.players.length > 2 ? `<button class="btn sm ghost" data-rm="${k}">✕</button>` : ''}</div>`).join('')}</div>
      ${PARTY.players.length < 6 ? '<button class="btn sm" id="padd">＋ Ajouter un joueur</button>' : ''}</div>
    <div class="panel"><h3>Le jeu</h3><div class="modes gmodes">${L.map(([id, g]) => `<button class="mode${PARTY.game === id ? ' on' : ''}" data-pg="${id}" aria-pressed="${PARTY.game === id}"><em>${g.icon}</em><strong>${g.name}</strong></button>`).join('')}</div>
      <div class="gopts" style="margin-top:12px"><div><div class="note">Manches par joueur</div><div class="seg" id="pper">${[2, 3, 5, 8].map(n => `<button data-v="${n}" aria-pressed="${PARTY.per === n}">${n}</button>`).join('')}</div></div>
      <div><div class="note">Réponse</div><div class="seg" id="pmode"><button data-v="choice" aria-pressed="${G.mode === 'choice'}">4 choix</button><button data-v="type" aria-pressed="${G.mode === 'type'}">Je tape</button></div></div></div></div>
    <button class="btn primary" id="pgo" ${PARTY.game ? '' : 'disabled'}>🎉 Lancer la soirée</button></section>`;
  const keep = () => view.querySelectorAll('[data-p]').forEach(i => { PARTY.players[+i.dataset.p].n = i.value.trim() || `Joueur ${+i.dataset.p + 1}`; });
  $('pback').onclick = () => { keep(); PARTY.setup = false; renderGame(); };
  if ($('padd')) $('padd').onclick = () => { keep(); PARTY.players.push({n: `Joueur ${PARTY.players.length + 1}`, s: 0}); renderPartySetup(); };
  view.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => { keep(); PARTY.players.splice(+b.dataset.rm, 1); renderPartySetup(); });
  view.querySelectorAll('[data-pg]').forEach(b => b.onclick = () => { keep(); PARTY.game = b.dataset.pg; renderPartySetup(); });
  $('pper').querySelectorAll('button').forEach(b => b.onclick = () => { keep(); PARTY.per = +b.dataset.v; renderPartySetup(); });
  $('pmode').querySelectorAll('button').forEach(b => b.onclick = () => { keep(); G.mode = b.dataset.v; renderPartySetup(); });
  $('pgo').onclick = () => { keep(); partyStart(); };
}
function partyStart(){
  PARTY.players.forEach(p => p.s = 0); Object.assign(PARTY, {on:true, setup:false, turn:0, played:0, pending:false, over:false});
  try { if (!document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {}); } catch(e){}
  G.id = PARTY.game; G.round = 0; G.score = 0; G.streak = 0; G.used.clear(); gNewRound();
}
function partyBar(){
  if (!PARTY.on || !G.id) return;
  const host = $('gstage') || view; let bar = $('partybar');
  if (!bar) { bar = document.createElement('div'); bar.id = 'partybar'; bar.className = 'partybar'; host.prepend(bar); }
  const total = PARTY.players.length * PARTY.per, cur = PARTY.players[PARTY.turn];
  bar.innerHTML = `<div class="pb-turn">🎉 Au tour de <b>${esc(cur.n)}</b><small>manche ${Math.min(total, PARTY.played + (PARTY.pending ? 0 : 1))} / ${total}</small></div><div class="pb-sc">${PARTY.players.map((p, k) => `<span class="${k === PARTY.turn ? 'on' : ''}">${esc(p.n)} <b>${p.s}</b></span>`).join('')}</div>`;
}
function renderPartyEnd(){
  PARTY.on = false; PARTY.over = true; G.tok++; G.id = null; G.cur = null;
  const R2 = PARTY.players.map((p, k) => ({...p, k})).sort((a, b) => b.s - a.s), medals = ['🥇', '🥈', '🥉'];
  confetti(140); sfx('bell');
  view.innerHTML = `<section class="party-end"><span class="kicker">Soirée quiz · ${esc(GAMES[PARTY.game].name)}</span><h2>🏆 ${esc(R2[0].n)} gagne !</h2>
    <div class="podium">${R2.map((p, k) => `<div class="pod p${k}"><em>${medals[k] || (k + 1) + 'e'}</em><b>${esc(p.n)}</b><span>${p.s} pt${p.s > 1 ? 's' : ''}</span></div>`).join('')}</div>
    <div class="fx" style="gap:8px;justify-content:center"><button class="btn primary" id="pagain">↻ Rejouer</button><button class="btn" id="pset">Changer les réglages</button><button class="btn ghost" id="pquit">Quitter</button></div></section>`;
  $('pagain').onclick = partyStart; $('pset').onclick = () => { PARTY.over = false; PARTY.setup = true; renderGame(); }; $('pquit').onclick = () => { PARTY.over = false; try { if (document.fullscreenElement) document.exitFullscreen(); } catch(e){} renderGame(); };
}
{
  const _gEnd = gEnd, _gNew = gNewRound, _render = renderGame, _quit = gQuit, _picker = renderGamePicker;
  gEnd = function(won){ _gEnd(won); if (PARTY.on && G.cur && G.cur.done && !G.cur.partied) { G.cur.partied = true; PARTY.players[PARTY.turn].s += G.cur.pts || 0; PARTY.played++; PARTY.pending = true; partyBar(); } };
  gNewRound = function(){ if (PARTY.on && PARTY.pending) { PARTY.pending = false; if (PARTY.played >= PARTY.players.length * PARTY.per) return renderPartyEnd(); PARTY.turn = (PARTY.turn + 1) % PARTY.players.length; } return _gNew.apply(this, arguments); };
  renderGame = function(u){ if (!G.id && PARTY.setup) return renderPartySetup(); if (!G.id && PARTY.over && curView === 'game') return renderPartyEnd2(); const r = _render.apply(this, arguments); if (PARTY.on && G.id && GAMES[G.id] && !GAMES[G.id].custom) partyBar(); return r; };
  gQuit = function(){ PARTY.on = false; PARTY.over = false; return _quit.apply(this, arguments); };
  renderGamePicker = function(){
    _picker.apply(this, arguments);
    const h = view.querySelector('.sech'); if (h && !$('partygo')) { const b = document.createElement('button'); b.className = 'btn'; b.id = 'partygo'; b.textContent = '🎉 Soirée quiz à plusieurs'; b.onclick = () => { PARTY.setup = true; renderGame(); }; h.appendChild(b); }
    const st = pfText(); if (st && !$('pfstat')) { const p = document.createElement('p'); p.className = 'note'; p.id = 'pfstat'; p.textContent = st; const gm = view.querySelector('.gmodes'); if (gm) gm.before(p); }
  };
}
function renderPartyEnd2(){ PARTY.over = false; return renderGame(); }
/* ---------- Difficulté du jeu 1 seconde : popularité du film (rang dans le catalogue) ---------- */
const DIFFS = ['easy', 'medium', 'hard', 'expert', 'impossible'];
const DIFF_NAME = {easy:'Easy', medium:'Medium', hard:'Hard', expert:'Expert', impossible:'Impossible'};
const DIFF_RANK = {easy:[0, 150], medium:[150, 350], hard:[350, 600], expert:[600, 850], impossible:[850, Infinity]};
let EXT_RANK = null;
function popRank(it){ if (!EXT_RANK) { EXT_RANK = new Map(); EXT_FILMS.forEach(([t, y, , en], k) => { const key = keyHash(`${en || t} (${y})`); if (!EXT_RANK.has(key)) EXT_RANK.set(key, k); }); } const r = EXT_RANK.get(it.key); return r === undefined ? 9999 : r; }
function diffOk(it, d){ const [a, b] = DIFF_RANK[d] || DIFF_RANK.medium, r = popRank(it); return r >= a && r < b; }
/* musique : plus c'est dur, plus l'extrait est pris tôt (intro au lieu du refrain) */
function spotLadder(d){ const k = DIFFS.indexOf(d); return `<span class="gladder">${DIFFS.map((x, n) => `<i class="d-${x}${n === k ? ' on' : n < k ? ' done' : ''}">${DIFF_NAME[x]}</i>`).join('')}</span>${G.loop ? ` <span class="gloop">🔁 Boucle ${G.loop + 1}</span>` : ''}`; }
function diffStart(d){ return {easy:[45, 70], medium:[30, 50], hard:[15, 30], expert:[6, 15], impossible:[0, 4]}[d || 'medium'].reduce((a, b) => rnd(a, b)); }

/* ---------- Titres français des films (Wikidata) : on peut répondre en français ou en anglais ---------- */
const altTitle = it => { const a = [it.fr, it.en].filter(x => x && x !== it.t); return a.length ? ' · ' + esc(a[0]) : ''; };
let frBusy = false;
async function frRun(){
  if (frBusy || !ONLINE) return; frBusy = true;
  try {
    const cache = ls.get('ringcine-fr', {}), todo = [], seen = new Set();
    allCols().filter(c => c.type === 'films').forEach(col => buildItems(col).forEach(it => { if (cache[it.key] === undefined && !seen.has(it.key) && (it.en || it.t)) { seen.add(it.key); todo.push(it); } }));
    for (let p = 0; p < todo.length; p += 40) {
      const part = todo.slice(p, p + 40), tt = it => it.en || it.t;
      const vals = [...new Set(part.map(it => JSON.stringify(tt(it)) + '@en'))].join(' ');
      let B = [];
      try { B = await otSparql(`SELECT ?t ?y ?fr WHERE { VALUES ?t { ${vals} } VALUES ?cls { ${OT_CLS} } ?film rdfs:label ?t ; wdt:P31 ?cls ; rdfs:label ?fr . FILTER(LANG(?fr) = "fr") OPTIONAL { ?film wdt:P577 ?d . BIND(YEAR(?d) AS ?y) } }`); } catch(e){ continue; }
      part.forEach(it => {
        const rows = B.filter(b => b.t.value === tt(it) && (!it.y || !b.y || Math.abs(+b.y.value - it.y) <= 1));
        const fr = rows.length ? rows[0].fr.value.trim() : '';
        cache[it.key] = fr && norm(fr) !== norm(tt(it)) ? fr : '';
      });
      ls.set('ringcine-fr', cache);
      await new Promise(r => setTimeout(r, 400));
    }
    if (C && C.type === 'films' && F) F.forEach(it => { const f = cache[it.key]; if (f && norm(f) !== norm(it.t) && norm(f) !== norm(it.en)) it.fr = f; });
  } finally { frBusy = false; }
}

/* ---------- Multijoueur en ligne : 1 seconde à plusieurs, avec un code de partie ---------- */
const MP_RANK_PTS = [300, 150, 75], MP_GUESS_S = 12, MP_WRONG_PEN = 50;
/* jeux jouables à plusieurs : clip = extrait YouTube (vis = vidéo visible), sinon indice image / texte */
const MPG = {
  spot:      {name:'1 seconde', icon:'⏱', types:['films','music'], clip:true, get vis(){ return MP.type !== 'music'; }, steps:[1, 3, 6, 10]},
  sceneclip: {name:'Scène culte', icon:'🎬', types:['films'], clip:true, vis:true, steps:[3, 6, 12, 25]},
  sound:     {name:'Son du film', icon:'🔊', types:['films'], clip:true, vis:false, steps:[3, 6, 12, 25]},
  blind:     {name:'Blind test', icon:'🎧', types:['music'], clip:true, vis:true, steps:[1, 5, 10, 25]},
  poster:    {name:'Affiche zoomée', mname:'Pochette zoomée', icon:'🔍', types:['films','music'], steps:[9, 5.5, 3.4, 2, 1], lab:k => ['×9', '×5', '×3', '×2', 'Entière'][k]},
  plot:      {name:'Synopsis caché', icon:'📜', types:['films'], steps:[0, 1, 2, 3], lab:k => ['Début', 'Suite', 'Tout', '+ Année'][k]},
  cast:      {name:'Casting', icon:'🎭', types:['films'], steps:[0, 1, 2, 3], lab:k => ['1 acteur', '2 acteurs', '3 acteurs', '+ Année'][k]},
  quote:     {name:'Réplique culte', icon:'💬', types:['films'], steps:[0, 1, 2, 3], lab:k => ['VO', '+ Trad.', '+ Année', '+ Réal.'][k]},
  scene:     {name:'Scène du film', icon:'🎞', types:['films'], steps:[0, 1, 2, 3], lab:k => ['1 image', '2 images', '3 images', '4 images'][k]}
};
const mpG = () => MPG[MP.cfg.game] || MPG.spot;
const mpGName = (g, type) => (type === 'music' && g.mname) || g.name;
const mpPts = k => (mpG().steps.length === 5 ? [400, 300, 220, 150, 100] : [400, 300, 200, 100])[k] || 100;
const mpLab = k => { const g = mpG(); return g.lab ? g.lab(k) : g.steps[k] + ' s'; };
const MP = {on:false, peer:null, host:false, code:'', me:'', myId:'', conns:new Map(), conn:null, players:[], cfg:{rounds:10, src:'mix', game:'spot'},
  phase:'menu', round:0, stage:-1, deadline:0, cur:null, ans:null, titles:[], items:[], used:new Set(), next:null, timers:[], err:'', busy:false, myFound:false, myPts:0, wrong:[], hints:[], feed:[], wait:null, lastGuess:0};
const mpName = () => ls.get('ringcine-mpname', '') || ls.get('ringcine-name', '') || '';
function mpLoadLib(){
  if (window.Peer) return Promise.resolve();
  return new Promise((res, rej) => { const sc = document.createElement('script'); sc.src = 'https://unpkg.com/peerjs@1.5.4/dist/peerjs.min.js'; sc.onload = () => res(); sc.onerror = () => rej(new Error('impossible de charger le module multijoueur (connexion ?)')); document.head.appendChild(sc); });
}
function mpClear(){ MP.timers.forEach(clearTimeout); MP.timers = []; }
function mpLater(fn, ms){ MP.timers.push(setTimeout(fn, ms)); }
function mpReset(msg){
  mpClear(); try { if (MP.peer) MP.peer.destroy(); } catch(e){}
  Object.assign(MP, {peer:null, host:false, code:'', conns:new Map(), conn:null, players:[], phase:'menu', round:0, stage:-1, cur:null, ans:null, titles:[], items:[], used:new Set(), next:null, err: msg || '', busy:false, feed:[], hints:[], wrong:[], chatDraft:''});
  if (curView === 'game') renderGame();
}
function mpLeave(){ stopAudio(); if (MP.host) mpBroadcast({t:'bye'}); else if (MP.conn) try { MP.conn.close(); } catch(e){} MP.on = false; mpReset(); }
function mpSend(conn, msg){ try { if (conn && conn.open) conn.send(msg); } catch(e){} }
function mpBroadcast(msg){ MP.conns.forEach(c => mpSend(c, msg)); mpOnMsg(msg); }
function mpPublic(){ return MP.players.map(p => ({id:p.id, name:p.name, score:p.score, found:p.found, pts:p.pts, rank:p.rank, nw:p.nw || 0, list: p.rows ? p.rows.length : 0, ltype: p.ltype || ''})); }
function mpSync(){ mpBroadcast({t:'state', phase:MP.phase, round:MP.round, rounds:MP.cfg.rounds, stage:MP.stage, cfg:MP.cfg, players:mpPublic(), code:MP.code, type:C.type}); }
function mpCode(){ const A = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let c = ''; for (let k = 0; k < 5; k++) c += A[Math.floor(Math.random() * A.length)]; return c; }
/* la liste du joueur (son ring ouvert), envoyée à l'hôte pour le mélange */
function mpMyRows(){
  if (!C || (C.type !== 'films' && C.type !== 'music')) return {type:'', rows:[]};
  const L = EXT.on && EXT.saved ? EXT.saved.F : F;
  return {type: C.type, rows: L.slice(0, 3000).map(it => C.type === 'films' ? [it.t, it.y || 0, it.sub || '', it.en || '', it.img || '', it.key, it.fr || ''] : [it.t, it.sub || '', it.img || '', it.key, it.first || ''])};
}
const mpRowItem = (type, r) => type === 'films' ? {t:r[0], y:r[1], sub:r[2], en:r[3], img:safeUrl(r[4]), key:r[5], fr:r[6] || ''} : {t:r[0], sub:r[1], img:safeUrl(r[2]), key:r[3], first:r[4], yt:''};

async function mpCreate(name){
  if (!SERVER) { MP.err = 'Ouvre Ring avec Ring.bat pour créer une partie.'; return renderGame(); }
  if (!name) { toast('Écris ton prénom.'); return; }
  ls.set('ringcine-mpname', name); MP.me = name; MP.busy = true; MP.err = ''; renderGame();
  try { await mpLoadLib(); } catch(e){ MP.busy = false; MP.err = e.message; return renderGame(); }
  const open = tries => {
    MP.code = mpCode();
    const peer = new Peer('ringcine-mp-' + MP.code);
    peer.on('open', id => { MP.peer = peer; MP.host = true; MP.myId = 'host'; MP.busy = false; MP.phase = 'lobby'; const mine = mpMyRows(); MP.players = [{id:'host', name, score:0, rows: mine.rows, ltype: mine.type}]; mpSync(); });
    peer.on('error', e => { if (e.type === 'unavailable-id' && tries < 4) { try { peer.destroy(); } catch(x){} open(tries + 1); } else if (!MP.peer || e.type === 'network' || e.type === 'server-error') { MP.busy = false; MP.err = 'Connexion au service multijoueur impossible (' + e.type + ').'; renderGame(); } });
    peer.on('connection', conn => {
      conn.on('data', d => mpHostMsg(conn, d));
      conn.on('close', () => { MP.conns.delete(conn.peer); MP.players = MP.players.filter(p => p.id !== conn.peer); if (MP.phase !== 'menu') mpSync(); });
    });
  };
  open(0);
}
async function mpJoin(name, code){
  code = String(code || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (!name) { toast('Écris ton prénom.'); return; }
  if (code.length < 4) { toast('Tape le code de la partie (5 caractères).'); return; }
  ls.set('ringcine-mpname', name); MP.me = name; MP.busy = true; MP.err = ''; renderGame();
  try { await mpLoadLib(); } catch(e){ MP.busy = false; MP.err = e.message; return renderGame(); }
  const peer = new Peer(); MP.peer = peer;
  const fail = msg => { if (MP.peer !== peer) return; MP.busy = false; MP.err = msg; try { peer.destroy(); } catch(x){} MP.peer = null; renderGame(); };
  const to = setTimeout(() => fail('Pas de réponse : vérifie le code (l’hôte doit avoir Ring ouvert).'), 15000);
  peer.on('error', e => { clearTimeout(to); fail(e.type === 'peer-unavailable' ? 'Code introuvable : vérifie-le avec l’hôte.' : 'Connexion impossible (' + e.type + ').'); });
  peer.on('open', id => {
    MP.myId = id;
    const conn = peer.connect('ringcine-mp-' + code, {reliable:true}); MP.conn = conn;
    conn.on('open', () => { clearTimeout(to); MP.code = code; MP.host = false; MP.busy = false; MP.phase = 'lobby'; const mine = mpMyRows(); mpSend(conn, {t:'hello', name, ltype: mine.type, rows: mine.rows}); renderGame(); });
    conn.on('data', d => mpOnMsg(d));
    conn.on('close', () => { if (MP.on && MP.conn === conn && MP.phase !== 'menu') mpReset('L’hôte a fermé la partie.'); });
  });
}

/* --- côté hôte --- */
function mpHostMsg(conn, d){
  if (!d || typeof d !== 'object') return;
  if (d.t === 'hello') {
    MP.conns.set(conn.peer, conn);
    let name = String(d.name || 'Joueur').slice(0, 24); const taken = new Set(MP.players.map(p => p.name)); let n = 2; const base = name; while (taken.has(name)) name = base + ' ' + n++;
    MP.players.push({id: conn.peer, name, score:0, ltype: String(d.ltype || ''), rows: Array.isArray(d.rows) ? d.rows.slice(0, 3000) : []});
    mpSend(conn, {t:'welcome', id: conn.peer, name});
    if (MP.titles.length) mpSend(conn, {t:'titles', list: MP.titles, type: MP.type});
    if (MP.cur && (MP.phase === 'stage' || MP.phase === 'load')) mpSend(conn, {t:'round', round:MP.round, yt:MP.cur.yt, audio:MP.cur.audio, start:MP.cur.start, lvl:MP.cur.lvl, clue:MP.cur.clue});
    mpSync();
  }
  if (d.t === 'guess') mpHostGuess(conn.peer, d.text, d.j);
  if (d.t === 'chat') mpHostChat(conn.peer, d.text);
}
function mpHostChat(id, text){
  const p = MP.players.find(x => x.id === id); if (!p) return;
  let t = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 160); if (!t) return;
  if (MP.cur && MP.phase === 'stage' && MP.items[MP.cur.k]) {
    const it = MP.items[MP.cur.k], nt = norm(t);
    if ([it.t, it.en, it.fr].some(x => x && norm(x).length >= 3 && nt.includes(norm(x)))) t = '🤐 (réponse cachée)';
  }
  mpBroadcast({t:'msg', name: p.name, text: t});
}
function mpChat(text){
  text = String(text || '').trim(); if (!text) return;
  if (MP.host) mpHostChat('host', text); else mpSend(MP.conn, {t:'chat', text});
}
/* toutes les listes : rings de l'hôte du même type + liste de chaque joueur, sans doublons */
function mpMixItems(){
  const map = new Map(), add = (it, who) => { if (!it || !it.t || !it.key) return; let x = map.get(it.key); if (!x) { x = Object.assign({}, it, {own: []}); map.set(it.key, x); } if (!x.fr && it.fr) x.fr = it.fr; if (!x.own.includes(who)) x.own.push(who); };
  const host = MP.players.find(p => p.id === 'host');
  allCols().filter(c => c.type === C.type).forEach(col => { const who = col.id === C.id ? (host ? host.name : 'Hôte') : col.label; (col.id === C.id ? (EXT.on && EXT.saved ? EXT.saved.F : F) : buildItems(col)).forEach(it => add(it, who)); });
  MP.players.filter(p => p.id !== 'host' && p.ltype === C.type).forEach(p => p.rows.forEach(r => add(mpRowItem(C.type, r), p.name)));
  return [...map.values()];
}
async function mpStartGame(){
  const cfg = MP.cfg; MP.busy = true; renderGame();
  let items;
  try {
    if (cfg.src === 'ext') items = await extItems(); else if (cfg.src === 'mix') items = mpMixItems(); else items = (EXT.on && EXT.saved ? EXT.saved.F : F).slice();
  } catch(e){ MP.busy = false; MP.err = e.message; return renderGame(); }
  MP.type = C.type;
  let pool = items.map((_, k) => k);
  MP.pools = {}; DIFFS.forEach(d => { MP.pools[d] = C.type === 'films' ? pool.filter(k => diffOk(items[k], d)) : pool; });
  if (!MPG[cfg.game] || !MPG[cfg.game].types.includes(C.type)) cfg.game = 'spot';
  if (pool.length < 4) { MP.busy = false; MP.err = 'Pas assez de ' + TY.many + ' pour jouer.'; return renderGame(); }
  if (cfg.game === 'quote' || cfg.game === 'poster') { const n = items.filter(it => cfg.game === 'quote' ? QUOTES.has(it.key) : it.img).length; if (n < 3) { MP.busy = false; MP.err = `Pas assez de ${TY.many} utilisables pour « ${mpGName(MPG[cfg.game], C.type)} » dans cette source (${n}).`; return renderGame(); } }
  MP.items = items; MP.pool = pool; MP.used = new Set(); MP.next = null; MP.busy = false; MP.err = '';
  MP.titles = items.map(it => [it.t, C.type === 'music' ? (it.sub || '') : String(it.y || ''), it.en && it.en !== it.t ? it.en : '', tinyRes(it.img || ''), it.fr || '']);
  MP.players.forEach(p => { p.score = 0; p.found = false; p.pts = 0; p.rank = 0; p.nw = 0; });
  mpBroadcast({t:'titles', list: MP.titles, type: MP.type});
  MP.round = 0; mpNextRound();
}
const mpLevel = round => DIFFS[(Math.max(1, round) - 1) % DIFFS.length];
function mpCan(it){ const id = MP.cfg.game; if (id === 'poster') return !!it.img; if (id === 'quote') return QUOTES.has(it.key); return true; }
async function mpPrep(it, lvl){
  const id = MP.cfg.game, music = MP.type === 'music', who = `${it.first || it.sub || ''} ${it.t}`;
  if (music && id === 'spot') { const au = await spPreview(it.key); if (au) return {audio: au, start: pvStart(lvl, MPG[id].steps[MPG[id].steps.length - 1])}; }
  if (id === 'spot') { const yt = music ? (it.yt || await ytFind(`${who} official audio`)) : await sceneClipFind(it); return yt ? {yt, start: music ? diffStart(lvl) : rnd(3, 20)} : null; }
  if (id === 'sceneclip') { const yt = await sceneClipFind(it); return yt ? {yt, start: rnd(6, 30)} : null; }
  if (id === 'blind') { const yt = it.yt || await ytFind(who); return yt ? {yt, start: diffStart(lvl)} : null; }
  if (id === 'sound') { const yt = await voTrailer(it); return yt ? {yt, start: rnd(20, 50)} : null; }
  if (id === 'poster') return it.img ? {clue: {img: hiRes(it.img, true), lo: it.img, fx: rnd(22, 78), fy: rnd(18, 70), sq: music}} : null;
  if (id === 'plot') { const wp = await wikiPlot(it); if (!wp) return null; const sent = (maskText(wp.plot, it, wp.title).match(/[^.!?]+[.!?]+(\s|$)|[^.!?]+$/g) || [wp.plot]).map(x => x.trim()).filter(Boolean); return {clue: {sent, y: it.y || '', sub: it.sub || ''}}; }
  if (id === 'cast') { const cast = await wikiCast(it); if (!cast || cast.filter(x => x.img).length < 2) return null; return {clue: {cast: cast.slice(0, 6).map(a => ({n: a.n, img: a.img || ''})), y: it.y || ''}}; }
  if (id === 'quote') { const q = QUOTES.get(it.key); return q ? {clue: {q: [maskText(q[0], it), maskText(q[1], it)], y: it.y || '', sub: it.sub || ''}} : null; }
  if (id === 'scene') {
    const yt = await trailerFind(it); if (!yt) return null;
    const frames = [[yt, 2], [yt, 1], [yt, 3]], rel = relTitle(it);
    const L2 = (await ytList(`${it.en || it.t} ${it.y || ''} clip scene`)).filter(x => x.id !== yt && rel(x) && /clip|scene|scène|extrait|trailer/i.test(x.t));
    if (L2[0]) frames.push([L2[0].id, 2]);
    return {clue: {frames: frames.slice(0, 4)}};
  }
  return null;
}
async function mpPick(round){
  const lvl = mpLevel(round), base = MP.pools && MP.pools[lvl] && MP.pools[lvl].filter(k => mpCan(MP.items[k])).length >= 2 ? MP.pools[lvl] : MP.pool;
  const P = base.filter(k => mpCan(MP.items[k]));
  for (let tries = 0; tries < 10 && P.length; tries++) {
    let free = P.filter(k => !MP.used.has(k)); if (!free.length) free = P.slice();
    const k = free[Math.floor(Math.random() * free.length)]; MP.used.add(k);
    let c = null; try { c = await mpPrep(MP.items[k], lvl); } catch(e){}
    if (c) { if (c.clue) c.clue.g = MP.cfg.game; return Object.assign({k, lvl, yt: '', audio: '', start: 0, clue: null}, c); }
  }
  return null;
}
async function mpNextRound(){
  if (!MP.host) return;
  mpClear();
  if (MP.round >= MP.cfg.rounds) { MP.phase = 'end'; mpSync(); return; }
  MP.phase = 'load'; MP.round++; MP.stage = -1; mpSync();
  const r = MP.next ? await MP.next : await mpPick(MP.round); MP.next = null;
  if (!MP.host || MP.phase !== 'load') return;
  if (!r) { MP.err = MPG[MP.cfg.game] && MPG[MP.cfg.game].clip ? 'Impossible de trouver des vidéos (connexion ?).' : 'Impossible de préparer les manches (connexion ?).'; MP.phase = 'lobby'; MP.round = 0; mpSync(); return; }
  MP.cur = r; MP.players.forEach(p => { p.found = false; p.pts = 0; p.rank = 0; p.nw = 0; });
  mpBroadcast({t:'round', round:MP.round, yt:r.yt, audio:r.audio, start:r.start, lvl:r.lvl, clue:r.clue});
  MP.next = MP.round < MP.cfg.rounds ? mpPick(MP.round + 1) : null;
  mpLater(() => mpStage(0), 4000);
}
function mpStage(k){
  if (!MP.host) return;
  mpClear(); MP.phase = 'stage'; MP.stage = k;
  const g = mpG(), clip = g.clip ? g.steps[k] - (k ? g.steps[k - 1] : 0) + 1.5 : 2, ms = (clip + MP_GUESS_S) * 1000;
  mpBroadcast({t:'stage', k, ms}); mpSync();
  mpLater(() => k < g.steps.length - 1 ? mpStage(k + 1) : mpReveal(), ms);
}
/* indices donnés au joueur au fil de ses erreurs */
function mpHints(it, nw){
  const h = [], t = String(it.t || '');
  if (MP.type === 'music') {
    if (nw >= 2 && it.sub) h.push(`L’artiste commence par « ${it.sub.trim()[0].toUpperCase()} »`);
    if (nw >= 3 && it.sub) h.push(`Artiste : ${it.sub}`);
  } else {
    if (nw >= 2 && it.y) h.push(`Sorti en ${it.y}`);
    if (nw >= 3 && it.sub) h.push(`Réalisé par ${it.sub}`);
  }
  if (nw >= 4) h.push(`Le titre commence par « ${t.slice(0, 1).toUpperCase()} » (${t.replace(/[^\p{L}\p{N}]/gu, '').length} lettres)`);
  if (nw >= 6) h.push(`Le titre commence par « ${t.slice(0, Math.min(4, Math.ceil(t.length / 3)))}… »`);
  return h;
}
function mpHostGuess(id, text, j){
  const p = MP.players.find(x => x.id === id); if (!p || MP.phase !== 'stage' || p.found) return;
  const to = id === 'host' ? null : MP.conns.get(id), send = m => to ? mpSend(to, m) : mpOnMsg(m);
  const it = MP.items[MP.cur.k], nt = norm(text);
  const ok = j === MP.cur.k || (j != null && j >= 0 && MP.titles[j] && norm(MP.titles[j][0]) === norm(it.t) && MP.titles[j][1] === MP.titles[MP.cur.k][1]) || (nt && (nt === norm(it.t) || (it.en && nt === norm(it.en)) || (it.fr && nt === norm(it.fr))));
  const label = j != null && j >= 0 && MP.titles[j] ? MP.titles[j][0] : String(text || '').slice(0, 60);
  if (!ok) {
    p.nw = (p.nw || 0) + 1;
    send({t:'res', ok:false, text: label});
    mpBroadcast({t:'try', name: p.name, text: label, ok:false});
    mpSync(); return;
  }
  const rank = MP.players.filter(x => x.found).length;
  const pts = Math.max(50, mpPts(MP.stage) + (MP_RANK_PTS[rank] || 0) - MP_WRONG_PEN * (p.nw || 0));
  p.found = true; p.pts = pts; p.rank = rank + 1; p.score += pts;
  send({t:'res', ok:true, pts, rank: rank + 1});
  mpBroadcast({t:'try', name: p.name, ok:true, rank: rank + 1});
  mpSync();
  if (MP.players.every(x => x.found)) { mpClear(); mpLater(mpReveal, 1500); }
}
function mpReveal(){
  if (!MP.host) return;
  mpClear(); MP.phase = 'reveal';
  const it = MP.items[MP.cur.k];
  mpBroadcast({t:'reveal', ans:{t: it.t, en: [it.fr, it.en].filter(x => x && x !== it.t).join(' · '), sub: it.sub || '', y: it.y || '', img: it.img || '', own: MP.cfg.src === 'mix' ? (it.own || []) : []}});
  mpSync();
  mpLater(mpNextRound, 10000);
}

/* --- côté joueur (l'hôte passe aussi par ici) --- */
function mpOnMsg(d){
  if (!d || typeof d !== 'object') return;
  if (d.t === 'welcome') { MP.myId = d.id; MP.me = d.name; }
  else if (d.t === 'titles') { MP.titles = d.list || []; MP.type = d.type; }
  else if (d.t === 'state') {
    const prev = MP.phase; Object.assign(MP, {phase:d.phase, round:d.round, stage:d.stage}); MP.pub = d.players || []; if (!MP.host) MP.players = MP.pub; MP.cfg = d.cfg || MP.cfg; if (d.code) MP.code = d.code; if (d.type) MP.htype = d.type;
    if (d.phase === 'end' && prev !== 'end') { confetti(140); sfx('bell'); }
    return mpRender(true);
  }
  else if (d.t === 'round') { MP.lvl = d.lvl || 'easy'; if (!MP.host) MP.cur = {yt:safeYt(d.yt), audio: PV_RX.test(d.audio || '') ? d.audio : '', start:+d.start || 0, clue:d.clue || null}; stopAudio(); MP.ans = null; MP.myFound = false; MP.myPts = 0; MP.wrong = []; MP.hints = []; MP.feed.push({sys:1, text:'Manche ' + d.round}); MP.feed = MP.feed.slice(-120); MP.stage = -1; MP.phase = 'load'; MP.round = d.round; mpRender(); }
  else if (d.t === 'stage') { MP.stage = d.k; MP.deadline = Date.now() + d.ms; MP.phase = 'stage'; mpRender(); const g = mpG(); if (g.clip) mpPlay(d.k ? g.steps[d.k - 1] : 0, g.steps[d.k]); }
  else if (d.t === 'res') { if (d.ok) { MP.myFound = true; MP.myPts = d.pts; sfx('win'); if (d.rank === 1) confetti(60); } else { MP.wrong.unshift(d.text); MP.hints = d.hints || MP.hints; sfx('lose'); } mpRender(); }
  else if (d.t === 'try' || d.t === 'msg') { MP.feed.push(d); MP.feed = MP.feed.slice(-120); mpFeedDraw(); }
  else if (d.t === 'reveal') { MP.ans = d.ans; MP.phase = 'reveal'; mpRender(); const f = $('mpframe'); if (f) { ytCmd(f, 'seekTo', [MP.cur.start, true]); ytCmd(f, 'playVideo'); } const au = $('mpaudio'); if (au) { clearTimeout(MP.pauseT); try { au.currentTime = 0; } catch(e){} au.play().catch(() => {}); } }
  else if (d.t === 'bye') { mpReset('L’hôte a fermé la partie.'); }
}
function mpPlay(from, to, tries = 0){
  const au = $('mpaudio');
  if (au && MP.cur && MP.cur.audio) {
    clearTimeout(MP.pauseT); MP.wait = {dur: to - from, from, to, id: Date.now()}; MP.lastPlay = {from, to}; const w = MP.wait;
    try { au.currentTime = MP.cur.start + from; } catch(e){}
    au.volume = gVol();
    au.play().then(() => { if (MP.wait === w) mpPlaying(); }).catch(() => { if (MP.wait !== w) return; MP.wait = null; const b = $('mpclip'); if (b) { b.classList.add('blocked'); const sp = b.querySelector('.gmask span'); if (sp) sp.textContent = '🔇 Le son ne démarre pas : clique ici pour le lancer'; } });
    return;
  }
  const f = $('mpframe'); if (!f) return;
  if (!f.dataset.ready) { if (tries < 40) setTimeout(() => mpPlay(from, to, tries + 1), 200); return; }
  clearTimeout(MP.pauseT);
  MP.wait = {dur: to - from, from, to, id: Date.now()}; MP.lastPlay = {from, to};
  ytCmd(f, 'unMute'); ytCmd(f, 'setVolume', [Math.round(gVol() * 100)]); ytCmd(f, 'seekTo', [MP.cur.start + from, true]); ytCmd(f, 'playVideo');
  const w = MP.wait;
  /* le navigateur a bloqué la lecture : on demande un clic (obligatoire pour lancer un son) */
  setTimeout(() => { if (MP.wait !== w) return; MP.wait = null; const b = $('mpclip'); if (b) { b.classList.add('blocked'); const sp = b.querySelector('.gmask span'); if (sp) sp.textContent = '🔇 Le son ne démarre pas : clique ici pour le lancer'; } }, 4500);
}
function mpPlaying(){
  const w = MP.wait; if (!w) return; MP.wait = null;
  const box = $('mpclip'); if (box) { box.classList.add('playing'); if (box.classList.contains('blocked')) { box.classList.remove('blocked'); const sp = box.querySelector('.gmask span'); if (sp) sp.textContent = mpG().vis ? '⏱' : '🎧'; } }
  const pr = $('mpprog'); if (pr) { pr.style.transition = 'none'; pr.style.width = (w.from / w.to * 100) + '%'; void pr.offsetWidth; pr.style.transition = `width ${w.dur}s linear`; pr.style.width = '100%'; }
  MP.pauseT = setTimeout(() => { const f = $('mpframe'); if (f && MP.phase !== 'reveal') ytCmd(f, 'pauseVideo'); const au = $('mpaudio'); if (au && MP.phase !== 'reveal') au.pause(); const b = $('mpclip'); if (b && MP.phase !== 'reveal') b.classList.remove('playing'); }, w.dur * 1000);
}
window.addEventListener('message', e => {
  const f = $('mpframe'); if (!f || e.source !== f.contentWindow) return;
  let d = e.data; if (typeof d === 'string') { try { d = JSON.parse(d); } catch(err) { return; } }
  const st = d && (d.event === 'onStateChange' ? d.info : d.event === 'infoDelivery' && d.info ? d.info.playerState : undefined);
  if (st === 1 && MP.wait) mpPlaying();
});
function mpGuess(text, j){
  if (MP.phase !== 'stage' || MP.myFound) return;
  const now = Date.now(); if (now - MP.lastGuess < 600) return; MP.lastGuess = now;
  if (MP.host) mpHostGuess('host', text, j); else mpSend(MP.conn, {t:'guess', text, j});
}
/* recherche : seulement les titres dont un mot commence par ce qu'on tape */
function mpSuggest(q){
  q = norm(q); if (!q) return [];
  const out = [], seen = new Set();
  MP.titles.forEach(([t, s, en, im, fr], j) => {
    const a = norm(t), b = norm(en), c = norm(fr); let v = 0;
    if (a.startsWith(q) || (b && b.startsWith(q)) || (c && c.startsWith(q))) v = 3;
    else if ((' ' + a).includes(' ' + q) || (b && (' ' + b).includes(' ' + q)) || (c && (' ' + c).includes(' ' + q))) v = 2;
    else if (MP.type === 'music' && s && (' ' + norm(s)).includes(' ' + q)) v = 1;
    const k = a + '|' + s;
    if (v && !seen.has(k)) { seen.add(k); out.push([j, v, a.length]); }
  });
  const art = out.some(x => x[1] === 1);
  return out.sort((x, y) => y[1] - x[1] || x[2] - y[2]).slice(0, art ? 60 : 8).map(x => x[0]);
}
function mpMark(text, q){
  const t = String(text || ''), nq = norm(q); if (!nq) return esc(t);
  const words = t.split(/(\s+)/); let done = false;
  return words.map(w => { if (!done && norm(w).startsWith(nq.split(' ')[0])) { done = true; const n = Math.min(w.length, q.trim().split(/\s+/)[0].length); return `<b>${esc(w.slice(0, n))}</b>${esc(w.slice(n))}`; } return esc(w); }).join('');
}

/* --- affichage --- */
function mpBoard(final){
  const P = [...(MP.host ? mpPublic() : MP.players)].sort((a, b) => b.score - a.score), medals = ['🥇', '🥈', '🥉'];
  return `<div class="mp-board${final ? ' final' : ''}">${P.map((p, k) => `<div class="mp-pl${p.id === MP.myId ? ' me' : ''}${p.found ? ' ok' : ''}"><span class="mp-rk">${final ? medals[k] || k + 1 : k + 1}</span><b>${esc(p.name)}${p.id === 'host' ? ' <small>hôte</small>' : ''}${MP.phase === 'lobby' && p.list ? ` <small>· ${fmt(p.list)} ${p.ltype === 'music' ? 'sons' : 'films'}</small>` : ''}</b>${MP.phase === 'stage' || MP.phase === 'reveal' ? `<span class="mp-st">${p.found ? `✓ ${p.rank === 1 ? '1er' : p.rank + 'e'} · +${p.pts}` : p.nw ? `${p.nw} ✗` : ''}</span>` : ''}<em>${fmt(p.score)}</em></div>`).join('')}</div>`;
}
const mpHue = n => { let h = 0; for (const ch of String(n)) h = (h * 31 + ch.charCodeAt(0)) % 360; return h; };
function mpFeed(){
  if (!MP.feed.length) return '<p class="note mp-empty">Les essais ratés et vos messages s’affichent ici.</p>';
  return MP.feed.map(f => f.sys ? `<div class="mp-sep">${esc(f.text)}</div>`
    : `<div class="mp-line ${f.t === 'msg' ? 'msg' : f.ok ? 'ok' : 'ko'}"><b style="color:hsl(${mpHue(f.name)} 70% 68%)">${esc(f.name)}</b> ${f.t === 'msg' ? esc(f.text) : f.ok ? `a trouvé ! 🎉${f.rank === 1 ? ' <em>1er</em>' : ''}` : `<span class="mp-miss">✗ ${esc(f.text)}</span>`}</div>`).join('');
}
function mpFeedDraw(){ const fw = $('mpfeedw'); if (!fw) return; const atEnd = fw.scrollHeight - fw.scrollTop - fw.clientHeight < 40; fw.innerHTML = mpFeed(); if (atEnd) fw.scrollTop = fw.scrollHeight; }
const mpChatBox = () => `<div class="panel mp-chat"><h3>Chat</h3><div id="mpfeedw" class="mp-chatlist"></div><div class="mp-chatin"><input class="input sm" id="mpchatin" maxlength="160" autocomplete="off" placeholder="Écrire un message…"><button class="btn sm" id="mpchatgo">Envoyer</button></div></div>`;
function mpSrcNames(type){ const t = type || C.type; return t === 'music' ? {mine:'Ma playlist', mix:'Mélange des playlists', ext:'Hors playlist'} : {mine:'Mes films Letterboxd', mix:'Mélange des Letterboxd', ext:'Hors Letterboxd'}; }
function mpMenu(){
  const name = esc(MP.me || mpName());
  return `<section class="mp-menu"><span class="kicker">🌐 Multijoueur en ligne</span><h2>Jouer à plusieurs</h2>
    <p class="note">Une personne crée la partie et donne le code aux autres. L’hôte choisit le jeu (1 seconde, blind test, affiche zoomée, casting…). Tout le monde voit le même indice en même temps : <b>le premier qui trouve gagne le plus de points</b>, et un classement s’affiche à la fin. Chaque joueur doit avoir Ring ouvert sur son ordinateur. Ouvre ton ring de films (ou ta playlist) avant de rejoindre : il sera mélangé avec ceux des autres.</p>
    ${MP.err ? `<div class="result err">${esc(MP.err)}</div>` : ''}
    <label class="mp-f"><span>Ton prénom</span><input class="input" id="mpname" maxlength="24" value="${name}" placeholder="Ton prénom"></label>
    <div class="mp-cols"><div class="panel"><h3>Créer une partie</h3><p class="note">Tu choisis les réglages et tu lances quand tout le monde est là.</p><button class="btn primary" id="mpnew" ${MP.busy ? 'disabled' : ''}>＋ Créer une partie</button></div>
      <div class="panel"><h3>Rejoindre</h3><div class="fx" style="gap:8px;flex-wrap:wrap"><input class="input mp-code" id="mpcode" maxlength="7" placeholder="CODE" autocomplete="off"><button class="btn primary" id="mpjoin" ${MP.busy ? 'disabled' : ''}>Rejoindre</button></div></div></div>
    ${MP.busy ? '<div class="gload" style="padding:20px 0"><span class="spin"></span>Connexion…</div>' : ''}
    <button class="btn ghost" id="mpback">← Retour aux jeux</button></section>`;
}
function mpLobby(){
  const opt = (id, v, opts, dis) => `<div class="seg" id="${id}">${opts.map(([k, l]) => `<button data-v="${k}" aria-pressed="${v === k}" ${dis ? 'disabled' : ''}>${l}</button>`).join('')}</div>`;
  const c = MP.cfg, N2 = mpSrcNames(MP.host ? C.type : MP.htype);
  const mixInfo = (MP.host ? mpPublic() : MP.players).filter(p => p.list && p.ltype === (MP.host ? C.type : MP.htype)).map(p => `${esc(p.name)} (${fmt(p.list)})`).join(', ');
  return `<section class="mp-lobby"><div class="mp-codebox"><span>Code de la partie</span><b id="mpcodev">${esc(MP.code)}</b><button class="btn sm" id="mpcopy">Copier</button></div>
    <p class="note" style="text-align:center">${MP.host ? 'Donne ce code à tes potes : ils cliquent sur <b>Jeux → 🌐 Multijoueur → Rejoindre</b> dans leur Ring.' : 'Tu es dans la partie. L’hôte va lancer quand tout le monde est là.'}</p>
    <div class="mp-cols"><div class="panel"><h3>Joueurs (${MP.players.length})</h3>${mpBoard()}</div>
      <div class="panel"><h3>Réglages${MP.host ? '' : ' (choisis par l’hôte)'}</h3>
        <div class="gopts" style="display:grid;gap:12px">
          ${MP.host ? `<div><div class="note">Source</div>${opt('mpsrc', c.src, [['mix', N2.mix], ['mine', N2.mine], ['ext', N2.ext]], !MP.host)}</div>` : `<div class="note">Source : <b>${esc(N2[c.src] || '')}</b></div>`}
          ${c.src === 'mix' ? `<p class="note" style="margin:-4px 0 0">Mélange de : ${mixInfo || '—'}${MP.host ? ' + tes autres rings' : ''}. Chaque joueur ajoute la liste du ring qu’il avait ouvert.</p>` : ''}
          ${MP.host ? `<div><div class="note">Jeu</div>${opt('mpgame', MPG[c.game] && MPG[c.game].types.includes(C.type) ? c.game : 'spot', Object.entries(MPG).filter(([id, g]) => g.types.includes(C.type)).map(([id, g]) => [id, g.icon + ' ' + mpGName(g, C.type)]))}</div>` : `<div class="note">Jeu : <b>${mpG().icon} ${esc(mpGName(mpG(), MP.htype))}</b></div>`}
          <div><div class="note">Difficulté</div><p class="note" style="margin:4px 0 0">Elle monte à chaque manche : ${spotLadder('')}<br>puis on recommence la boucle.</p></div>
          <div><div class="note">Manches</div>${opt('mprounds', String(c.rounds), [['5', '5'], ['10', '10'], ['15', '15'], ['20', '20']], !MP.host)}</div>
        </div>
        <p class="note" style="margin-top:10px">Points : ${mpG().steps.map((s, k) => `${mpLab(k)} = ${mpPts(k)}`).join(' · ')}, + bonus de rapidité ${MP_RANK_PTS.map((p, k) => `${k + 1}${k ? 'e' : 'er'} +${p}`).join(', ')}. Essais illimités, −${MP_WRONG_PEN} par erreur.</p></div></div>
    ${mpChatBox()}
    ${MP.err ? `<div class="result err">${esc(MP.err)}</div>` : ''}
    <div class="fx" style="gap:8px;justify-content:center;flex-wrap:wrap">${MP.host ? `<button class="btn primary" id="mpgo" ${MP.busy ? 'disabled' : ''}>${MP.busy ? 'Préparation…' : '▶ Lancer la partie'}</button>` : ''}<button class="btn ghost" id="mpquit">Quitter la partie</button></div></section>`;
}
function mpBody(){
  const left = Math.max(0, Math.ceil((MP.deadline - Date.now()) / 1000)), a = MP.ans;
  if (MP.phase === 'reveal' && a) return `<div class="greveal ${MP.myFound ? 'ok' : 'ko'}"><div class="gres">${MP.myFound ? `Trouvé ! <b>+${MP.myPts}</b>` : 'Raté…'}</div><div class="gcard">${a.img ? `<img class="poster${MP.type === 'music' ? ' sq' : ''}" src="${esc(a.img)}" alt="" referrerpolicy="no-referrer">` : `<div class="noposter">${esc(a.t)}</div>`}<div><h3>${esc(a.t)}</h3><div class="cmeta"><span>${esc(String(a.y || ''))}</span><span>${esc(a.sub)}</span></div>${a.en && a.en !== a.t ? `<p class="note">${esc(a.en)}</p>` : ''}${a.own && a.own.length ? `<p class="note">Dans la liste de : <b>${a.own.map(esc).join(', ')}</b></p>` : ''}</div></div>${MP.host ? `<div class="fx" style="justify-content:center"><button class="btn primary" id="mpnext">${MP.round >= MP.cfg.rounds ? 'Voir le classement final 🏆' : 'Manche suivante ⏩'}</button></div>` : '<p class="note" style="text-align:center">La suite arrive dans quelques secondes…</p>'}</div>`;
  if (MP.phase === 'stage') return `<div class="mp-bar"><span class="mp-timer"><span id="mpleft">${left}</span> s</span>${mpG().clip ? `<button class="btn sm" id="mpreplay">↻ ${mpG().vis ? 'Revoir' : 'Réécouter'} l’extrait</button>` : ''}</div>
    ${MP.myFound ? `<div class="result">✓ Trouvé ! <b>+${MP.myPts} pts</b> — attends les autres…</div>` : `<div class="gguess"><input class="input" id="mpin" autocomplete="off" placeholder="${MP.type === 'music' ? 'Titre du son…' : 'Nom du film…'}"><div class="gsug" id="mpsug"></div></div>`}
    ${MP.wrong.length ? `<div class="mp-mine"><span class="note">Tes essais</span><div class="gwrong">${MP.wrong.map(w => `<span>✗ ${esc(w)}</span>`).join('')}</div></div>` : ''}`;
  return '<div class="gload" style="padding:24px 0"><span class="spin"></span>Chargement de l’extrait…</div>';
}
function mpRender(soft){
  if (curView !== 'game' || G.id || !MP.on) return;
  if (MP.phase === 'stage' || MP.phase === 'load' || MP.phase === 'reveal') {
    const yt = MP.cur ? MP.cur.yt : '', aud = MP.cur && MP.cur.audio ? MP.cur.audio : '';
    if (!$('mpstage') || $('mpstage').dataset.yt !== (yt || aud) || $('mpstage').dataset.g !== MP.cfg.game) {
      view.innerHTML = `<section class="stage game full" id="mpstage" data-yt="${esc(yt || aud)}" data-g="${esc(MP.cfg.game)}"><div class="stagehead"><div class="round"><b>🌐 ${mpG().icon} ${esc(mpGName(mpG(), MP.type))} à plusieurs</b> · <span id="mpround"></span> · <span class="gdiffb d-${MP.lvl || 'easy'}">${DIFF_NAME[MP.lvl || 'easy']}</span></div>
        <div class="fx" style="gap:8px">${volHtml()}<span class="pill">Code <b>${esc(MP.code)}</b></span><button class="btn sm ghost" id="mpquit">✕ Quitter</button></div></div>
        <div class="mp-game"><div class="mp-main"><div id="mpsteps"></div>
          ${aud ? `<div class="gclip aud" id="mpclip"><audio id="mpaudio" src="${esc(aud)}" preload="auto"></audio><div class="gmask"><span>🎧</span></div><div class="gprog"><i id="mpprog"></i></div></div>` : ''}
          ${yt ? `<div class="gclip${mpG().vis ? ' vis' : ''}" id="mpclip"><iframe id="mpframe" src="https://www.youtube.com/embed/${esc(yt)}?enablejsapi=1&controls=0&disablekb=1&rel=0&playsinline=1&iv_load_policy=3&fs=0&modestbranding=1&start=${Math.floor(MP.cur.start)}&origin=${encodeURIComponent(location.origin)}" allow="autoplay; encrypted-media" onload="ytListen(this);setTimeout(()=>this.dataset.ready=1,400)" title="Extrait"></iframe><div class="gmask"><span>${mpG().vis ? '⏱' : '🎧'}</span></div><div class="gprog"><i id="mpprog"></i></div></div>` : ''}
          <div id="mpclue" class="mp-clue"></div>
          <div id="mpbody" class="mp-bodyw"></div>
        </div><aside class="mp-side"><div class="panel"><h3>Classement</h3><div id="mpboardw"></div></div>${mpChatBox()}</aside></div></section>`;
      soft = false;
    }
    $('mpround').textContent = `Manche ${MP.round} / ${MP.cfg.rounds}`;
    $('mpsteps').innerHTML = mpSteps();
    $('mpboardw').innerHTML = mpBoard();
    mpFeedDraw(); if (!soft) { const fw = $('mpfeedw'); fw.scrollTop = fw.scrollHeight; }
    const clip = $('mpclip'); if (clip) clip.classList.toggle('revealed', MP.phase === 'reveal');
    if (!soft) { $('mpclue').innerHTML = mpClueHtml(); $('mpbody').innerHTML = mpBody(); mpBind(); }
    return;
  }
  const ci = $('mpchatin'), draft = ci ? ci.value : '', hadFocus = ci && document.activeElement === ci;
  if (MP.phase === 'menu') view.innerHTML = mpMenu();
  else if (MP.phase === 'lobby') { view.innerHTML = mpLobby(); const n = $('mpchatin'); if (n) { n.value = draft; if (hadFocus) n.focus(); } mpFeedDraw(); const fw = $('mpfeedw'); if (fw) fw.scrollTop = fw.scrollHeight; }
  else if (MP.phase === 'end') view.innerHTML = `<section class="mp-end"><span class="kicker">${mpG().icon} ${esc(mpGName(mpG(), MP.type))} · ${MP.cfg.rounds} manches</span><h2>🏆 ${esc(([...MP.players].sort((a, b) => b.score - a.score)[0] || {}).name || '')} gagne !</h2>${mpBoard(true)}
      <div class="fx" style="gap:8px;justify-content:center">${MP.host ? '<button class="btn primary" id="mpagain">↻ Rejouer avec les mêmes joueurs</button>' : '<p class="note">L’hôte peut relancer une partie.</p>'}<button class="btn ghost" id="mpquit">Quitter</button></div></section>`;
  mpBind();
}
function mpSteps(){ return `<div class="gsteps">${mpG().steps.map((s, k) => `<span class="${k < MP.stage ? 'past' : k === MP.stage ? 'cur' : ''}"><b>${mpLab(k)}</b><i>${mpPts(k)} pts</i></span>`).join('')}</div>`; }
/* indice image / texte des jeux sans vidéo */
function mpClueHtml(){
  const c = MP.cur && MP.cur.clue, g = mpG(), id = MP.cfg.game, rev = MP.phase === 'reveal';
  if (!c || g.clip || c.g !== id) return '';
  if (MP.stage < 0 && !rev) return '<div class="gload" style="padding:40px 0"><span class="spin"></span>Prépare-toi…</div>';
  const st = rev ? 9 : MP.stage;
  if (id === 'poster') { const z = rev ? 1 : g.steps[Math.min(st, g.steps.length - 1)]; return `<div class="gcrop${c.sq ? ' sq' : ''}"><img src="${esc(safeUrl(c.img))}" data-lo="${esc(safeUrl(c.lo))}" alt="Image à deviner" referrerpolicy="no-referrer" onerror="if(this.dataset.lo){this.src=this.dataset.lo;this.removeAttribute('data-lo')}" style="transform:scale(${+z || 1});transform-origin:${+c.fx || 50}% ${+c.fy || 50}%"></div>`; }
  if (id === 'plot') { const n = c.sent.length, show = rev ? n : [Math.max(1, Math.ceil(n * .34)), Math.max(1, Math.ceil(n * .67)), n, n][st]; return `<div class="gplot"><p>${esc(c.sent.slice(0, show).join(' '))}${show < n ? ' <span class="more">…</span>' : ''}</p>${st >= 3 ? `<div class="gfacts"><span>📅 ${esc(String(c.y || '?'))}</span>${rev && c.sub ? `<span>🎥 ${esc(c.sub)}</span>` : ''}</div>` : ''}</div>`; }
  if (id === 'cast') { const n = rev ? c.cast.length : Math.min(3, st + 1); return `<div class="gcast${rev ? ' all' : ''}">${c.cast.slice(0, n).map(a => `<div class="gactor">${a.img ? `<img src="${esc(safeUrl(a.img))}" alt="" referrerpolicy="no-referrer">` : `<i class="noface">${esc(String(a.n).split(' ').map(w => w[0]).join('').slice(0, 2).toUpperCase())}</i>`}<b>${esc(a.n)}</b></div>`).join('')}${st >= 3 && !rev ? `<div class="gfacts"><span>📅 ${esc(String(c.y || '?'))}</span></div>` : ''}</div>`; }
  if (id === 'quote') return `<div class="gquote"><blockquote class="vo">« ${esc(c.q[0])} »<cite>VO</cite></blockquote>${st >= 1 ? `<blockquote class="fr">« ${esc(c.q[1])} »<cite>Traduction française</cite></blockquote>` : ''}${st >= 2 ? `<div class="gfacts"><span>📅 ${esc(String(c.y || '?'))}</span>${st >= 3 && c.sub ? `<span>🎥 ${esc(c.sub)}</span>` : ''}</div>` : ''}</div>`;
  if (id === 'scene') { const fr = c.frames.map(f => [safeYt(f[0]), +f[1] || 1]), n = rev ? fr.length : Math.min(fr.length, st + 1), sh = fr.slice(0, n); return `<div class="gscene"><div class="gs-main">${sceneImg(...sh[sh.length - 1])}</div>${n > 1 ? `<div class="gs-thumbs">${sh.slice(0, -1).map(f => sceneImg(...f)).join('')}</div>` : ''}</div>`; }
  return '';
}
let mpTick = null;
function mpBind(){
  clearInterval(mpTick);
  if ($('mpback')) $('mpback').onclick = () => { MP.on = false; mpReset(); };
  if ($('mpnew')) $('mpnew').onclick = () => mpCreate($('mpname').value.trim());
  if ($('mpjoin')) $('mpjoin').onclick = () => mpJoin($('mpname').value.trim(), $('mpcode').value);
  if ($('mpcode')) $('mpcode').onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); $('mpjoin').click(); } };
  if ($('mpquit')) $('mpquit').onclick = () => { try { if (document.fullscreenElement) document.exitFullscreen(); } catch(e){} mpLeave(); };
  if ($('mpcopy')) $('mpcopy').onclick = async () => toast(await copyText(MP.code) ? 'Code copié : ' + MP.code : 'Code : ' + MP.code);
  if ($('mpgo')) $('mpgo').onclick = () => { try { if (!document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {}); } catch(e){} mpStartGame(); };
  if ($('mpagain')) $('mpagain').onclick = () => mpStartGame();
  if ($('mpnext')) $('mpnext').onclick = () => mpNextRound();
  const ci = $('mpchatin');
  if (ci && !ci.dataset.b) { ci.dataset.b = 1; const send = () => { mpChat(ci.value); ci.value = ''; }; ci.onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter') { e.preventDefault(); send(); } }; $('mpchatgo').onclick = () => { send(); ci.focus(); }; }
  const mk = document.querySelector('#mpclip .gmask'); if (mk) mk.onclick = () => { const b = $('mpclip'); if (b && b.classList.contains('blocked') && MP.lastPlay) mpPlay(MP.lastPlay.from, MP.lastPlay.to); };
  if ($('mpreplay')) $('mpreplay').onclick = () => { if (MP.stage >= 0 && mpG().clip) mpPlay(0, mpG().steps[MP.stage]); const i = $('mpin'); if (i) i.focus(); };
  if (MP.host) {
    view.querySelectorAll('#mpsrc button').forEach(b => b.onclick = () => { MP.cfg.src = b.dataset.v; mpSync(); });
    view.querySelectorAll('#mprounds button').forEach(b => b.onclick = () => { MP.cfg.rounds = +b.dataset.v; mpSync(); });
    view.querySelectorAll('#mpgame button').forEach(b => b.onclick = () => { MP.cfg.game = b.dataset.v; mpSync(); });
  }
  if ($('mpleft')) mpTick = setInterval(() => { const el = $('mpleft'); if (!el) return clearInterval(mpTick); el.textContent = Math.max(0, Math.ceil((MP.deadline - Date.now()) / 1000)); }, 250);
  const inp = $('mpin');
  if (inp) {
    let sel = 0, hits = [];
    const draw = () => {
      hits = mpSuggest(inp.value); sel = Math.min(sel, Math.max(0, hits.length - 1));
      $('mpsug').innerHTML = hits.map((j, k) => { const [t, s, en, im, fr] = MP.titles[j]; return `<button class="${k === sel ? 'on' : ''}" data-j="${j}">${im ? `<img class="th${MP.type === 'music' ? ' sq' : ''}" src="${esc(im)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.style.visibility='hidden'">` : `<i class="th mp-noth"></i>`}<span><span class="mp-tt">${mpMark(t, inp.value)}</span><small>${esc(s)}${fr && fr !== t ? ' · ' + mpMark(fr, inp.value) : ''}${en && en !== t ? ' · ' + mpMark(en, inp.value) : ''}</small></span></button>`; }).join('')
        || (norm(inp.value) ? `<div class="mp-nores">Aucun titre ne commence par « ${esc(inp.value.trim())} » — Entrée pour l’envoyer quand même</div>` : '');
      $('mpsug').querySelectorAll('button').forEach(b => b.onmousedown = e => { e.preventDefault(); mpGuess(MP.titles[+b.dataset.j][0], +b.dataset.j); });
    };
    inp.oninput = () => { sel = 0; draw(); };
    inp.onkeydown = e => {
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(sel + 1, hits.length - 1); draw(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(sel - 1, 0); draw(); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (hits.length) mpGuess(MP.titles[hits[sel]][0], hits[sel]); else if (inp.value.trim()) mpGuess(inp.value.trim(), -1); }
    };
    setTimeout(() => inp.focus(), 30);
  }
}
{
  const _r = renderGame, _p = renderGamePicker;
  renderGame = function(){ if (!G.id && MP.on) return mpRender(); return _r.apply(this, arguments); };
  renderGamePicker = function(){
    _p.apply(this, arguments);
    const h = view.querySelector('.sech'); if (h && !$('mpgo2') && (C.type === 'films' || C.type === 'music')) { const b = document.createElement('button'); b.className = 'btn primary'; b.id = 'mpgo2'; b.textContent = '🌐 Multijoueur en ligne'; b.onclick = () => { MP.on = true; if (!MP.peer) MP.phase = 'menu'; renderGame(); }; h.appendChild(b); }
  };
}

/* ---------- Import direct AniList (animés / mangas / manhwas) ---------- */
async function anilistImport(user, type){
  if (!user) { toast('Tape ton pseudo AniList.'); return; }
  toast('Lecture de ta liste AniList…');
  const q = `query($u:String,$t:MediaType){MediaListCollection(userName:$u,type:$t){lists{entries{media{title{userPreferred romaji english} coverImage{extraLarge large} startDate{year} siteUrl format countryOfOrigin}}}}}`;
  try {
    const r = await fetch('https://graphql.anilist.co', {method:'POST', headers:{'Content-Type':'application/json', 'Accept':'application/json'}, body: JSON.stringify({query: q, variables: {u: user, t: type}})});
    const j = await r.json();
    if (!j.data || !j.data.MediaListCollection) { toast(j.errors && j.errors[0] ? 'AniList : ' + j.errors[0].message : 'Liste introuvable (pseudo ? liste privée ?)'); return; }
    const FMT = {TV:'Série TV', TV_SHORT:'Série courte', MOVIE:'Film', OVA:'OVA', ONA:'ONA', SPECIAL:'Spécial', MANGA:'Manga', NOVEL:'Light novel', ONE_SHOT:'One shot', MUSIC:'Clip'};
    const items = []; (j.data.MediaListCollection.lists || []).forEach(l => (l.entries || []).forEach(e => { const m = e.media; if (!m) return; const y = m.startDate && m.startDate.year || 0; const kind = type === 'MANGA' ? (m.countryOfOrigin === 'KR' ? 'Manhwa' : m.countryOfOrigin === 'CN' ? 'Manhua' : FMT[m.format] || 'Manga') : FMT[m.format] || ''; items.push([m.title.userPreferred || m.title.romaji || m.title.english || '', [kind, y || ''].filter(Boolean).join(' · '), (m.coverImage && (m.coverImage.extraLarge || m.coverImage.large)) || '', m.siteUrl || '', '', y]); }));
    closeModal();
    openGenPreview({k:'gen', v:5, src: `https://anilist.co/user/${user}/${type === 'ANIME' ? 'animelist' : 'mangalist'}`, host: 'anilist.co', name: `${type === 'ANIME' ? 'Animés' : 'Mangas'} de ${user}`, kind: type === 'ANIME' ? 'anime' : 'manga', items});
  } catch(e){ toast('Impossible de joindre AniList (connexion ?).'); }
}

applyTheme();
(async () => {
  await initStore();
  applyTheme();
  const saved = ls.get('ringcine-col', null) || (ls.get('ringcine-cat', 'films') === 'music' ? 'music' : 'films');
  switchCol(colById(saved) ? saved : 'films', 'home');
  setTimeout(() => checkTrophies(), 2500);
  setTimeout(() => otRun(), 1200);
  setTimeout(() => frRun(), 6000);
  setTimeout(() => lbAutoSync(), 4000);
  setTimeout(() => prefetchRun(), 25000);
})();

</script>
</body>
</html>

'@
$HtmlBytes = [Text.Encoding]::UTF8.GetBytes($HTML)

$ReplyHelpers = @'
function Reply($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.Headers.Add('Cache-Control', 'no-store')
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}
function ReplyText($ctx, [int]$code, [string]$type, [string]$text) { Reply $ctx $code $type ([Text.Encoding]::UTF8.GetBytes($text)) }
'@
. ([scriptblock]::Create($ReplyHelpers))

# requêtes lentes (YouTube, images, Letterboxd) : traitées en parallèle pour ne jamais bloquer la sauvegarde
$SlowScript = @'
param($ctx, $CommonText, $ReplyHelpers)
. ([scriptblock]::Create($CommonText))
. ([scriptblock]::Create($ReplyHelpers))
$req = $ctx.Request
$path = $req.Url.AbsolutePath
try {
  if ($path -eq '/subs') { ReplyText $ctx 200 'application/json; charset=utf-8' (YTSubs ([string]$req.QueryString['v'])) }
  elseif ($path -eq '/yts') { ReplyText $ctx 200 'application/json; charset=utf-8' ('{"items":' + (YTList ([string]$req.QueryString['q'])) + '}') }
  elseif ($path -eq '/yt') { ReplyText $ctx 200 'application/json; charset=utf-8' ('{"id":' + (JStr (YT ([string]$req.QueryString['q']))) + '}') }
  elseif ($path -eq '/sppv') {
    $tid = [string]$req.QueryString['id']
    if ($tid -notmatch '^[A-Za-z0-9]{22}$') { ReplyText $ctx 400 'text/plain' 'bad id' }
    else {
      $pv = ''
      try { $h = YTReq ('https://open.spotify.com/embed/track/' + $tid) $UA ''; $m = [regex]::Match($h, '"audioPreview":\{"url":"(https://p\.scdn\.co/mp3-preview/[A-Za-z0-9]+)'); if ($m.Success) { $pv = $m.Groups[1].Value } } catch {}
      ReplyText $ctx 200 'application/json; charset=utf-8' ('{"url":' + (JStr $pv) + '}')
    }
  }
  elseif ($path -eq '/lbrss') {
    $lu = [string]$req.QueryString['u']
    if ($lu -notmatch '^[A-Za-z0-9_]{2,40}$') { ReplyText $ctx 400 'text/plain' 'bad user' }
    else { try { ReplyText $ctx 200 'application/xml; charset=utf-8' (YTReq ("https://letterboxd.com/" + $lu + "/rss/") $UA '') } catch { ReplyText $ctx 502 'text/plain' 'blocked' } }
  }
  elseif ($path -eq '/img') {
    $u = [string]$req.QueryString['u']
    if ($u -notmatch '^https://[^/]+/') { ReplyText $ctx 400 'text/plain' 'bad url' }
    else {
      $wr = [Net.HttpWebRequest]::Create($u); $wr.UserAgent = $UA; $wr.Timeout = 12000; $wr.ReadWriteTimeout = 12000
      $resp = $wr.GetResponse(); $ct = [string]$resp.ContentType
      if ($ct -notmatch '^image/') { $resp.Close(); ReplyText $ctx 415 'text/plain' 'not an image' }
      else { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); $resp.Close(); Reply $ctx 200 $ct $ms.ToArray() }
    }
  }
} catch {
  try { ReplyText $ctx 502 'application/json' ('{"error":' + (JStr ([string]$_.Exception.Message)) + '}') } catch {}
}
'@
$SlowPaths = @('/subs', '/yts', '/yt', '/lbrss', '/img', '/sppv')
$HttpPool = [runspacefactory]::CreateRunspacePool(1, 8); $HttpPool.Open()
$Slow = New-Object Collections.ArrayList
function Start-Slow($ctx) {
  $ps = [powershell]::Create(); $ps.RunspacePool = $HttpPool
  [void]$ps.AddScript($SlowScript).AddArgument($ctx).AddArgument($Common).AddArgument($ReplyHelpers)
  [void]$Slow.Add(@($ps, $ps.BeginInvoke()))
}
function Clear-Slow { for ($k = $Slow.Count - 1; $k -ge 0; $k--) { $t = $Slow[$k]; if ($t[1].IsCompleted) { try { [void]$t[0].EndInvoke($t[1]) } catch {}; $t[0].Dispose(); $Slow.RemoveAt($k) } } }
function ReadBody($req) { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close(); return $t }

$L = New-Object Net.HttpListener
$L.Prefixes.Add($Base)
try { $L.Start() }
catch {
  Write-Host 'Ring est deja ouvert : ouverture de la page...'
  Start-Process $Base
  Start-Sleep -Seconds 2
  return
}

Write-Host ''
Write-Host '  RING est lance :' $Base
Write-Host '  Laisse cette fenetre ouverte (tu peux la reduire). Ferme-la pour arreter Ring.'
Write-Host ''

if (-not $env:RING_NO_BROWSER) {
  $legacy = $false
  if (-not (Test-Path -LiteralPath $StorePath) -and (Test-Path -LiteralPath $LegacyPath)) {
    try { $legacy = ([IO.File]::ReadAllText($LegacyPath)).Contains('ringcine-transfer') } catch {}
  }
  if ($legacy) { Start-Process $LegacyPath } else { Start-Process $Base }
}

while ($L.IsListening) {
  try { $ctx = $L.GetContext() } catch { break }
  Clear-Slow
  $req = $ctx.Request
  $path = $req.Url.AbsolutePath
  $orig = [string]$req.Headers['Origin']
  if ($orig -and $orig -ne 'null' -and $orig -ne ('http://localhost:' + $Port) -and $orig -ne ('http://127.0.0.1:' + $Port)) {
    try { ReplyText $ctx 403 'text/plain' 'forbidden' } catch {}
    continue
  }
  try {
    if ($req.HttpMethod -eq 'OPTIONS') {
      $ctx.Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST')
      $ctx.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
      ReplyText $ctx 204 'text/plain' ''
    }
    elseif ($path -eq '/' -or $path -eq '/index.html') { Reply $ctx 200 'text/html; charset=utf-8' $HtmlBytes }
    elseif ($path -eq '/api/ping') { ReplyText $ctx 200 'text/plain' 'ok' }
    elseif ($path -eq '/api/store') {
      if ($req.HttpMethod -eq 'POST') {
        $body = ReadBody $req
        if ($req.QueryString['ifempty'] -and (Test-Path -LiteralPath $StorePath)) { ReplyText $ctx 200 'application/json' '{"ok":false}' }
        else {
          if (Test-Path -LiteralPath $StorePath) {
            try {
              $cur = (Get-Item -LiteralPath $StorePath).Length
              $bak = if (Test-Path -LiteralPath $BackupPath) { Get-Item -LiteralPath $BackupPath } else { $null }
              $shrink = [Text.Encoding]::UTF8.GetByteCount($body) -lt $cur * 0.6
              $stale = $bak -and ((Get-Date) - $bak.LastWriteTime).TotalHours -gt 24 -and $cur -ge $bak.Length * 0.6
              if ($shrink -or -not $bak -or $stale) { Copy-Item -LiteralPath $StorePath -Destination $BackupPath -Force; (Get-Item -LiteralPath $BackupPath).LastWriteTime = Get-Date }
            } catch {}
          }
          $tmp = $StorePath + '.tmp'
          [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($false)))
          Move-Item -LiteralPath $tmp -Destination $StorePath -Force
          ReplyText $ctx 200 'application/json' '{"ok":true}'
        }
      } else {
        $t = '{}'
        if (Test-Path -LiteralPath $StorePath) { $t = [IO.File]::ReadAllText($StorePath, [Text.Encoding]::UTF8) }
        ReplyText $ctx 200 'application/json; charset=utf-8' $t
      }
    }
    elseif ($path -eq '/api/job') {
      if ($req.HttpMethod -eq 'POST') {
        $o = (ReadBody $req) | ConvertFrom-Json
        if (-not $JobScripts.ContainsKey([string]$o.kind)) { ReplyText $ctx 400 'application/json' '{"error":"tache inconnue"}' }
        else { $id = Start-RingJob ([string]$o.kind) $o.args; ReplyText $ctx 200 'application/json' ('{"id":"' + $id + '"}') }
      } else {
        $id = [string]$req.QueryString['id']
        $s = $Jobs[$id]
        if (-not $s) { ReplyText $ctx 200 'application/json' '{"status":"missing","error":"tache introuvable"}' }
        else {
          $st = [string]$s.status
          if ($st -ne 'run' -and -not $s.handle.IsCompleted) { $st = 'run' }
          elseif ($st -eq 'run' -and $s.handle.IsCompleted) {
            $st = 'error'
            try { [void]$s.ps.EndInvoke($s.handle); $s.error = 'tache interrompue' } catch { $s.error = [string]$_.Exception.Message }
          }
          $json = '{"status":' + (JStr $st) + ',"done":' + [int]$s.done + ',"total":' + [int]$s.total
          if ($st -eq 'error') { $json += ',"error":' + (JStr ([string]$s.error)) }
          if ($st -eq 'done') { $json += ',"result":' + (ToJson $s.result) }
          $json += '}'
          if ($st -ne 'run') { try { $s.ps.Dispose() } catch {}; $Jobs.Remove($id) }
          ReplyText $ctx 200 'application/json; charset=utf-8' $json
        }
      }
    }
    elseif ($SlowPaths -contains $path) { Start-Slow $ctx }
    elseif ($path -eq '/api/quit') { ReplyText $ctx 200 'text/plain' 'bye'; $L.Stop(); break }
    else { ReplyText $ctx 404 'text/plain; charset=utf-8' 'Introuvable' }
  } catch {
    Write-Host ('Erreur : ' + $_.Exception.Message)
    try { ReplyText $ctx 500 'application/json' ('{"error":' + (JStr ([string]$_.Exception.Message)) + '}') } catch {}
  }
}
try { $Pool.Close() } catch {}
try { $HttpPool.Close() } catch {}
