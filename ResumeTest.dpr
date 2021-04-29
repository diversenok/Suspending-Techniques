program ResumeTest;

{
  This is a sample application that demonstrates how a process can try to
  counteract suspension.
}

{$APPTYPE CONSOLE}
{$R *.res}

uses
  Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntpsapi, NtUtils, NtUtils.Threads,
  NtUtils.SysUtils, NtUtils.Synchronization, NtUtils.Processes.Query,
  NtUiLib.Errors;

var
  AllThreads: TArray<IHandle>;

function ThreadMain(Context: Pointer): NTSTATUS; stdcall;
var
  CurrentIndex: NativeInt absolute Context;
  i: Integer;
begin
  // Resume all other threads in a loop

  while True do
    for i := 0 to High(AllThreads) do
      if i <> CurrentIndex then
      begin
        Result := NtResumeThread(AllThreads[i].Handle);

        if not NT_SUCCESS(Result) then
          Exit;
      end;
end;

function Main: TNtxStatus;
var
  Threads: TArray<IHandle>;
  i, Count: Integer;
  Info: TThreadBasicInformation;
begin
  writeln('A demo of multiple threads constantly resuming each other.');
  writeln;
  write('Specify the number of threads (2 or more): ');
  readln(Count);

  if Count >= 1 shl 24 then
  begin
    Result.Location := 'Main';
    Result.Status := STATUS_TOO_MANY_THREADS;
    Exit;
  end
  else if Count < 2 then
  begin
    Result.Location := 'Main';
    Result.Status := STATUS_INVALID_PARAMETER;
    Exit;
  end;

  SetLength(Threads, Count);

  for i := 0 to High(Threads) do
  begin
    // Create each thread in a suspended state
    Result := NtxCreateThread(Threads[i], NtCurrentProcess, ThreadMain,
      Pointer(i), THREAD_CREATE_FLAGS_CREATE_SUSPENDED);

    if Result.IsSuccess then
      NtxSetNameThread(Threads[i].Handle, 'Resumer Thread #' + RtlxIntToStr(i))
    else
      Exit;
  end;

  // Here the user can adjust their priorities, etc.
  writeln;
  write('Ready? Press enter to start.');
  readln;

  AllThreads := Threads;
  Result := NtxResumeThread(Threads[0].Handle);

  if not Result.IsSuccess then
    Exit;

  writeln('Try suspending any/all of them.');

  repeat
    // Let the user trigger mode transitions on the main thread
    readln;
  until False;
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

