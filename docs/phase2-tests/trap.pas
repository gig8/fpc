program trap;
{$mode objfpc}
uses sysutils;
procedure Level2;
begin
  raise Exception.Create('The Unwind Trap');
end;
begin
  try
    Level2;
  except
    on E: Exception do Writeln('Caught: ', E.Message);
  end;
end.
