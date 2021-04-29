program SuspendTool;

{
  A small tool for testing various methods of suspending processes.
}

{$APPTYPE CONSOLE}
{$MINENUMSIZE 4}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, NtUtils,
  NtUtils.Ldr, NtUtils.Processes, NtUtils.Processes.Snapshots, NtUtils.Debug,
  NtUtils.Job, NtUtils.Processes.Query, NtUtils.SysUtils, NtUiLib.Errors;

type
  TSuspendAction = (
    saSuspendProcess,
    saResumeProcess,
    saFreezeViaDebug,
    saFreezeViaJob,
    saFreezeViaState
  );

function Main: TNtxStatus;
var
  hxProcess, hxDbg, hxJob, hxProcessState: IHandle;
  AccessMask: TProcessAccessMask;
  ProcessName: String;
  Action: TSuspendAction;
  PID: Cardinal;
  JobInfo: TJobObjectFreezeInformation;
begin
  writeln('Available options:');
  writeln;
  writeln('[', Integer(saSuspendProcess), '] Suspend via NtSuspendProcess');
  writeln('[', Integer(saResumeProcess), '] Resume via NtResumeProcess');
  writeln('[', Integer(saFreezeViaDebug), '] Freeze via a debug object');
  writeln('[', Integer(saFreezeViaJob), '] Freeze via a job object');
  writeln('[', Integer(saFreezeViaState), '] Suspend via a state change object');
  writeln;
  write('Your choice: ');
  readln(Cardinal(Action));
  writeln;

  case Action of
    saSuspendProcess, saResumeProcess, saFreezeViaDebug:
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
  readln(ProcessName);
  writeln;

  if RtlxStrToInt(ProcessName, PID) then
    Result := NtxOpenProcess(hxProcess, PID, AccessMask)
  else
    Result := NtxOpenProcessByName(hxProcess, ProcessName, AccessMask);

  if not Result.IsSuccess then
    Exit;

  case Action of
    saSuspendProcess:
      Result := NtxSuspendProcess(hxProcess.Handle);

    saResumeProcess:
      Result := NtxResumeProcess(hxProcess.Handle);

    saFreezeViaDebug:
      begin
        Result := NtxCreateDebugObject(hxDbg);

        if not Result.IsSuccess then
          Exit;

        Result := NtxDebugProcess(hxProcess.Handle, hxDbg.Handle);

        if not Result.IsSuccess then
          Exit;

        write('The process was frozen via a debug object. Press enter to undo...');
        readln;

        Result := NtxDebugProcessStop(hxProcess.Handle, hxDbg.Handle);
      end;

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

