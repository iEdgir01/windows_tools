# Simple test script to debug the username issue
param()

Write-Host "=== SIMPLE USERNAME TEST ===" -ForegroundColor Green
Write-Host ""

# Test 1: Simple string handling
$testString = "INNERCITY"
Write-Host "Test 1 - Direct string: '$testString'" -ForegroundColor Yellow
Write-Host "Length: $($testString.Length)" -ForegroundColor Yellow

# Test 2: Get user folders - basic approach
Write-Host "`nTest 2 - Basic folder listing:" -ForegroundColor Yellow
try {
    $folders = Get-ChildItem "C:\Users" -Directory
    foreach ($folder in $folders) {
        $name = $folder.Name
        Write-Host "  Folder: '$name' (Length: $($name.Length))" -ForegroundColor White
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 3: Direct directory access
Write-Host "`nTest 3 - .NET Directory listing:" -ForegroundColor Yellow
try {
    $dirs = [System.IO.Directory]::GetDirectories("C:\Users")
    foreach ($dir in $dirs) {
        $name = [System.IO.Path]::GetFileName($dir)
        Write-Host "  Directory: '$name' (Length: $($name.Length))" -ForegroundColor White
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Test 4: Array handling
Write-Host "`nTest 4 - Array processing:" -ForegroundColor Yellow
$testArray = @("INNERCITY", "TestUser", "Administrator")
for ($i = 0; $i -lt $testArray.Count; $i++) {
    $user = $testArray[$i]
    Write-Host "  Array[$i]: '$user' (Length: $($user.Length))" -ForegroundColor White
}

Write-Host "`n=== TEST COMPLETE ===" -ForegroundColor Green
Write-Host "Press Enter to exit..."
Read-Host