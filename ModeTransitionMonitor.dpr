program ModeTransitionMonitor;

{
  This is a sample application that counts program's transitions from kernel
  to user mode via an instrumentation callback.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntstatus, DelphiUtils.AutoObject, NtUtils,
  NtUtils.SysUtils, NtUtils.Processes, NtUtils.Processes.Snapshots,
  NtUtils.Processes.Query, NtUtils.Processes.Query.Remote,
  NtUtils.Shellcode, NtUtils.Synchronization, NtUiLib.Errors;

{
  The idea is the following:

  1. Map a shared memory region with the target
  2. Write a small shellcode to it that counts the number of times it is called
     into a variable within the same memory region
  3. Install this shellcode as the instrumentation callback (requires
     temporarily injecting another piece of code to avoid the requirement for
     the Debug Privilege). This will make sure every time Windows returns
     from a system call, it will invoke our callback.
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

// Installs an instrumentation callback in the target process that counts
// kernel-to-user mode transitions.
function InstallInstrumentation(
  const hxProcess: IHandle;
  out LocalMapping: IMemory<PSyscallCountMonitor>;
  const Timeout: Int64 = DEFAULT_REMOTE_TIMEOUT
): TNtxStatus;
var
  TargetIsWoW64: Boolean;
  RemoteMapping: IMemory;
begin
  Result := NtxQueryIsWoW64Process(hxProcess.Handle, TargetIsWoW64);

  if not Result.IsSuccess then
    Exit;

  if TargetIsWoW64 then
  begin
    Result.Location := 'Target runs under WoW64';
    Result.Status := STATUS_NOT_SUPPORTED;
    Exit;
  end;

  // Map a shares memory region for the shellcode and the syscall counter
  Result := RtlxMapSharedMemory(hxProcess, SizeOf(TSyscallCountMonitor),
    IMemory(LocalMapping), RemoteMapping, [mmAllowWrite, mmAllowExecute]);

  if not Result.IsSuccess then
    Exit;

  // Fill in the shellcode (see explanations in type definition)
  LocalMapping.Data.Code[0] := $410000000905FF90;
  LocalMapping.Data.Code[1] := $CCCCCCCCCCCCE2FF;

  // Inject yet another shellcode for setting instrumentation callback without
  // requiring the Debug Privilege
  Result := NtxSetInstrumentationProcess(hxProcess, RemoteMapping.Data,
    Timeout);

  // Make sure we don't unmap the callback from the target
  if Result.IsSuccess then
    RemoteMapping.AutoRelease := False;
end;

function Main: TNtxStatus;
const
  AccessMask = PROCESS_SET_INSTRUMENTATION or SYNCHRONIZE;
var
  ProcessName: String;
  PID: Cardinal;
  hxProcess: IHandle;
  LocalMapping: IMemory<PSyscallCountMonitor>;
  Count: UInt64;
  IsIdle: Boolean;
begin
  writeln('This is a program for monitoring transitions from kernel mode to user mode that happen in a context of a specific process.');
  writeln;
  write('Target''s PID or a unique image name: ');
  readln(ProcessName);
  writeln;

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask);

  if not Result.IsSuccess then
    Exit;

  Result := InstallInstrumentation(hxProcess, LocalMapping);

  if not Result.IsSuccess then
    Exit;

  IsIdle := False;

  repeat
    Count := AtomicExchange(LocalMapping.Data.SyscallCount, 0);

    if (Count > 0) or not IsIdle then
      writeln('Transitions / second: ', Count);

    IsIdle := (Count = 0);

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
  {$IFDEF Debug}readln;{$ENDIF}
end.

