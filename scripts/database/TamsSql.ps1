<# Shared helpers (dot-source): .  "$PSScriptRoot\TamsSql.ps1" #>

function New-TamsConnection {
    param([string]$Server = 'localhost', [string]$Database = 'master', [int]$Timeout = 30)
    $c = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=$Timeout"
    $c.Open(); return $c
}

# Runs a query and returns a DataTable. Parameters: @{ name = value } (referenced as @name).
function Invoke-TamsQuery {
    param($Conn, [string]$Sql, [hashtable]$Params = @{}, [int]$Timeout = 300)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $Params[$k]) }
    $dt = New-Object System.Data.DataTable
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($dt)
    return , $dt
}

function Invoke-TamsNonQuery {
    param($Conn, [string]$Sql, [hashtable]$Params = @{}, [int]$Timeout = 600)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    foreach ($k in $Params.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $Params[$k]) }
    [void]$cmd.ExecuteNonQuery()
}

function Get-TamsScalar {
    param($Conn, [string]$Sql, [hashtable]$Params = @{})
    $dt = Invoke-TamsQuery -Conn $Conn -Sql $Sql -Params $Params
    if ($dt.Rows.Count -eq 0) { return $null }
    $v = $dt.Rows[0][0]; if ($v -is [System.DBNull]) { return $null } else { return $v }
}

# Starts a command without waiting. Returns @{ Task; Cmd }.
function Start-TamsAsync {
    param($Conn, [string]$Sql, [int]$Timeout = 60)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    return @{ Task = $cmd.ExecuteNonQueryAsync(); Cmd = $cmd }
}

# Waits for an async command. Returns @{ Done; Ok; Number; Message } (Number = SQL error number when it failed).
function Wait-TamsAsync {
    param($Handle, [int]$Milliseconds = 30000)
    $t = $Handle.Task
    try { $done = $t.Wait($Milliseconds) } catch { $done = $true }
    if (-not $done) { return @{ Done = $false; Ok = $false; Number = 0; Message = 'still running' } }
    if ($t.IsFaulted) {
        $ex = $t.Exception
        while ($ex -and $ex -isnot [System.Data.SqlClient.SqlException] -and $ex.InnerException) { $ex = $ex.InnerException }
        $num = 0; if ($ex -is [System.Data.SqlClient.SqlException]) { $num = $ex.Number }
        return @{ Done = $true; Ok = $false; Number = $num; Message = $ex.Message }
    }
    return @{ Done = $true; Ok = $true; Number = 0; Message = '' }
}

# Synchronous exec that captures a SQL error instead of throwing. Returns @{ Ok; Number; Message }.
function Try-TamsNonQuery {
    param($Conn, [string]$Sql, [int]$Timeout = 120)
    try { Invoke-TamsNonQuery -Conn $Conn -Sql $Sql -Timeout $Timeout; return @{ Ok = $true; Number = 0; Message = '' } }
    catch {
        $ex = $_.Exception; while ($ex -and $ex -isnot [System.Data.SqlClient.SqlException] -and $ex.InnerException) { $ex = $ex.InnerException }
        $num = 0; if ($ex -is [System.Data.SqlClient.SqlException]) { $num = $ex.Number }
        return @{ Ok = $false; Number = $num; Message = $ex.Message }
    }
}
