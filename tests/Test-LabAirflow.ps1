<#
.SYNOPSIS
    Checks Apache Airflow on the Kubernetes cluster end to end, the way you use it: through
    https://airflow.<domain> from this PC, one run of the example DAG lab_hello, and its task logs.

.DESCRIPTION
    What it does, all through Airflow's REST API (the same API the web UI uses):
      1. Logs in as admin (password read from OpenBao with a pc-admin login, never printed) and
         gets a token (POST /auth/token).
      2. Finds the DAG lab_hello (fleet/airflow-dags, pulled by git-sync). If it is paused, the test
         unpauses it for the run and pauses it again at the end.
      3. Triggers a run and waits up to 5 minutes for it: the scheduler queues the tasks in Redis, the
         Celery worker runs them, XCom passes the results through PostgreSQL.
      4. Checks each task: state success, and the host it recorded is an IP address (the worker
         reports its pod IP, config.core.hostname_callable in fleet/airflow/fleet.yaml; a pod name
         would not resolve, and the UI could not fetch the log).
      5. Reads each task's log through the API: the api-server fetches it from the worker that ran
         the task (port 8793). The load task's log must contain the line it prints.
      6. Cleans up: deletes the run it triggered (and, if it had to unpause the DAG, the scheduled
         run the scheduler may have started in the meantime) and restores the pause state.
    Changes: a run of lab_hello while the test lasts, deleted again (the task log files stay on the
    worker until the pod is replaced). Needs: lab.ps1 deploy fleet.

.EXAMPLE
    .\tests\Test-LabAirflow.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$base = "https://airflow.$($script:LabConfig.domain)"
$dagId = 'lab_hello'
$started = [DateTimeOffset]::UtcNow.AddSeconds(-5)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Airflow at $base"
$health = Invoke-RestMethod -Uri "$base/api/v2/monitor/health" -UseBasicParsing -TimeoutSec 20
Assert-LabTest 'the health endpoint reports database and scheduler healthy' ($health.metadatabase.status -eq 'healthy' -and $health.scheduler.status -eq 'healthy') "metadatabase=$($health.metadatabase.status), scheduler=$($health.scheduler.status)"

# The admin password goes from OpenBao straight into the login request; the token into headers.
$baoToken = Get-LabAdminToken
try { $password = (Invoke-LabBao GET 'lab/data/k8s/airflow/admin' -Token $baoToken).data.data.password }
finally { Close-LabBaoToken $baoToken }
$login = Invoke-RestMethod -Method Post -Uri "$base/auth/token" -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20 `
    -Body (ConvertTo-Json @{ username = 'admin'; password = $password })
$password = $null
Assert-LabTest 'admin logs in through the API (token issued)' ([bool]$login.access_token)
$headers = @{ Authorization = "Bearer $($login.access_token)" }
function Invoke-Airflow([string]$Method, [string]$Path, $Body) {
    $call = @{ Method = $Method; Uri = "$base$Path"; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($null -ne $Body) { $call.Body = (ConvertTo-Json $Body -Depth 5); $call.ContentType = 'application/json' }
    Invoke-RestMethod @call
}

$dag = Invoke-Airflow GET "/api/v2/dags/$dagId"
Assert-LabTest "the DAG $dagId is there (git-sync from fleet/airflow-dags)" ($dag.dag_id -eq $dagId) "paused=$($dag.is_paused)"
$wasPaused = [bool]$dag.is_paused
$runId = $null
try {
    if ($wasPaused) { Invoke-Airflow PATCH "/api/v2/dags/$dagId" @{ is_paused = $false } | Out-Null }
    $run = Invoke-Airflow POST "/api/v2/dags/$dagId/dagRuns" @{ logical_date = $null; note = 'Test-LabAirflow.ps1' }
    $runId = $run.dag_run_id
    $runPath = "/api/v2/dags/$dagId/dagRuns/$([uri]::EscapeDataString($runId))"
    Write-Host "Run $runId"
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $run = Invoke-Airflow GET $runPath
    } while ($run.state -notin 'success', 'failed' -and (Get-Date) -lt $deadline)
    Assert-LabTest 'the run succeeded (scheduler, Redis, Celery worker, XCom in PostgreSQL)' ($run.state -eq 'success') "state=$($run.state)"

    $instances = @((Invoke-Airflow GET "$runPath/taskInstances").task_instances)
    Assert-LabTest 'three task instances: extract, transform, load' ($instances.Count -eq 3) "$(@($instances | ForEach-Object { "$($_.task_id)=$($_.state)" }) -join ', ')"
    foreach ($ti in $instances) {
        Assert-LabTest "$($ti.task_id): success, recorded host is the worker's pod IP" ($ti.state -eq 'success' -and $ti.hostname -match '^\d{1,3}(\.\d{1,3}){3}$') "state=$($ti.state), host=$($ti.hostname)"
        $log = Invoke-Airflow GET "$runPath/taskInstances/$($ti.task_id)/logs/$([Math]::Max(1, [int]$ti.try_number))"
        $text = ConvertTo-Json @($log.content) -Depth 6 -Compress
        $served = $text -notmatch 'Could not read served logs' -and $text.Length -gt 50
        if ($ti.task_id -eq 'load') { $served = $served -and $text -match 'Summary of this run' }
        Assert-LabTest "$($ti.task_id): its log reads through the API (fetched from the worker)" $served "$($text.Length) characters"
    }
}
finally {
    # Leave Airflow as it was: delete the runs this test caused, restore the pause state.
    if ($wasPaused) { try { Invoke-Airflow PATCH "/api/v2/dags/$dagId" @{ is_paused = $true } | Out-Null } catch { Write-Host "  could not pause $dagId again: $($_.Exception.Message)" } }
    try {
        $recent = @((Invoke-Airflow GET "/api/v2/dags/$dagId/dagRuns?limit=50&order_by=-run_after").dag_runs)
        foreach ($r in $recent) {
            $ours = $r.dag_run_id -eq $runId
            $scheduledMeanwhile = $wasPaused -and $r.run_type -eq 'scheduled' -and $r.queued_at -and [DateTimeOffset]::Parse($r.queued_at) -ge $started
            if ($ours -or $scheduledMeanwhile) { Invoke-Airflow DELETE "/api/v2/dags/$dagId/dagRuns/$([uri]::EscapeDataString($r.dag_run_id))" | Out-Null }
        }
    }
    catch { Write-Host "  could not delete the test's runs: $($_.Exception.Message)" }
}
$after = Invoke-Airflow GET "/api/v2/dags/$dagId"
$left = @(@((Invoke-Airflow GET "/api/v2/dags/$dagId/dagRuns?limit=50&order_by=-run_after").dag_runs) | Where-Object { $_.dag_run_id -eq $runId })
Assert-LabTest 'cleaned up: the run is deleted, the DAG paused as before' ($left.Count -eq 0 -and [bool]$after.is_paused -eq $wasPaused) "paused=$($after.is_paused)"
Complete-LabTest 'Test-LabAirflow'
