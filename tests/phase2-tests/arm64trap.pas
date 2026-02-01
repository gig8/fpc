{ Bounty Boss test: try...finally + exit.
  When a Pascal program uses try...finally and then Exit (or Break/Continue)
  from inside the try block, the runtime must run the finally block before
  exiting (local unwind). On Windows arm64, incorrect .pdata/unwind info
  causes hang or crash. If this runs and prints "Success: Finally block executed!"
  the compiler has generated correct unwind for this case. }
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
    DumpFrames('3. In finally block');
  end;
  writeln('DEBUG: After finally block in TestException');  { if missing, crash at RtlUnwindEx transfer or first instr after try }
  DumpFrames('4. After finally, before return');
end;

begin
  TestException;
  writeln('DEBUG: Back in main (after TestException)');  { if missing, crash on return from TestException }
  DumpFrames('5. Back in main');
  Flush(Output);
  writeln('DEBUG: After Flush(Output)');                  { if missing, crash in Flush }
  DumpFrames('6. After Flush');
  writeln('Done.');
  Flush(Output);
end.
