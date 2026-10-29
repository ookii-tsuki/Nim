# N# standard library: the System.IO namespace. Imported by `using System.IO;`.
#
# `File`, `Directory` and `Path` are static classes, their members declared over
# `typedesc[...]` since several share a name (`File.Exists`, `Directory.Exists`).
# Text is UTF-8 without a byte order mark, one read is skipped, and lines end in
# `Environment.NewLine` ("\n"); a line read ends at "\n", "\r\n" or "\r". A path
# that is missing throws .NET's exception and message, naming the full path.
#
# Pinned surface (SPEC section 15.5):
#
#   File        AppendAllLines AppendAllText Copy Delete Exists Move ReadAllLines
#               ReadAllText ReadLines WriteAllLines WriteAllText
#   Directory   CreateDirectory Delete EnumerateDirectories EnumerateFiles Exists
#               GetCurrentDirectory GetDirectories GetFiles SetCurrentDirectory
#   DirectoryInfo  Exists FullName Name
#   Path        AltDirectorySeparatorChar ChangeExtension Combine
#               DirectorySeparatorChar GetDirectoryName GetExtension GetFileName
#               GetFileNameWithoutExtension GetFullPath GetTempPath HasExtension
#               IsPathRooted Join PathSeparator
#   StreamReader  Close Dispose EndOfStream Peek Read ReadLine ReadToEnd
#   StreamWriter  Close Dispose Flush Write WriteLine
#   IOException, FileNotFoundException (FileName), DirectoryNotFoundException,
#   EndOfStreamException, PathTooLongException
#
# Deliberately absent: `FileStream` and the byte-level `Stream` family, `FileInfo`,
# encodings other than UTF-8, attributes and times, and `FileSystemWatcher`.
# `ReadLine` at the end returns null, which N# spells as the empty string, so a
# loop reading to the end tests `EndOfStream` (or `Peek() >= 0`) rather than null.

import std/[os, strutils, syncio, algorithm]
import ../System
from ../../nsharp/pragmas import nsHidden
import Collections/Generic
from ../../nsharp/intrinsics import NsArray, nsArrayOf, items, len, ToString, nsTypeName,
  Type, nsTypeNamed, nsState, nsStateOrNil

{.push discardable.}

type
  IOException* = object of SystemException
  FileNotFoundException* = object of IOException
  DirectoryNotFoundException* = object of IOException
  EndOfStreamException* = object of IOException
  PathTooLongException* = object of IOException

  File* = object
    ## `System.IO.File`: its members are static.
  Directory* = object
    ## `System.IO.Directory`: its members are static.
  Path* = object
    ## `System.IO.Path`: its members are static.
  DirectoryInfo* = ref object of RootObj
    ## What `Directory.CreateDirectory` returns.
    nsPath: string

  StreamReader* = ref object of RootObj
    ## `System.IO.StreamReader` over a file, read whole when opened.
    nsText: string
    nsPos: int
    nsClosed: bool
  StreamWriter* = ref object of RootObj
    ## `System.IO.StreamWriter` over a file.
    nsFile: syncio.File
    nsOpen: bool

method ToString*(r: StreamReader): string = "System.IO.StreamReader"
method nsTypeName*(r: StreamReader): string {.nsHidden.} = "System.IO.StreamReader"
method ToString*(w: StreamWriter): string = "System.IO.StreamWriter"
method nsTypeName*(w: StreamWriter): string {.nsHidden.} = "System.IO.StreamWriter"
method ToString*(d: DirectoryInfo): string = d.nsPath
method nsTypeName*(d: DirectoryInfo): string {.nsHidden.} = "System.IO.DirectoryInfo"
proc nsTypeOf*(t: typedesc[StreamReader]): Type {.nsHidden.} = nsTypeNamed("System.IO.StreamReader")
proc nsTypeOf*(t: typedesc[StreamWriter]): Type {.nsHidden.} = nsTypeNamed("System.IO.StreamWriter")
proc nsTypeOf*(t: typedesc[DirectoryInfo]): Type {.nsHidden.} = nsTypeNamed("System.IO.DirectoryInfo")

proc Message*(e: ref FileNotFoundException): string = e.msg
  ## .NET's `FileNotFoundException` overrides `Message` (to name the file when made
  ## without a message); the text is the field here too.

proc nsInitException*(e: ref Exception; t: typedesc[FileNotFoundException]; a, b: string) {.nsHidden.} =
  ## `FileNotFoundException(message, fileName)`, a derived class's `: base(...)` too.
  e.msg = a
  e.nsState.fileName = b

proc nsNewException*(t: typedesc[FileNotFoundException]; a, b: string): ref FileNotFoundException {.nsHidden.} =
  result = nsNewException(FileNotFoundException, a)
  nsInitException(result, FileNotFoundException, a, b)

proc FileName*[T: ref FileNotFoundException](e: T): string =
  ## The file it could not find, or null.
  let st = nsStateOrNil(e)
  if st != nil: st.fileName else: ""

nsMoreMessages = proc (e: ref Exception): string {.nimcall.} =
  ## The messages this namespace's parameterless constructors make.
  if e of FileNotFoundException: "Unable to find the specified file."
  elif e of DirectoryNotFoundException: "Attempted to access a path that is not on the disk."
  elif e of EndOfStreamException: "Attempted to read past the end of the stream."
  elif e of PathTooLongException:
    "The specified file name or path is too long, or a component of the specified " &
    "path is too long."
  elif e of IOException: "I/O error occurred."
  else: ""

nsMoreHResults = proc (e: ref Exception): int32 {.nimcall.} =
  ## The HRESULTs of this namespace's exceptions, for `Exception.HResult`.
  if e of FileNotFoundException: -2147024894'i32
  elif e of DirectoryNotFoundException: -2147024893'i32
  elif e of EndOfStreamException: -2147024858'i32
  elif e of PathTooLongException: -2147024690'i32
  elif e of IOException: -2146232800'i32
  else: 0'i32

# --- System.IO.Path -------------------------------------------------------------

proc nsFull(path: string): string =
  ## `Path.GetFullPath`: rooted at the working directory, `.` and `..` resolved, a
  ## trailing separator kept.
  if path.len == 0:
    raise nsNewException(ArgumentException, "The value cannot be an empty string.", "path")
  result = normalizedPath(absolutePath(path))
  if path.endsWith('/') and not result.endsWith('/'): result.add '/'

template DirectorySeparatorChar*(t: typedesc[Path]): char = '/'
template AltDirectorySeparatorChar*(t: typedesc[Path]): char = '/'
template PathSeparator*(t: typedesc[Path]): char = ':'

proc GetFullPath*(t: typedesc[Path]; path: string): string = nsFull(path)
proc IsPathRooted*(t: typedesc[Path]; path: string): bool = path.startsWith('/')
proc Combine*(t: typedesc[Path]; paths: varargs[string]): string =
  ## Joined with `/` where the left part does not end in one; a rooted part starts
  ## over, and an empty one is skipped.
  result = ""
  for p in paths:
    if p.len == 0: continue
    if p.startsWith('/'): result = p
    elif result.len == 0 or result.endsWith('/'): result.add p
    else: result.add '/' & p
proc Join*(t: typedesc[Path]; paths: varargs[string]): string =
  ## As `Combine`, but a rooted part is appended like any other.
  result = ""
  for p in paths:
    if p.len == 0: continue
    if result.len == 0 or result.endsWith('/') or p.startsWith('/'): result.add p
    else: result.add '/' & p
proc GetFileName*(t: typedesc[Path]; path: string): string =
  let i = path.rfind('/')
  path[i + 1 .. ^1]
proc nsExtAt(path: string): int =
  ## Where the extension's `.` is in the last part, or -1.
  let i = path.rfind('.')
  if i < 0 or i < path.rfind('/') or i == path.high: -1 else: i
proc GetExtension*(t: typedesc[Path]; path: string): string =
  let i = nsExtAt(path)
  if i < 0: "" else: path[i .. ^1]
proc HasExtension*(t: typedesc[Path]; path: string): bool = nsExtAt(path) >= 0
proc GetFileNameWithoutExtension*(t: typedesc[Path]; path: string): string =
  let name = Path.GetFileName(path)
  let i = name.rfind('.')
  if i < 0: name else: name[0 ..< i]
proc GetDirectoryName*(t: typedesc[Path]; path: string): string =
  ## The part before the last separator; `/` for a file at the root, and null
  ## (N#'s empty string) for the root itself or a bare name.
  if path == "/": return ""
  let i = path.rfind('/')
  if i < 0: "" elif i == 0: "/" else: path[0 ..< i]
proc ChangeExtension*(t: typedesc[Path]; path, extension: string): string =
  ## A null extension removes it (an empty one too, since N# spells null as
  ## the empty string, where .NET would leave the `.`); one without `.` gains one.
  let i = nsExtAt(path)
  result = (if i >= 0: path[0 ..< i] elif path.endsWith('.'): path[0 ..< ^1] else: path)
  if extension.len > 0:
    result.add (if extension.startsWith('.'): extension else: "." & extension)
proc GetTempPath*(t: typedesc[Path]): string =
  result = getEnv("TMPDIR", "/tmp")
  if not result.endsWith('/'): result.add '/'

# --- failures -------------------------------------------------------------------

proc nsMissing(path: string) {.noinline, noreturn.} =
  ## A path that is not there: the file, when its directory is; else a part of it.
  let full = nsFull(path)
  if dirExists(full):
    raise nsNewException(UnauthorizedAccessException, "Access to the path '" & full & "' is denied.")
  if dirExists(parentDir(full)):
    raise nsNewException(FileNotFoundException, "Could not find file '" & full & "'.", full)
  raise nsNewException(DirectoryNotFoundException, "Could not find a part of the path '" & full & "'.")

proc nsWriteFail(path: string) {.noinline, noreturn.} =
  let full = nsFull(path)
  if dirExists(full) or dirExists(parentDir(full)):
    raise nsNewException(UnauthorizedAccessException, "Access to the path '" & full & "' is denied.")
  raise nsNewException(DirectoryNotFoundException, "Could not find a part of the path '" & full & "'.")

proc nsOpen(path: string; mode: FileMode): syncio.File =
  if mode == fmRead:
    if not fileExists(path) or not open(result, path, mode): nsMissing(path)
  elif not open(result, path, mode): nsWriteFail(path)

proc nsSplitLines(text: string): seq[string] =
  ## Lines ended by "\n", "\r\n" or "\r"; a last one without an end counts.
  result = @[]
  var i = 0
  var start = 0
  while i < text.len:
    if text[i] in {'\n', '\r'}:
      result.add text[start ..< i]
      if text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n': inc i
      start = i + 1
    inc i
  if start < text.len: result.add text[start .. ^1]

proc nsReadAll(path: string): string =
  let f = nsOpen(path, fmRead)
  try: result = readAll(f)
  finally: close(f)
  if result.startsWith("\xEF\xBB\xBF"): result = result[3 .. ^1]

proc nsWrite(path, text: string; mode: FileMode) =
  let f = nsOpen(path, mode)
  try: f.write text
  finally: close(f)

# --- System.IO.File -------------------------------------------------------------

proc Exists*(t: typedesc[File]; path: string): bool =
  ## A file, not a directory, is there.
  path.len > 0 and fileExists(path)
proc ReadAllText*(t: typedesc[File]; path: string): string = nsReadAll(path)
proc ReadAllLines*(t: typedesc[File]; path: string): NsArray[string] =
  nsArrayOf(nsSplitLines(nsReadAll(path)))
proc ReadLines*(t: typedesc[File]; path: string): NsArray[string] =
  ## Read at once rather than lazily.
  nsArrayOf(nsSplitLines(nsReadAll(path)))
proc WriteAllText*(t: typedesc[File]; path, contents: string) = nsWrite(path, contents, fmWrite)
proc AppendAllText*(t: typedesc[File]; path, contents: string) = nsWrite(path, contents, fmAppend)
proc WriteAllLines*[C](t: typedesc[File]; path: string; contents: C) =
  ## Each line then `Environment.NewLine`.
  var text = ""
  for line in contents: text.add line & "\n"
  nsWrite(path, text, fmWrite)
proc AppendAllLines*[C](t: typedesc[File]; path: string; contents: C) =
  var text = ""
  for line in contents: text.add line & "\n"
  nsWrite(path, text, fmAppend)
proc Delete*(t: typedesc[File]; path: string) =
  ## Nothing to do when the file is not there; its directory must be.
  let full = nsFull(path)
  if not dirExists(parentDir(full)):
    raise nsNewException(DirectoryNotFoundException, "Could not find a part of the path '" & full & "'.")
  if fileExists(full): removeFile(full)
proc Copy*(t: typedesc[File]; sourceFileName, destFileName: string; overwrite: bool) =
  if not fileExists(sourceFileName): nsMissing(sourceFileName)
  if not overwrite and fileExists(destFileName):
    raise nsNewException(IOException, "The file '" & nsFull(destFileName) & "' already exists.")
  nsWrite(destFileName, nsReadAll(sourceFileName), fmWrite)
proc Copy*(t: typedesc[File]; sourceFileName, destFileName: string) =
  File.Copy(sourceFileName, destFileName, false)
proc Move*(t: typedesc[File]; sourceFileName, destFileName: string) =
  if not fileExists(sourceFileName): nsMissing(sourceFileName)
  let dest = nsFull(destFileName)
  if fileExists(dest) or dirExists(dest):
    raise nsNewException(IOException, "The file '" & dest & "' already exists.")
  if not dirExists(parentDir(dest)):
    raise nsNewException(DirectoryNotFoundException, "Could not find a part of the path '" & dest & "'.")
  moveFile(sourceFileName, dest)

# --- System.IO.Directory --------------------------------------------------------

proc FullName*(d: DirectoryInfo): string = d.nsPath
proc Name*(d: DirectoryInfo): string =
  let p = (if d.nsPath.len > 1 and d.nsPath.endsWith('/'): d.nsPath[0 ..< ^1] else: d.nsPath)
  let i = p.rfind('/')
  if p == "/": "/" else: p[i + 1 .. ^1]
proc Exists*(d: DirectoryInfo): bool = dirExists(d.nsPath)

proc Exists*(t: typedesc[Directory]; path: string): bool = path.len > 0 and dirExists(path)
proc CreateDirectory*(t: typedesc[Directory]; path: string): DirectoryInfo =
  ## With every missing parent; nothing to do when it is there.
  let full = nsFull(path)
  if fileExists(full):
    raise nsNewException(IOException, "The file '" & full & "' already exists.")
  createDir(full)
  DirectoryInfo(nsPath: full)
proc Delete*(t: typedesc[Directory]; path: string; recursive: bool) =
  let full = nsFull(path)
  if not dirExists(full):
    raise nsNewException(DirectoryNotFoundException, "Could not find a part of the path '" & full & "'.")
  if recursive: removeDir(full)
  else:
    for _ in walkDir(full):
      raise nsNewException(IOException, "Directory not empty : '" & full & "'")
    removeDir(full)
proc Delete*(t: typedesc[Directory]; path: string) = Directory.Delete(path, false)
proc GetCurrentDirectory*(t: typedesc[Directory]): string = getCurrentDir()
proc SetCurrentDirectory*(t: typedesc[Directory]; path: string) =
  if not dirExists(path):
    raise nsNewException(DirectoryNotFoundException,
                         "Could not find a part of the path '" & nsFull(path) & "'.")
  setCurrentDir(path)

proc nsMatches(name, pattern: string): bool =
  ## `*` any run, `?` one character, as a search pattern reads; `*.*` is all. In
  ## linear time: on a mismatch, the last `*` takes one more character.
  if pattern == "*" or pattern == "*.*": return true
  var n, p = 0
  var star = -1
  var mark = 0
  while n < name.len:
    if p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n]):
      inc n
      inc p
    elif p < pattern.len and pattern[p] == '*':
      star = p
      mark = n
      inc p
    elif star >= 0:
      p = star + 1
      inc mark
      n = mark
    else: return false
  while p < pattern.len and pattern[p] == '*': inc p
  p == pattern.len

proc nsEntries(path, pattern: string; dirs: bool): NsArray[string] =
  ## The entries' paths as `path` spells them, sorted by name (.NET leaves the
  ## order to the file system).
  if not dirExists(path):
    raise nsNewException(DirectoryNotFoundException,
                         "Could not find a part of the path '" & nsFull(path) & "'.")
  var names: seq[string] = @[]
  for kind, p in walkDir(path, relative = true):
    let isDir = kind in {pcDir, pcLinkToDir}
    if isDir == dirs and nsMatches(p, pattern): names.add p
  names.sort(system.cmp)
  var xs: seq[string] = @[]
  for n in names: xs.add Path.Combine(path, n)
  nsArrayOf(xs)

proc GetFiles*(t: typedesc[Directory]; path: string): NsArray[string] = nsEntries(path, "*", false)
proc GetFiles*(t: typedesc[Directory]; path, searchPattern: string): NsArray[string] =
  nsEntries(path, searchPattern, false)
proc GetDirectories*(t: typedesc[Directory]; path: string): NsArray[string] = nsEntries(path, "*", true)
proc GetDirectories*(t: typedesc[Directory]; path, searchPattern: string): NsArray[string] =
  nsEntries(path, searchPattern, true)
proc EnumerateFiles*(t: typedesc[Directory]; path: string): NsArray[string] = nsEntries(path, "*", false)
proc EnumerateFiles*(t: typedesc[Directory]; path, searchPattern: string): NsArray[string] =
  nsEntries(path, searchPattern, false)
proc EnumerateDirectories*(t: typedesc[Directory]; path: string): NsArray[string] =
  nsEntries(path, "*", true)

# --- System.IO.StreamReader -----------------------------------------------------

proc newStreamReader*(path: string): StreamReader {.nsHidden.} = StreamReader(nsText: nsReadAll(path))

proc nsCheckOpen(r: StreamReader) =
  if r.nsClosed:
    raise nsNewException(ObjectDisposedException, "StreamReader",
                         "Cannot read from a closed TextReader.")

proc EndOfStream*(r: StreamReader): bool =
  r.nsCheckOpen
  r.nsPos >= r.nsText.len
proc Peek*(r: StreamReader): int32 =
  ## The next character's code, or -1 at the end.
  r.nsCheckOpen
  if r.nsPos < r.nsText.len: int32(ord(r.nsText[r.nsPos])) else: -1
proc Read*(r: StreamReader): int32 =
  result = r.Peek
  if result >= 0: inc r.nsPos
proc ReadLine*(r: StreamReader): string =
  ## The next line without its end; null (the empty string) at the end.
  r.nsCheckOpen
  result = ""
  if r.nsPos >= r.nsText.len: return
  let start = r.nsPos
  while r.nsPos < r.nsText.len and r.nsText[r.nsPos] notin {'\n', '\r'}: inc r.nsPos
  result = r.nsText[start ..< r.nsPos]
  if r.nsPos < r.nsText.len:
    if r.nsText[r.nsPos] == '\r' and r.nsPos + 1 < r.nsText.len and r.nsText[r.nsPos + 1] == '\n':
      inc r.nsPos
    inc r.nsPos
proc ReadToEnd*(r: StreamReader): string =
  r.nsCheckOpen
  result = r.nsText[r.nsPos .. ^1]
  r.nsPos = r.nsText.len
proc Close*(r: StreamReader) = r.nsClosed = true
proc Dispose*(r: StreamReader) = r.nsClosed = true

# --- System.IO.StreamWriter -----------------------------------------------------

proc newStreamWriter*(path: string; append: bool): StreamWriter {.nsHidden.} =
  StreamWriter(nsFile: nsOpen(path, if append: fmAppend else: fmWrite), nsOpen: true)
proc newStreamWriter*(path: string): StreamWriter {.nsHidden.} = newStreamWriter(path, false)

proc nsCheckOpen(w: StreamWriter) =
  if not w.nsOpen:
    raise nsNewException(ObjectDisposedException, "StreamWriter",
                         "Cannot write to a closed TextWriter.")

proc Write*[T](w: StreamWriter; value: T) =
  w.nsCheckOpen
  w.nsFile.write $value
proc WriteLine*[T](w: StreamWriter; value: T) =
  w.nsCheckOpen
  w.nsFile.write $value & "\n"
proc WriteLine*(w: StreamWriter) =
  w.nsCheckOpen
  w.nsFile.write "\n"
proc Flush*(w: StreamWriter) =
  w.nsCheckOpen
  flushFile(w.nsFile)
proc Close*(w: StreamWriter) =
  ## What was written reaches the file; closing again does nothing.
  if w.nsOpen:
    close(w.nsFile)
    w.nsOpen = false
proc Dispose*(w: StreamWriter) = w.Close

{.pop.}
