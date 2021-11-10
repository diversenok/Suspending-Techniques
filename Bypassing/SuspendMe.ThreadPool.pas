unit SuspendMe.ThreadPool;

{
  This module demonstrates how an application can resume itself by taking
  advantage of the scenarios when the operating system creates additional
  threads in the application's thread pool.
}

interface

uses
  NtUtils;

// Create a thread pool and wait for someone to trigger thread creation in it.
function UseThreadPool: TNtxStatus;

implementation

uses
  Ntapi.ntpsapi, NtUtils.SysUtils, NtUtils.Threads, NtUtils.Threads.Worker,
  NtUtils.Synchronization;

var
  hxWorkerFactory, hxMainThread: IHandle;
  Count: Cardinal = 0;

// The function to execute on the thread pool
procedure ThreadPoolMain(Context: Pointer); stdcall;
var
  Name: String;
  RemainingResumes: Cardinal;
  i: Integer;
begin
  Inc(Count);
  Name := 'Thread pool''s thread #' + RtlxUIntToStr(Count);
  NtxSetNameThread(NtCurrentThread, Name);

  writeln;
  writeln('Hello from ', Name);
  writeln;

  // In case there are multiple suspensions on the main thread, lift them all
  if Assigned(hxMainThread) then
    if NtxResumeThread(hxMainThread.Handle, @RemainingResumes).IsSuccess then
      for i := 0 to Integer(RemainingResumes) - 2 do
        NtxResumeThread(hxMainThread.Handle);

  NtxWorkerFactoryWorkerReady(hxWorkerFactory.Handle);
  NtxDelayExecution(NT_INFINITE)
end;

function UseThreadPool;
var
  hxIoCompletion: IHandle;
begin
  Result := NtxOpenCurrentThread(hxMainThread);

  if not Result.IsSuccess then
    Exit;

  Result := NtxCreateIoCompletion(hxIoCompletion);

  if not Result.IsSuccess then
    Exit;

  Result := NtxCreateWorkerFactory(hxWorkerFactory, hxIoCompletion.Handle,
    ThreadPoolMain, nil);

  if not Result.IsSuccess then
    Exit;

  writeln('Current PID: ', NtCurrentProcessId);
  writeln('Thread pool''s handle: ', RtlxUIntPtrToStr(hxWorkerFactory.Handle, 16));
  writeln;
  writeln('Now try to trigger thread creation. You will see a message on success.');
end;

end.
