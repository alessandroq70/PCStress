<#
.SYNOPSIS
  PCStress - Stress test nativo di stabilita' per Windows.

.DESCRIPTION
  Porta al limite CPU e RAM del computer per il tempo indicato e sorveglia
  il sistema: se lo scheduler si blocca (il segno tipico di un PC che "si
  impalla") lo registra e lo riporta nel verdetto finale.

  Non richiede installazioni: usa solo PowerShell, gia' presente in Windows.

.PARAMETER DurataMinuti
  Durata del test in minuti (predefinito: 10).

.PARAMETER CaricoCPU
  Percentuale di carico per ogni core, da 10 a 100 (predefinito: 100).

.PARAMETER MemoriaMB
  Quantita' di RAM da occupare in MB (predefinito: 2048).
  Viene ridotta automaticamente se supera l'80% della memoria libera.

.PARAMETER SenzaConferma
  Salta la richiesta di conferma iniziale.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\stress-nativo.ps1
  Test standard: 10 minuti, CPU al 100%, 2 GB di RAM.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\stress-nativo.ps1 -DurataMinuti 30 -MemoriaMB 4096
  Test approfondito da 30 minuti con 4 GB di RAM occupata.

.NOTES
  Interrompibile in qualsiasi momento con CTRL+C: il carico viene fermato
  e la memoria rilasciata comunque.

  Temperatura: lo script prova a leggere il sensore termico ACPI di Windows
  (namespace root/wmi). Non tutti i PC lo espongono - molti desktop non lo
  hanno - e di norma serve PowerShell da amministratore; e' una temperatura
  "di sistema", non quella per-core. Per letture precise affianca al test un
  monitor come LibreHardwareMonitor o HWiNFO.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)][int]$DurataMinuti = 10,
    [ValidateRange(10, 100)][int]$CaricoCPU = 100,
    [ValidateRange(64, 65536)][int]$MemoriaMB = 2048,
    [switch]$SenzaConferma
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- info sistema
$nCore = [int]$env:NUMBER_OF_PROCESSORS
if ($nCore -lt 1) { $nCore = 4 }

$nomeCpu = 'CPU sconosciuta'
$ramTotGB = 0
$ramLiberaMB = 0
try {
    $cpuInfo = Get-CimInstance Win32_Processor
    $nomeCpu = ($cpuInfo | Select-Object -First 1).Name.Trim()
    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $ramLiberaMB = [math]::Floor($os.FreePhysicalMemory / 1KB)
} catch { }

# ------------------------------------------------ sensore temperatura (ACPI)
# Best effort: molti PC (soprattutto desktop) non espongono questo sensore e
# di norma la lettura richiede diritti di amministratore.
function Leggi-Temperatura {
    try {
        $zone = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        $max = ($zone | Measure-Object -Property CurrentTemperature -Maximum).Maximum
        # il valore ACPI e' in decimi di kelvin
        if ($max -gt 0) { return [math]::Round($max / 10.0 - 273.15, 1) }
    } catch { }
    return $null
}
$temperaturaAvvio = Leggi-Temperatura

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  PCStress - stress test nativo per Windows'  -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "  CPU        : $nomeCpu ($nCore core logici)"
Write-Host "  RAM totale : $ramTotGB GB (libera: $([math]::Round($ramLiberaMB/1024,1)) GB)"
Write-Host "  Test       : $DurataMinuti min - CPU $CaricoCPU% su tutti i core - RAM $MemoriaMB MB"
if ($null -ne $temperaturaAvvio) {
    Write-Host "  Temperatura: $temperaturaAvvio gradi C (sensore ACPI di sistema)"
} else {
    Write-Host '  Temperatura: sensore ACPI non disponibile (normale su molti desktop;' -ForegroundColor Gray
    Write-Host '               prova da amministratore, o affianca LibreHardwareMonitor/HWiNFO)' -ForegroundColor Gray
}
Write-Host ''

# non prosciugare la memoria: mai oltre l'80% della RAM libera
# (clamp a 64 MB: ValidateRange resta attaccato alla variabile e una
#  riassegnazione sotto il minimo farebbe esplodere lo script)
if ($ramLiberaMB -gt 0 -and $MemoriaMB -gt $ramLiberaMB * 0.8) {
    $MemoriaMB = [int][math]::Max(64, [math]::Floor($ramLiberaMB * 0.8))
    Write-Warning "RAM richiesta troppo alta: ridotta a $MemoriaMB MB (80% della memoria libera)."
}

if (-not $SenzaConferma) {
    Write-Host 'ATTENZIONE: il PC verra'' portato al massimo carico. Salva e chiudi i documenti aperti.' -ForegroundColor Yellow
    $risposta = Read-Host 'Avviare il test? [S/N]'
    if ($risposta -notmatch '^[sSyY]') { Write-Host 'Test annullato.'; exit 0 }
}

# ------------------------------------------------------------------- log file
$cartellaLog = $PSScriptRoot
if (-not $cartellaLog -or -not (Test-Path $cartellaLog -PathType Container)) { $cartellaLog = $env:TEMP }
try { [IO.File]::AppendAllText((Join-Path $cartellaLog '.pcstress-scrivibile'), ''); Remove-Item (Join-Path $cartellaLog '.pcstress-scrivibile') -ErrorAction SilentlyContinue }
catch { $cartellaLog = $env:TEMP }
$fileLog = Join-Path $cartellaLog ("pcstress-log-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Scrivi-Log([string]$riga) {
    # best effort: un file di log bloccato (antivirus, sync) non deve
    # abortire un test lungo
    $testo = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $riga
    Add-Content -Path $fileLog -Value $testo -Encoding UTF8 -ErrorAction SilentlyContinue
}

Scrivi-Log "Avvio test: $DurataMinuti min, CPU $CaricoCPU%, RAM $MemoriaMB MB, $nCore core ($nomeCpu)"

# ------------------------------------------------------- carico CPU (runspace)
$segnaleStop = New-Object System.Threading.ManualResetEventSlim($false)

$bloccoCpu = {
    param($stop, $percentuale)
    # ciclo con duty cycle su finestre da 100 ms: lavora N ms, riposa 100-N ms
    $msLavoro = $percentuale
    $msRiposo = 100 - $percentuale
    $x = 0.5
    $orologio = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $stop.IsSet) {
        $orologio.Restart()
        while ($orologio.ElapsedMilliseconds -lt $msLavoro) {
            for ($i = 0; $i -lt 5000; $i++) {
                $x = [math]::Sqrt([math]::Abs([math]::Sin($x) * 1.1 + [math]::Cos($x * 3.7)) + 1e-9)
            }
        }
        if ($msRiposo -gt 0) { Start-Sleep -Milliseconds $msRiposo }
    }
}

$lavoratori = @()
Write-Host "Avvio di $nCore thread di carico CPU..." -ForegroundColor Gray
for ($c = 0; $c -lt $nCore; $c++) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($bloccoCpu).AddArgument($segnaleStop).AddArgument($CaricoCPU)
    $lavoratori += [pscustomobject]@{ Shell = $ps; Handle = $ps.BeginInvoke() }
}

# ------------------------------------------------------------- occupazione RAM
$blocchiRam = New-Object System.Collections.Generic.List[byte[]]
$CHUNK_MB = 64
$errore = $null

try {
    Write-Host "Occupazione di $MemoriaMB MB di RAM..." -ForegroundColor Gray
    $daAllocare = $MemoriaMB
    $mbAllocati = 0
    while ($daAllocare -gt 0) {
        $dim = [math]::Min($CHUNK_MB, $daAllocare)
        try {
            $blocco = New-Object byte[] ($dim * 1MB)
            # tocca le pagine per forzare l'impegno fisico della memoria
            for ($i = 0; $i -lt $blocco.Length; $i += 4096) { $blocco[$i] = 171 }
            $blocchiRam.Add($blocco)
            $mbAllocati += $dim
        } catch {
            Write-Warning "Limite di memoria raggiunto a $mbAllocati MB."
            Scrivi-Log "RAM: limite raggiunto a $mbAllocati MB"
            break
        }
        $daAllocare -= $dim
        Write-Progress -Activity 'PCStress' -Status "RAM occupata: $mbAllocati / $MemoriaMB MB" -PercentComplete (($mbAllocati / $MemoriaMB) * 100)
    }
    Write-Progress -Activity 'PCStress' -Completed
    $ramOccupata = $mbAllocati
    Scrivi-Log "RAM occupata: $ramOccupata MB"

    # ------------------------------------------------------- ciclo di controllo
    # Il "cane da guardia": ogni secondo prende un timestamp. Se tra un giro e
    # l'altro passano piu' di 3 secondi, il sistema intero si e' bloccato
    # (lo scheduler non ha eseguito nemmeno questo ciclo leggero in tempo).
    $avvio = Get-Date
    $fine = $avvio.AddMinutes($DurataMinuti)
    $orologioGiro = [System.Diagnostics.Stopwatch]::StartNew()
    $blocchiRilevati = 0
    $bloccoMassimoMs = 0
    $campioniCarico = New-Object System.Collections.Generic.List[double]
    $contatore = 0
    $interrotto = $false
    $tempMassima = $null

    # CTRL+C gestito a mano: cosi' il report finale viene stampato comunque
    $ctrlCGestito = $false
    try { [Console]::TreatControlCAsInput = $true; $ctrlCGestito = $true } catch { }

    Write-Host ''
    Write-Host 'Test in corso. Premi CTRL+C per interrompere in anticipo.' -ForegroundColor Green
    Write-Host "Log dettagliato: $fileLog" -ForegroundColor Gray
    Write-Host ''

    while ((Get-Date) -lt $fine) {
        # misura SOLO la finestra di sonno: se dura molto piu' di 1 s, lo
        # scheduler di sistema e' rimasto bloccato (il PC si e' "impallato")
        $orologioGiro.Restart()
        Start-Sleep -Seconds 1
        $giroMs = $orologioGiro.ElapsedMilliseconds
        $contatore++

        if ($giroMs -gt 3000) {
            $blocchiRilevati++
            if ($giroMs -gt $bloccoMassimoMs) { $bloccoMassimoMs = $giroMs }
            $msg = "POSSIBILE BLOCCO: il sistema non ha risposto per $([math]::Round($giroMs/1000.0,1)) s"
            Write-Host ("  [{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Red
            Scrivi-Log $msg
        }

        # CTRL+C premuto?
        if ($ctrlCGestito) {
            while ([Console]::KeyAvailable) {
                $tasto = [Console]::ReadKey($true)
                if ($tasto.Key -eq 'C' -and ($tasto.Modifiers -band [ConsoleModifiers]::Control)) { $interrotto = $true }
            }
            if ($interrotto) {
                Write-Host '  Interruzione richiesta: fermo il carico...' -ForegroundColor Yellow
                Scrivi-Log 'Test interrotto manualmente (CTRL+C)'
                break
            }
        }

        # ogni 5 secondi: campiona il carico CPU e aggiorna lo stato
        if ($contatore % 5 -eq 0) {
            $caricoAttuale = $null
            try {
                # LoadPercentage via CIM: funziona su qualsiasi lingua di Windows
                $caricoAttuale = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            } catch { }
            if ($null -ne $caricoAttuale) { $campioniCarico.Add([double]$caricoAttuale) }
            $temp = if ($null -ne $temperaturaAvvio) { Leggi-Temperatura } else { $null }
            $testoTemp = ''
            if ($null -ne $temp) {
                if ($null -eq $tempMassima -or $temp -gt $tempMassima) { $tempMassima = $temp }
                $testoTemp = "  |  temp: $temp C"
            }
            $rimasto = [math]::Max(0, [math]::Ceiling(($fine - (Get-Date)).TotalSeconds))
            $testoCarico = if ($null -ne $caricoAttuale) { "$([math]::Round($caricoAttuale))%" } else { 'n/d' }
            $trascorso = ((Get-Date) - $avvio).TotalSeconds
            $percento = [math]::Max(0, [math]::Min(100, ($trascorso / ($DurataMinuti * 60)) * 100))
            # minuti totali, non "minuti nell'ora": un test da 90 min deve mostrare 90:00
            $minRimasti = [int][math]::Floor($rimasto / 60)
            $secRimasti = [int]($rimasto % 60)
            Write-Progress -Activity 'PCStress - test in corso' `
                -Status ("CPU: {0}  |  RAM occupata: {1} MB  |  blocchi rilevati: {2}{3}  |  restano {4}:{5:d2}" -f $testoCarico, $ramOccupata, $blocchiRilevati, $testoTemp, $minRimasti, $secRimasti) `
                -PercentComplete $percento
            Scrivi-Log "vivo - CPU: $testoCarico, blocchi: $blocchiRilevati$testoTemp"
        }
    }
    Write-Progress -Activity 'PCStress - test in corso' -Completed
    if ($ctrlCGestito) { try { [Console]::TreatControlCAsInput = $false } catch { } }
} catch {
    $errore = $_
} finally {
    # ferma SEMPRE il carico e libera la memoria, anche dopo CTRL+C
    try { [Console]::TreatControlCAsInput = $false } catch { }
    $segnaleStop.Set()
    foreach ($l in $lavoratori) {
        try { [void]$l.Shell.EndInvoke($l.Handle) } catch { }
        try { $l.Shell.Dispose() } catch { }
    }
    $blocchiRam.Clear()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

if ($errore) {
    Scrivi-Log "Errore imprevisto: $errore"
    Write-Host "ERRORE imprevisto durante il test: $errore" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------- report
$durataEffettiva = [math]::Round(((Get-Date) - $avvio).TotalMinutes, 1)
$caricoMedio = if ($campioniCarico.Count -gt 0) { [math]::Round(($campioniCarico | Measure-Object -Average).Average) } else { $null }

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  RISULTATO DEL TEST'                          -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "  Durata effettiva : $durataEffettiva min$(if ($interrotto) { ' (interrotto manualmente)' })"
if ($null -ne $caricoMedio) { Write-Host "  Carico CPU medio : $caricoMedio%" }
Write-Host "  RAM occupata     : $ramOccupata MB"
if ($null -ne $tempMassima) {
    Write-Host "  Temperatura max  : $tempMassima gradi C (sensore ACPI di sistema)"
    if ($tempMassima -ge 90) {
        Write-Host '  ATTENZIONE: temperatura molto alta - controlla ventole e raffreddamento.' -ForegroundColor Yellow
    }
} else {
    Write-Host '  Temperatura max  : non disponibile (sensore ACPI assente o servono diritti admin)'
}
Write-Host "  Blocchi rilevati : $blocchiRilevati"
if ($blocchiRilevati -gt 0) { Write-Host "  Blocco piu' lungo: $([math]::Round($bloccoMassimoMs/1000.0,1)) s" }
Write-Host ''

if ($blocchiRilevati -gt 0) {
    $verdetto = "INSTABILE: il sistema si e' bloccato $blocchiRilevati volta/e sotto carico."
    Write-Host "  [X] $verdetto" -ForegroundColor Red
    Write-Host '    Cause tipiche: surriscaldamento, RAM difettosa, alimentazione insufficiente,' -ForegroundColor Red
    Write-Host '    driver instabili. Controlla temperature e memoria (mdsched.exe).' -ForegroundColor Red
} else {
    $verdetto = 'STABILE: nessun blocco rilevato per tutta la durata del test.'
    Write-Host "  [OK] $verdetto" -ForegroundColor Green
    Write-Host '    Nota: se durante il test il PC si e'' riavviato o spento da solo,' -ForegroundColor Gray
    Write-Host '    il risultato e'' comunque INSTABILE (controlla il log per l''ora esatta).' -ForegroundColor Gray
}
Scrivi-Log "FINE - $verdetto (durata: $durataEffettiva min)"
Write-Host ''
Write-Host "  Report completo: $fileLog" -ForegroundColor Gray
Write-Host ''
