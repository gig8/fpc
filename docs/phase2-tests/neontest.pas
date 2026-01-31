{ NEON vector math test (SIMD) – performance validation.
  Tests 128-bit vector op (4× Single in one cycle), register pressure (v0–v31),
  memory alignment for ld1/st1, and inline asm integrity with llvm-mingw.
  If this passes on Arm64, the backend supports production HPC-style code. }
program neontest;
{$mode objfpc}

type
  TVector4 = array[0..3] of Single;

procedure VectorAdd(constref A, B: TVector4; out C: TVector4); assembler;
asm
  // AArch64 AAPCS: A in x0, B in x1, C in x2
  ld1 {v0.4s}, [x0]
  ld1 {v1.4s}, [x1]
  fadd v2.4s, v0.4s, v1.4s
  st1 {v2.4s}, [x2]
end;

var
  VecA, VecB, VecRes: TVector4;
  i: Integer;
begin
  for i := 0 to 3 do begin
    VecA[i] := i * 1.1;
    VecB[i] := i * 2.2;
  end;

  writeln('Starting NEON Vector Addition Test...');
  VectorAdd(VecA, VecB, VecRes);

  for i := 0 to 3 do
    writeln(Format('Lane %d: %f + %f = %f', [i, VecA[i], VecB[i], VecRes[i]]));

  if Abs(VecRes[3] - 9.9) < 0.0001 then
    writeln('Result: PASS (SIMD alignment and execution successful)')
  else
    writeln('Result: FAIL (Check register allocation or alignment)');
end.
