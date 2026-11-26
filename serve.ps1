# 간단한 정적 파일 웹 서버 + 데모용 메시지 중계 API (관리자 권한 불필요)
# 실행: powershell -ExecutionPolicy Bypass -File .\serve.ps1  [-Port 80]
# 기본은 80번 포트 → 휴대폰 주소창에 "PC IP"만 치면 됨 (예: 192.168.0.13). 80이 막혀 있으면 8080으로 자동 전환.
# 짧은 주소: /w 현장 작업자 단말, /q 품질 알림 앱, /c CCR 콘솔, /d 품질 대시보드, /qr 접속 QR. 종료는 Ctrl+C.
# /api/* 는 process.html 데모(CCR <-> 현장 단말)용 메모리 내 메시지 중계입니다.
# 인증·암호화가 없으니 시연용으로만 쓰세요. 서버를 끄면 메시지는 사라집니다.
param([int]$Port = 80)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = [System.Text.UTF8Encoding]::new($false)
$ascii = [System.Text.Encoding]::ASCII
$types = @{ '.html'='text/html; charset=utf-8'; '.htm'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8';
  '.js'='text/javascript; charset=utf-8'; '.json'='application/json; charset=utf-8'; '.csv'='text/csv; charset=utf-8';
  '.svg'='image/svg+xml'; '.png'='image/png'; '.jpg'='image/jpeg'; '.ico'='image/x-icon'; '.webmanifest'='application/manifest+json' }
$msgs = [System.Collections.ArrayList]::new()
$nextId = 1
$state = '{}'
$maxBody = 65536

# 짧은 주소 → 실제 페이지 (대소문자 무관)
$short = @{ '/w'='/process.html?role=worker'; '/q'='/live.html'; '/c'='/process.html'; '/d'='/index.html'; '/qr'='/qr.html' }

try {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
  $listener.Start()
} catch {
  if ($Port -eq 80) {
    Write-Host "80번 포트를 쓸 수 없어 8080으로 엽니다."
    $Port = 8080
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
  } else { throw }
}

$ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } | ForEach-Object IPAddress)
$pp = if ($Port -eq 80) { '' } else { ":$Port" }
Write-Host "서버 시작: 폴더 $root"
Write-Host ""
Write-Host "  PC에서     CCR 콘솔: http://localhost$pp/c    접속 QR: http://localhost$pp/qr"
foreach ($ip in $ips) {
  Write-Host "  휴대폰에서 시작 화면: http://$ip$pp        (주소창에 $ip$pp 만 입력)"
  Write-Host "             현장 단말: http://$ip$pp/w      품질 알림: http://$ip$pp/q"
}
Write-Host ""
Write-Host "종료하려면 Ctrl+C"

function Send-Redirect($stream, [string]$loc) {
  $hb = $ascii.GetBytes("HTTP/1.1 302 Found`r`nLocation: $loc`r`nContent-Length: 0`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n")
  $stream.Write($hb, 0, $hb.Length)
}

function Send-Response($stream, [int]$code, [string]$ctype, [byte[]]$body) {
  $status = switch ($code) { 200 {'OK'} 400 {'Bad Request'} 404 {'Not Found'} 405 {'Method Not Allowed'} default {'Error'} }
  $head = "HTTP/1.1 $code $status`r`nContent-Type: $ctype`r`nContent-Length: $($body.Length)`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
  $hb = $ascii.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length) { $stream.Write($body, 0, $body.Length) }
}
function Send-Json($stream, [string]$json, [int]$code = 200) {
  Send-Response $stream $code 'application/json; charset=utf-8' $utf8.GetBytes($json)
}
function Test-JsonObject([string]$s) {
  if (-not $s -or -not $s.TrimStart().StartsWith('{')) { return $false }
  try { $null = ConvertFrom-Json -InputObject $s -ErrorAction Stop; return $true } catch { return $false }
}
# 요청 줄 + 헤더 + (POST) 본문을 바이트 단위로 읽음. 본문은 UTF-8.
function Read-Request($stream) {
  $ms = [System.IO.MemoryStream]::new()
  $buf = New-Object byte[] 8192
  $hEnd = -1
  while ($hEnd -lt 0 -and $ms.Length -lt $maxBody) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
    $hEnd = $ascii.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
  }
  if ($hEnd -lt 0) { return $null }
  $all = $ms.ToArray()
  $lines = $ascii.GetString($all, 0, $hEnd) -split "`r`n"
  $len = 0
  foreach ($l in $lines) { if ($l -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
  if ($len -gt $maxBody) { $len = $maxBody }
  $bodyText = ''
  if ($len -gt 0) {
    $body = New-Object byte[] $len
    $start = $hEnd + 4
    $got = [Math]::Min($all.Length - $start, $len)
    if ($got -gt 0) { [Array]::Copy($all, $start, $body, 0, $got) } else { $got = 0 }
    while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
    $bodyText = $utf8.GetString($body, 0, $got)
  }
  return @{ Line = $lines[0]; Body = $bodyText }
}

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 2000
      $stream = $client.GetStream()
      $req = Read-Request $stream
      if ($req) {
        $parts = $req.Line.Split(' ')
        if ($parts.Length -ge 2) {
          $method = $parts[0]
          $path, $query = ($parts[1] -split '\?', 2)
          $path = [System.Uri]::UnescapeDataString($path)
          $time = Get-Date -Format 'HH:mm:ss'
          $from = $client.Client.RemoteEndPoint.Address

          if ($path.StartsWith('/api/')) {
            $route = "$method $path"
            if ($route -eq 'GET /api/info') {
              $ipJson = ($ips | ForEach-Object { '"' + $_ + '"' }) -join ','
              Send-Json $stream ('{"ips":[' + $ipJson + '],"port":' + $Port + ',"lastId":' + ($nextId - 1) + '}')
            }
            elseif ($route -eq 'GET /api/msg') {
              $since = 0
              if ($query -match 'since=(\d+)') { $since = [int]$Matches[1] }
              $items = @($msgs | Where-Object { $_.Id -gt $since } | ForEach-Object { $_.Json })
              Send-Json $stream ('[' + ($items -join ',') + ']')
            }
            elseif ($route -eq 'POST /api/msg') {
              if (Test-JsonObject $req.Body) {
                $id = $nextId; $nextId++
                $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                [void]$msgs.Add([pscustomobject]@{ Id = $id; Json = ('{"id":' + $id + ',"ts":' + $ts + ',"m":' + $req.Body + '}') })
                if ($msgs.Count -gt 1000) { $msgs.RemoveRange(0, $msgs.Count - 1000) }
                Send-Json $stream ('{"id":' + $id + '}')
                if ($req.Body -notmatch '"type"\s*:\s*"hb"') {
                  $t = $req.Body; if ($t.Length -gt 80) { $t = $t.Substring(0, 80) + '...' }
                  Write-Host "$time $from 메시지 #$id $t"
                }
              } else { Send-Json $stream '{"error":"bad json"}' 400 }
            }
            elseif ($route -eq 'GET /api/state') { Send-Json $stream $state }
            elseif ($route -eq 'POST /api/state') {
              if (Test-JsonObject $req.Body) { $state = $req.Body; Send-Json $stream '{"ok":true}' }
              else { Send-Json $stream '{"error":"bad json"}' 400 }
            }
            else { Send-Json $stream '{"error":"not found"}' 404 }
          }
          elseif ($short.ContainsKey($path.TrimEnd('/').ToLower())) {
            Send-Redirect $stream $short[$path.TrimEnd('/').ToLower()]
            Write-Host "$time $from 302 $path"
          }
          else {
            if ($path -eq '/') { $path = '/start.html' }
            $full = [System.IO.Path]::GetFullPath((Join-Path $root $path.TrimStart('/')))
            if ($method -ne 'GET' -and $method -ne 'HEAD') {
              Send-Response $stream 405 'text/plain; charset=utf-8' ($utf8.GetBytes('405'))
            } elseif (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf) -or $full -like '*.ps1') {
              Send-Response $stream 404 'text/plain; charset=utf-8' ($utf8.GetBytes('404 Not Found'))
              Write-Host "$time $from 404 $path"
            } else {
              $ext = [System.IO.Path]::GetExtension($full).ToLower()
              $ct = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
              $bytes = [System.IO.File]::ReadAllBytes($full)
              if ($method -eq 'HEAD') { $bytes = [byte[]]@() }
              Send-Response $stream 200 $ct $bytes
              Write-Host "$time $from 200 $path"
            }
          }
        }
      }
    } catch {
      # 아무것도 보내지 않는 미리 연결(preconnect) 소켓의 읽기 시간 초과는 조용히 무시
      $ex = $_.Exception
      if (-not ($ex -is [System.IO.IOException] -or $ex.InnerException -is [System.IO.IOException])) {
        Write-Host "요청 처리 오류: $($ex.Message)"
      }
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
