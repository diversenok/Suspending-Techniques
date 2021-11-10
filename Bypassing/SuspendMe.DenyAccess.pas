unit SuspendMe.DenyAccess;

{
  This module demonstrates protecting the process and thread objects with a
  denying DACL.
}

interface

uses
  NtUtils;

// Set a denying security descriptor on the current process and its threads
function ProtectProcessObject: TNtxStatus;

implementation

uses
  Ntapi.WinNt, Ntapi.ntpsapi, NtUtils.Objects, NtUtils.Threads,
  NtUtils.Security.Acl;

function ProtectProcessObject;
var
  SD: ISecDesc;
  hxThread: IHandle;
begin
  Result := RtlxAllocateDenyingSd(SD);

  if not Result.IsSuccess then
    Exit;

  Result := NtxSetSecurityObject(NtCurrentProcess, DACL_SECURITY_INFORMATION,
    SD.Data);

  if not Result.IsSuccess then
    Exit;

  hxThread := nil;
  while NtxGetNextThread(NtCurrentProcess, hxThread, WRITE_DAC).IsSuccess do
    NtxSetSecurityObject(hxThread.Handle, DACL_SECURITY_INFORMATION, SD.Data);

  writeln('Unprivileged programs should not be able to suspend this process.');
end;

end.
