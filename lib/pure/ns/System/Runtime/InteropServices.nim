# N# standard library: the System.Runtime.InteropServices namespace. Imported by
# `using System.Runtime.InteropServices;`.
#
# The attributes a P/Invoke declaration is written with. As in .NET, the compiler
# reads them and nothing does at run time:
#
#   [DllImport("libm.so.6", EntryPoint = "cos")]
#   static extern double Cos(double x);
#
# `DllImport("lib")` loads the library when the method is first called, as .NET
# does (a missing one throws `DllNotFoundException` there), and
# `DllImport("__Internal")` names a function linked into the program (Unity's
# spelling). The marshalling N# does is .NET's default for
# blittable arguments: numbers, `ref`/`out` of them, `string` as a NUL-terminated
# UTF-8 copy (CharSet.Ansi, which on Unix is UTF-8), `bool` as a 4-byte BOOL
# unless `[MarshalAs(UnmanagedType.U1)]`, and structs by value as their fields in
# order (`StructLayout(LayoutKind.Sequential)`, the default for a C# struct).
#
# Deliberately absent: `Marshal`'s heap helpers, `SafeHandle`, `GCHandle`, COM.

from ../../System import Attribute
from ../../../nsharp/pragmas import nsHidden

type
  DllImportAttribute* = ref object of Attribute
    ## `[DllImport("lib", EntryPoint = "name")]` on a `static extern` method: the C
    ## function it calls, from that shared library, or linked in (`"__Internal"`).
  StructLayoutAttribute* = ref object of Attribute
    ## `[StructLayout(LayoutKind.Sequential, Pack = 1)]` on a struct: its fields in
    ## declaration order, as C lays them out (packed with `Pack = 1`).
  MarshalAsAttribute* = ref object of Attribute
    ## `[MarshalAs(UnmanagedType.U1)]` on a `bool` parameter or result: one byte
    ## rather than the 4-byte BOOL.
  LayoutKind* = distinct int32
    ## `System.Runtime.InteropServices.LayoutKind`.
  CallingConvention* = distinct int32
    ## `System.Runtime.InteropServices.CallingConvention`.
  CharSet* = distinct int32
    ## `System.Runtime.InteropServices.CharSet`.
  UnmanagedType* = distinct int32
    ## `System.Runtime.InteropServices.UnmanagedType` (the values N# reads).

template Sequential*(t: typedesc[LayoutKind]): LayoutKind = LayoutKind(0)
template Explicit*(t: typedesc[LayoutKind]): LayoutKind = LayoutKind(2)
template Auto*(t: typedesc[LayoutKind]): LayoutKind = LayoutKind(3)

template Winapi*(t: typedesc[CallingConvention]): CallingConvention = CallingConvention(1)
template Cdecl*(t: typedesc[CallingConvention]): CallingConvention = CallingConvention(2)
template StdCall*(t: typedesc[CallingConvention]): CallingConvention = CallingConvention(3)

template None*(t: typedesc[CharSet]): CharSet = CharSet(1)
template Ansi*(t: typedesc[CharSet]): CharSet = CharSet(2)
template Unicode*(t: typedesc[CharSet]): CharSet = CharSet(3)
template Auto*(t: typedesc[CharSet]): CharSet = CharSet(4)

template Bool*(t: typedesc[UnmanagedType]): UnmanagedType = UnmanagedType(2)
template I1*(t: typedesc[UnmanagedType]): UnmanagedType = UnmanagedType(3)
template U1*(t: typedesc[UnmanagedType]): UnmanagedType = UnmanagedType(4)
template LPStr*(t: typedesc[UnmanagedType]): UnmanagedType = UnmanagedType(20)
template LPUTF8Str*(t: typedesc[UnmanagedType]): UnmanagedType = UnmanagedType(48)
