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
