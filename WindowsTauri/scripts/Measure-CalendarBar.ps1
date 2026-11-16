param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$RootProcessId,
    [ValidateRange(1, 30)]
    [int]$Samples = 5,
    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 2
)

$ErrorActionPreference = 'Stop'
$root = Get-Process -Id $RootProcessId
for ($sample = 1; $sample -le $Samples; $sample++) {
    if ($root.HasExited) { throw 'CalendarBar has exited. Start it again and pass the new PID.' }
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate
    $rootRow = $all | Where-Object ProcessId -eq $RootProcessId
    if (!$rootRow) { throw 'CalendarBar process is no longer available.' }
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootProcessId)
    do {
        $count = $ids.Count
        foreach ($proc in $all) {
            if ($proc.CreationDate -ge $rootRow.CreationDate -and $ids.Contains([int]$proc.ParentProcessId)) {
                [void]$ids.Add([int]$proc.ProcessId)
            }
        }
    } while ($count -ne $ids.Count)

    $memory = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Property IDProcess, WorkingSetPrivate, PrivateBytes |
        Where-Object { $ids.Contains([int]$_.IDProcess) })
    [pscustomobject]@{
        Sample               = $sample
        MeasuredProcesses    = $memory.Count
        PrivateWorkingSetMiB = [math]::Round(($memory | Measure-Object WorkingSetPrivate -Sum).Sum / 1MB, 1)
        PrivateCommitMiB     = [math]::Round(($memory | Measure-Object PrivateBytes -Sum).Sum / 1MB, 1)
    }
    if ($sample -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
}
