program SuspendMe;

{
  This is a sample application that demonstrates how a process can try to
  counteract suspension.
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Winapi.WinNt,
  Ntapi.ntstatus,
  Ntapi.ntpsapi,
  NtUtils,
  NtUtils.Threads,
  NtUtils.Synchronization,
  NtUtils.Processes.Query,
  NtUiLib.Errors,
  SuspendMe.RaceCondition in 'SuspendMe.RaceCondition.pas',
  SuspendMe.ThreadPool in 'SuspendMe.ThreadPool.pas',
  SuspendMe.PatchCreation in 'SuspendMe.PatchCreation.pas',
  SuspendMe.SelfDebug in 'SuspendMe.SelfDebug.pas';

type
  TActionOptions = (
    aoRaceSuspension,
    aoRaceSuspensionStealthy,
    aoUseThreadPool,
    aoHijackThreads,
    aoHijackThreadsAndDetach,
    aoUseSelfDebug
  );

function Main: TNtxStatus;
var
  Action: TActionOptions;
  Checkpoint: Cardinal;
  hxDebugObject: IHandle;
begin
  NtxSetNameThread(NtCurrentThread, 'Main Thread');

  writeln('This is a demo application for bypassing process & thread suspension.');
  writeln;
  writeln('Available options:');
  writeln('[', Integer(aoRaceSuspension), '] Circumvent suspension using a race condition');
  writeln('[', Integer(aoRaceSuspensionStealthy), '] Circumvent suspension using a race condition (hide threads from debugger)');
  writeln('[', Integer(aoUseThreadPool), '] Create a thread pool for someone to trigger');
  writeln('[', Integer(aoHijackThreads), '] Hijack thread execution (resume on code injection)');
  writeln('[', Integer(aoHijackThreadsAndDetach), '] Hijack thread execution (detach debuggers and resume on code injection)');
  writeln('[', Integer(aoUseSelfDebug), '] Start self-debugging so nobody else can attach');

  writeln;
  write('Your choice: ');
  readln(Cardinal(Action));
  writeln;

  case Action of
    aoRaceSuspension, aoRaceSuspensionStealthy:
      Result := RaceSuspension(Action = aoRaceSuspensionStealthy);

    aoUseThreadPool:
      Result := UseThreadPool;

    aoHijackThreads, aoHijackThreadsAndDetach:
      Result := HijackNewThreads(Action = aoHijackThreadsAndDetach);

    aoUseSelfDebug:
      Result := StartSelfDebugging(hxDebugObject);
  else
    Result.Status := STATUS_INVALID_PARAMETER;
    Result.Location := 'Main';
    Exit;
  end;

  if not Result.IsSuccess then
    Exit;

  Checkpoint := 0;
  writeln;

  repeat
    writeln('[#', Checkpoint, '] The main thread is active!');
    Inc(Checkpoint);
  until not NtxDelayExecution(2000 * MILLISEC).IsSuccess;
end;

procedure ReportFailures(const xStatus: TNtxStatus);
begin
  if not xStatus.IsSuccess then
    writeln(xStatus.Location, ': ', RtlxNtStatusName(xStatus.Status));
end;

begin
  ReportFailures(Main);

  if RtlxConsoleHostState <> chInterited then
    readln;
end.

