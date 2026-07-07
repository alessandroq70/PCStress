<#
.SYNOPSIS
  PCStress - Avvia il server web locale per usare il test da altri PC.

.DESCRIPTION
  Serve la cartella di PCStress in HTTP sulla rete locale: da qualsiasi
  computer della rete apri il browser sull'indirizzo mostrato e il test
  gira direttamente su quel computer (e' li' che serve il carico).

  Senza diritti di amministratore Windows consente il binding solo su
  "localhost": il server funziona ma solo da questo PC. Per renderlo
  raggiungibile dalla rete, esegui PowerShell come amministratore
  (lo script aggiunge da solo anche la regola del firewall).

.PARAMETER Porta
  Porta TCP su cui ascoltare (predefinita: 8080).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\avvia-server.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Porta = 8080
)

$ErrorActionPreference = 'Stop'
$radice = $PSScriptRoot
if (-not $radice) { $radice = (Get-Location).Path }
$radice = [IO.Path]::GetFullPath($radice)

$tipiMime = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
    '.md'   = 'text/plain; charset=utf-8'
    '.ps1'  = 'application/octet-stream'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
}

# amministratore?
$sonoAdmin = $false
try {
    $identita = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sonoAdmin = (New-Object Security.Principal.WindowsPrincipal($identita)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# prova il binding su tutte le interfacce; senza admin ripiega su localhost
$listener = New-Object System.Net.HttpListener
$soloLocale = $false
try {
    $listener.Prefixes.Add("http://+:$Porta/")
    $listener.Start()
} catch {
    $listener.Close()
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Porta/")
    try {
        $listener.Start()
    } catch {
        Write-Host "ERRORE: impossibile aprire la porta $Porta (probabilmente e' gia' usata da un altro programma)." -ForegroundColor Red
        Write-Host "Riprova con un'altra porta, ad esempio:" -ForegroundColor Yellow
        Write-Host "    powershell -ExecutionPolicy Bypass -File .\avvia-server.ps1 -Porta 8090" -ForegroundColor Yellow
        exit 1
    }
    $soloLocale = $true
}

# con i diritti admin, apri anche il firewall (una sola volta)
if (-not $soloLocale -and $sonoAdmin) {
    try {
        if (-not (Get-NetFirewallRule -DisplayName 'PCStress server web' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'PCStress server web' -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $Porta -Profile Private,Domain | Out-Null
            Write-Host "Regola firewall aggiunta (porta $Porta, reti private)." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Impossibile aggiungere la regola firewall: $_"
    }
}

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  PCStress - server web attivo'                -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "  Cartella servita: $radice"
Write-Host ''
Write-Host '  Apri il test da questo PC:' -ForegroundColor Green
Write-Host "      http://localhost:$Porta/"
Write-Host ''

if ($soloLocale) {
    Write-Warning 'Server raggiungibile SOLO da questo PC (niente diritti amministratore).'
    Write-Host '  Per aprirlo alla rete locale, in un PowerShell da AMMINISTRATORE esegui questi due comandi' -ForegroundColor Yellow
    Write-Host '  (binding di rete + regola firewall), poi rilancia lo script:' -ForegroundColor Yellow
    Write-Host "      netsh http add urlacl url=http://+:$Porta/ user=$env:USERNAME" -ForegroundColor Yellow
    Write-Host "      netsh advfirewall firewall add rule name=`"PCStress server web`" dir=in action=allow protocol=TCP localport=$Porta" -ForegroundColor Yellow
    Write-Host '  In alternativa, riavvia direttamente questo script come amministratore: fa tutto da solo.' -ForegroundColor Yellow
} else {
    Write-Host '  Apri il test dagli ALTRI PC della rete:' -ForegroundColor Green
    $indirizzi = @()
    try {
        $indirizzi = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress
    } catch {
        try {
            $indirizzi = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.ToString() } |
                Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' }
        } catch { }
    }
    if ($indirizzi.Count -eq 0) {
        Write-Host '      (nessun indirizzo di rete rilevato)' -ForegroundColor Yellow
    }
    foreach ($ip in $indirizzi) {
        Write-Host "      http://${ip}:$Porta/"
    }
}
Write-Host ''
Write-Host '  Premi CTRL+C per fermare il server.' -ForegroundColor Gray
Write-Host ''

# ------------------------------------------------------------- ciclo richieste
try {
    while ($listener.IsListening) {
        $contesto = $listener.GetContext()
        $richiesta = $contesto.Request
        $risposta = $contesto.Response
        try {
            $percorso = [Uri]::UnescapeDataString($richiesta.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($percorso)) { $percorso = 'index.html' }
            $completo = [IO.Path]::GetFullPath((Join-Path $radice $percorso))

            $dentroRadice = $completo.StartsWith($radice + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                            $completo.Equals($radice, [StringComparison]::OrdinalIgnoreCase)
            if (-not $dentroRadice) {
                $risposta.StatusCode = 403
            } elseif (Test-Path $completo -PathType Container) {
                $indice = Join-Path $completo 'index.html'
                if (Test-Path $indice -PathType Leaf) { $completo = $indice } else { $risposta.StatusCode = 404 }
            }

            if ($risposta.StatusCode -eq 200 -and (Test-Path $completo -PathType Leaf)) {
                $byte = [IO.File]::ReadAllBytes($completo)
                $est = [IO.Path]::GetExtension($completo).ToLowerInvariant()
                if ($tipiMime.ContainsKey($est)) { $risposta.ContentType = $tipiMime[$est] }
                else { $risposta.ContentType = 'application/octet-stream' }
                $risposta.ContentLength64 = $byte.Length
                $risposta.OutputStream.Write($byte, 0, $byte.Length)
                Write-Host ("  {0}  {1}  <- {2}" -f (Get-Date -Format 'HH:mm:ss'), $richiesta.Url.AbsolutePath, $richiesta.RemoteEndPoint.Address) -ForegroundColor DarkGray
            } elseif ($risposta.StatusCode -eq 200) {
                $risposta.StatusCode = 404
            }

            if ($risposta.StatusCode -ge 400) {
                $testoErrore = if ($risposta.StatusCode -eq 403) { 'accesso negato' } else { 'risorsa non trovata' }
                $msg = [Text.Encoding]::UTF8.GetBytes("$($risposta.StatusCode) - $testoErrore")
                $risposta.ContentType = 'text/plain; charset=utf-8'
                $risposta.ContentLength64 = $msg.Length
                $risposta.OutputStream.Write($msg, 0, $msg.Length)
            }
        } catch {
            try { $risposta.StatusCode = 500 } catch { }
        } finally {
            try { $risposta.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host 'Server fermato.' -ForegroundColor Gray
}
