{ Bounty Boss test: try...finally + exit.
  When a Pascal program uses try...finally and then Exit (or Break/Continue)
  from inside the try block, the runtime must run the finally block before
  exiting (local unwind). On Windows arm64, incorrect .pdata/unwind info
  causes hang or crash. If this runs and prints "Success: Finally block executed!"
  the compiler has generated correct unwind for this case.

  Debug flow (FPC_DEBUG_WIN64_UNWIND): step 0..7 in _fpc_local_unwind; step 8
  only if RtlUnwindEx returned (it shouldn't). Last step seen = where we were
  before crash. In program: "LANDED at first instr" = we reached target;
  "Back in main" = we returned from TestException; "Done." = full success. }
program arm64trap;
{$mode objfpc}

{ Minimal types for Vectored Exception Handler to log crash (ExceptionCode + ExceptionAddress)
  and, on ARM64, the context at fault (Pc/Sp/Lr/Fp) to diagnose which register is wrong. }
type
  PExceptionRecord = ^TExceptionRecord;
  TExceptionRecord = record
    ExceptionCode: LongWord;
    ExceptionFlags: LongWord;
    ExceptionRecord: PExceptionRecord;
    ExceptionAddress: Pointer;
    NumberParameters: LongWord;
    ExceptionInformation: array[0..14] of PtrUInt;
  end;
  PExceptionPointers = ^TExceptionPointers;
  TExceptionPointers = record
    ExceptionRecord: PExceptionRecord;
    ContextRecord: Pointer;
  end;
  TVectoredHandler = function(excep: PExceptionPointers): LongInt; stdcall;
  { ARM64 Windows CONTEXT layout (match RTL/win64/seh64.inc) so we can read Pc/Sp/Lr/Fp at fault. }
  PArm64Ctx = ^TArm64Ctx;
  TArm64Ctx = record
    ContextFlags: LongWord;
    Cpsr: LongWord;
    X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15,
    X16, X17, X18, X19, X20, X21, X22, X23, X24, X25, X26, X27, X28: QWord;
    Fp, Lr, Sp, Pc: QWord;
  end;

function AddVectoredExceptionHandler(First: DWord; Handler: TVectoredHandler): Pointer;
  external 'kernel32' name 'AddVectoredExceptionHandler';

function LogExceptionVEH(excep: PExceptionPointers): LongInt; stdcall;
var
  ctx: PArm64Ctx;
begin
  if (excep <> nil) and (excep^.ExceptionRecord <> nil) then
  begin
    writeln(stderr, '[VEH] ExceptionCode=$', HexStr(excep^.ExceptionRecord^.ExceptionCode, 8),
      ' ExceptionAddress=$', HexStr(PtrUInt(excep^.ExceptionRecord^.ExceptionAddress), 16));
    if (excep^.ContextRecord <> nil) then
    begin
      ctx := PArm64Ctx(excep^.ContextRecord);
      writeln(stderr, '[VEH] ContextAtFault Pc=$', HexStr(ctx^.Pc, 16), ' Sp=$', HexStr(ctx^.Sp, 16),
        ' Lr=$', HexStr(ctx^.Lr, 16), ' Fp=$', HexStr(ctx^.Fp, 16), ' ContextFlags=$', HexStr(ctx^.ContextFlags, 8));
    end;
    Flush(stderr);
  end;
  Result := 0;  { EXCEPTION_CONTINUE_SEARCH }
end;

procedure DumpFrames(const tag: string);
var
  frames: array[0..31] of CodePointer;
  n, i: longint;
begin
  n := CaptureBacktrace(1, 32, @frames[0]);
  writeln(stderr, 'DEBUG FRAMES [', tag, '] count=', n);
  for i := 0 to n - 1 do
    writeln(stderr, '  ', i, ': ', BackTraceStrFunc(frames[i]));
  Flush(stderr);
end;

procedure TestException;
begin
  DumpFrames('1. TestException entry (before try)');
  try
    writeln('Entering try block...');
    DumpFrames('2. In try block, about to exit');
    exit;
  finally
    writeln('Success: Finally block executed!');
    Flush(Output);
    Flush(stderr);
    DumpFrames('3. In finally block');
  end;
  { First line after try-finally: if we never see this, crash is in RtlUnwindEx or at target. }
  writeln('DEBUG: LANDED at first instr after try-finally');
  Flush(Output);
  Flush(stderr);
  writeln('DEBUG: After finally block in TestException');
  Flush(Output);
  DumpFrames('4. After finally, before return');
  writeln('DEBUG: TestException epilogue (about to ret to main)');
  Flush(Output);
  Flush(stderr);
end;

begin
  AddVectoredExceptionHandler(1, @LogExceptionVEH);  { log any exception (code + address) before other handlers }
  TestException;
  writeln('DEBUG: Back in main (after TestException)');
  Flush(Output);
  Flush(stderr);
  DumpFrames('5. Back in main');
  writeln('DEBUG: After Flush(Output)');
  Flush(Output);
  DumpFrames('6. After Flush');
  writeln('Done.');
  Flush(Output);
end.
