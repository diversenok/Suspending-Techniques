program InjectTool;

{
  This is a tool for testing thread creation in other processes. It can inject
  threads directy or trigger it via an existing thread pool.
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Ntapi.ntstatus,
  Ntapi.ntseapi,
  Ntapi.ntpsapi,
  NtUtils,
  NtUtils.SysUtils,
  NtUtils.Processes,
  NtUtils.Processes.Snapshots,
  NtUtils.Tokens,
  NtUtils.Console,
  NtUiLib.Errors,
  InjectTool.ThreadPool in 'InjectTool.ThreadPool.pas',
  InjectTool.Direct in 'InjectTool.Direct.pas';

type
  TInjectionAction = (
    iaInjectThread,
    iaTriggerThreadPool
  );

function Main: TNtxStatus;
var
  hxProcess: IHandle;
  ProcessName: String;
  PID: Cardinal;
  Action: TInjectionAction;
  AccessMask: TProcessAccessMask;
  ThreadFlags: TThreadCreateFlags;
begin
  writeln('This is a program for testing thread creation.');
  writeln;
  writeln('Available options:');
  writeln;
  writeln('[', Integer(iaInjectThread) ,'] Create a thread');
  writeln('[', Integer(iaTriggerThreadPool) ,'] Trigger thread pool''s thread creation');
  writeln;
  write('Your choice: ');
  Cardinal(Action) := ReadCardinal(0, Cardinal(High(TInjectionAction)));
  ThreadFlags := 0;
  writeln;

  case Action of
    iaInjectThread:
    begin
      AccessMask := PROCESS_CREATE_THREAD or PROCESS_QUERY_LIMITED_INFORMATION;

      write('Do you want to hide it from DLLs? [y/n]: ');

      if ReadBoolean then
        ThreadFlags := ThreadFlags or THREAD_CREATE_FLAGS_SKIP_THREAD_ATTACH;

      write('Do you want to hide it from debuggers? [y/n]: ');

      if ReadBoolean then
        ThreadFlags := ThreadFlags or THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER;

      write('Do you want it to bypass process freezing? [y/n]: ');

      if ReadBoolean then
        ThreadFlags := ThreadFlags or THREAD_CREATE_FLAGS_BYPASS_PROCESS_FREEZE;

      writeln;
    end;

    iaTriggerThreadPool:
      AccessMask := PROCESS_DUP_HANDLE or PROCESS_QUERY_INFORMATION;
  else
    Result.Location := 'Main';
    Result.Status := STATUS_INVALID_PARAMETER;
    Exit;
  end;

  write('PID or a unique image name: ');
  ProcessName := ReadString(False);
  writeln;

  NtxAdjustPrivilege(NtxCurrentEffectiveToken, SE_DEBUG_PRIVILEGE,
    SE_PRIVILEGE_ENABLED, True);

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask,
      [pnAllowShortNames]);

  if not Result.IsSuccess then
    Exit;

  case Action of
    iaInjectThread:
      Result := InjectDummyThread(hxProcess.Handle, ThreadFlags);

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
