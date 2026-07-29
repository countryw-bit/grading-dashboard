param(
    [ValidateSet("QA", "PROD")]
    [string]$Environment = "QA"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$PythonPath = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

if (-not (Test-Path $PythonPath)) {
    Write-Host ""
    Write-Host "Python virtual environment was not found." -ForegroundColor Red
    Write-Host "Expected location:" -ForegroundColor Yellow
    Write-Host $PythonPath
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

if ($Environment -eq "PROD") {
    $env:ENV_FILE = ".env.prod"
    $Port = 8001

    # Use localhost for PROD so its browser cookie is separate from QA.
    $DashboardUrl = "http://localhost:$Port/login"

    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host "      EagleApps Dashboard - PRODUCTION" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "This application is connected to live PROD data." -ForegroundColor Yellow
}
else {
    $env:ENV_FILE = ".env.qa"
    $Port = 8000

    # Use 127.0.0.1 for QA.
    $DashboardUrl = "http://127.0.0.1:$Port/login"

    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "          EagleApps Dashboard - QA" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
}

$SelectedEnvFile = Join-Path $ProjectRoot $env:ENV_FILE

if (-not (Test-Path $SelectedEnvFile)) {
    Write-Host ""
    Write-Host "Environment file was not found:" -ForegroundColor Red
    Write-Host $SelectedEnvFile -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

Write-Host ""
Write-Host "Environment file: $($env:ENV_FILE)"
Write-Host "Dashboard URL: $DashboardUrl"
Write-Host ""
Write-Host "Starting application..."
Write-Host "Keep this window open while using the dashboard."
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$UvicornArguments = @(
    "-m",
    "uvicorn",
    "app.main:app",
    "--host",
    "127.0.0.1",
    "--port",
    $Port
)

$ServerProcess = $null

try {
    # Start Uvicorn without blocking the launcher.
    $ServerProcess = Start-Process `
        -FilePath $PythonPath `
        -ArgumentList $UvicornArguments `
        -WorkingDirectory $ProjectRoot `
        -NoNewWindow `
        -PassThru

    # Wait until FastAPI responds before opening the browser.
    $ServerReady = $false

    for ($Attempt = 1; $Attempt -le 20; $Attempt++) {
        Start-Sleep -Milliseconds 500

        try {
            $Response = Invoke-WebRequest `
                -Uri "http://127.0.0.1:$Port/health" `
                -UseBasicParsing `
                -TimeoutSec 2

            if ($Response.StatusCode -eq 200) {
                $ServerReady = $true
                break
            }
        }
        catch {
            # Server is still starting.
        }

        if ($ServerProcess.HasExited) {
            throw "The FastAPI server stopped during startup."
        }
    }

    if (-not $ServerReady) {
        throw "The dashboard did not become available within 10 seconds."
    }

    Write-Host ""
    Write-Host "Application started successfully." -ForegroundColor Green
    Write-Host "Opening browser..."
    Write-Host ""

    Start-Process $DashboardUrl

    # Keep this launcher open while the server runs.
    Wait-Process -Id $ServerProcess.Id
}
catch {
    Write-Host ""
    Write-Host "The dashboard could not be started." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}
finally {
    if ($ServerProcess -and -not $ServerProcess.HasExited) {
        Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue
    }
}