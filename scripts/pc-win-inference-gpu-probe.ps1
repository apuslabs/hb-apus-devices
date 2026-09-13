param(
    [string]$InferenceUrl = "https://hb.apus.network/~inference@1.0/v1/chat/completions",
    [string]$Model = "google/gemma-4-26B-A4B-it",
    [string]$Prompt = "Reply with exactly: pc-win inference probe"
)

$ErrorActionPreference = "Stop"

function Get-Sha256Hex([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NvidiaRow([string]$Query) {
    $line = & nvidia-smi.exe "--query-gpu=$Query" "--format=csv,noheader,nounits" |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "nvidia-smi returned no row for $Query"
    }
    return (($line -split ",") | ForEach-Object { $_.Trim() })
}

$staticFields = Get-NvidiaRow "name,pci.bus_id,driver_version,uuid,memory.total,compute_cap"
$runtimeFields = Get-NvidiaRow "temperature.gpu,power.draw,utilization.gpu,utilization.memory,memory.used,memory.total"

$request = [ordered]@{
    model = $Model
    messages = @(
        [ordered]@{
            role = "user"
            content = $Prompt
        }
    )
    max_tokens = 16
}
$requestJson = $request | ConvertTo-Json -Compress

$response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $InferenceUrl -ContentType "application/json" -Body $requestJson
$responseJson = $response.Content | ConvertFrom-Json

$inventory = [ordered]@{
    name = $staticFields[0]
    pci_bdf = $staticFields[1]
    driver = $staticFields[2]
    uuid = $staticFields[3]
    vram_mib = $staticFields[4]
    compute_capability = $staticFields[5]
}
$runtime = [ordered]@{
    temperature_c = $runtimeFields[0]
    power_watts = $runtimeFields[1]
    utilization_gpu_percent = $runtimeFields[2]
    utilization_memory_percent = $runtimeFields[3]
    memory_used_mib = $runtimeFields[4]
    memory_total_mib = $runtimeFields[5]
}

$requestDigest = Get-Sha256Hex $requestJson
$responseDigest = Get-Sha256Hex $response.Content
$jointDigest = Get-Sha256Hex (($inventory | ConvertTo-Json -Compress) + "|" + $requestDigest + "|" + $responseDigest)

$probe = [ordered]@{
    type = "apus-pc-win-inference-gpu-probe"
    version = "1.0"
    host = $env:COMPUTERNAME
    os_version = (Get-CimInstance Win32_OperatingSystem).Version
    captured_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    provenance_class = "host-observed"
    measurement_integration = $false
    attestation = $false
    inference = [ordered]@{
        http_status = [int]$response.StatusCode
        url = $InferenceUrl
        model = $responseJson.model
        content = $responseJson.choices[0].message.content
        request_digest = $requestDigest
        response_digest = $responseDigest
    }
    gpu_inventory = $inventory
    runtime_snapshot = $runtime
    joint_digest = $jointDigest
}

$probe | ConvertTo-Json -Depth 8 -Compress
