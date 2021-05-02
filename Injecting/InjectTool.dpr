program InjectTool;

{
  This is a tool for testing thread creation in other processes. It can inject
  threads directy (methods #0 and #1) or trigger it via an existing thread pool
  (method #2, see InjectViaThreadPool.pas).
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, NtUtils,
  NtUtils.SysUtils, NtUtils.Processes, NtUtils.Processes.Snapshots,
  NtUtils.Processes.Query, NtUtils.Shellcode, NtUtils.Threads,
  NtUtils.Synchronization, NtUiLib.Errors,
  InjectViaThreadPool in 'InjectViaThreadPool.pas';

type
  TInjectionAction = (
    iaInjectThread,
    iaInjectStealtyThread,
    iaTriggerThreadPool
  );

// Methods #0 and #1
function InjectThread(hProcess: THandle; Action: TInjectionAction): TNtxStatus;
var
  ThreadFlags: TThreadCreateFlags;
  ThreadMain: Pointer;
  ThreadParam: NativeUInt;
  IsWoW64: Boolean;
  hxThread: IHandle;
  Checkpoint: Cardinal;
begin
  // Prevent WoW64 -> Native injection
  Result := RtlxAssertWoW64Compatible(hProcess, IsWoW64);

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

  if Action = iaInjectStealtyThread then
    ThreadFlags := THREAD_CREATE_FLAGS_SKIP_THREAD_ATTACH or
      THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER
  else
    ThreadFlags := 0;

  Result := NtxCreateThread(hxThread, hProcess, ThreadMain,
    Pointer(ThreadParam), ThreadFlags);

  if not Result.IsSuccess then
    Exit;

  NtxSetNameThread(hxThread.Handle, 'Thread injection test');
  writeln('Successfully created a thread.');
  Checkpoint := 0;

  repeat
    writeln('[', Checkpoint, '] Waiting for it...');
    Inc(Checkpoint);

    Result := NtxWaitForSingleObject(hxThread.Handle, 2000 * MILLISEC);
  until Result.Status <> STATUS_TIMEOUT;

  writeln;

  if Result.Status = STATUS_WAIT_0 then
    writeln('Wait completed, thread exited.');
end;

function Main: TNtxStatus;
var
  hxProcess: IHandle;
  ProcessName: String;
  PID: Cardinal;
  Action: TInjectionAction;
  AccessMask: TProcessAccessMask;
begin
  writeln('This is a program for testing thread creation. Available options:');
  writeln('[', Integer(iaInjectThread) ,'] Create a thread');
  writeln('[', Integer(iaInjectStealtyThread) ,'] Create a thread (no attaching to DLLs & notifiying debuggers)');
  writeln('[', Integer(iaTriggerThreadPool) ,'] Trigger thread pool''s thread creation');
  writeln;
  write('Your choice: ');
  readln(Cardinal(Action));
  writeln;

  case Action of
    iaInjectThread, iaInjectStealtyThread:
      AccessMask := PROCESS_CREATE_THREAD or PROCESS_QUERY_LIMITED_INFORMATION;

    iaTriggerThreadPool:
      AccessMask := PROCESS_DUP_HANDLE or PROCESS_QUERY_INFORMATION;
  else
    Result.Location := 'Main';
    Result.Status := STATUS_INVALID_PARAMETER;
    Exit;
  end;

  write('PID or a unique image name: ');
  readln(ProcessName);
  writeln;

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask);

  if not Result.IsSuccess then
    Exit;

  case Action of
    iaInjectThread, iaInjectStealtyThread:
      Result := InjectThread(hxProcess.Handle, Action);

    iaTriggerThreadPool:
      Result := TriggerThreadPool(hxProcess.Handle);
  end;
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

  if RtlxConsoleHostState <> chInterited then
    readln;
end.
