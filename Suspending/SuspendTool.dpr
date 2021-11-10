program SuspendTool;

{
  A small tool for testing various techniques for suspending/freezing processes.
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Ntapi.ntstatus,
  Ntapi.ntseapi,
  Ntapi.ntpsapi,
  NtUtils,
  NtUtils.Threads,
  NtUtils.Tokens,
  NtUtils.Processes,
  NtUtils.Processes.Snapshots,
  NtUtils.SysUtils,
  NtUtils.Jobs,
  NtUtils.Console,
  NtUiLib.Errors,
  SuspendTool.DebugObject in 'SuspendTool.DebugObject.pas';

type
  TSuspendAction = (
    saSuspendThreads,
    saResumeThreads,
    saSuspendProcess,
    saResumeProcess,
    saSuspendViaDebug,
    saFreezeViaDebug,
    saFreezeViaJob,
    saFreezeViaState
  );

function Main: TNtxStatus;
var
  hxProcess, hxThread, hxJob, hxProcessState: IHandle;
  AccessMask: TProcessAccessMask;
  ProcessName: String;
  Action: TSuspendAction;
  PID: Cardinal;
  JobInfo: TJobObjectFreezeInformation;
begin
  writeln('This program implements various techniques for suspending processes.');
  writeln;
  writeln('Available options:');
  writeln;
  writeln('[', Integer(saSuspendThreads), '] Enumerate & suspend all threads');
  writeln('[', Integer(saResumeThreads), '] Enumerate & resume all threads');
  writeln('[', Integer(saSuspendProcess), '] Suspend via NtSuspendProcess');
  writeln('[', Integer(saResumeProcess), '] Resume via NtResumeProcess');
  writeln('[', Integer(saSuspendViaDebug), '] Suspend via a debug object');
  writeln('[', Integer(saFreezeViaDebug), '] Freeze via a debug object');
  writeln('[', Integer(saFreezeViaJob), '] Freeze via a job object');
  writeln('[', Integer(saFreezeViaState), '] Freeze via a state change object');
  writeln;
  write('Your choice: ');
  Cardinal(Action) := ReadCardinal(0, Cardinal(High(TSuspendAction)));
  writeln;

  case Action of
    saSuspendThreads, saResumeThreads:
      AccessMask := PROCESS_QUERY_INFORMATION;

    saSuspendProcess, saResumeProcess, saSuspendViaDebug, saFreezeViaDebug:
      AccessMask := PROCESS_SUSPEND_RESUME;

    saFreezeViaJob:
      AccessMask := PROCESS_ASSIGN_TO_JOB;

    saFreezeViaState:
      AccessMask := PROCESS_CHANGE_STATE;
  else
    Result.Location := 'Main';
    Result.Status := STATUS_INVALID_PARAMETER;
    Exit;
  end;

  write('PID or a unique image name: ');
  ProcessName := ReadString(False);
  writeln;

  // Enable the Debug Privilege if available
  NtxAdjustPrivilege(NtxCurrentEffectiveToken, SE_DEBUG_PRIVILEGE,
    SE_PRIVILEGE_ENABLED, True);

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask,
      [pnAllowShortNames]);

  if not Result.IsSuccess then
    Exit;

  hxThread := nil;

  case Action of
    saSuspendThreads:
      while NtxGetNextThread(hxProcess.Handle, hxThread,
        THREAD_SUSPEND_RESUME).Save(Result) do
        if not NtxSuspendThread(hxThread.Handle).Save(Result) then
          Exit;

    saResumeThreads:
      while NtxGetNextThread(hxProcess.Handle, hxThread,
        THREAD_SUSPEND_RESUME).Save(Result) do
        if not NtxResumeThread(hxThread.Handle).Save(Result) then
          Exit;

    saSuspendProcess:
      Result := NtxSuspendProcess(hxProcess.Handle);

    saResumeProcess:
      Result := NtxResumeProcess(hxProcess.Handle);

    saSuspendViaDebug:
      Result := SuspendViaDebugMain(hxProcess);

    saFreezeViaDebug:
      Result := FreezeViaDebugMain(hxProcess);

    saFreezeViaJob:
      begin
        Result := NtxCreateJob(hxJob);

        if not Result.IsSuccess then
          Exit;

        JobInfo := Default(TJobObjectFreezeInformation);
        JobInfo.Flags := JOB_OBJECT_OPERATION_FREEZE;
        JobInfo.Freeze := True;

        Result := NtxJob.Set(hxJob.Handle, JobObjectFreezeInformation, JobInfo);

        if not Result.IsSuccess then
          Exit;

        Result := NtxAssignProcessToJob(hxProcess.Handle, hxJob.Handle);

        if not Result.IsSuccess then
          Exit;

        write('The process was frozen via a job object. Press enter to undo...');
        readln;

        JobInfo.Freeze := False;

        Result := NtxJob.Set(hxJob.Handle, JobObjectFreezeInformation, JobInfo);
      end;

    saFreezeViaState:
      begin
        Result := NtxCreateProcessState(hxProcessState, hxProcess.Handle);

        if not Result.IsSuccess then
          Exit;

        Result := NtxChageStateProcess(hxProcessState.Handle, hxProcess.Handle,
          ProcessStateChangeSuspend);

        if not Result.IsSuccess then
          Exit;

        write('The process was frozen via a state change. Press enter to undo...');
        readln;

        Result := NtxChageStateProcess(hxProcessState.Handle, hxProcess.Handle,
          ProcessStateChangeResume);
      end;
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

