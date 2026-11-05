@echo off
rem Builds "Audio Scratchpad.exe" with the compiler and libraries that ship with Windows, so nothing needs installing.
setlocal
cd /d "%~dp0"
set "fw=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
set "wpf=%fw%\WPF"
if not exist ..\build mkdir ..\build

rem An optional version such as v1.2.0, stored in the exe along with its product name.
set "version=%~1"
if not defined version set "version=0.0.0"
if "%version:~0,1%"=="v" set "version=%version:~1%"
> ..\build\AssemblyInfo.cs echo using System.Reflection;
>> ..\build\AssemblyInfo.cs echo [assembly: AssemblyTitle("Audio Scratchpad")]
>> ..\build\AssemblyInfo.cs echo [assembly: AssemblyProduct("Audio Scratchpad")]
>> ..\build\AssemblyInfo.cs echo [assembly: AssemblyCopyright("Copyright (c) 2026 Felix Wu")]
>> ..\build\AssemblyInfo.cs echo [assembly: AssemblyVersion("%version%")]
>> ..\build\AssemblyInfo.cs echo [assembly: AssemblyFileVersion("%version%")]

"%fw%\csc.exe" /nologo /optimize /out:..\build\self-check.exe SelfCheck.cs RecordingFile.cs Waveform.cs || exit /b 1
..\build\self-check.exe || exit /b 1

"%fw%\csc.exe" /nologo /optimize /target:winexe "/out:..\build\Audio Scratchpad.exe" ^
  "/r:%wpf%\PresentationCore.dll" "/r:%wpf%\PresentationFramework.dll" "/r:%wpf%\WindowsBase.dll" ^
  "/r:%fw%\System.Xaml.dll" /r:System.Drawing.dll /r:Microsoft.VisualBasic.dll ^
  ..\build\AssemblyInfo.cs AudioScratchpad.cs TitleBar.cs Theme.cs Recorder.cs RecordingFile.cs Waveform.cs || exit /b 1
echo Built build\Audio Scratchpad.exe
