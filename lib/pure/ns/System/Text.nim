# N# standard library: the System.Text namespace. Imported by `using System.Text;`.
#
# `StringBuilder` is a class, as in .NET: a `ref object` owning the text it builds,
# the Nim a user's own `class StringBuilder` would lower to. Its members return the
# builder itself, so calls chain (`sb.Append(1).Append('x')`), and a call statement
# may drop the result.
#
# Pinned surface (SPEC section 15.1):
#
#   StringBuilder    Append AppendFormat AppendJoin AppendLine Clear Insert Length
#                    Remove Replace ToString, [] []=
#
# Deliberately absent: `Capacity`, `MaxCapacity`, `EnsureCapacity`, `CopyTo`,
# `Equals(StringBuilder)`, chunk enumeration, and `Encoding` with its kin.

import std/strutils
import ../System
from ../../nsharp/intrinsics import ToString, nsTypeName


{.push discardable.}

type
  StringBuilder* = ref object of RootObj
    ## `System.Text.StringBuilder`.
    nsText: string

proc newStringBuilder*(): StringBuilder = StringBuilder()
proc newStringBuilder*(value: string): StringBuilder = StringBuilder(nsText: value)
proc newStringBuilder*(capacity: int32): StringBuilder =
  if capacity < 0:
    raise nsActualValue("capacity", $capacity, "must be a non-negative value.")
  StringBuilder(nsText: newStringOfCap(int(capacity)))

proc nsNegative(param: string; value: int32) {.noinline, noreturn.} =
  raise nsActualValue(param, $value, "must be a non-negative value.")

proc nsIndexFail(param: string) {.noinline, noreturn.} =
  raise nsNewException(ArgumentOutOfRangeException, param, "Index was out of range. " &
    "Must be non-negative and less than or equal to the size of the collection.")

proc Length*(sb: StringBuilder): int32 = int32(sb.nsText.len)
proc `Length=`*(sb: StringBuilder; value: int32) =
  ## Shortens the text, or pads it with `'\0'`, as .NET does.
  if value < 0:
    raise nsActualValue("value", $value, "must be a non-negative value.")
  sb.nsText.setLen(int(value))

proc `[]`*(sb: StringBuilder; index: int32): char =
  if index < 0 or int(index) >= sb.nsText.len:
    raise nsNewException(IndexOutOfRangeException)
  sb.nsText[int(index)]
proc `[]=`*(sb: StringBuilder; index: int32; value: char) =
  if index < 0 or int(index) >= sb.nsText.len:
    ## Setting out of range is an argument out of range, where getting is an index.
    raise nsNewException(ArgumentOutOfRangeException, "index", "Index was out of range. " &
      "Must be non-negative and less than the size of the collection.")
  sb.nsText[int(index)] = value

proc Append*(sb: StringBuilder; value: string): StringBuilder =
  sb.nsText.add value
  sb
proc Append*(sb: StringBuilder; value: char): StringBuilder =
  sb.nsText.add value
  sb
proc Append*(sb: StringBuilder; value: char; repeatCount: int32): StringBuilder =
  if repeatCount < 0:
    nsNegative("repeatCount", repeatCount)
  sb.nsText.add repeat(value, int(repeatCount))
  sb
proc Append*[T](sb: StringBuilder; value: T): StringBuilder =
  ## Any other value, as `ToString()` renders it (`Console.Write` agrees).
  mixin `$`
  sb.nsText.add $value
  sb

proc AppendLine*(sb: StringBuilder): StringBuilder =
  sb.nsText.add '\n'
  sb
proc AppendLine*(sb: StringBuilder; value: string): StringBuilder =
  sb.nsText.add value
  sb.nsText.add '\n'
  sb

proc AppendFormat*(sb: StringBuilder; format: string; args: varargs[RootRef, nsBox]): StringBuilder =
  ## A composite format, as `string.Format` makes it.
  sb.nsText.add nsComposite(format, args)
  sb

proc AppendJoin*(sb: StringBuilder; separator: string; values: varargs[string]): StringBuilder =
  sb.nsText.add values.join(separator)
  sb

proc Insert*(sb: StringBuilder; index: int32; value: string): StringBuilder =
  if index < 0 or int(index) > sb.nsText.len: nsIndexFail("index")
  sb.nsText.insert(value, int(index))
  sb
proc Insert*[T](sb: StringBuilder; index: int32; value: T): StringBuilder =
  mixin `$`
  Insert(sb, index, $value)

proc Remove*(sb: StringBuilder; startIndex, length: int32): StringBuilder =
  if length < 0: nsNegative("length", length)
  if startIndex < 0: nsNegative("startIndex", startIndex)
  if int(startIndex) + int(length) > sb.nsText.len: nsIndexFail("length")
  sb.nsText.delete(int(startIndex) ..< int(startIndex) + int(length))
  sb

proc Replace*(sb: StringBuilder; oldValue, newValue: string): StringBuilder =
  if oldValue.len == 0:
    raise nsNewException(ArgumentException, "The value cannot be an empty string.", "oldValue")
  sb.nsText = sb.nsText.replace(oldValue, newValue)
  sb
proc Replace*(sb: StringBuilder; oldChar, newChar: char): StringBuilder =
  for c in sb.nsText.mitems:
    if c == oldChar: c = newChar
  sb

proc Clear*(sb: StringBuilder): StringBuilder =
  sb.nsText.setLen(0)
  sb

method ToString*(sb: StringBuilder): string = sb.nsText
method nsTypeName*(sb: StringBuilder): string = "System.Text.StringBuilder"
proc ToString*(sb: StringBuilder; startIndex, length: int32): string =
  if startIndex < 0: nsNegative("startIndex", startIndex)
  if length < 0: nsNegative("length", length)
  if int(startIndex) + int(length) > sb.nsText.len:
    raise nsNewException(ArgumentOutOfRangeException, "length",
      "Index and length must refer to a location within the string.")
  sb.nsText[int(startIndex) ..< int(startIndex) + int(length)]

{.pop.}
