<#
.SYNOPSIS
  Comprueba una lista de URLs y reporta códigos HTTP, resaltando las accesibles.

.PARAMETER InputFile
  Archivo .txt con una URL por línea. Las líneas que comienzan con # se ignoran.

.PARAMETER OutputCsv
  Archivo CSV de salida con los resultados.

.PARAMETER TimeoutSeconds
  Timeout en segundos para cada petición.

.EXAMPLE
  pwsh .\check-urls.ps1 -InputFile urls.txt -OutputCsv resultados.csv -TimeoutSeconds 15
#>

param(
    [string]$InputFile = "progress_endpoints.txt",
    [string]$OutputCsv = "results.csv",
    [int]$TimeoutSeconds = 15
)

if (-not (Test-Path $InputFile)) {
    Write-Error "No se encontró el fichero '$InputFile'. Coloca una lista de URLs (una por línea)."
    exit 1
}

# Leer y limpiar URLs (ignorar líneas vacías o que empiecen con #)
$urls = Get-Content $InputFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not ($_.StartsWith('#')) }

if ($urls.Count -eq 0) {
    Write-Warning "No hay URLs válidas en '$InputFile'."
    exit 0
}

# Preparar HttpClient
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$client  = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [System.TimeSpan]::FromSeconds($TimeoutSeconds)
# User-Agent decente para evitar bloqueos básicos
$client.DefaultRequestHeaders.UserAgent.ParseAdd("URLChecker/1.0 (+https://example)")

$results = @()

Write-Host "Comprobando $($urls.Count) URLs..." -ForegroundColor Cyan

foreach ($raw in $urls) {
    # normalizar: si no tiene esquema, añadir http://
    $url = $raw
    if (-not ($url -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://')) {
        $url = "http://$url"
    }

    $statusCode = $null
    $reason = ""
    $elapsedMs = $null
    $accessible = $false

    try {
        $uri = [System.Uri]::new($url)
    } catch {
        $reason = "URL inválida"
        Write-Host "❌ $raw -> $reason" -ForegroundColor DarkRed
        $results += [pscustomobject]@{
            URL = $raw
            RequestURL = $url
            StatusCode = ""
            ReasonPhrase = $reason
            TimeMs = ""
            Accessible = $false
        }
        continue
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Intentar HEAD primero para ahorrar tráfico
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $uri)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $statusCode = [int]$resp.StatusCode
        $reason = $resp.ReasonPhrase
        $sw.Stop()

        # Si servidor no permite HEAD (405 Method Not Allowed o 501 Not Implemented) -> intentar GET
        if ($statusCode -eq 405 -or $statusCode -eq 501) {
            $sw.Restart()
            $req2 = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
            $resp2 = $client.SendAsync($req2).GetAwaiter().GetResult()
            $statusCode = [int]$resp2.StatusCode
            $reason = $resp2.ReasonPhrase
            $sw.Stop()
        }
    }
    catch [System.AggregateException] {
        $sw.Stop()
        # extraer info cuando es WebException encerrada
        $agg = $_.Exception
        $inner = $agg.Flatten().InnerExceptions | Select-Object -First 1
        $reason = $inner.Message
    }
    catch {
        $sw.Stop()
        $reason = $_.Exception.Message
    }

    if ($statusCode -ne $null) {
        $elapsedMs = $sw.ElapsedMilliseconds
        # Consideramos "accesible" los códigos 2xx y 3xx (200-399)
        if ($statusCode -ge 200 -and $statusCode -lt 400) { $accessible = $true } else { $accessible = $false }

        # Salida coloreada según categoría
        switch ($true) {
            { $statusCode -ge 200 -and $statusCode -lt 300 } {
                Write-Host "✅ $raw -> $statusCode $reason ($elapsedMs ms)" -ForegroundColor Green
            }
            { $statusCode -ge 300 -and $statusCode -lt 400 } {
                Write-Host "➡️  $raw -> $statusCode $reason ($elapsedMs ms)" -ForegroundColor Yellow
            }
            { $statusCode -ge 400 } {
                Write-Host "❌ $raw -> $statusCode $reason ($elapsedMs ms)" -ForegroundColor Red
            }
            default {
                Write-Host "ℹ️  $raw -> $statusCode $reason ($elapsedMs ms)"
            }
        }
    }
    else {
        # Sin statusCode (error de conexión, timeout...)
        Write-Host "⚠️  $raw -> $reason" -ForegroundColor DarkRed
    }

    $results += [pscustomobject]@{
        URL = $raw
        RequestURL = $url
        StatusCode = if ($statusCode) { $statusCode } else { "" }
        ReasonPhrase = $reason
        TimeMs = if ($elapsedMs) { $elapsedMs } else { "" }
        Accessible = $accessible
    }
}

# Guardar CSV
$results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Hecho. Resultados guardados en '$OutputCsv'." -ForegroundColor Cyan
