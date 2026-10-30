param(
    [string]$Dxc = $env:DXC,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
    if (-not $SkipBuild) {
        zig build -Dcli=true -Doptimize=ReleaseSafe
        if ($LASTEXITCODE -ne 0) { throw 'zig build failed' }
    }

    zig build test -Dcli=true
    if ($LASTEXITCODE -ne 0) { throw 'unit tests failed' }

    zig build c-test
    if ($LASTEXITCODE -ne 0) { throw 'C interop test failed' }

    zig build cpp-test
    if ($LASTEXITCODE -ne 0) { throw 'C++ interop test failed' }

    $exe = Join-Path $root 'zig-out\bin\glsl2hlsl.exe'
    if (-not (Test-Path $exe)) { throw "binary not found: $exe" }

    if (-not $Dxc) {
        $vulkan = Join-Path $env:ProgramFiles 'Khronos Group\Vulkan SDK\Bin\dxc.exe'
        if (Test-Path $vulkan) {
            $Dxc = $vulkan
        } else {
            $command = Get-Command dxc.exe -ErrorAction SilentlyContinue
            if ($command) { $Dxc = $command.Source }
        }
    }
    if (-not $Dxc) { Write-Warning 'dxc.exe not found; generated HLSL will not be compiled' }

    $sources = @()
    foreach ($directory in @('tests\shaders', 'examples')) {
        $path = Join-Path $root $directory
        if (Test-Path $path) {
            $sources += Get-ChildItem $path -File | Where-Object { $_.Extension -in '.vert', '.frag' }
        }
    }

    $failures = 0
    foreach ($source in $sources) {
        $stage = if ($source.Extension -eq '.vert') { 'vertex' } else { 'fragment' }
        $profile = if ($stage -eq 'vertex') { 'vs_6_0' } else { 'ps_6_0' }
        $output = "$($source.FullName).hlsl"

        & $exe $source.FullName -o $output -s $stage
        if ($LASTEXITCODE -ne 0) {
            Write-Host "convert failed: $($source.Name)"
            $failures += 1
            continue
        }

        if ($Dxc) {
            $object = Join-Path $env:TEMP ("glsl2hlsl-" + $source.BaseName + ".cso")
            & $Dxc -T $profile -E main -Fo $object $output
            if ($LASTEXITCODE -ne 0) {
                Write-Host "dxc failed: $($source.Name)"
                $failures += 1
                continue
            }
        }

        Write-Host "ok: $($source.Name)"
    }

    if ($failures -ne 0) {
        Write-Host "$failures shader(s) failed"
        exit 1
    }

    Write-Host "all shaders ok"
} finally {
    Pop-Location
}
