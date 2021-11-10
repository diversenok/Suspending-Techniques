program SuspendMe;

{
  This is a sample application that demonstrates how a process can try to
  counteract suspension.
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Ntapi.WinNt,
  Ntapi.ntstatus,
  Ntapi.ntpsapi,
  NtUtils,
  NtUtils.Threads,
  NtUtils.Synchronization,
  NtUtils.Console,
  NtUiLib.Errors,
  SuspendMe.RaceCondition in 'SuspendMe.RaceCondition.pas',
  SuspendMe.ThreadPool in 'SuspendMe.ThreadPool.pas',
  SuspendMe.PatchCreation in 'SuspendMe.PatchCreation.pas',
  SuspendMe.SelfDebug in 'SuspendMe.SelfDebug.pas',
  SuspendMe.DenyAccess in 'SuspendMe.DenyAccess.pas';

type
  TActionOptions = (
    aoAdjustSecurity,
    aoRaceSuspension,
    aoUseThreadPool,
    aoHijackThreads,
    aoUseSelfDebug
  );

function Main: TNtxStatus;
var
  Action: TActionOptions;
  Checkpoint: Cardinal;
  hxDebugObject: IHandle;
begin
  NtxSetNameThread(NtCurrentThread, 'Main Thread');

  writeln('This is a demo application for bypassing process suspension and freezing.');
  writeln;
  writeln('Available options:');
  writeln;
  writeln('[', Integer(aoAdjustSecurity), '] Protect the process with a denying security descriptor');
  writeln('[', Integer(aoRaceSuspension), '] Circumvent suspension using a race condition');
  writeln('[', Integer(aoUseThreadPool), '] Create a thread pool for someone to trigger');
  writeln('[', Integer(aoHijackThreads), '] Hijack thread execution (resume & detach debuggers on code injection)');
  writeln('[', Integer(aoUseSelfDebug), '] Start self-debugging so nobody else can attach');

  writeln;
  write('Your choice: ');
  Cardinal(Action) := ReadCardinal(0, Cardinal(High(TActionOptions)));
  writeln;

  case Action of
    aoAdjustSecurity:
      ProtectProcessObject;

    aoRaceSuspension:
      Result := RaceSuspension;

    aoUseThreadPool:
      Result := UseThreadPool;

    aoHijackThreads:
      Result := HijackNewThreads;

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

