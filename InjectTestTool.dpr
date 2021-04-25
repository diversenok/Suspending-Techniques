program InjectTestTool;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, NtUtils,
  NtUtils.SysUtils, NtUtils.Processes, NtUtils.Processes.Snapshots,
  NtUtils.Processes.Query, NtUtils.Shellcode, NtUtils.Threads,
  NtUtils.Synchronization, NtUiLib.Errors;

function Main: TNtxStatus;
const
  PROCESS_INJECT_THREAD = PROCESS_QUERY_LIMITED_INFORMATION or
    PROCESS_CREATE_THREAD;
var
  hxProcess, hxThread: IHandle;
  ActionStr, ProcessName: String;
  Action, PID, Checkpoint: Cardinal;
  ThreadFlags: TThreadCreateFlags;
  ThreadMain: Pointer;
  ThreadParam: NativeUInt;
  IsWoW64: Boolean;
begin
  writeln('This is a program for testing thread creation. Available options:');
  writeln('[0] Create a thread');
  writeln('[1] Create a thread without attaching to DLLs');
  writeln;
  write('Your choice: ');
  readln(ActionStr);
  writeln;

  if not RtlxStrToInt(ActionStr, Action) then
    Integer(Action) := -1;

  case Action of
    0: ThreadFlags := 0;
    1: ThreadFlags := THREAD_CREATE_FLAGS_SKIP_THREAD_ATTACH;
  else
    Result.Location := 'Main';
    Result.Status := STATUS_INVALID_PARAMETER;
    Exit;
  end;

  write('PID or a unique image name: ');
  readln(ProcessName);
  writeln;

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, PROCESS_INJECT_THREAD)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, PROCESS_INJECT_THREAD);

  if not Result.IsSuccess then
    Exit;

  // Prevent WoW64 -> Native injection
  Result := RtlxAssertWoW64Compatible(hxProcess.Handle, IsWoW64);

  if not Result.IsSuccess then
    Exit;

  // Use some simple function with a single NativeUInt parameter as the payload
  Result := RtlxFindKnownDllExport(ntdll, IsWoW64, 'NtAlertThread', ThreadMain);

  if not Result.IsSuccess then
    Exit;

  ThreadParam := NtCurrentThread;

{$IFDEF Win64}
  if IsWoW64 then
    ThreadParam := Cardinal(ThreadParam);
{$ENDIF}

  Result := NtxCreateThread(hxThread, hxProcess.Handle, ThreadMain,
    Pointer(ThreadParam), ThreadFlags);

  if not Result.IsSuccess then
    Exit;

  writeln('Successfully created a thread.');
  Checkpoint := 0;

  repeat
    writeln('[', Checkpoint, '] Waiting for it...');
    Inc(Checkpoint);

    Result := NtxWaitForSingleObject(hxThread.Handle, 2000 * MILLISEC);
  until Result.Status <> STATUS_TIMEOUT;

  if Result.Status = STATUS_WAIT_0 then
    writeln('Wait completed, thread executed.');
end;

procedure ReportFailures(const xStatus: TNtxStatus);
begin
  if not xStatus.IsSuccess then
    writeln(xStatus.Location, ': ', RtlxNtStatusName(xStatus.Status))
  else
    writeln('Success.');
end;

begin
  ReportFailures(Main);
  {$IFDEF Debug}readln;{$ENDIF}
end.
