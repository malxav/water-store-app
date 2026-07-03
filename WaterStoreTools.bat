@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist ".env" (
    echo.
    echo  ERROR: No .env file found in this folder.
    echo  Follow the setup steps in README.md first, then try again.
    echo.
    pause
    exit /b
)

:MENU
cls
echo ================================================
echo           WATER STORE REGISTER - TOOLS
echo ================================================
echo.
echo   1. Run the app
echo   2. Export database tables to CSV (for Excel)
echo   3. Exit
echo.
set /p CHOICE="Choose an option (1-3): "

if "%CHOICE%"=="1" goto RUN_APP
if "%CHOICE%"=="2" goto EXPORT_TABLES
if "%CHOICE%"=="3" exit /b
goto MENU


:RUN_APP
cls
if not exist "node_modules" (
    echo Setting up the app for the first time — this only happens once.
    echo Please wait, this can take a minute...
    call npm install
)
echo.
echo Starting the water store app...
start "Water Store Server - DO NOT CLOSE while using the app" cmd /k "npm start"
timeout /t 3 /nobreak >nul
start "" http://localhost:3000
echo.
echo The app should now be open in your browser.
echo A second window titled "Water Store Server" is also open — that is the
echo app running. Leave it open while you use the register. Closing that
echo window will stop the app.
echo.
pause
goto MENU


:EXPORT_TABLES
cls
call :LOAD_ENV

if "%DB_SERVER%"=="" (
    echo Could not read database settings from .env — check that file and try again.
    pause
    goto MENU
)

where bcp >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: The "bcp" export tool was not found on this computer.
    echo  It normally comes installed together with SQL Server.
    echo  Ask whoever set up the database to install the SQL Server
    echo  command-line tools, then try this option again.
    echo.
    pause
    goto MENU
)

for /f "tokens=2 delims==" %%D in ('wmic os get localdatetime /value ^| find "="') do set DT=%%D
set EXPORT_DIR=exports\%DT:~0,8%_%DT:~8,6%
mkdir "%EXPORT_DIR%" 2>nul

echo.
echo Exporting tables to %EXPORT_DIR% ...
echo.

call :EXPORT_ONE Customer "CustomerID,CustomerName,AccountType,CustomerSegment,DateJoined"
call :EXPORT_ONE Item "ItemID,ItemName,IsFreeVariant,LinkedItemID"
call :EXPORT_ONE PriceList "PriceID,ItemID,CustomerSegment,UnitPrice,EffectiveDate"
call :EXPORT_ONE SalesTransaction "TransactionID,CustomerID,NameOnRecord,TransactionDate,FundingType,ShippingFlag,ShippingFee,TotalAmount"
call :EXPORT_ONE TransactionDetail "DetailID,TransactionID,ItemID,Quantity,UnitPriceSnapshot,LineTotal"
call :EXPORT_ONE Debt "DebtID,TransactionID,AmountDue,Status,DateIncurred,DateSettled,SettledChannel"
call :EXPORT_ONE AdvancePaymentDeposit "DepositID,CustomerID,DepositDate,Amount,Channel,ExpiryDate"
call :EXPORT_ONE AppConfig "ConfigKey,ConfigValue,Description"

echo.
echo Also exporting the summary reports (balances, open debts, points)...
call :EXPORT_VIEW vw_CustomerBalance "CustomerID,CustomerName,CurrentBalance"
call :EXPORT_VIEW vw_OpenDebts "DebtID,TransactionID,CustomerName,AmountDue,DateIncurred,DaysOutstanding"
call :EXPORT_VIEW vw_CustomerPoints "CustomerID,FiscalYear,SlimRoundQtyPurchased,PointsFromSlimRound,AmountDeposited,PointsFromAdvancePayment,TotalPoints"

echo.
echo Done. Files are in: %CD%\%EXPORT_DIR%
echo You can open any of these .csv files directly in Excel.
echo.
pause
goto MENU


:LOAD_ENV
for /f "usebackq tokens=1,2 delims==" %%A in (".env") do (
    if "%%A"=="DB_SERVER" set DB_SERVER=%%B
    if "%%A"=="DB_DATABASE" set DB_DATABASE=%%B
    if "%%A"=="DB_USER" set DB_USER=%%B
    if "%%A"=="DB_PASSWORD" set DB_PASSWORD=%%B
)
exit /b


:EXPORT_ONE
set TABLE=%~1
set HEADER=%~2
echo   - %TABLE%
echo %HEADER%> "%EXPORT_DIR%\%TABLE%.csv"
bcp "SELECT * FROM %DB_DATABASE%.dbo.%TABLE%" queryout "%EXPORT_DIR%\%TABLE%_data.tmp" -c -t"," -S %DB_SERVER% -U %DB_USER% -P %DB_PASSWORD% -d %DB_DATABASE% >nul
type "%EXPORT_DIR%\%TABLE%_data.tmp" >> "%EXPORT_DIR%\%TABLE%.csv" 2>nul
del "%EXPORT_DIR%\%TABLE%_data.tmp" 2>nul
exit /b


:EXPORT_VIEW
set VIEWNAME=%~1
set HEADER=%~2
echo   - %VIEWNAME% (report)
echo %HEADER%> "%EXPORT_DIR%\%VIEWNAME%.csv"
bcp "SELECT * FROM %DB_DATABASE%.dbo.%VIEWNAME%" queryout "%EXPORT_DIR%\%VIEWNAME%_data.tmp" -c -t"," -S %DB_SERVER% -U %DB_USER% -P %DB_PASSWORD% -d %DB_DATABASE% >nul
type "%EXPORT_DIR%\%VIEWNAME%_data.tmp" >> "%EXPORT_DIR%\%VIEWNAME%.csv" 2>nul
del "%EXPORT_DIR%\%VIEWNAME%_data.tmp" 2>nul
exit /b
