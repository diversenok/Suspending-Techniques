unit ModeTransitionMonitor.Trace;

{
  This module adds support for showing a summary of the return addresses
  encountered during syscall monitoring.
}

interface

uses
  NtUtils, Instrumentation.Monitor;

// Load symbols for looking up addresses
procedure InitializeSymbols;

// Display the summary return addresses
procedure PrintFreshTraces(
  Mapping: PSyscallMonitor;
  const PreviousCount: UInt64
);

implementation

uses
  Ntapi.ntdef, Ntapi.ntldr, NtUtils.Ldr, NtUtils.SysUtils, DelphiUtils.Arrays,
  NtUtils.ImageHlp.DbgHelp;

var
  NtdllModule, Win32Module: TModuleEntry;
  NtdllSymbols, Win32uSymbols: TArray<TImageHlpSymbol>;

procedure InitializeSymbols;
var
  hWin32u: PDllBase;
begin
  // We expect system call to be executed and exported from two libraries.
  // We can use local module enumeration since they are Known Dlls, so they
  // share addresses between processes.

  if LdrxFindModule(NtdllModule, ByBaseName(ntdll)).IsSuccess then
    RtlxEnumSymbols(NtdllSymbols, NtdllModule.DllBase, NtdllModule.SizeOfImage,
      True);

  if LdrxLoadDll(win32u, hWin32u).IsSuccess and
    LdrxFindModule(Win32Module, ByBaseName(win32u)).IsSuccess then
    RtlxEnumSymbols(Win32uSymbols, Win32Module.DllBase, Win32Module.SizeOfImage,
      True);
end;

function LookupAddress(Address: Pointer): String;
begin
  // Check ntdll
  if Assigned(NtdllModule.DllBase) and NtdllModule.IsInRange(Address) then
    Result := RtlxFindBestMatchModule(NtdllModule, NtdllSymbols,
      UIntPtr(Address) - UIntPtr(NtdllModule.DllBase)).ToString

  // Check win32u
  else if Assigned(Win32Module.DllBase) and Win32Module.IsInRange(Address) then
    Result := RtlxFindBestMatchModule(Win32Module, Win32uSymbols,
      UIntPtr(Address) - UIntPtr(Win32Module.DllBase)).ToString

  else
    Result := RtlxPtrToStr(Address);
end;

procedure PrintFreshTraces;
const
  OVERFLOW_SUFFIX: array [Boolean] of String = ('', '+');
var
  TraceGroups: TArray<TArrayGroup<Pointer, Pointer>>;
  Overflowed: Boolean;
  i: Integer;
begin
  // Group them, merging the same return addresses
  TraceGroups := TArray.GroupBy<Pointer, Pointer>(
    Mapping.CollectNewTraces(PreviousCount, Overflowed),
    function (const Entry: Pointer): Pointer
    begin
      Result := Entry
    end,
    function (const A, B: Pointer): Boolean
    begin
      Result := (A = B);
    end
  );

  // Sort them by the number of occurances
  TArray.SortInline<TArrayGroup<Pointer, Pointer>>(TraceGroups,
    function (const A, B: TArrayGroup<Pointer, Pointer>): Integer
    begin
      Result := Length(B.Values) - Length(A.Values);
    end
  );

  for i := 0 to High(TraceGroups) do
  begin
    write('  ', LookupAddress(TraceGroups[i].Key));

    if Overflowed or (Length(TraceGroups[i].Values) > 1) then
      writeln(' x ', Length(TraceGroups[i].Values),
        OVERFLOW_SUFFIX[Overflowed <> False], ' times')
    else
      writeln;

{    if i > 6 then
    begin
      writeln('  ...');
      Break;
    end;}
  end;
end;

end.
