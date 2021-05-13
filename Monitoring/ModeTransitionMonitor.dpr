program ModeTransitionMonitor;

{
  This is a sample application that counts program's transitions from kernel
  to user mode via an instrumentation callback.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntstatus, Ntapi.ntpsapi, Ntapi.ntseapi, NtUtils,
  DelphiUtils.AutoObject, NtUtils.SysUtils, NtUtils.Processes,
  NtUtils.Processes.Snapshots, NtUtils.Processes.Query,
  NtUtils.Processes.Query.Remote, NtUtils.Tokens, NtUtils.Shellcode,
  NtUtils.Synchronization, NtUtils.Version, NtUiLib.Errors;

{
  The idea is the following:

  1. Map a shared memory region with the target
  2. Write a small shellcode to it that counts the number of times it is called
     into a variable within the same memory region
  3. Install it as the instrumentation callback (by either setting it
     directly if we have the Debug privilege, or injecting yet another piece of
     code to do it on the target's behalf). This will make sure every time
     Windows returns from a system call, it will invoke our callback.
  4. Pull the counter via a local memory mapping.
}

type
  TSyscallCountMonitor = record
    // 90                   nop { in case someone whats to set a breakpoint }
    // FF 05 09 00 00 00    inc dword [rel $0000000F]
    // 41 FF E2             jmp r10
    // CC CC CC CC CC CC    int 3 (x6)
    Code: array [0..1] of UInt64;
    SyscallCount: UInt64;
  end;
  PSyscallCountMonitor = ^TSyscallCountMonitor;

function Main: TNtxStatus;
const
  AccessMask = PROCESS_VM_OPERATION or PROCESS_SET_INFORMATION or
    PROCESS_SET_INSTRUMENTATION or SYNCHRONIZE;
var
  ProcessName: String;
  PID: Cardinal;
  hxProcess: IHandle;
  LocalMapping: IMemory<PSyscallCountMonitor>;
  RemoteMapping: IMemory;
  HasDebugPrivilege, TargetIsWoW64, IsIdle: Boolean;
  SyscallCount: UInt64;
begin
  writeln('This is a program for monitoring transitions from kernel mode to '
    + 'user mode that happen in a context of a specific process.');
  writeln;

  // Try enabling the debug privilege since we can set the instrumentation
  // callback directly in this case.
  Result := NtxAdjustPrivilege(NtCurrentEffectiveToken, SE_DEBUG_PRIVILEGE,
    SE_PRIVILEGE_ENABLED, True);

  if not Result.IsSuccess then
    Exit;

  HasDebugPrivilege := Result.Status <> STATUS_NOT_ALL_ASSIGNED;

  write('Target''s PID or a unique image name: ');
  readln(ProcessName);
  writeln;

  // Open the target
  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask,
      [pnAllowShortNames]);

  if not Result.IsSuccess then
    Exit;

  // Instrumentation callbacks do not work under WoW64
  Result := NtxQueryIsWoW64Process(hxProcess.Handle, TargetIsWoW64);

  if not Result.IsSuccess then
    Exit;

  if TargetIsWoW64 then
  begin
    Result.Location := 'Target runs under WoW64';
    Result.Status := STATUS_NOT_SUPPORTED;
    Exit;
  end;

  // Map a shared memory region for the shellcode and the syscall counter
  Result := RtlxMapSharedMemory(hxProcess, SizeOf(TSyscallCountMonitor),
    IMemory(LocalMapping), RemoteMapping, [mmAllowWrite, mmAllowExecute]);

  if not Result.IsSuccess then
    Exit;

  // Fill in the shellcode (see explanations in type definition)
  LocalMapping.Data.Code[0] := $410000000905FF90;
  LocalMapping.Data.Code[1] := $CCCCCCCCCCCCE2FF;

  writeln('Enabling instrumentation callback...');

  if HasDebugPrivilege or (RtlOsVersion < OsWin81) then
    // Either set it directly
    Result := NtxProcess.Set(hxProcess.Handle, ProcessInstrumentationCallback,
      RemoteMapping.Data)
  else
    // Or inject the code that does it on the target's behalf (if it helps
    // avoiding the debug privilege)
    Result := NtxSetInstrumentationProcess(hxProcess, RemoteMapping.Data,
      NT_INFINITE);

  if not Result.IsSuccess then
    Exit;

  // Make sure we don't unmap the callback when we exit
  RemoteMapping.AutoRelease := False;

  writeln('Staring monitoring...');
  writeln;
  IsIdle := False;

  repeat
    SyscallCount := AtomicExchange(LocalMapping.Data.SyscallCount, 0);

    if (SyscallCount > 0) or not IsIdle then
      writeln('Transitions / second: ', SyscallCount);

    IsIdle := (SyscallCount = 0);

    Result := NtxWaitForSingleObject(hxProcess.Handle, 1000 * MILLISEC);
  until Result.Status <> STATUS_TIMEOUT;

  if Result.Status = STATUS_WAIT_0 then
    writeln('Target process exited.');
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

