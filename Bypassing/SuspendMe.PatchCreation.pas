unit SuspendMe.PatchCreation;

{
  This module demonstrates how a suspended program can resume itself by taking
  advantage of the threads that some tools (for example, Process Explorer)
  inject into processes.
}

interface

uses
  NtUtils;

// Patch local thread initialization to execute our payload. The payload resumes
// the main thread and (optionally) detaches the process from its debugger.
function HijackNewThreads: TNtxStatus;

implementation

uses
  Ntapi.WinNt, Ntapi.ntdef, Ntapi.ntstatus, Ntapi.ntrtl, Ntapi.ntmmapi,
  DelphiApi.Reflection, DelphiUtils.ExternalImport, NtUtils.Processes,
  NtUtils.Threads, NtUtils.Memory, NtUtils.Debug, NtUiLib.Errors;

var
  hxMainThread: IHandle;

// The function to execute on thread creation
function Payload: TNtxStatus;
var
  RemainingResumes: Cardinal;
  i: Integer;
  hxDbgObj: IHandle;
begin
  if not Assigned(hxMainThread) then
  begin
    Result.Location := 'Payload';
    Result.Status := STATUS_INVALID_HANDLE;
    Exit;
  end;

  Result := NtxResumeThread(hxMainThread.Handle, @RemainingResumes);

  if not Result.IsSuccess then
    Exit;

  // In case there are multiple suspensions on the main thread, lift them all
  for i := 0 to Integer(RemainingResumes) - 2 do
  begin
    Result := NtxResumeThread(hxMainThread.Handle);

    if not Result.IsSuccess then
      Break;
  end;

  // If we are frozen via a debug object, removing it will unfreeze us
  Result := NtxOpenDebugObjectProcess(hxDbgObj, NtCurrentProcess);

  if Result.IsSuccess then
    Result := NtxDebugProcessStop(NtCurrentProcess, hxDbgObj.Handle)
  else if Result.Status = STATUS_PORT_NOT_SET then
    Result.Status := STATUS_SUCCESS; // Nothing to do
end;

procedure RunPayload;
var
  Result: TNtxStatus;
begin
  // When using Delphi's I/O functions (writeln, etc.), the compiler emits the
  // calls to System.__IOTest that uses TLS and crashes our process with access
  // violation if executed from a thread that skipped attaching to DLLs.
  // So, suppress these calls.

{$IOCHECKS OFF}
  writeln;
  writeln('Hijacking injected thread...');

  Result := Payload;

  if not Result.IsSuccess then
    writeln(Result.Location, ': ', RtlxNtStatusName(Result.Status))
  else
    writeln('Success');

  writeln;
{$IOCHECKS ON}
end;

// The function that RtlUserThreadStart usually forwards the call to
function BaseThreadInitThunk(
  [Reserved] Reserved: Cardinal;
  [in] Func: TUserThreadStartRoutine;
  [in, opt] Parameter: Pointer
): NTSTATUS; stdcall; external kernel32;

// A patched version of RtlUserThreadStart
procedure PatchedThreadStartRoutine(
  [in] Func: TUserThreadStartRoutine;
  [in, opt] Parameter: Pointer
); stdcall;
begin
  // Note that we call RunPayload instead of inlining it because Delphi
  // often emits code into function epilogues that cleans up strings and other
  // resources. Since BaseThreadInitThunk never returns, we need to make sure
  // our callback cleans up before calling it.
  RunPayload;
  BaseThreadInitThunk(0, Func, Parameter);
end;

exports
  // Help resolving the name without symbols
  PatchedThreadStartRoutine;

type
  TFarJump = packed record
    InstructionStart: Word;
    Address: UInt64;
    JumpRax: Word;
  end;
  PFarJump = ^TFarJump;

function HijackNewThreads;
const
  JMP_LOOP = $FEEB; // jmp short 0 (aka infinite loop)
  MOV_RAX = $B848;  // mov rax, ...
  JMP_RAX = $E0FF;  // jmp rax
var
  pCode: PPointer;
  Code: PFarJump;
  UndoProtection: IAutoReleasable;
begin
  Result := NtxOpenCurrentThread(hxMainThread);

  if not Result.IsSuccess then
    Exit;

  // Find the code to patch
  pCode := ExternalImportTarget(@RtlUserThreadStart);

  if not Assigned(pCode) then
  begin
    Result.Location := 'HijackThreadCreation';
    Result.Status := STATUS_INVALID_IMAGE_FORMAT;
    Exit;
  end;

  Code := pCode^;

  // Make it writable
  Result := NtxProtectMemoryAuto(NtxCurrentProcess, Code, SizeOf(TFarJump),
    PAGE_EXECUTE_READWRITE, UndoProtection);

  if not Result.IsSuccess then
    Exit;

  // Make sure nobody enters the code while we patch it
  Code.InstructionStart := JMP_LOOP;

  Code.Address := UIntPtr(@PatchedThreadStartRoutine);
  Code.JumpRax := JMP_RAX;
  Code.InstructionStart := MOV_RAX;

  UndoProtection := nil;
  NtxFlushInstructionCache(NtCurrentProcess, Code, SizeOf(TFarJump));

  writeln('Now suspend the process and try injecting some code or inspecting ' +
    'the list of threads in Process Explorer.');
end;

end.
