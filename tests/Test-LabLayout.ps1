<#
.SYNOPSIS
    Checks the repository's structure and the lab.ps1 dispatcher. Needs no lab: it reads files and
    starts lab.ps1 in child processes.

.DESCRIPTION
    The repository holds several lists that must agree with each other; this test catches the
    drift a rename or a new playbook can cause:
      - lab.ps1's command list (its ValidateSet, for Tab completion) and the command table in
        scripts\lib\Lab.ps1 name the same commands, and every command's script or function exists,
      - PowerShell code lives only in scripts\lib, scripts\commands, scripts\host and scripts\dev,
      - every run profile (config\run-profiles.json) names an existing playbook or script, valid
        SSH principals, existing OpenBao policies and a known token role,
      - every playbook has a run profile (or is started by a script that is in one), and every
        OpenBao policy file is used,
      - no code or comment names a script or function that no longer exists (the repository's
        layout before lab.ps1). README.md is not checked: its rename table names them on purpose.
    The dispatcher: "help" works, an unknown command is refused, a command for your own window is
    refused when the output is redirected (as here), "breakglass" without a command is refused.

.EXAMPLE
    .\tests\Test-LabLayout.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')
$root = $script:LabTestRoot

Write-Host 'Commands'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lab.ps1'), [ref]$null, [ref]$null)
$validateSet = $ast.ParamBlock.Parameters[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
$listed = @($validateSet.PositionalArguments | ForEach-Object { $_.Value })
$table = @($script:LabCommands.Keys)
$difference = @(Compare-Object $listed $table | ForEach-Object { "$($_.InputObject) ($(if ($_.SideIndicator -eq '<=') { 'only in lab.ps1' } else { 'only in Lab.ps1' }))" })
Assert-LabTest 'lab.ps1 and the command table name the same commands' ($difference.Count -eq 0) ($difference -join ', ')
foreach ($name in $table) {
    $entry = $script:LabCommands[$name]
    if ($entry.File) { Assert-LabTest "command $name -> $($entry.File)" (Test-Path (Join-Path $root $entry.File)) }
    elseif ($entry.Function) { Assert-LabTest "command $name -> function $($entry.Function)" ([bool](Get-Command $entry.Function -ErrorAction SilentlyContinue)) }
}
$stray = @(Get-ChildItem (Join-Path $root 'scripts') -Recurse -Filter '*.ps1' | Where-Object {
        $_.Directory.Name -notin 'lib', 'commands', 'host', 'dev' -or $_.Directory.Parent.FullName -ne (Join-Path $root 'scripts') } |
    ForEach-Object { $_.FullName.Substring($root.Length + 1) })
Assert-LabTest 'PowerShell code only in scripts\lib, commands, host, dev' ($stray.Count -eq 0) ($stray -join ', ')

Write-Host 'Run profiles'
$profiles = Get-LabRunProfiles
$machines = @(Get-LabSshMachines)
$policyDir = Join-Path $root 'config\openbao\policies'
foreach ($property in $profiles.PSObject.Properties) {
    $name = $property.Name; $p = $property.Value
    if ($p.playbook) { $target = $p.playbook }
    elseif ("$($p.command)" -match '\bbash (\S+)') { $target = $Matches[1] }
    else { $target = $null }
    if ($target) { Assert-LabTest "profile $name -> ansible\$target" (Test-Path (Join-Path $root "ansible\$target")) }
    $badPrincipals = @($p.principals | Where-Object { $_ -ne 'lab-all' -and ($_ -notmatch '^host-(.+)$' -or $machines -notcontains $Matches[1]) })
    Assert-LabTest "profile $name`: SSH principals" ($badPrincipals.Count -eq 0) ($badPrincipals -join ', ')
    $missing = @($p.policies | Where-Object { $_ -and -not (Test-Path (Join-Path $policyDir "$_.hcl")) })
    if ($p.policies) { Assert-LabTest "profile $name`: OpenBao policies exist" ($missing.Count -eq 0) ($missing -join ', ') }
    if ($p.tokenRole) { Assert-LabTest "profile $name`: token role $($p.tokenRole)" ($p.tokenRole -in 'ansible-run', 'ansible-config') }
}
$profileText = Get-Content -Raw (Join-Path $root 'config\run-profiles.json')
# Playbooks that a script in a profile starts (bin/deploy-matrix runs matrix-check.yml).
$startedByScripts = (Get-ChildItem (Join-Path $root 'ansible\bin') | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
foreach ($playbook in Get-ChildItem (Join-Path $root 'ansible\playbooks') -Filter '*.yml') {
    $used = $profileText -match [regex]::Escape("playbooks/$($playbook.Name)") -or $startedByScripts -match [regex]::Escape("playbooks/$($playbook.Name)")
    Assert-LabTest "playbook $($playbook.Name) has a run profile" $used
}
$vaultCode = Get-Content -Raw (Join-Path $root 'scripts\lib\LabVault.ps1')
foreach ($policy in Get-ChildItem $policyDir -Filter '*.hcl') {
    $quoted = '"{0}"' -f $policy.BaseName
    $used = $profileText.Contains($quoted) -or $vaultCode.Contains("'$($policy.BaseName)'")
    Assert-LabTest "policy $($policy.BaseName) is used" $used
}

Write-Host 'No names from before lab.ps1'
$retired = 'Initialize-Lab', 'New-LabFirewall', 'Deploy-LabVault', 'Deploy-LabKeycloak', 'Deploy-LabMatrix', 'Remove-Lab',
    'Connect-Lab', 'Show-LabSecret', 'New-LabRecoveryKit', 'Install-LabHostNetwork', 'Invoke-LabPlaybook', 'Unlock-LabVault',
    'Backup-LabVault', 'Open-LabVaultUi', 'Update-LabSshCertificate', 'New-LabSshCa', 'New-LabRootCA', 'Import-LabSecrets',
    'Complete-LabSshMigration'
$pattern = "(\b($($retired -join '|'))\.ps1\b|\bInvoke-LabRunToken\b|\bUpdate-GuiCertificate\b|\bLabTlsPin2\b|tests/remote\b)"
# The firewall VM's tag in Hyper-V keeps its old text: changing it would make lab.ps1 refuse the
# existing firewall as "not built by this script".
$frozen = 'managed-by=DeployableServer/scripts/New-LabFirewall.ps1'
$checked = @(Join-Path $root 'lab.ps1') + @('scripts', 'tests', 'ansible', 'vagrant', 'provision', 'config', 'opnsense' |
        ForEach-Object { Get-ChildItem (Join-Path $root $_) -Recurse -File | Where-Object { $_.Length -lt 2MB } | ForEach-Object { $_.FullName } }) +
    @(Join-Path $root 'vendor\README.md')
$found = @()
foreach ($file in $checked | Where-Object { $_ -ne $PSCommandPath }) {
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $lineNumber++
        if ($line -match $pattern -and -not $line.Contains($frozen)) { $found += "$($file.Substring($root.Length + 1)):$lineNumber" }
    }
}
Assert-LabTest 'no retired script or function is named' ($found.Count -eq 0) (($found | Select-Object -First 8) -join ', ')

Write-Host 'Dispatcher'
$ErrorActionPreference = 'Continue'
$lab = Join-Path $root 'lab.ps1'
function Invoke-LabChild([string[]]$Arguments) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lab @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}
$help = Invoke-LabChild @('help')
$missingInHelp = @($table | Where-Object { $help.Text -notmatch "(?m)^\s+$([regex]::Escape($_))\s" })
Assert-LabTest 'help lists every command' ($help.Code -eq 0 -and $missingInHelp.Count -eq 0) ($missingInHelp -join ', ')
$unknown = Invoke-LabChild @('no-such-command')
Assert-LabTest 'an unknown command is refused' ($unknown.Code -eq 1)  "exit code $($unknown.Code)"
$own = Invoke-LabChild @('trust')
Assert-LabTest 'trust (your own window) is refused with redirected output' ($own.Code -eq 2 -and $own.Text -match 'your own PowerShell window') "exit code $($own.Code)"
$glass = Invoke-LabChild @('breakglass')
Assert-LabTest 'breakglass without a command is refused' ($glass.Code -eq 2) "exit code $($glass.Code)"
$list = Invoke-LabChild @('run')
Assert-LabTest 'run without arguments lists the profiles' ($list.Code -eq 0 -and $list.Text -match 'openbao-config') "exit code $($list.Code)"
Complete-LabTest 'Test-LabLayout'
