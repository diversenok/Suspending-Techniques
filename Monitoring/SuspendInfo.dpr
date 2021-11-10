program SuspendInfo;

{
  This program determines suspension and freezing of processes and threads.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Ntapi.WinNt,
  Ntapi.ntstatus,
  Ntapi.ntseapi,
  Ntapi.ntpsapi,
  Ntapi.ntexapi,
  Ntapi.Versions,
  DelphiUtils.Arrays,
  NtUtils,
  NtUtils.Processes,
  NtUtils.Processes.Info,
  NtUtils.Processes.Snapshots,
  NtUtils.Threads,
  NtUtils.Tokens,
  NtUtils.SysUtils,
  NtUtils.Console,
  NtUiLib.Errors;

function ChooseProcess(
  out Process: TProcessEntry
): TNtxStatus;
var
  Processes: TArray<TProcessEntry>;
  ProcessName: String;
  PID: Cardinal;
begin
  write('Target''s PID or a unique image name: ');
  ProcessName := ReadString(False);
  writeln;

  Result := NtxEnumerateProcesses(Processes);

  if not Result.IsSuccess then
    Exit;

  if RtlxStrToInt(ProcessName, PID) then
    TArray.FilterInline<TProcessEntry>(Processes, ByPid(PID))
  else
    TArray.FilterInline<TProcessEntry>(Processes, ByImage(ProcessName,
      [pfAllowShortNames]));

  Result.Location := 'ChooseProcess';
  case Length(Processes) of
    0: Result.Status := STATUS_NOT_FOUND;
    1: Process := Processes[0];
  else
    Result.Status := STATUS_OBJECT_NAME_COLLISION;
  end;
end;

procedure PrintProcessFreeze(PID: TProcessId);
var
  hxProcess: IHandle;
  Info: TProcessBasicInformationEx;
begin
  Info := Default(TProcessBasicInformationEx);
  Info.Size := SizeOf(TProcessBasicInformationEx);

  write('Frozen: ');
  if NtxOpenProcess(hxProcess, PID, PROCESS_QUERY_LIMITED_INFORMATION).IsSuccess
    and NtxProcess.Query(hxProcess.Handle, ProcessBasicInformation, Info).IsSuccess then
    if LongBool(Info.Flags and PROCESS_BASIC_FLAG_FROZEN) then
    begin
      writeln('Yes');
      writeln('Deep-Frozen: Unknown');
    end
    else
      writeln('No')
  else
    writeln('Unknown');
end;

function QueryUnbaisedSuspendCount(
  TID: TThreadId;
  out UnbaisedSuspendCount: Cardinal
): TNtxStatus;
var
  hxThread: IHandle;
begin
  Result := NtxOpenThread(hxThread, TID, THREAD_SUSPEND_RESUME);

  if not Result.IsSuccess then
    Exit;

  // Retrieve the last suspend count via suspension
  Result := NtxSuspendThread(hxThread.Handle, @UnbaisedSuspendCount);

  if Result.IsSuccess then
    NtxResumeThread(hxThread.Handle);

  if Result.Status = STATUS_THREAD_IS_TERMINATING then
  begin
    Result.Status := STATUS_SUCCESS;
    UnbaisedSuspendCount := 0;
  end
  else if Result.Status = STATUS_SUSPEND_COUNT_EXCEEDED then
  begin
    Result.Status := STATUS_SUCCESS;
    UnbaisedSuspendCount := 127;
  end;
end;

procedure PrintThreadInfo(const Thread: TThreadEntry);
const
  // We could've use reflection instead, but there is no point of bringing it
  // for converting a single enumeration
  WaitReasonStrings: array [TWaitReason] of String = ('Executive',
    'FreePage', 'PageIn', 'PoolAllocation', 'DelayExecution', 'Suspended',
    'UserRequest', 'WrExecutive', 'WrFreePage', 'WrPageIn', 'WrPoolAllocation',
    'WrDelayExecution', 'WrSuspended', 'WrUserRequest', 'WrEventPair',
    'WrQueue', 'WrLpcReceive', 'WrLpcReply', 'WrVirtualMemory', 'WrPageOut',
    'WrRendezvous', 'WrKeyedEvent', 'WrTerminated', 'WrProcessInSwap',
    'WrCpuRateControl', 'WrCalloutStack', 'WrKernel', 'WrResource',
    'WrPushLock', 'WrMutex', 'WrQuantumEnd', 'WrDispatchInt', 'WrPreempted',
    'WrYieldExecution', 'WrFastMutex', 'WrGuardedMutex', 'WrRundown',
    'WrAlertByThreadId', 'WrDeferredPreempt');
var
  hxThread: IHandle;
  BaisedSuspendCount, UnbaisedSuspendCount: Cardinal;
  BaisedCountKnown, UnbaisedCountKnown: Boolean;
  ThreadName: String;
begin
  ThreadName := '';
  BaisedCountKnown := False;

  // Naming threads and querying suspend count directly requires Win 8.1+
  if RtlOsVersionAtLeast(OsWin81) and
    NtxOpenThread(hxThread, Thread.Basic.ClientID.UniqueThread,
      THREAD_QUERY_LIMITED_INFORMATION).IsSuccess then
  begin
    NtxQueryNameThread(hxThread.Handle, ThreadName);

    BaisedCountKnown := NtxThread.Query(hxThread.Handle, ThreadSuspendCount,
      BaisedSuspendCount).IsSuccess;
  end;

  // Another way to retrieve the count is via suspension
  UnbaisedCountKnown := QueryUnbaisedSuspendCount(
    Thread.Basic.ClientID.UniqueThread, UnbaisedSuspendCount).IsSuccess;

  if ThreadName = '' then
    ThreadName := 'Unnamed';

  writeln('Thread: ', Thread.Basic.ClientID.UniqueThread, ' [', ThreadName, ']');

  if Thread.Basic.WaitReason <= High(TWaitReason) then
    writeln('Wait Reason: ', WaitReasonStrings[Thread.Basic.WaitReason])
  else
    writeln('Wait Reason: ', Cardinal(Thread.Basic.WaitReason), ' (Unknown)');

  write('Suspend Count: ');
  if BaisedCountKnown and UnbaisedCountKnown then
    if BaisedSuspendCount = UnbaisedSuspendCount then
      writeln(UnbaisedSuspendCount)
    else
      writeln(UnbaisedSuspendCount, ' (+', BaisedSuspendCount -
        UnbaisedSuspendCount, ' from freezing)')
  else if UnbaisedCountKnown then
    writeln(UnbaisedSuspendCount, ' (not including freezing)')
  else if BaisedCountKnown then
    writeln(BaisedSuspendCount, ' (including freezing)')
  else
    writeln('Unknown');

  write('Frozen: ');
  if BaisedCountKnown and UnbaisedCountKnown then
    if BaisedSuspendCount = UnbaisedSuspendCount then
      writeln('No')
    else
      writeln('Yes')
  else
    writeln('Unknown');

  writeln;
end;

function Main: TNtxStatus;
var
  Process: TProcessEntry;
  i: Integer;
begin
  writeln('This is a program for querying process and thread suspension state.');
  writeln;

  Result := ChooseProcess(Process);

  if not Result.IsSuccess then
    Exit;

  NtxAdjustPrivilege(NtxCurrentEffectiveToken, SE_DEBUG_PRIVILEGE,
    SE_PRIVILEGE_ENABLED, True);

  writeln('-------- Process --------');
  writeln('Process: ', Process.Basic.ProcessID, ' [', Process.ImageName, ']');
  writeln('Threads: ', Length(Process.Threads));
  PrintProcessFreeze(Process.Basic.ProcessID);
  writeln;
  writeln('-------- Threads --------');

  for i := 0 to High(Process.Threads) do
    PrintThreadInfo(Process.Threads[i]);
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

