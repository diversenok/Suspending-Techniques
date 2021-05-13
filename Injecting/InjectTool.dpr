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
  Ntapi.ntpsapi,
  NtUtils,
  NtUtils.SysUtils,
  NtUtils.Processes,
  NtUtils.Processes.Snapshots,
  NtUtils.Processes.Query,
  NtUiLib.Errors,
  InjectTool.ThreadPool in 'InjectTool.ThreadPool.pas',
  InjectTool.Direct in 'InjectTool.Direct.pas';

type
  TInjectionAction = (
    iaInjectThread,
    iaInjectStealty,
    iaTriggerThreadPool
  );

function Main: TNtxStatus;
var
  hxProcess: IHandle;
  ProcessName: String;
  PID: Cardinal;
  Action: TInjectionAction;
  AccessMask: TProcessAccessMask;
begin
  writeln('This is a program for testing thread creation.');
  writeln;
  writeln('Available options:');
  writeln('[', Integer(iaInjectThread) ,'] Create a thread');
  writeln('[', Integer(iaInjectStealty) ,'] Create a thread (hide from DLLs & debuggers)');
  writeln('[', Integer(iaTriggerThreadPool) ,'] Trigger thread pool''s thread creation');
  writeln;
  write('Your choice: ');
  readln(Cardinal(Action));
  writeln;

  case Action of
    iaInjectThread, iaInjectStealty:
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
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask,
      [pnAllowShortNames]);

  if not Result.IsSuccess then
    Exit;

  case Action of
    iaInjectThread, iaInjectStealty:
      Result := InjectDummyThread(hxProcess.Handle, Action = iaInjectStealty);

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
