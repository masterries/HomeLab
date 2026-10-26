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
        layout before lab.ps1); README.md names them only in its rename section ("Where the old
        scripts went"),
      - every link in README.md, tests\README.md and vendor\README.md resolves: "#anchor" links to
        a heading of the same document, other links to a file or folder of the repository.
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
    $badVendor = @($p.vendor | Where-Object { $_ -and ($_ -eq 'mdad' -or -not (Test-Path (Join-Path $root "vendor\$_"))) })
    if ($p.vendor) { Assert-LabTest "profile $name`: vendor folders exist" ($badVendor.Count -eq 0) ($badVendor -join ', ') }
}
$profileText = Get-Content -Raw (Join-Path $root 'config\run-profiles.json')
# Playbooks that a script in a profile starts (bin/deploy-matrix runs matrix-check.yml).
$startedByScripts = (Get-ChildItem (Join-Path $root 'ansible\bin') | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
foreach ($folder in 'playbooks', 'kubernetes') {
    foreach ($playbook in Get-ChildItem (Join-Path $root "ansible\$folder") -Filter '*.yml') {
        $used = $profileText -match [regex]::Escape("$folder/$($playbook.Name)") -or $startedByScripts -match [regex]::Escape("$folder/$($playbook.Name)")
        Assert-LabTest "playbook $folder/$($playbook.Name) has a run profile" $used
    }
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
# Also any script directly in scripts\ (there are none since lab.ps1) and "Deploy-Lab*.ps1".
$pattern = "(\b($($retired -join '|'))\.ps1\b|\bscripts[\\/][A-Z][A-Za-z-]*\.ps1\b|Deploy-Lab\*|\bInvoke-LabRunToken\b|\bUpdate-GuiCertificate\b|\bLabTlsPin2\b|tests[\\/]remote\b)"
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

Write-Host 'Documentation'
# GitHub's anchor for a heading: lower case, without punctuation (letters, digits, spaces, "-" and
# "_" stay), spaces become "-"; a repeated heading gets "-1", "-2", ...
function Get-LabDocAnchors([string[]]$Lines) {
    $anchors = @{}
    $inCode = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
        if ($inCode -or $line -notmatch '^#{1,6} +(.+?)\s*$') { continue }
        $slug = ($Matches[1].ToLowerInvariant() -replace '[^\p{L}\p{Nd} _-]', '') -replace ' ', '-'
        $unique = $slug; $n = 0
        while ($anchors.ContainsKey($unique)) { $n++; $unique = "$slug-$n" }
        $anchors[$unique] = $true
    }
    return $anchors
}
foreach ($doc in 'README.md', 'tests\README.md', 'vendor\README.md') {
    $path = Join-Path $root $doc
    $lines = [IO.File]::ReadAllLines($path)
    $anchors = Get-LabDocAnchors $lines
    $broken = @()
    $inCode = $false
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        foreach ($m in [regex]::Matches($line, '\]\(([^)\s]+)\)')) {
            $target = $m.Groups[1].Value
            if ($target -match '^(https?|mailto):') { continue }
            if ($target.StartsWith('#')) {
                if (-not $anchors.ContainsKey($target.Substring(1))) { $broken += "${doc}:$lineNumber $target" }
                continue
            }
            # A file link, relative to the document's folder (anchors and :line suffixes dropped).
            $file = ($target -replace '#.*$', '' -replace ':\d+$', '') -replace '/', '\'
            if (-not (Test-Path (Join-Path (Split-Path -Parent $path) ([Uri]::UnescapeDataString($file))))) { $broken += "${doc}:$lineNumber $target" }
        }
    }
    Assert-LabTest "$doc`: every link resolves" ($broken.Count -eq 0) "$($broken.Count) broken$(if ($broken) { ': ' + (($broken | Select-Object -First 6) -join ', ') })"
}
# Retired names in the README only in its rename section ("Where the old scripts went").
$readmeLines = [IO.File]::ReadAllLines((Join-Path $root 'README.md'))
$inRenames = $false
$inCode = $false
$found = @()
$lineNumber = 0
foreach ($line in $readmeLines) {
    $lineNumber++
    if ($line -match '^\s*```') { $inCode = -not $inCode }
    if (-not $inCode -and $line -match '^#{1,6} ') { $inRenames = $line -match '^#{1,6} Where the old scripts went' }
    if (-not $inRenames -and $line -match $pattern -and -not $line.Contains($frozen)) { $found += "README.md:$lineNumber" }
}
Assert-LabTest 'README names retired scripts only in "Where the old scripts went"' ($found.Count -eq 0) "$($found.Count) lines$(if ($found) { ': ' + (($found | Select-Object -First 8) -join ', ') })"

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
# Typed in a PowerShell session, "-Confirm:$false" reaches lab.ps1 as two elements of $args,
# "-Confirm:" and $false (Split-LabArguments in scripts\lib\Lab.ps1). They must become one named
# parameter; everything else stays positional, in its order.
$split = Split-LabArguments @('matrix', '-Confirm:', $false, '-WhatIf', '--check', '-Target:', 'vault')
$splitOk = ($split.Named.Count -eq 2 -and $split.Named['Confirm'] -eq $false -and $split.Named['Target'] -eq 'vault' -and
    (@($split.Positional) -join ' ') -eq 'matrix -WhatIf --check')
Assert-LabTest '-Name:value becomes a named parameter (Split-LabArguments)' $splitOk "named: $(($split.Named.Keys | Sort-Object) -join ','); positional: $(@($split.Positional) -join ' ')"
Complete-LabTest 'Test-LabLayout'
