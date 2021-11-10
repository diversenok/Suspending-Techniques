unit SuspendTool.DebugObject;

{
  The module provides logic for suspending/freezing processes via debug objects.
}

interface

uses
  NtUtils;

// Suspend a process via a debug object
function SuspendViaDebugMain(
  const hxProcess: IHandle
): TNtxStatus;

// An improved version for freezing a process via a debug object
function FreezeViaDebugMain(
  hxProcess: IHandle
): TNtxStatus;

implementation

uses
  Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntdbg, Ntapi.ntpsapi, Ntapi.ntmmapi,
  NtUtils.Debug, NtUtils.Processes.Info, NtUtils.Memory,
  NtUtils.Threads, NtUtils.Console, NtUiLib.Errors;

function SuspendViaDebugMain;
var
  hxDebugObject: IHandle;
begin
  Result := NtxCreateDebugObject(hxDebugObject);

  if not Result.IsSuccess then
    Exit;

  Result := NtxDebugProcess(hxProcess.Handle, hxDebugObject.Handle);

  if not Result.IsSuccess then
    Exit;

  write('The process was suspended via a debug object. Press enter to undo...');
  readln;

  Result := NtxDebugProcessStop(hxProcess.Handle, hxDebugObject.Handle);
end;

// Protecting the page with the MZ header blocks external thread creation
function PreventThreadInjection(
  const hxProcess: IHandle;
  out Reverter: IAutoReleasable
): TNtxStatus;
var
  Info: TProcessBasicInformation;
  ImageBase: Pointer;
begin
  // Locate PEB
  Result := NtxProcess.Query(hxProcess.Handle, ProcessBasicInformation, Info);

  if not Result.IsSuccess then
    Exit;

  // Read the address of the image base
  Result := NtxMemory.Read(hxProcess.Handle,
    @Info.PebBaseAddress.ImageBaseAddress, ImageBase);

  if not Result.IsSuccess then
    Exit;

  // Protect the first page
  Result := NtxProtectMemoryAuto(hxProcess, ImageBase, 1, PAGE_READONLY or
    PAGE_GUARD, Reverter);
end;

function FreezeViaDebugMain;
var
  ObjAttributes: IObjectAttributes;
  hxDebugObject, hxThread: IHandle;
  WaitState: TDbgxWaitState;
  WaitHandles: TDbgxHandles;
  DelayedAllowInjection: IAutoReleasable;
  PreventInjection: Boolean;
begin
  write('Do you want to prevent detaching? [y/n]: ');
  if ReadBoolean then
    ObjAttributes := AttributeBuilder.UseAttributes(OBJ_EXCLUSIVE)
  else
    ObjAttributes := nil;

  write('Do you want to prevent thread injection? [y/n]: ');
  PreventInjection := ReadBoolean;

  Result := NtxCreateDebugObject(hxDebugObject, False, ObjAttributes );

  if not Result.IsSuccess then
    Exit;

  Result := NtxDebugProcess(hxProcess.Handle, hxDebugObject.Handle);

  if not Result.IsSuccess then
    Exit;

  // Retrieve the first debug event without waiting
  Result := NtxDebugWait(hxDebugObject.Handle, WaitState, WaitHandles, 0);

  if Result.IsFailOrTimeout then
    Exit;

  // The first event should be process creation
  if (WaitState.NewState <> DbgCreateProcessStateChange) or
    not Assigned(WaitHandles.hxProcess) then
  begin
    Result.Location := '[Unexpected debug event]';
    Result.Status := STATUS_UNSUCCESSFUL;
    Exit;
  end;

  // Now we got full access
  hxProcess := WaitHandles.hxProcess;

  // Injecting a thread causes the system to freeze other threads
  // No need to specify a valid start address since it will never run
  Result := NtxCreateThread(hxThread, hxProcess.Handle, nil, nil,
    THREAD_CREATE_FLAGS_CREATE_SUSPENDED);

  if not Result.IsSuccess then
    Exit;

  NtxSetNameThread(hxThread.Handle, 'Debugger-injected thread');
  Result := NtxTerminateThread(hxThread.Handle, DBG_TERMINATE_THREAD);

  if not Result.IsSuccess then
    Exit;

  if PreventInjection then
  begin
    // Prevent tools like Process Explorer from injecting hide-from-debugger
    // threads (optional)
    Result := PreventThreadInjection(hxProcess, DelayedAllowInjection);

    if not Result.IsSuccess then
      writeln('Cannot prevent thread injection: ', Result.Location, ': ',
        RtlxNtStatusName(Result.Status));
  end;

  write('The process was frozen via a debug object. Press enter to undo...');
  readln;

  // Undo memory protection changes before stopping the debug session
  DelayedAllowInjection := nil;

  // Exiting the function will stop debugging through closing the handle within
  // the hxDebugObject variable.
end;

end.
