program SuspendTool;

{
  A small tool for testing various methods of suspending processes.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, NtUtils,
  NtUtils.Ldr, NtUtils.Processes, NtUtils.Processes.Snapshots, NtUtils.Debug,
  NtUtils.Job, NtUtils.SysUtils, NtUiLib.Errors;

function Main: TNtxStatus;
var
  hxProcess, hxDbg, hxJob, hxProcessState: IHandle;
  AccessMask: TProcessAccessMask;
  ActionStr, ProcessName: String;
  Action, PID: Cardinal;
  JobInfo: TJobObjectFreezeInformation;
begin
  writeln('Available options:');
  writeln('[0] Suspend via NtSuspendProcess');
  writeln('[1] Resume via NtResumeProcess');
  writeln('[2] Freeze via a debug object');
  writeln('[3] Freeze via a job object');
  writeln('[4] Suspend via a state change object');
  writeln;
  write('Your choice: ');
  readln(ActionStr);
  writeln;

  if not RtlxStrToInt(ActionStr, Action) then
    Integer(Action) := -1;

  case Action of
    0, 1, 2: AccessMask := PROCESS_SUSPEND_RESUME;
    3: AccessMask := PROCESS_ASSIGN_TO_JOB;
    4: AccessMask := PROCESS_CHANGE_STATE;
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
    0: Result := NtxSuspendProcess(hxProcess.Handle);
    1: Result := NtxResumeProcess(hxProcess.Handle);
    2:
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
    3:
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
    4:
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
  {$IFDEF Debug}readln;{$ENDIF}
end.

