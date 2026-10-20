$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$project = 'src/WindowsImeCaretIndicator/WindowsImeCaretIndicator.csproj'
$redRoot = 'artifacts/caret-recovery-red-source'
if (Test-Path $redRoot) { throw 'Red fixture already exists; use a clean checkout.' }
New-Item -ItemType Directory -Path $redRoot -Force | Out-Null
Copy-Item 'src/WindowsImeCaretIndicator' $redRoot -Recurse
$redProject = Join-Path $redRoot 'WindowsImeCaretIndicator/WindowsImeCaretIndicator.csproj'
$catch = "        catch (FlaUI.Core.Exceptions.ElementNotAvailableException)`n        {`n            return false;`n        }`n"
foreach ($file in @('Uia3Text2CaretProvider.cs', 'CaretTracking.cs')) {
    $path = Join-Path $redRoot "WindowsImeCaretIndicator/$file"
    $content = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
    if (([regex]::Matches($content, [regex]::Escape($catch)).Count) -ne 1) { throw "Expected one recovery catch in $file" }
    [IO.File]::WriteAllText($path, $content.Replace($catch, ''))
}
# The red fixture differs only by the two exact catch clauses being absent.
& dotnet build $redProject -c Debug -o artifacts/caret-recovery-red
if ($LASTEXITCODE -ne 0) { throw 'Red fixture did not compile.' }
$redOutput = & './artifacts/caret-recovery-red/WindowsImeCaretIndicator.exe' --self-test 2>&1
$redExit = $LASTEXITCODE
$redOutput | Set-Content artifacts/caret-recovery-red.txt
$redOutput | Write-Host
$expected = @(
    'UIA3 unavailable element is a failed lookup',
    'selection UIA unavailable element is a failed lookup',
    'unavailable primary continues to selection fallback',
    'unavailable UIA providers preserve subsequent timer refresh'
)
$text = $redOutput -join "`n"
if ($redExit -ne 1) { throw "Expected red exit 1, got $redExit" }
foreach ($name in $expected) {
    if (-not $text.Contains("FAIL: ${name}: FlaUI.Core.Exceptions.ElementNotAvailableException")) {
        throw "Red failure did not match the reported exception: $name"
    }
}
if ([regex]::Matches($text, '(?m)^FAIL(?:[: ])').Count -ne 4) { throw 'Unexpected red fixture failures.' }
& dotnet build $project -c Debug -o artifacts/caret-recovery-green
if ($LASTEXITCODE -ne 0) { throw 'Fixed candidate did not compile.' }
$greenOutput = & './artifacts/caret-recovery-green/WindowsImeCaretIndicator.exe' --self-test 2>&1
$greenExit = $LASTEXITCODE
$greenOutput | Set-Content artifacts/caret-recovery-green.txt
$greenOutput | Write-Host
if ($greenExit -ne 0 -or -not (($greenOutput -join "`n").Contains('37/37 tests passed.'))) {
    throw "Fixed candidate regression failed, exit $greenExit"
}
