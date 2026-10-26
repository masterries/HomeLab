<#
.SYNOPSIS
    Checks the ACME external account binding (EAB) of Traefik on the Matrix VM: OpenBao requires
    it, no binding key lies around unused, and Traefik's account is recorded as a bound one.

.DESCRIPTION
    Read-only. Three views:
      1. OpenBao's ACME directory for the role acme-matrix (no login needed): its meta says
         externalAccountRequired = true (eab_policy always-required, vars/openbao-config.yml).
      2. OpenBao itself (pc-admin login, revoked at the end): LIST pki_int/eab lists the binding
         keys handed out but not used yet. Normally there is none: matrix-prepare.yml mints one
         only when Traefik needs a new account, Traefik uses it in the same deployment, and
         OpenBao deletes it then. A key left over would still open a registration.
      3. The Matrix VM (SSH as ansible, sudo): Traefik has its ACME store (acme.json), the marker
         lab_acme_bound_marker lies next to it, the key file lab_acme_eab_file is gone, and
         Traefik's configuration (traefik.yml) carries no eab section any more.
    The two paths come from ansible/inventory/group_vars/all.yml. No secret is printed.

.EXAMPLE
    .\tests\Test-LabAcmeBinding.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$groupVars = Get-Content -Raw (Join-Path $script:LabTestRoot 'ansible\inventory\group_vars\all.yml')
$keyFile = [regex]::Match($groupVars, '(?m)^lab_acme_eab_file:\s*(\S+)').Groups[1].Value
$marker = [regex]::Match($groupVars, '(?m)^lab_acme_bound_marker:\s*(\S+)').Groups[1].Value
Assert-LabTest 'group_vars name the key file and the marker' ($keyFile -like '/*' -and $marker -like '/matrix/traefik/ssl/*') "$keyFile, $marker"

Write-Host 'OpenBao'
$directory = Invoke-LabBao GET 'pki_int/roles/acme-matrix/acme/directory'
Assert-LabTest 'the ACME directory requires external account binding' ([bool]$directory.meta.externalAccountRequired) "externalAccountRequired=$($directory.meta.externalAccountRequired)"
$token = Get-LabAdminToken
try {
    # LIST as GET with ?list=true (Windows PowerShell's web cmdlets know no LIST method).
    $listing = Invoke-LabBao GET 'pki_int/eab?list=true' -Token $token -AllowNotFound
    $unused = @(if ($listing -and $listing.data -and $listing.data.keys) { $listing.data.keys })
    Assert-LabTest 'no binding key handed out and still unused' ($unused.Count -eq 0) "$($unused.Count) unused"
}
finally { Close-LabBaoToken $token }

Write-Host 'Matrix VM'
$sshConfig = Get-LabSshConfig
$probe = "test -f /matrix/traefik/ssl/acme.json && echo store=yes || echo store=no; test -f $marker && echo marker=yes || echo marker=no; test -e $keyFile && echo keyfile=yes || echo keyfile=no; grep -q -w eab /matrix/traefik/config/traefik.yml && echo eab=yes || echo eab=no"
$ErrorActionPreference = 'Continue'
$lines = @(& ssh -F $sshConfig -o LogLevel=ERROR matrix "sudo sh -c '$probe'")
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$state = @{}
foreach ($line in $lines) { if ("$line" -match '^(\w+)=(yes|no)$') { $state[$Matches[1]] = $Matches[2] } }
Assert-LabTest 'the probe ran on the Matrix VM' ($exitCode -eq 0 -and $state.Count -eq 4) "exit code $exitCode"
Assert-LabTest "Traefik has its ACME store (acme.json)" ($state.store -eq 'yes')
Assert-LabTest "its account is recorded as bound ($marker)" ($state.marker -eq 'yes')
Assert-LabTest "no binding key left on the VM ($keyFile)" ($state.keyfile -eq 'no')
Assert-LabTest "Traefik's configuration carries no binding key" ($state.eab -eq 'no')
Complete-LabTest 'Test-LabAcmeBinding'
