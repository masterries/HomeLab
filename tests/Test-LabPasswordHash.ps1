<#
.SYNOPSIS
    Checks that New-LabFirewall.ps1's Get-PasswordHash (secret on openssl's stdin) gives exactly
    the hash of the plain command-line form - with a DUMMY value, never a real password.

.DESCRIPTION
    Local only. Loads Get-PasswordHash and its helpers from New-LabFirewall.ps1 (without running
    the script), hashes a dummy value with a fixed salt both ways and compares. It also runs
    with a console input encoding that writes a byte order mark (UTF-8 with BOM), the case in
    which a naive stdin version would hash the BOM as part of the password.

.EXAMPLE
    .\tests\Test-LabPasswordHash.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$scriptPath = Join-Path $script:LabTestRoot 'scripts\New-LabFirewall.ps1'
$openssl = Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
foreach ($name in 'New-RandomBytes', 'New-RandomText', 'Get-PasswordHash') {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

Write-Host 'Password hashing for the firewall'
$dummy = 'dummyvalue-Ab3'
$salt = 'abcdefgh'
$argvHash = (& $openssl passwd -6 -salt $salt $dummy).Trim()
$saved = [Console]::InputEncoding
try {
    foreach ($encoding in @((New-Object Text.UTF8Encoding $true), [Text.Encoding]::GetEncoding(850))) {
        [Console]::InputEncoding = $encoding
        Assert-LabTest "stdin hash = command-line hash (console input $($encoding.WebName), BOM: $($encoding.GetPreamble().Length -gt 0))" ((Get-PasswordHash $dummy $salt) -ceq $argvHash)
    }
}
finally { [Console]::InputEncoding = $saved }
Assert-LabTest 'random salt of 16 characters by default' ((Get-PasswordHash $dummy) -match '^\$6\$[A-Za-z0-9]{16}\$')
Complete-LabTest 'Test-LabPasswordHash'
