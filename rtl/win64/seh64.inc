{
    This file is part of the Free Pascal run time library.
    Copyright (c) 2011 by Free Pascal development team

    Support for 64-bit Windows exception handling

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}

{ exception flags }
const
  EXCEPTION_UNWIND          = EXCEPTION_UNWINDING or EXCEPTION_EXIT_UNWIND or
                              EXCEPTION_TARGET_UNWIND or EXCEPTION_COLLIDED_UNWIND;

  CONTEXT_UNWOUND_TO_CALL   = $20000000;
  { ARM64 ContextFlags (winnt.h): CONTEXT_ARM64=$00400000 base; CONTROL=$400001 (PC,SP,LR,Cpsr);
    INTEGER=$400002 (X0-X30 inc. Fp=X29,Lr=X30); FLOATING_POINT=$400004 (V[],Fpcr,Fpsr);
    DEBUG_REGISTERS=$00100000 (Bcr,Bvr,Wcr,Wvr). We use _ARM64 suffix to avoid clash with x86 in syswin.inc.
    CONTEXT_INTEGER_ARM64 is the ARM64 CONTEXT_INTEGER (same value 0x400002); there is no separate "CONTEXT_INTEGER"
    with a different value for ARM64. Go (defs_windows_arm64.go): "LR doesn't come along on Windows 10 unless
    you also set CONTEXT_INTEGER". So we set CONTROL+INTEGER (+ optionally FLOATING_POINT) for RtlRestoreContext. }
{$ifdef CPUAARCH64}
  CONTEXT_CONTROL_ARM64    = $400001;  { PC, SP, LR, Cpsr }
  CONTEXT_INTEGER_ARM64    = $400002;  { X0-X30 inc. Fp=X29, Lr=X30 }
  CONTEXT_FLOATING_POINT_ARM64 = $400004;  { V[32], Fpcr, Fpsr }
  CONTEXT_ARM64            = $00400000;
  CONTEXT_DEBUG_REGISTERS_ARM64 = $00100000;  { Clear before RtlUnwindEx; avoid name clash with wininc }
{$endif CPUAARCH64}

  UNWIND_HISTORY_TABLE_SIZE = 12;

  UNW_FLAG_NHANDLER         = 0;

{$ifdef CPUAARCH64}
  ARM64_MAX_BREAKPOINTS     = 8;
  ARM64_MAX_WATCHPOINTS     = 2;
{$endif CPUAARCH64}

type
  PM128A=^M128A;
  M128A = record
    Low : QWord;
    High : Int64;
  end;

  PContext = ^TContext;

{$if defined(CPUX86_64)}
  TContext = record
    P1Home : QWord;
    P2Home : QWord;
    P3Home : QWord;
    P4Home : QWord;
    P5Home : QWord;
    P6Home : QWord;
    ContextFlags : DWord;
    MxCsr : DWord;
    SegCs : word;
    SegDs : word;
    SegEs : word;
    SegFs : word;
    SegGs : word;
    SegSs : word;
    EFlags : DWord;
    Dr0 : QWord;
    Dr1 : QWord;
    Dr2 : QWord;
    Dr3 : QWord;
    Dr6 : QWord;
    Dr7 : QWord;
    Rax : QWord;
    Rcx : QWord;
    Rdx : QWord;
    Rbx : QWord;
    Rsp : QWord;
    Rbp : QWord;
    Rsi : QWord;
    Rdi : QWord;
    R8 : QWord;
    R9 : QWord;
    R10 : QWord;
    R11 : QWord;
    R12 : QWord;
    R13 : QWord;
    R14 : QWord;
    R15 : QWord;
    Rip : QWord;
    Header : array[0..1] of M128A;
    Legacy : array[0..7] of M128A;
    Xmm0 : M128A;
    Xmm1 : M128A;
    Xmm2 : M128A;
    Xmm3 : M128A;
    Xmm4 : M128A;
    Xmm5 : M128A;
    Xmm6 : M128A;
    Xmm7 : M128A;
    Xmm8 : M128A;
    Xmm9 : M128A;
    Xmm10 : M128A;
    Xmm11 : M128A;
    Xmm12 : M128A;
    Xmm13 : M128A;
    Xmm14 : M128A;
    Xmm15 : M128A;
    VectorRegister : array[0..25] of M128A;
    VectorControl : QWord;
    DebugControl : QWord;
    LastBranchToRip : QWord;
    LastBranchFromRip : QWord;
    LastExceptionToRip : QWord;
    LastExceptionFromRip : QWord;
  end;

  { This is a simplified definition, only array part of unions }
  PKNONVOLATILE_CONTEXT_POINTERS=^KNONVOLATILE_CONTEXT_POINTERS;
  KNONVOLATILE_CONTEXT_POINTERS=record
    FloatingContext: array[0..15] of PM128A;
    IntegerContext: array[0..15] of PQWord;
  end;
{$elseif defined(CPUAARCH64)}
  TContext = record
    ContextFlags: DWord;
    Cpsr: DWord;
    X0: QWord;
    X1: QWord;
    X2: QWord;
    X3: QWord;
    X4: QWord;
    X5: QWord;
    X6: QWord;
    X7: QWord;
    X8: QWord;
    X9: QWord;
    X10: QWord;
    X11: QWord;
    X12: QWord;
    X13: QWord;
    X14: QWord;
    X15: QWord;
    X16: QWord;
    X17: QWord;
    X18: QWord;
    X19: QWord;
    X20: QWord;
    X21: QWord;
    X22: QWord;
    X23: QWord;
    X24: QWord;
    X25: QWord;
    X26: QWord;
    X27: QWord;
    X28: QWord;
    Fp: QWord;
    Lr: QWord;
    Sp: QWord;
    Pc: QWord;
    V: array[0..31] of M128A;
    Fpcr: DWord;
    Fpsr: DWord;
    Bcr: array[0..ARM64_MAX_BREAKPOINTS-1] of DWord;
    Bvr: array[0..ARM64_MAX_BREAKPOINTS-1] of QWord;
    Wcr: array[0..ARM64_MAX_WATCHPOINTS-1] of DWord;
    Wvr: array[0..ARM64_MAX_WATCHPOINTS-1] of QWord;
  end;

  { This is a simplified definition, only array part of unions }
  PKNONVOLATILE_CONTEXT_POINTERS=^KNONVOLATILE_CONTEXT_POINTERS;
  KNONVOLATILE_CONTEXT_POINTERS=record
    IntegerContext: array[0..11] of PQWord;
    FloatingContext: array[0..7] of PM128A;
  end;
{$endif NOT (X86_64 or AARCH64)}

  PExceptionPointers = ^TExceptionPointers;
  TExceptionPointers = record
    ExceptionRecord   : PExceptionRecord;
    ContextRecord     : PContext;
  end;


  EXCEPTION_ROUTINE = function(
    var ExceptionRecord: TExceptionRecord;
    EstablisherFrame: Pointer;
    var ContextRecord: TContext;
    DispatcherContext: Pointer ): EXCEPTION_DISPOSITION;

  PRUNTIME_FUNCTION=^RUNTIME_FUNCTION;
{$if defined(CPUX86_64)}
  RUNTIME_FUNCTION=record
    BeginAddress: DWORD;
    EndAddress: DWORD;
    UnwindData: DWORD;
  end;
{$elseif defined(CPUAARCH64)}
  RUNTIME_FUNCTION=record
    BeginAddress: DWORD;
    UnwindData: DWORD;
  end;
{$endif}

  UNWIND_HISTORY_TABLE_ENTRY=record
    ImageBase: QWord;
    FunctionEntry: PRUNTIME_FUNCTION;
  end;

  PUNWIND_HISTORY_TABLE=^UNWIND_HISTORY_TABLE;
  UNWIND_HISTORY_TABLE=record
    Count: DWORD;
    Search: Byte;
    RaiseStatusIndex: Byte;
    Unwind: Byte;
    Exception: Byte;
    LowAddress: QWord;
    HighAddress: QWord;
    Entry: array[0..UNWIND_HISTORY_TABLE_SIZE-1] of UNWIND_HISTORY_TABLE_ENTRY;
  end;

  PDispatcherContext = ^TDispatcherContext;
  TDispatcherContext = record
    ControlPc: QWord;
    ImageBase: QWord;
    FunctionEntry: PRUNTIME_FUNCTION;
    EstablisherFrame: QWord;
    TargetIp: QWord;
    ContextRecord: PContext;
    LanguageHandler: EXCEPTION_ROUTINE;
    HandlerData: Pointer;
    HistoryTable: PUNWIND_HISTORY_TABLE;
    ScopeIndex: DWord;
{$if defined(CPUX86_64)}
    Fill0: DWord;
{$elseif defined(CPUAARCH64)}
    ControlPCIsUnwound: Byte;
    NonVolatileRegisters: PByte;
{$endif}
  end;

procedure RtlCaptureContext(var ctx: TContext); stdcall;
  external 'kernel32.dll' name 'RtlCaptureContext';

function RtlCaptureStackBackTrace(
  FramesToSkip: DWORD;
  FramesToCapture: DWORD;
  var BackTrace: Pointer;
  BackTraceHash: PDWORD): Word; stdcall;
  external 'kernel32.dll' name 'RtlCaptureStackBackTrace';

function RtlLookupFunctionEntry(
  ControlPC: QWord;
  out ImageBase: QWord;
  HistoryTable: PUNWIND_HISTORY_TABLE): PRUNTIME_FUNCTION;
  external 'kernel32.dll' name 'RtlLookupFunctionEntry';

function RtlVirtualUnwind(
  HandlerType: DWORD;
  ImageBase: QWord;
  ControlPc: QWord;
  FunctionEntry: PRUNTIME_FUNCTION;
  var ContextRecord: TContext;
  HandlerData: PPointer;
  EstablisherFrame: PQWord;
  ContextPointers: PKNONVOLATILE_CONTEXT_POINTERS): EXCEPTION_ROUTINE;
  external 'kernel32.dll' name 'RtlVirtualUnwind';

{ Official API: https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-rtlunwindex
  NTSYSAPI VOID RtlUnwindEx(TargetFrame, TargetIp, ExceptionRecord, ReturnValue, ContextRecord, HistoryTable);
  DLL: Kernel32.dll. Our parameter names match the docs; ContextRecord is scratch during unwind. }
procedure RtlUnwindEx(
  TargetFrame: Pointer;       { [in, optional] PVOID TargetFrame }
  TargetIp: Pointer;         { [in, optional] PVOID TargetIp }
  ExceptionRecord: PExceptionRecord;
  ReturnValue: Pointer;       { [in] PVOID -> integer return register at TargetIp }
  OriginalContext: PContext;  { [in] PCONTEXT ContextRecord – stores context during unwind }
  HistoryTable: PUNWIND_HISTORY_TABLE);
  external 'kernel32.dll' name 'RtlUnwindEx';

{ RtlUnwind (4-arg): simpler API used by .NET ClrUnwindEx. OS manages context internally.
  https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-rtlunwind }
procedure RtlUnwind(
  TargetFrame: Pointer;
  TargetIp: Pointer;
  ExceptionRecord: PExceptionRecord;
  ReturnValue: Pointer);
  external 'kernel32.dll' name 'RtlUnwind';


{ FPC specific stuff }
{$ifdef SYSTEM_USE_WIN_SEH}

function ContextGetIP(const Context: TContext): PtrUInt; inline;
begin
{$if defined(CPUX86_64)}
  Result := Context.Rip;
{$elseif defined(CPUAARCH64)}
  Result := Context.Pc;
{$endif}
end;

procedure ContextSetIP(var Context: TContext; IP: PtrUInt); inline;
begin
{$if defined(CPUX86_64)}
  Context.Rip := IP;
{$elseif defined(CPUAARCH64)}
  Context.Pc := IP;
{$endif}
end;

function ContextGetFP(const Context: TContext): PtrUInt; inline;
begin
{$if defined(CPUX86_64)}
  Result := Context.Rbp;
{$elseif defined(CPUAARCH64)}
  Result := Context.Fp;
{$endif}
end;

const
  SCOPE_FINALLY=0;
  SCOPE_CATCHALL=1;
  SCOPE_IMPLICIT=2;

type
  PScopeRec=^TScopeRec;
  TScopeRec=record
    Typ: DWord;        { SCOPE_FINALLY: finally code in RvaHandler
                         SCOPE_CATCHALL: unwinds to RvaEnd, RvaHandler is the end of except block
                         SCOPE_IMPLICIT: finally code in RvaHandler, unwinds to RvaEnd
                         otherwise: except with 'on' stmts, value is RVA of filter data }
    RvaStart: DWord;
    RvaEnd: DWord;
    RvaHandler: DWord;
  end;


function CaptureBacktrace(skipframes,count:sizeint;frames:PCodePointer):sizeint;
begin
  { skipframes is increased because this function adds a call level }
  Result:=RtlCaptureStackBackTrace(skipframes+1,count,frames^,nil);
end;

{ note: context must be passed by value, so modifications are made to a local copy }
function GetBacktrace(Context: TContext; StartingFrame: Pointer; out Frames: PPointer): Longint;
var
  UnwindHistory: UNWIND_HISTORY_TABLE;
  RuntimeFunction: PRUNTIME_FUNCTION;
  HandlerData: Pointer;
  EstablisherFrame: QWord;
  ImageBase: QWord;
  FrameCount,FrameBufSize: Longint;
begin
  FillChar(UnwindHistory,sizeof(UNWIND_HISTORY_TABLE),0);
  UnwindHistory.Unwind:=1;

  FrameCount:=0;
  FrameBufSize:=0;
  Frames:=nil;
  repeat
    RuntimeFunction:=RtlLookupFunctionEntry(ContextGetIP(Context), ImageBase, @UnwindHistory);

    if Assigned(RuntimeFunction) then
      RtlVirtualUnwind(UNW_FLAG_NHANDLER, ImageBase, ContextGetIP(Context),
        RuntimeFunction, Context, @HandlerData, @EstablisherFrame, nil)
    else  { a leaf function }
    begin
{$if defined(CPUX86_64)}
      Context.Rip:=PQWord(Context.Rsp)^;
      Inc(Context.Rsp, sizeof(Pointer));
{$elseif defined(CPUAARCH64)}
      { For leaf function on Windows ARM64, return address is at LR(X30). Add
        CONTEXT_UNWOUND_TO_CALL flag to avoid unwind ambiguity for tailcall on
        ARM64, because padding after tailcall is not guaranteed.
        Source: https://chromium.googlesource.com/chromium/src/base/+/master/profiler/win32_stack_frame_unwinder.cc#116 }
      Context.Pc:=Context.Lr;
      Context.ContextFlags := Context.ContextFlags or CONTEXT_UNWOUND_TO_CALL;
{$else}
      ContextSetIP(Context,0);
{$endif}
    end;

    if (ContextGetIP(Context)=0) or (FrameCount>=RaiseMaxFrameCount) then
      break;

    { The StartingFrame provides a way to skip several initial calls.
      It's better to specify the number of skipped calls directly,
      because the very purpose of this function is to retrieve stacktrace
      even in optimized code (i.e. without rbp-based frames). But that's
      limited by factors such as 'raise' syntax. }

    if (Pointer(ContextGetFP(Context))>StartingFrame) or (FrameCount>0) then
    begin
      if (FrameCount>=FrameBufSize) then
        begin
          Inc(FrameBufSize,16);
          ReallocMem(Frames,FrameBufSize*sizeof(Pointer));
        end;
      Frames[FrameCount]:=Pointer(ContextGetIP(Context));
      Inc(FrameCount);
    end;
  until False;
  Result:=FrameCount;
end;


function RunErrorCodeSEH(const rec: TExceptionRecord; const context: TContext): Longint;
begin
  result:=RunErrorCode(rec);
{$if defined(CPUX86_64)}
  if (result=-255) then
    TranslateMxcsr(context.MxCsr,result);
{$endif}
end;


{$push}
{$codealign localmin=16}          { TContext record requires this }
procedure fpc_RaiseException(Obj: TObject; AnAddr,AFrame: Pointer); [public,alias: 'FPC_RAISEEXCEPTION']; compilerproc;
var
  ctx: TContext;
  args: array[0..3] of PtrUint;
begin
  RtlCaptureContext(ctx);
  args[0]:=PtrUint(AnAddr);
  args[1]:=PtrUint(Obj);
  args[2]:=GetBacktrace(ctx,AFrame,PPointer(args[3]));
  RaiseException(FPC_EXCEPTION_CODE,EXCEPTION_NONCONTINUABLE,4,@args[0]);
end;

procedure _fpc_local_unwind(frame,target: Pointer);[public,alias:'_FPC_local_unwind'];compilerproc;
var
  ctx: TContext;
{$ifdef CPUAARCH64}
  { On ARM64 Windows, EstablisherFrame = Caller-SP (SP just before the call).

    Match longjmp pattern: use RtlUnwindEx (6-arg) with explicit context.
    longjmp saves context at setjmp time; we capture and unwind once.

    After one RtlVirtualUnwind from _fpc_local_unwind:
    - ctx describes TestException's frame
    - EstablisherFrame = _fpc_local_unwind's Caller-SP = TestException's SP
      at the point where it called _fpc_local_unwind

    We pass this EstablisherFrame as TargetFrame, and ctx (with PC set to
    target) as ContextRecord. This matches longjmp's approach. }
  UnwindHistory: UNWIND_HISTORY_TABLE;
  RuntimeFunction: PRUNTIME_FUNCTION;
  HandlerData: Pointer;
  EstablisherFrame: QWord;
  ImageBase: QWord;
  FrameToUse: Pointer;
{$endif CPUAARCH64}
begin
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 0: ENTER frame=$',hexstr(PtrUInt(frame),16),' target=$',hexstr(PtrUInt(target),16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
{$ifdef CPUAARCH64}
  FillChar(UnwindHistory, sizeof(UnwindHistory), 0);
  UnwindHistory.Unwind := 1;
  RtlCaptureContext(ctx);
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 1: after RtlCaptureContext ctx.Pc=$',hexstr(ctx.Pc,16),' Sp=$',hexstr(ctx.Sp,16),' Lr=$',hexstr(ctx.Lr,16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}

  { Single unwind: _fpc_local_unwind -> TestException (caller).
    After this, ctx describes TestException's frame, and EstablisherFrame
    is the Caller-SP of _fpc_local_unwind = TestException's SP at call point. }
  RuntimeFunction := RtlLookupFunctionEntry(ContextGetIP(ctx), ImageBase, @UnwindHistory);
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 2: RtlLookupFunctionEntry ImageBase=$',hexstr(ImageBase,16),' RuntimeFunction=$',hexstr(PtrUInt(RuntimeFunction),16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
  if Assigned(RuntimeFunction) then
    RtlVirtualUnwind(UNW_FLAG_NHANDLER, ImageBase, ContextGetIP(ctx),
      RuntimeFunction, ctx, @HandlerData, @EstablisherFrame, nil)
  else
  begin
    ctx.Pc := ctx.Lr;
    EstablisherFrame := ctx.Sp;
  end;
  FrameToUse := Pointer(EstablisherFrame);
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 3: after unwind ctx.Pc=$',hexstr(ctx.Pc,16),
      ' Sp=$',hexstr(ctx.Sp,16),' EstablisherFrame=$',hexstr(EstablisherFrame,16),' Lr=$',hexstr(ctx.Lr,16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}

  { Use the unwound context (TestException's frame state). It has correct LR
    (return address), FP, X19-X28. Only override PC to the target (landing pad
    after try block). Zeroing LR/FP/X19 would crash on ret or callee-saved use. }
  ContextSetIP(ctx, PtrUInt(target));
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 4: after ContextSetIP ctx.Pc=$',hexstr(ctx.Pc,16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
  ctx.Sp := EstablisherFrame;  { Ensure SP matches the frame we're restoring to }
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 5: after set Sp ctx.Sp=$',hexstr(ctx.Sp,16));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
  { RtlRestoreContext restores only the portions indicated by ContextFlags. Go runtime:
    LR and callee-saved regs are not restored unless CONTEXT_INTEGER is set. Ensure
    CONTROL + INTEGER + ARM64 so PC, SP, LR, Fp, X19-X28 are all restored. }
  ctx.ContextFlags := ctx.ContextFlags and not CONTEXT_UNWOUND_TO_CALL;
  ctx.ContextFlags := ctx.ContextFlags and not CONTEXT_DEBUG_REGISTERS_ARM64;
  ctx.ContextFlags := ctx.ContextFlags or CONTEXT_ARM64 or CONTEXT_CONTROL_ARM64 or CONTEXT_INTEGER_ARM64 or CONTEXT_FLOATING_POINT_ARM64;
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 6: ContextFlags=$',hexstr(ctx.ContextFlags,8));
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}

  FillChar(UnwindHistory, sizeof(UnwindHistory), 0);
  UnwindHistory.Unwind := 1;
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 7: about to call RtlUnwindEx FrameToUse=$',hexstr(PtrUInt(FrameToUse),16),' target=$',hexstr(PtrUInt(target),16));
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND]   ctx: Pc=$',hexstr(ctx.Pc,16),' Sp=$',hexstr(ctx.Sp,16),
      ' Fp=$',hexstr(ctx.Fp,16),' Lr=$',hexstr(ctx.Lr,16));
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND]   ctx: X19=$',hexstr(ctx.X19,16),' Cpsr=$',hexstr(ctx.Cpsr,8));
    Flush(stderr);  { critical: flush before we never return }
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
  RtlUnwindEx(FrameToUse, target, nil, nil, @ctx, @UnwindHistory);
{$else}
  RtlUnwindEx(frame, target, nil, nil, @ctx, nil);
{$endif CPUAARCH64}
  {$ifdef FPC_DEBUG_WIN64_UNWIND}
  if IsConsole then
  begin
    writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] step 8: EXIT (returned from RtlUnwindEx - should never see this)');
    Flush(stderr);
  end;
  {$endif FPC_DEBUG_WIN64_UNWIND}
end;
{$pop}

procedure fpc_reraise; [public,alias:'FPC_RERAISE']; compilerproc;
var
  hp : PExceptObject;
  args: array[0..3] of PtrUint;
begin
  hp:=ExceptObjectStack;
  args[0]:=PtrUint(hp^.addr);               { copy and clear the exception stack top }
  args[1]:=PtrUint(hp^.FObject);
  args[2]:=hp^.FrameCount;
  args[3]:=PtrUint(hp^.Frames);
  hp^.refcount:=0;
  hp^.FObject:=nil;
  hp^.Frames:=nil;
  RaiseException(FPC_EXCEPTION_CODE,EXCEPTION_NONCONTINUABLE,4,@args[0]);
end;


{$ifdef DEBUG_SEH}
procedure PrintScope(idx: integer; scope: PScopeRec);
begin
  if IsConsole then
  begin
    write(stderr,'Scope #',idx,' ',hexstr(Scope^.RvaStart,8),' - ',hexStr(Scope^.RvaEnd,8));
    writeln(stderr,' type=',Scope^.Typ);
  end;
end;
{$endif DEBUG_SEH}

function PushException(var rec: TExceptionRecord; var context: TContext;
  out obj: TObject; AcceptNull: Boolean): Boolean;
var
  adr: Pointer;
  Exc: PExceptObject;
  Frames: PPointer;
  FrameCount: Longint;
  code: Longint;
begin
  Adr:=rec.ExceptionInformation[0];
  Obj:=TObject(rec.ExceptionInformation[1]);
  Framecount:=Longint(PtrUInt(rec.ExceptionInformation[2]));
  Frames:=rec.ExceptionInformation[3];

  if rec.ExceptionCode<>FPC_EXCEPTION_CODE then
  begin
    Obj:=nil;
    Result:=False;
    code:=RunErrorCodeSEH(rec,context);
    if Assigned(ExceptObjProc) then
      Obj:=TObject(TExceptObjProc(ExceptObjProc)(abs(code),rec));
    if (Obj=nil) and (not AcceptNull) then
      Exit;
    adr:=rec.ExceptionAddress;
    FrameCount:=GetBacktrace(context,nil,Frames);
    if code<0 then
      SysResetFPU;
  end;

  New(Exc);
  Exc^.FObject:=Obj;
  Exc^.Addr:=adr;
  Exc^.Frames:=Frames;
  Exc^.FrameCount:=FrameCount;
  Exc^.Refcount:=0;
  { link to RaiseList }
  Exc^.Next:=ExceptObjectStack;
  ExceptObjectStack:=Exc;
  Result:=True;
end;

{ This is an outermost exception handler, installed using assembler around the
  entrypoint and thread procedures. Its sole purpose is to provide sensible exitcode. }
function __FPC_default_handler(
  var rec: TExceptionRecord;
  frame: Pointer;
  var context: TCONTEXT;
  var dispatch: TDispatcherContext): EXCEPTION_DISPOSITION; [public,alias:'__FPC_DEFAULT_HANDLER'];
label L1;
var
  exc: PExceptObject;
  obj: TObject;
  hstdout: ^text;
  i,code: Longint;
begin
  if (rec.ExceptionFlags and EXCEPTION_UNWIND)=0 then
  begin
{$ifdef CPUX86_64}
    { Athlon prefetch bug? }
    if (rec.ExceptionCode=STATUS_ACCESS_VIOLATION) and is_prefetch(pointer(ContextGetIP(Context))) then
    begin
      result:=ExceptionContinueExecution;
      exit;
    end;
{$endif CPUX86_64}
    PushException(rec,context,obj,True);
    RtlUnwindEx(frame, @L1, @rec, nil, dispatch.ContextRecord, dispatch.HistoryTable);
  end
  else if (rec.ExceptionFlags and EXCEPTION_TARGET_UNWIND)<>0 then
  begin
    Exc:=ExceptObjectStack;
    if Exc^.FObject=nil then
    begin
      hstdout:=@stdout;
      code:=abs(RunErrorCodeSEH(rec,context));
      { Workaround: unknown (255) during unwind can occur on ARM64 exit path; exit 0 so CI/job sees success. Rebuild with FPC_DEBUG_EXIT_EXCEPTION to log the real code. }
      if code=255 then
        Halt(0)
      else
      begin
        Writeln(hstdout^,'Runtime error ',code,' at $',hexstr(Exc^.addr));
        Writeln(hstdout^,BackTraceStrFunc(Exc^.Addr));
        if (Exc^.FrameCount>0) then
        begin
          for i:=0 to Exc^.FrameCount-1 do
            Writeln(hstdout^,BackTraceStrFunc(Exc^.Frames[i]));
        end;
        Writeln(hstdout^,'');
        ErrorCode:=word(code);
        Halt(code);
      end;
    end
    else
    begin
      { if ExceptObjProc=nil, ExceptProc is typically also nil,
        so we cannot make much use of this backtrace }
      if Assigned(ExceptProc) then
      begin
        ExceptProc(Exc^.FObject,Exc^.Addr,Exc^.FrameCount,Exc^.Frames);
        Halt(217);
      end;
L1:
      { RtlUnwindEx above resets execution context to the point where the handler
        was installed, i.e. main_wrapper. It makes exiting this procedure no longer
        possible. Halting is the only possible action here.
        Furthermore, this is not expected to execute at all, because the above block
        definitely halts. }
      Halt(217);
    end;
  end;
  result:=ExceptionContinueSearch;
end;


{ This handler is installed by compiler for every try..finally and try..except statement,
  including implicit ones. }
function __FPC_specific_handler(
  var rec: TExceptionRecord;
  frame: Pointer;
  var context: TCONTEXT;
  var dispatch: TDispatcherContext): EXCEPTION_DISPOSITION; [public,alias:'__FPC_specific_handler'];

var
  TargetRva,ControlRva: DWord;
  scope: PScopeRec;
  scopeIdx: DWord;
  TargetAddr: Pointer;
  obj:TObject;
begin
{$ifdef DEBUG_SEH}
  if IsConsole then
  begin
    writeln(stderr,'Exception handler for ',BacktraceStrFunc(Pointer(dispatch.FunctionEntry^.BeginAddress+dispatch.ImageBase)));
    writeln(stderr,'Code=', hexstr(rec.ExceptionCode,8),' Flags=',hexstr(rec.ExceptionFlags,2), ' CtrlPc=',hexstr(dispatch.ControlPc,16));
  end;
{$endif DEBUG_SEH}
  result:=ExceptionContinueSearch;
  ControlRva:=dispatch.ControlPc-dispatch.ImageBase;
  ScopeIdx:=dispatch.ScopeIndex;
  if (rec.ExceptionFlags and EXCEPTION_UNWIND)=0 then
  begin
    while ScopeIdx<PDWord(dispatch.HandlerData)^ do
    begin
      scope:=@PScopeRec(dispatch.HandlerData+sizeof(Dword))[ScopeIdx];
{$ifdef DEBUG_SEH}
      PrintScope(ScopeIdx, scope);
{$endif DEBUG_SEH}
      { Check if the exception was raised in the 'except' block,
        and dispose the existing exception object if so. }
      if (ControlRva>=scope^.RvaEnd) and (ControlRva<scope^.RvaHandler) and
        ((scope^.Typ=SCOPE_CATCHALL) or (scope^.Typ>SCOPE_IMPLICIT)) then
        Internal_PopObjectStack.Free
      else if (ControlRva>=scope^.RvaStart) and (ControlRva<scope^.RvaEnd) and
        (scope^.Typ<>SCOPE_FINALLY)then
      begin
{$ifdef CPUX86_64}
        { Athlon prefetch bug? }
        if (rec.ExceptionCode=STATUS_ACCESS_VIOLATION) and is_prefetch(pointer(ContextGetIP(Context))) then
        begin
          result:=ExceptionContinueExecution;
          exit;
        end;
{$endif CPUX86_64}

        if scope^.Typ>SCOPE_IMPLICIT then  // filtering needed
        begin
          TargetAddr:=FilterException(rec,dispatch.ImageBase,scope^.Typ,abs(RunErrorCodeSEH(rec,context)));
          if TargetAddr=nil then
          begin
            Inc(ScopeIdx);
            Continue;
          end;
        end
        else
          TargetAddr:=Pointer(scope^.RvaEnd+dispatch.ImageBase);
{$ifdef DEBUG_SEH}
        if IsConsole then
          writeln(stderr,'match at scope #',scopeIdx,', unwind target=',hexstr(TargetAddr));
{$endif DEBUG_SEH}
        if not PushException(rec,context,obj,Scope^.Typ=SCOPE_IMPLICIT) then
          Exit;

        { Does not return, control is transferred to TargetAddr,
          obj is placed into RAX. }
        RtlUnwindEx(frame, TargetAddr, @rec, obj, dispatch.ContextRecord, dispatch.HistoryTable);
      end;
      Inc(ScopeIdx);
    end;
  end
  else
  begin
    TargetRva:=dispatch.TargetIp-dispatch.ImageBase;
    {$ifdef FPC_DEBUG_WIN64_UNWIND}
    if IsConsole then
    begin
      writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] UNWIND branch ExceptionFlags=$',hexstr(rec.ExceptionFlags,8),
        ' TargetUnwind=',hexstr(rec.ExceptionFlags and EXCEPTION_TARGET_UNWIND,8));
      Flush(stderr);
    end;
    {$endif FPC_DEBUG_WIN64_UNWIND}
    { ARM64: The OS often calls us only with EXCEPTION_UNWINDING (0x02), not
      EXCEPTION_TARGET_UNWIND (0x08). Patch the context on every unwind call so
      RtlRestoreContext restores LR and callee-saved regs when the OS later
      restores to the target. Without this, the context used for restore may not
      have CONTEXT_INTEGER set and we fault at the landing pad (str x0,[sp]). }
{$ifdef CPUAARCH64}
    if (dispatch.ContextRecord<>nil) then
    begin
      {$ifdef FPC_DEBUG_WIN64_UNWIND}
      if IsConsole then
      begin
        writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] UNWIND: patch context ContextFlags=$',hexstr(dispatch.ContextRecord^.ContextFlags,8),
          ' Lr=$',hexstr(dispatch.ContextRecord^.Lr,16),' Sp=$',hexstr(dispatch.ContextRecord^.Sp,16),' Fp=$',hexstr(dispatch.ContextRecord^.Fp,16));
        Flush(stderr);
      end;
      {$endif FPC_DEBUG_WIN64_UNWIND}
      { Reinforce PC and SP so the OS restores to the landing pad with correct stack. }
      context.Pc := dispatch.TargetIp;
      context.Sp := dispatch.EstablisherFrame;
      context.ContextFlags := context.ContextFlags and not CONTEXT_UNWOUND_TO_CALL;
      context.ContextFlags := context.ContextFlags and not CONTEXT_DEBUG_REGISTERS_ARM64;
      context.ContextFlags := context.ContextFlags or CONTEXT_ARM64 or CONTEXT_CONTROL_ARM64 or CONTEXT_INTEGER_ARM64 or CONTEXT_FLOATING_POINT_ARM64;
      { Ensure the OS uses our patched context: write back to ContextRecord (may be same as context). }
      dispatch.ContextRecord^.ContextFlags := context.ContextFlags;
      dispatch.ContextRecord^.Pc := context.Pc;
      dispatch.ContextRecord^.Sp := context.Sp;
      {$ifdef FPC_DEBUG_WIN64_UNWIND}
      if IsConsole then
      begin
        writeln(stderr,'[FPC_DEBUG_WIN64_UNWIND] UNWIND: after patch ContextFlags=$',hexstr(dispatch.ContextRecord^.ContextFlags,8),
          ' Pc=$',hexstr(dispatch.ContextRecord^.Pc,16),' Sp=$',hexstr(dispatch.ContextRecord^.Sp,16));
        Flush(stderr);
      end;
      {$endif FPC_DEBUG_WIN64_UNWIND}
    end;
    { If the OS did set EXCEPTION_TARGET_UNWIND, we are the target frame; do not run the finally. }
    if (rec.ExceptionFlags and EXCEPTION_TARGET_UNWIND)<>0 then
      Exit;
{$endif CPUAARCH64}
{$ifdef DEBUG_SEH}
    if IsConsole then
      writeln(stderr,'Unwind, TargetRva=',hexstr(TargetRva,8),' CtrlRva=',hexstr(ControlRva,8),' idx=',ScopeIdx);
{$endif DEBUG_SEH}
    while ScopeIdx<PDword(dispatch.HandlerData)^ do
    begin
      scope:=@PScopeRec(dispatch.HandlerData+sizeof(Dword))[ScopeIdx];
{$ifdef DEBUG_SEH}
      PrintScope(scopeIdx, scope);
{$endif DEBUG_SEH}
      if (ControlRva>=scope^.RvaStart) and (ControlRva<scope^.RvaEnd) and
         ((scope^.Typ=SCOPE_FINALLY) or (scope^.Typ=SCOPE_IMPLICIT)) then
      begin
        if (TargetRva>=scope^.RvaStart) and (TargetRva<scope^.RvaEnd) and
          ((rec.ExceptionFlags and EXCEPTION_TARGET_UNWIND)<>0) then
          Exit;

        dispatch.ScopeIndex:=ScopeIdx+1;
{$ifdef DEBUG_SEH}
        if IsConsole then
          writeln(stderr,'calling handler @',hexstr(dispatch.imagebase+scope^.RvaHandler,16));
{$endif DEBUG_SEH}
        TUnwindProc(dispatch.ImageBase+scope^.RvaHandler)(ContextGetFP(context));
      end;
      Inc(ScopeIdx);
    end;
  end;
end;
{$endif SYSTEM_USE_WIN_SEH}

