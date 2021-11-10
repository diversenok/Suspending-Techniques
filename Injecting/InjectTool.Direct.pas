unit InjectTool.Direct;

{
  The implementation for testing direct thread injection.
}

interface

uses
  Ntapi.ntpsapi, NtUtils;

// Inject a dummy thread into a suspended process to see how it behaves
function InjectDummyThread(
  hProcess: THandle;
  Flags: TThreadCreateFlags
): TNtxStatus;

implementation

uses
  Ntapi.WinNt, Ntapi.ntdef, Ntapi.Ntstatus, NtUtils.Threads,
  Ntutils.Processes.Info, NtUtils.ShellCode, NtUtils.Synchronization;

function InjectDummyThread;
var
  ThreadMain: Pointer;
  ThreadParam: NativeUInt;
  IsWoW64: Boolean;
  hxThread: IHandle;
  Checkpoint: Cardinal;
begin
  // Prevent WoW64 -> Native injection
  Result := RtlxAssertWoW64Compatible(hProcess, IsWoW64);

  if not Result.IsSuccess then
    Exit;

  // Use some simple function with a single NativeUInt parameter as the payload
  Result := RtlxFindKnownDllExport(ntdll, IsWoW64, 'NtAlertThread', ThreadMain);

  if not Result.IsSuccess then
    Exit;

  ThreadParam := NtCurrentThread;

{$IFDEF Win64}
  if IsWoW64 then
    ThreadParam := Cardinal(ThreadParam);
{$ENDIF}

  Result := NtxCreateThread(hxThread, hProcess, ThreadMain,
    Pointer(ThreadParam), Flags);

  if not Result.IsSuccess then
    Exit;

  NtxSetNameThread(hxThread.Handle, 'Thread injection test');
  writeln('Successfully created a thread.');
  writeln;
  Checkpoint := 0;

  repeat
    writeln('[#', Checkpoint, '] Waiting for it...');
    Inc(Checkpoint);

    Result := NtxWaitForSingleObject(hxThread.Handle, 2000 * MILLISEC);
  until Result.Status <> STATUS_TIMEOUT;

  writeln;

  if Result.Status = STATUS_WAIT_0 then
    writeln('Wait completed, thread exited.');
end;

end.
