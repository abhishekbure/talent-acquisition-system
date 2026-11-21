<#
.SYNOPSIS
  Runs the backend API integration tests against a DISPOSABLE copy of TalentAcquisitionDB.
  1. backs up TalentAcquisitionDB and restores it as TalentAcquisitionDB_ApiTest (Copy-Database.ps1; the source is only read)
  2. runs `dotnet test` on tests\backend\TalentAcquisition.Tests (the real API is hosted in-process on localhost:5055)
  3. drops the disposable copy (use -KeepDatabase to inspect it afterwards)
  Test passwords are applied ONLY inside the copy. Results (.trx) go to tests\backend\TestResults.
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$TestDatabase = 'TalentAcquisitionDB_ApiTest',
    [string]$Filter,
    [switch]$KeepDatabase
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if ($TestDatabase -eq 'TalentAcquisitionDB') { throw 'The live database is never used for tests.' }
. (Join-Path $root 'scripts\database\TamsSql.ps1')

Write-Host "== Creating disposable copy $TestDatabase"
& (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $TestDatabase -Force

$project = Join-Path $root 'tests\backend\TalentAcquisition.Tests\TalentAcquisition.Tests.csproj'
$results = Join-Path $root 'tests\backend\TestResults'
$env:TAMS_TEST_DB = $TestDatabase
$exit = 1
try {
    Write-Host '== Running API integration tests'
    $args2 = @('test', $project, '--logger', 'trx;LogFileName=api-tests.trx', '--logger', 'console;verbosity=normal', '--results-directory', $results)
    if ($Filter) { $args2 += @('--filter', $Filter) }
    & dotnet @args2
    $exit = $LASTEXITCODE
}
finally {
    Remove-Item Env:\TAMS_TEST_DB -ErrorAction SilentlyContinue
    if (-not $KeepDatabase) {
        $c = New-TamsConnection -Server $Server
        try {
            Invoke-TamsNonQuery $c "IF DB_ID(N'$TestDatabase') IS NOT NULL BEGIN ALTER DATABASE [$TestDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$TestDatabase]; END"
            Write-Host "== Dropped disposable copy $TestDatabase"
        } finally { $c.Close() }
    }
}
Write-Host ("== dotnet test exit code: {0}" -f $exit)
exit $exit
