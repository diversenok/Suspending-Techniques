program ThreadPoolTest;

{
  A small program that creates a thread pool and prints a message every time
  a new thread in it is created.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Winapi.WinNt, Ntapi.ntpsapi, NtUtils, NtUtils.SysUtils, NtUtils.Threads,
  NtUtils.Threads.Worker, NtUtils.Synchronization, NtUtils.Processes.Query,
  NtUiLib.Errors;

var
  hxWorkerFactory: IHandle;
  Count: Cardinal = 0;

procedure ThreadPoolMain(Context: Pointer); stdcall;
var
  Name: String;
begin
  Inc(Count);
  Name := 'thread pool''s thread #' + RtlxIntToStr(Count);
  writeln('Hello from ', Name);
  NtxSetNameThread(NtCurrentThread, Name);
  NtxWorkerFactoryWorkerReady(hxWorkerFactory.Handle);
  NtxDelayExecution(NT_INFINITE)
end;

function Main: TNtxStatus;
var
  hxIoCompletion: IHandle;
begin
  writeln('This is a sample application with a thread pool.');

  Result := NtxCreateIoCompletion(hxIoCompletion);

  if not Result.IsSuccess then
    Exit;

  Result := NtxCreateWorkerFactory(hxWorkerFactory, hxIoCompletion.Handle,
    ThreadPoolMain, nil);

  if not Result.IsSuccess then
    Exit;

  writeln;
  writeln('Current PID: ', NtCurrentProcessId);
  writeln('Thread pool''s handle: ', RtlxIntToStr(hxWorkerFactory.Handle, 16));
  writeln;
  writeln('Now try to trigger thread creation. You will see a message on success.');

  NtxDelayExecution(NT_INFINITE);
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
