# What the N# library asks of the OS: the clocks and the processor count. A
# target without one (`--os:any`, `--os:standalone`) has none of them, and the
# library members that need them throw `PlatformNotSupportedException` there.
# Kept apart from `System` so that its imports need no `when` at the top of a
# module in an import cycle.

const nsNoOs* = hostOS in ["any", "standalone"]

when nsNoOs:
  ## Nim links the C maths library only for the OSes it knows; `Math` needs it
  ## everywhere (newlib and picolibc ship one too).
  {.passL: "-lm".}

when not nsNoOs:
  import std/[times, monotimes, cpuinfo]

  proc nsUnixNow*(): tuple[seconds, nanoseconds: int64] =
    let t = getTime()
    (t.toUnix, int64(t.nanosecond))

  proc nsUtcOffset*(): int64 =
    ## Seconds west of UTC, now, as `std/times` counts them.
    int64(times.now().utcOffset)

  proc nsMonoNanoseconds*(): int64 = getMonoTime().ticks

  proc nsProcessorCount*(): int = countProcessors()
