program ModeTransitionMonitor;

{
  This is a sample application that counts program's transitions from kernel
  to user mode via an instrumentation callback.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Ntapi.WinNt,
  Ntapi.ntstatus,
  Ntapi.ntpsapi,
  Ntapi.ntseapi,
  Ntapi.Versions,
  DelphiUtils.AutoObjects,
  NtUtils,
  NtUtils.SysUtils,
  NtUtils.Processes,
  NtUtils.Processes.Snapshots,
  NtUtils.Processes.Info,
  NtUtils.Processes.Info.Remote,
  NtUtils.Synchronization,
  NtUtils.Tokens,
  NtUtils.Console,
  NtUiLib.Errors,
  Instrumentation.Monitor in 'Instrumentation.Monitor.pas',
  ModeTransitionMonitor.Trace in 'ModeTransitionMonitor.Trace.pas';

{
  The idea is the following:

  1. Map a shared memory region with the target
  2. Write a small shellcode to it that counts the number of its invocations
     and records returns addresses into a circular buffer.
  3. Install it as the instrumentation callback (either by setting it
     directly using the Debug privilege, or via injecting a thread that does
     that on the target's behalf). The system invokes the callback every time
     a thread within the process transitions to user-mode.
  4. Pull the counter and return addresses via a local memory mapping.
}

function Main: TNtxStatus;
const
  AccessMask = PROCESS_SET_INSTRUMENTATION or SYNCHRONIZE;
  TraceMagnitude: array [Boolean] of TTraceMagnitude = (TRACE_MAGNITUDE_LOW,
    TRACE_MAGNITUDE_MEDIUM);
var
  ProcessName: String;
  PID: Cardinal;
  hxProcess: IHandle;
  CaptureTraces, TargetIsWoW64, IsIdle: Boolean;
  CurrentCount, PreviousCount: UInt64;
  LocalMapping: IMemory<PSyscallMonitor>;
begin
  writeln('This program allows monitoring kernel-to-user mode transitions in a '
    + 'context of a specific process via the instrumentation callback.');
  writeln;

  // Try enabling the debug privilege. Note that it is not strictly necessary
  // starting from Windows 8.1 since we can set the instrumentation callback
  // on the target's behalf by injecting a thread.
  Result := NtxAdjustPrivilege(NtxCurrentEffectiveToken, SE_DEBUG_PRIVILEGE,
    SE_PRIVILEGE_ENABLED, RtlOsVersion >= OsWin81);

  if not Result.IsSuccess then
    Exit;

  if Result.Status = STATUS_NOT_ALL_ASSIGNED then
    writeln('WARNING: Debug Privilege is not available; will use thread ' +
      'injection instead.' + #$D#$A);

  write('Do you want to capture return addresses? [y/n]: ');
  CaptureTraces := ReadBoolean;

  if CaptureTraces then
  begin
    writeln('Loading symbols...');
    InitializeSymbols;
  end;

  writeln;
  write('Target''s PID or a unique image name: ');
  ProcessName := ReadString(False);

  // Open the target
  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask,
      [pnAllowShortNames]);

  if not Result.IsSuccess then
    Exit;

  // Instrumentation callbacks do not seem to work under WoW64
  Result := NtxQueryIsWoW64Process(hxProcess.Handle, TargetIsWoW64);

  if not Result.IsSuccess then
    Exit;

  if TargetIsWoW64 then
  begin
    Result.Location := 'Target runs under WoW64';
    Result.Status := STATUS_NOT_SUPPORTED;
    Exit;
  end;

  writeln('Setting up monitoring...');
  Result := StartMonitoring(hxProcess, TraceMagnitude[CaptureTraces],
    LocalMapping);

  if not Result.IsSuccess then
    Exit;

  writeln;
  IsIdle := False;
  PreviousCount := 0;
  Result.Status := STATUS_TIMEOUT;

  repeat
    CurrentCount := LocalMapping.Data.SyscallCount;

    if (CurrentCount <> PreviousCount) or not IsIdle then
    begin
      writeln('Transitions / second: ', CurrentCount - PreviousCount);

      if CaptureTraces then
      begin
        if CurrentCount <> PreviousCount then
          PrintFreshTraces(LocalMapping.Data, PreviousCount);

        writeln;
      end;
    end;

    IsIdle := (CurrentCount = PreviousCount);
    PreviousCount := CurrentCount;

    if Result.Status <> STATUS_TIMEOUT then
      Break;

    Result := NtxWaitForSingleObject(hxProcess.Handle, 1000 * MILLISEC);
  until False;

  if Result.Status <> STATUS_WAIT_0 then
    Exit;

  writeln('Target process exited. Transitions detected: ', PreviousCount);
end;

procedure ReportFailures(const xStatus: TNtxStatus);
begin
  if not xStatus.IsSuccess then
    writeln(xStatus.Location, ': ', RtlxNtStatusName(xStatus.Status))
end;

begin
  ReportFailures(Main);

  if RtlxConsoleHostState <> chInterited then
    readln;
end.

