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
  NtUtils.Job, NtUtils.Processes.Query, NtUtils.Threads, NtUtils.SysUtils,
  NtUiLib.Errors;

type
  TSuspendAction = (
    saSuspendThreads,
    saResumeThreads,
    saSuspendProcess,
    saResumeProcess,
    saFreezeViaDebug,
    saFreezeViaDebugInject,
    saFreezeViaJob,
    saFreezeViaState
  );

function Main: TNtxStatus;
var
  hxProcess, hxThread, hxDbg, hxJob, hxProcessState: IHandle;
  AccessMask: TProcessAccessMask;
  ProcessName: String;
  Action: TSuspendAction;
  PID: Cardinal;
  JobInfo: TJobObjectFreezeInformation;
begin
  writeln('Available options:');
  writeln;
  writeln('[', Integer(saSuspendThreads), '] Enumerate and suspend all threads');
  writeln('[', Integer(saResumeThreads), '] Enumerate and resume all threads');
  writeln('[', Integer(saSuspendProcess), '] Suspend via NtSuspendProcess');
  writeln('[', Integer(saResumeProcess), '] Resume via NtResumeProcess');
  writeln('[', Integer(saFreezeViaDebug), '] Freeze via a debug object');
  writeln('[', Integer(saFreezeViaDebugInject), '] Freeze via a debug object (with thread injection)');
  writeln('[', Integer(saFreezeViaJob), '] Freeze via a job object');
  writeln('[', Integer(saFreezeViaState), '] Suspend via a state change object');
  writeln;
  write('Your choice: ');
  readln(Cardinal(Action));
  writeln;

  case Action of
    saSuspendThreads, saResumeThreads:
      AccessMask := PROCESS_QUERY_INFORMATION;

    saSuspendProcess, saResumeProcess, saFreezeViaDebug:
      AccessMask := PROCESS_SUSPEND_RESUME;

    saFreezeViaDebugInject:
      AccessMask := PROCESS_SUSPEND_RESUME or PROCESS_CREATE_THREAD;

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

    saFreezeViaDebug, saFreezeViaDebugInject:
      begin
        Result := NtxCreateDebugObject(hxDbg);

        if not Result.IsSuccess then
          Exit;

        Result := NtxDebugProcess(hxProcess.Handle, hxDbg.Handle);

        if not Result.IsSuccess then
          Exit;

        // Injecting a thread causes the system to freeze other threads
        if Action = saFreezeViaDebugInject then
        begin
          // No need to specify a valid start address since it will never run
          Result := NtxCreateThread(hxThread, hxProcess.Handle, nil, nil,
            THREAD_CREATE_FLAGS_CREATE_SUSPENDED);

          if not Result.IsSuccess then
            Exit;

          NtxSetNameThread(hxThread.Handle, 'Injected helper thread');
          Result := NtxTerminateThread(hxThread.Handle, DBG_TERMINATE_THREAD);

          if not Result.IsSuccess then
            Exit;
        end;

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

