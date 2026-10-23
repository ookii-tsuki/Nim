# N# standard library: the System.Diagnostics namespace. Imported by
# `using System.Diagnostics;`.
#
# `Stopwatch` is a class over the monotonic clock, whose ticks are nanoseconds
# (`Frequency` is 1e9, as .NET's on Linux). `Debug` is a static class whose
# members .NET compiles only into a DEBUG build; here they run unless the program
# is built with `-d:release`, writing to stderr, so stdout reads the same either way.
#
# Pinned surface (SPEC section 15.4):
#
#   Stopwatch   Elapsed ElapsedMilliseconds ElapsedTicks Frequency GetTimestamp
#               IsHighResolution IsRunning Reset Restart Start StartNew Stop
#   Debug       Assert Write WriteLine
#
# Deliberately absent: `Process`, `Trace`, listeners, `Debugger`, `StackTrace`.

import std/[monotimes, syncio]
import ../System
from ../../nsharp/pragmas import nsHidden
from ../../nsharp/intrinsics import ToString, nsTypeName, Type, nsTypeNamed

{.push discardable.}

type
  Stopwatch* = ref object of RootObj
    ## `System.Diagnostics.Stopwatch`.
    nsStarted: int64   ## the clock when started, while running
    nsElapsed: int64   ## nanoseconds of the intervals already stopped
    nsRunning: bool
  Debug* = object
    ## `System.Diagnostics.Debug`: its members are static.

method ToString*(s: Stopwatch): string = "System.Diagnostics.Stopwatch"
method nsTypeName*(s: Stopwatch): string {.nsHidden.} = "System.Diagnostics.Stopwatch"
proc nsTypeOf*(t: typedesc[Stopwatch]): Type {.nsHidden.} = nsTypeNamed("System.Diagnostics.Stopwatch")

proc nsNow(): int64 = getMonoTime().ticks

proc newStopwatch*(): Stopwatch {.nsHidden.} = Stopwatch()

template Frequency*(t: typedesc[Stopwatch]): int64 = 1_000_000_000'i64
template IsHighResolution*(t: typedesc[Stopwatch]): bool = true
proc GetTimestamp*(t: typedesc[Stopwatch]): int64 = nsNow()

proc Start*(s: Stopwatch) =
  if not s.nsRunning:
    s.nsStarted = nsNow()
    s.nsRunning = true
proc StartNew*(t: typedesc[Stopwatch]): Stopwatch =
  result = Stopwatch()
  result.Start()
proc Stop*(s: Stopwatch) =
  if s.nsRunning:
    s.nsElapsed += nsNow() - s.nsStarted
    s.nsRunning = false
proc Reset*(s: Stopwatch) =
  s.nsElapsed = 0
  s.nsRunning = false
proc Restart*(s: Stopwatch) =
  s.nsElapsed = 0
  s.nsStarted = nsNow()
  s.nsRunning = true
proc IsRunning*(s: Stopwatch): bool = s.nsRunning
proc ElapsedTicks*(s: Stopwatch): int64 =
  ## In `Frequency` units: nanoseconds.
  s.nsElapsed + (if s.nsRunning: nsNow() - s.nsStarted else: 0)
proc Elapsed*(s: Stopwatch): TimeSpan = newTimeSpan(s.ElapsedTicks div 100)
proc ElapsedMilliseconds*(s: Stopwatch): int64 = s.ElapsedTicks div 1_000_000

proc nsDebugFail(message: string) {.noinline.} =
  ## A failed assertion ends the program, as .NET's does without a debugger.
  flushFile(stdout)
  stderr.write "Process terminated. Assertion failed.\n"
  if message.len > 0: stderr.write message & "\n"
  flushFile(stderr)
  quit(134)

proc Assert*(t: typedesc[Debug]; condition: bool) =
  when not defined(release):
    if not condition: nsDebugFail("")
proc Assert*(t: typedesc[Debug]; condition: bool; message: string) =
  when not defined(release):
    if not condition: nsDebugFail(message)
proc WriteLine*[T](t: typedesc[Debug]; value: T) =
  when not defined(release): stderr.write $value & "\n"
proc Write*[T](t: typedesc[Debug]; value: T) =
  when not defined(release): stderr.write $value

{.pop.}
