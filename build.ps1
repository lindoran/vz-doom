# build.ps1 — assemble a Z80 source file and wrap it as a .VZ autostart binary
#
# Usage:  .\build.ps1 src\wavedemo.asm WAVEDEMO
#         .\build.ps1 <source.asm> <NAME> [-LoadAddr 0x7AE9]
#
# Output: build\<NAME>.VZ  (24-byte VZF1 header + binary, type F1 autostart)
# The source must SAVEBIN to build\<basename>.bin (see wavedemo.asm).

param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$LoadAddr = 0x7AE9
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# ── Assemble ──────────────────────────────────────────────────────────────────
$sj = Join-Path $root "tools\sjasmplus.exe"
if (-not (Test-Path $sj)) {
    throw "sjasmplus.exe not found in tools\. Download it from " +
          "https://github.com/z00m128/sjasmplus/releases and put sjasmplus.exe " +
          "in the tools\ folder (see README > Building)."
}
& $sj $Source
if ($LASTEXITCODE -ne 0) { throw "sjasmplus failed with exit code $LASTEXITCODE" }

$binPath = Join-Path $root ("build\" + [IO.Path]::GetFileNameWithoutExtension($Source) + ".bin")
if (-not (Test-Path $binPath)) { throw "Expected assembler output not found: $binPath" }
$code = [IO.File]::ReadAllBytes($binPath)

# ── VZ header: 'VZF1' + name[17] + type F1 + load address LE ─────────────────
if ($Name.Length -gt 8) { throw ".VZ filenames are limited to 8 characters" }
$header = New-Object byte[] 24
[Text.Encoding]::ASCII.GetBytes("VZF1").CopyTo($header, 0)
[Text.Encoding]::ASCII.GetBytes($Name.ToUpper()).CopyTo($header, 4)
$header[21] = 0xF1                              # binary / autostart
$header[22] = $LoadAddr -band 0xFF              # load address, little-endian
$header[23] = ($LoadAddr -shr 8) -band 0xFF

$outPath = Join-Path $root ("build\" + $Name.ToUpper() + ".VZ")
[IO.File]::WriteAllBytes($outPath, [byte[]]($header + $code))

Write-Host ""
Write-Host ("Built {0}" -f $outPath)
Write-Host ("  code  : {0} bytes at 0x{1:X4}" -f $code.Length, $LoadAddr)
Write-Host ("  total : {0} bytes" -f (24 + $code.Length))
