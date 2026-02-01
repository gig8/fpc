{ Bounty Boss test: try...finally + exit.
  When a Pascal program uses try...finally and then Exit (or Break/Continue)
  from inside the try block, the runtime must run the finally block before
  exiting (local unwind). On Windows arm64, incorrect .pdata/unwind info
  causes hang or crash. If this runs and prints "Success: Finally block executed!"
  the compiler has generated correct unwind for this case. }
program arm64trap;
{$mode objfpc}

procedure TestException;
begin
  try
    writeln('Entering try block...');
    exit;
  finally
    writeln('Success: Finally block executed!');
  end;
end;

begin
  TestException;
  writeln('DEBUG: Back in main (after TestException)');  { if missing, crash on return from TestException }
  Flush(Output);
  writeln('DEBUG: After Flush(Output)');                  { if missing, crash in Flush }
  writeln('Done.');
  Flush(Output);
end.
