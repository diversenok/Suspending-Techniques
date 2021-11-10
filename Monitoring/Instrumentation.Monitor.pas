unit Instrumentation.Monitor;

{
  This module allows monitoring and recording mode transitions happening in a
  context of other processes via the instrumentation callback.
}

interface

uses
  Ntapi.WinNt, NtUtils, DelphiUtils.AutoObjects;

const
  TRACE_MAGNITUDE_LOW = 8;     // record 256 addresses or 2 KiB of data
  TRACE_MAGNITUDE_MEDIUM = 16; // record 65k addresses or 512 KiB of data
  TRACE_MAGNITUDE_HIGH = 20;   // record 4kk addresses or 32 MiB of data

type
  // Defines number of entries in the buffer as 2**Magnitude
  TTraceMagnitude = 0..27;

  TSyscallMonitor = record
    Code: array [0..7] of UInt64;
    TaceSlotMask: Cardinal; // 2**Magnitude - 1
    SyscallCount: UInt64;
    TraceSlots: TAnysizeArray<Pointer>;
    function CollectNewTraces(
      const PreviousCount: UInt64;
      out Overflowed: Boolean
    ): TArray<Pointer>;
  end;
  PSyscallMonitor = ^TSyscallMonitor;

// Install the instrumentation shellcode into a process and start monitoring
function StartMonitoring(
  hxProcess: IHandle;
  TraceMagnitude: TTraceMagnitude;
  out LocalMapping: IMemory<PSyscallMonitor>;
  const Timeout: Int64 = NT_INFINITE
): TNtxStatus;

// A helper function for bebugging the shellcode locally
function DebugShellcode: TNtxStatus;

implementation

uses
  Ntapi.crt, Ntapi.ntstatus, Ntapi.ntmmapi, NtUtils.Shellcode,
  NtUtils.Processes, NtUtils.Memory, NtUtils.Processes.Info.Remote;

// The shellcode for injecting into the target process
// Note: be consistent with the definition of the structure
procedure SyscallMonitor;
asm
  push rcx
  push r8
  lea r8, @@TraceSlots
  mov ecx, 1
  lock xadd qword ptr [@@SyscallCount], rcx // Increment the counter
  and ecx, dword ptr [@@TaceSlotMask]       // Infer the slot index
  mov qword ptr [r8 + rcx * 8], r10         // Save the return address
  pop r8
  pop rcx
  jmp r10

  // Add some padding to align the buffer
  dq $CCCCCCCCCCCCCCCC
  dq $CCCCCCCCCCCCCCCC
  dq $CCCCCCCCCCCCCCCC

@@TaceSlotMask:
  dd 0 // 2**Magnitude - 1 (aka NumberOfSlots - 1)
  dd 0
@@SyscallCount:
  dq 0
@@TraceSlots:
  dq 0
end;

procedure DebugShellcodeLoop;
asm
  lea r10, SyscallMonitor
  jmp r10
end;

function DebugShellcode;
var
  Reverter: IAutoReleasable;
begin
  // Make sure the memory is writable
  Result := NtxProtectMemoryAuto(NtxCurrentProcess, @SyscallMonitor,
    Sizeof(TSyscallMonitor), PAGE_EXECUTE_READWRITE, Reverter);

  if not Result.IsSuccess then
    Exit;

  Reverter.AutoRelease := False;
  Reverter := nil;

  // Jump to the shellcode
  DebugShellcodeLoop;
end;

function StartMonitoring;
var
  RemoteMapping: IMemory;
  SlotMask: Cardinal;
begin
  if TraceMagnitude > High(TTraceMagnitude) then
  begin
    Result.Location := 'StartMonitoring';
    Result.Status := STATUS_BUFFER_OVERFLOW;
    Exit;
  end;

  // The number of slots for recording addresses minus one
  SlotMask := (1 shl TraceMagnitude) - 1;

  // Map a shared memory region for the shellcode and its trace
  Result := RtlxMapSharedMemory(
    hxProcess,
    SizeOf(TSyscallMonitor) + SlotMask * SizeOf(Pointer),
    IMemory(LocalMapping),
    RemoteMapping,
    [mmAllowWrite, mmAllowExecute]
  );

  if not Result.IsSuccess then
    Exit;

  // Write the shellcode
  memmove(LocalMapping.Data, @SyscallMonitor, SizeOf(TSyscallMonitor));
  LocalMapping.Data.TaceSlotMask := SlotMask;

  // Set it as the instrumentation callback
  Result := NtxSetInstrumentationProcess(hxProcess, RemoteMapping.Data,
    Timeout);

  // Make sure we don't unmap the shellcode when we exit. Even if we reset the
  // callback later, we don't know when its safe to unmap the code because there
  // can be threads still executing or being suspended in the middle of it.
  if Result.IsSuccess then
    RemoteMapping.AutoRelease := False;
end;

function TSyscallMonitor.CollectNewTraces;
var
  CurrentCount: UInt64;
  FreshEntries: UInt64;
  PreviousIndex, UntilWrap: Cardinal;
begin
  // Make a defensive copy since the value can change rapidly
  CurrentCount := SyscallCount;

  FreshEntries := CurrentCount - PreviousCount;
  PreviousIndex := PreviousCount and TaceSlotMask;
  Overflowed := False;

  if FreshEntries > TaceSlotMask + 1 then
  begin
    // The trace grew bigger than can fit into the buffer, so it wrapped around
    // Some entries are lost.
    Overflowed := True;
    SetLength(Result, TaceSlotMask + 1);
    Move(TraceSlots, Result[0], Length(Result) * SizeOf(Pointer));
  end
  else if FreshEntries + PreviousIndex <= TaceSlotMask + 1 then
  begin
    // The buffer did not wrap since the last time
    SetLength(Result, FreshEntries);

    {$R-}
    Move(TraceSlots[PreviousIndex], Result[0], SizeOf(Pointer) * FreshEntries);
    {$R+}
  end
  else
  begin
    // The buffer wrapped since the last time, but not entirely
    SetLength(Result, FreshEntries);
    UntilWrap := TaceSlotMask + 1 - PreviousIndex;

    // Copy the portion from the last position to the right boundary
    {$R-}
    Move(TraceSlots[PreviousIndex], Result[0], SizeOf(Pointer) * UntilWrap);

    // Copy from the left boundary to the new poition
    Move(TraceSlots, Result[UntilWrap], SizeOf(Pointer) *
      (Length(Result) - UntilWrap));
    {$R+}
  end;
end;

end.
