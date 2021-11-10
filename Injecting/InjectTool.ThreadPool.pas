unit InjectTool.ThreadPool;

{
  The implementation for triggering thread creation via existing thread pools.
}

interface

uses
  NtUtils;

// Adjust the minimum number of threads in a thread pool to force the OS
// to create new threads in a suspended process.
function TriggerThreadPool(hProcess: THandle): TNtxStatus;

implementation

uses
  Ntapi.ntstatus, Ntapi.nttp, NtUtils.Threads.Worker, NtUtils.Objects,
  NtUtils.Objects.Snapshots, NtUtils.SysUtils, DelphiUtils.Arrays,
  NtUtils.Console, NtUiLib.Errors;

type
  TThreadPoolEntry = record
    HandleEntry: TProcessHandleEntry;
    hxLocalHandle: IHandle;
    Status: TNtxStatus;
    Info: TWorkerFactoryBasicInformation;
  end;

function ChooseThreadPool(
  hProcess: THandle;
  out ThreadPool: TThreadPoolEntry
): TNtxStatus;
var
  TypeIndex: Integer;
  Handles: TArray<TProcessHandleEntry>;
  ThreadPools: TArray<TThreadPoolEntry>;
  i: Integer;
begin
  // We are only interested in worker factories
  Result := NtxFindType('TpWorkerFactory', TypeIndex);

  if not Result.IsSuccess then
    Exit;

  Result := NtxEnumerateHandlesProcess(hProcess, Handles);

  if not Result.IsSuccess then
    Exit;

  TArray.FilterInline<TProcessHandleEntry>(Handles, ByType(TypeIndex));

  if Length(Handles) = 0 then
  begin
    Result.Location := 'ChooseThreadPool';
    Result.Status := STATUS_NOT_FOUND;
    Exit;
  end;

  // Collect information about each thread pool
  ThreadPools := TArray.Map<TProcessHandleEntry, TThreadPoolEntry>(Handles,
    function (const HandleEntry: TProcessHandleEntry): TThreadPoolEntry
    begin
      Result.HandleEntry := HandleEntry;

      Result.Status := NtxDuplicateHandleFrom(hProcess, HandleEntry.HandleValue,
        Result.hxLocalHandle);

      if not Result.Status.IsSuccess then
        Exit;

      Result.Status := NtxQueryWorkerFactory(Result.hxLocalHandle.Handle,
        Result.Info);
    end
  );

  writeln('Which thread pool should we work with?');
  for i := 0 to High(ThreadPools) do
  begin
    write('[', i, '] Handle ', RtlxUIntPtrToStr(ThreadPools[i].HandleEntry.
      HandleValue, 16), ' ');

    if ThreadPools[i].Status.IsSuccess then
      writeln('(',
        'min: ', ThreadPools[i].Info.ThreadMinimum, ', ',
        'max: ', ThreadPools[i].Info.ThreadMaximum, ', ',
        'current: ', ThreadPools[i].Info.TotalWorkerCount,
      ')')
    else
      writeln(RtlxNtStatusName(ThreadPools[i].Status.Status), ' @ ',
        ThreadPools[i].Status.Location);
  end;

  writeln;
  write('Your choice: ');
  ThreadPool := ThreadPools[ReadCardinal(0, High(ThreadPools))];
  Result := ThreadPool.Status;
end;

function TriggerThreadPool(hProcess: THandle): TNtxStatus;
var
  ThreadPool: TThreadPoolEntry;
  NewMinumum: Cardinal;
begin
  Result := ChooseThreadPool(hProcess, ThreadPool);

  if not Result.IsSuccess then
    Exit;

  // While the user was deciding which thread pool to use, the number of active
  // threads might've changed; refresh it.
  Result := NtxQueryWorkerFactory(ThreadPool.hxLocalHandle.Handle,
    ThreadPool.Info);

  if not Result.IsSuccess then
    Exit;

  NewMinumum := ThreadPool.Info.TotalWorkerCount + 1;

  if NewMinumum <= ThreadPool.Info.ThreadMinimum then
    NewMinumum := ThreadPool.Info.ThreadMinimum + 1;

  // Make sure we don't overflow the maximum
  if (ThreadPool.Info.ThreadMaximum <> 0) and
    (NewMinumum > ThreadPool.Info.ThreadMaximum) then
  begin
    Result := NtxWorkerFactory.Set(ThreadPool.hxLocalHandle.Handle,
      WorkerFactoryThreadMaximum, NewMinumum);

    if not Result.IsSuccess then
      Exit;
  end;

  // Adjust the minimum
  Result := NtxWorkerFactory.Set(ThreadPool.hxLocalHandle.Handle,
    WorkerFactoryThreadMinimum, NewMinumum);
end;

end.
