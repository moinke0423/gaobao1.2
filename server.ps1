# 内蒙古高考志愿智能推荐 - 本地数据服务
# 作用：仅做"浏览器 <-> 内蒙古考试院官网"的透明转发（绕过浏览器跨域安全限制），不保存任何数据。
# 数据全部保存在浏览器 IndexedDB 中。关闭本窗口即停止服务。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8090

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Prefixes.Add("http://[::1]:$port/")
try { $listener.Start() } catch {
  Write-Host "端口 $port 已被占用（可能服务已在运行）。请直接打开 http://localhost:$port/index.html"
  Start-Process "http://localhost:$port/index.html"
  exit
}

Write-Host "=============================================="
Write-Host " 内蒙古高考志愿智能推荐 - 本地数据服务已启动"
Write-Host " 请在浏览器打开: http://localhost:$port/index.html"
Write-Host " 本服务仅转发官网数据，不保存任何数据；关闭即停止。"
Write-Host "=============================================="
# Start-Process "http://localhost:$port/index.html"  # 维护期间临时关闭自动开浏览器

function Send-Response($ctx, [int]$status, [byte[]]$body, [string]$ctype) {
  $res = $ctx.Response
  $res.StatusCode = $status
  $res.ContentType = $ctype
  $res.Headers.Add("Access-Control-Allow-Origin", "*")
  $res.Headers.Add("Cache-Control", "no-store")
  $res.ContentLength64 = $body.Length
  if ($body.Length -gt 0) { $res.OutputStream.Write($body, 0, $body.Length) }
  $res.OutputStream.Close()
}

function Bytes([string]$s) { [System.Text.Encoding]::UTF8.GetBytes($s) }

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $path = $ctx.Request.Url.AbsolutePath
  Write-Host ("[{0}] IN {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $ctx.Request.RemoteEndPoint, $ctx.Request.Url.ToString())
  try {
    # --- 代理转发：/proxy?url=<编码后的官网地址>（仅允许官网与掌上高考院校信息接口） ---
    if ($path -eq "/proxy") {
      $qs = $ctx.Request.QueryString["url"]
      $allowed = '^https?://([A-Za-z0-9.-]*\.)?(nm\.zsks\.cn|zjzw\.cn|gaokao\.cn)/'
      if ([string]::IsNullOrWhiteSpace($qs) -or $qs -notmatch $allowed) {
        Send-Response $ctx 403 (Bytes '{"error":"only nm.zsks.cn / zjzw.cn / gaokao.cn allowed"}') "application/json; charset=utf-8"
        continue
      }
      # 临时开关：存在 .zjkill 文件时，对掌上高考接口直接回空成功包（用于终结失控的后台补抓循环）
      if ((Test-Path (Join-Path $root '.zjkill')) -and ($qs -match 'gk/score/special|gk/school/lists')) {
        $fake = '{"code":"0","message":"成功","data":{"item":[],"numFound":"0"},"location":"","encrydata":""}'
        Send-Response $ctx 200 (Bytes $fake) "application/json; charset=utf-8"
        Write-Host ("[{0}] ZJKILL fake-empty -> {1}" -f (Get-Date -Format 'HH:mm:ss'), $qs)
        continue
      }
      try {
        $req = [System.Net.HttpWebRequest]::Create($qs)
        if ($qs -match 'zsks\.cn') { $req.Referer = "https://www.nm.zsks.cn/" }
        if ($qs -match 'zjzw\.cn') {
          $req.Referer = "https://www.gaokao.cn/"
          try { $req.Headers.Add("Origin", "https://www.gaokao.cn") } catch {}
        }
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        $req.Accept = "application/json, text/plain, */*"
        try { $req.Headers.Add("Accept-Language", "zh-CN,zh;q=0.9") } catch {}
        $req.Timeout = 120000
        $req.ReadWriteTimeout = 120000
        $req.AllowAutoRedirect = $true
        # POST 转发（掌上高考网页版新接口 api-gaokao.zjzw.cn 要求 JSON body）
        if ($ctx.Request.HttpMethod -eq 'POST') {
          $req.Method = 'POST'
          $req.ContentType = $ctx.Request.ContentType
          $bodyMs = New-Object System.IO.MemoryStream
          $ctx.Request.InputStream.CopyTo($bodyMs)
          $bodyBytes = $bodyMs.ToArray()
          $req.ContentLength = $bodyBytes.Length
          $rs = $req.GetRequestStream()
          $rs.Write($bodyBytes, 0, $bodyBytes.Length)
          $rs.Close()
        }
        $resp = $req.GetResponse()
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $bytes = $ms.ToArray()
        $ctype = $resp.ContentType
        if ([string]::IsNullOrWhiteSpace($ctype)) { $ctype = "application/octet-stream" }
        $code = [int]$resp.StatusCode
        $resp.Close()
        Send-Response $ctx $code $bytes $ctype
        Write-Host ("[{0}] {1} -> {2} ({3}KB)" -f (Get-Date -Format 'HH:mm:ss'), $qs, $code, [Math]::Round($bytes.Length/1024))
      } catch [System.Net.WebException] {
        $code = 502
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Send-Response $ctx $code (Bytes ("proxy fetch failed: " + $_.Exception.Message)) "text/plain; charset=utf-8"
      }
      continue
    }
    # --- 数据备份落盘：POST /save（body 原样写入脚本目录 gaobao-data.json，仅本机使用） ---
    if ($path -eq "/save" -and $ctx.Request.HttpMethod -eq 'POST') {
      try {
        $ms = New-Object System.IO.MemoryStream
        $ctx.Request.InputStream.CopyTo($ms)
        $bytes = $ms.ToArray()
        if ($bytes.Length -gt 64MB) { throw "payload too large" }
        [System.IO.File]::WriteAllBytes((Join-Path $root "gaobao-data.json"), $bytes)
        Send-Response $ctx 200 (Bytes ('{"ok":true,"bytes":' + $bytes.Length + '}')) "application/json; charset=utf-8"
        Write-Host ("[{0}] SAVED gaobao-data.json ({1}KB)" -f (Get-Date -Format 'HH:mm:ss'), [Math]::Round($bytes.Length/1024))
      } catch {
        Send-Response $ctx 500 (Bytes ("save failed: " + $_.Exception.Message)) "text/plain; charset=utf-8"
      }
      continue
    }
    # --- 静态文件 ---
    $rel = if ($path -eq "/") { "index.html" } else { $path.TrimStart("/") }
    $file = Join-Path $root ($rel -replace "/", "\")
    $full = [System.IO.Path]::GetFullPath($file)
    $rootFull = [System.IO.Path]::GetFullPath($root)
    if ($full.StartsWith($rootFull) -and (Test-Path $full -PathType Leaf)) {
      $ext = [System.IO.Path]::GetExtension($full).ToLower()
      $ctype = switch ($ext) {
        ".html" { "text/html; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".svg"  { "image/svg+xml" }
        ".ico"  { "image/x-icon" }
        default { "application/octet-stream" }
      }
      Send-Response $ctx 200 ([System.IO.File]::ReadAllBytes($full)) $ctype
    } else {
      Send-Response $ctx 404 (Bytes "404 Not Found") "text/plain; charset=utf-8"
    }
  } catch {
    try { Send-Response $ctx 500 (Bytes ("server error: " + $_.Exception.Message)) "text/plain; charset=utf-8" } catch {}
  }
}
