# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim
#
# Parent side of the M365 OAuth browser-open delegation (issue #139, KDE).
#
# The built-in MCP host's parent<->child message handler (a flat if-chain that
# only knows msal-cache-get / msal-cache-set, wired via
# this.process.on("message", ...)) gains a new first branch:
#
#   {type:"open-url", url:"https://..."}  ->  shell.openExternal(url)
#
# This is the exact mechanism the remote-OAuth (Atlassian) flow uses, which is
# why that connector opens the browser fine on every DE while the local M365
# connector's in-child spawn("xdg-open") fails on KDE. The child side is
# patched by fix_office365_mcp_open_url.nim; both are required together.
#
# Safety: the branch only accepts string URLs starting with https:// so a
# compromised MCP child cannot open file:// or other schemes via the parent.
#
# Anchors: the unique "msal-cache-get" literal for the injection site, plus the
# electron namespace var recovered from X.safeStorage.decryptString( within the
# SAME code-split chunk as the injection site. Since v1.20186.1 the bundle is
# split into 82 chunks (separated by /*__CDB_SPLIT__<name>__*/ markers by the
# orchestrator) and each chunk is a distinct runtime module with its own
# electron require: a bundle-wide safeStorage scan now sees several vars (e.g.
# x in the MSAL host chunk, ne in an unrelated token-cache chunk). We therefore
# scope the scan to the injection-site chunk, where the var is unambiguous.
# All minified identifiers ([\w$]+) are captured and reused.

import std/[os, strutils, sets]
import regex

const SPLIT_MARKER = "/*__CDB_SPLIT__"

proc apply*(input: string): string =
  # Idempotency: positive end-state -- the open-url branch must be present.
  if """==="open-url"&&typeof""" in input:
    echo "  [OK] built-in MCP open-url handler: already patched"
    return input

  # Step 1: inject the branch at the head of the child-message if-chain.
  #
  # v1.25927.0 dropped the null-check ternary for real optional chaining and
  # renamed const->let: };return(a,c)=>{let u=a;if(u?.type==="msal-cache-get"
  # (previously: };return(d,f)=>{const p=d;if((p==null?void 0:p.type)==="msal-cache-get").
  # re2 has no backreferences, so the message-var identity between "let X=Y;"
  # and "if(X?.type===" can't be pinned in one pattern; match the head first,
  # then verify the immediately-following text is "if(<thatvar>?.type===" by
  # literal comparison.
  let headPat =
    re2"""\};return\(([\w$]+),[\w$]+\)=>\{let ([\w$]+)=[\w$]+;"""
  var injPos = -1
  var msgVar = ""
  var headText = ""
  var ifHeadText = ""
  for m in input.findAll(headPat):
    let candidateVar = input[m.group(1)]
    let afterPos = m.boundaries.b + 1
    let ifHead = "if(" & candidateVar & "?.type===`msal-cache-get`"
    if afterPos + ifHead.len <= input.len and
        input[afterPos ..< afterPos + ifHead.len] == ifHead:
      injPos = m.boundaries.a
      msgVar = candidateVar
      headText = input[m.boundaries.a .. m.boundaries.b]
      # Everything through the comparison operator, excluding the backtick-quoted
      # "msal-cache-get" value itself, so the original branch is preserved verbatim.
      ifHeadText = "if(" & msgVar & "?.type==="
      break
  if injPos < 0:
    echo "  [FAIL] built-in MCP open-url handler: found 0 msal-cache-get injection sites (expected 1)"
    quit(1)

  # Step 2: recover the electron namespace var from within the injection-site
  # chunk only. The chunk spans from the split marker preceding injPos to the
  # next split marker after it (or the buffer ends). safeStorage.decryptString(
  # is used by the MSAL host module and resolves to a single electron var here.
  var chunkStart = input.rfind(SPLIT_MARKER, last = injPos)
  if chunkStart < 0:
    chunkStart = 0
  var chunkEnd = input.find(SPLIT_MARKER, start = injPos)
  if chunkEnd < 0:
    chunkEnd = input.len
  let chunk = input[chunkStart ..< chunkEnd]

  var electronVars = initHashSet[string]()
  for m in chunk.findAll(re2"([\w$]+)\.safeStorage\.decryptString\("):
    electronVars.incl(chunk[m.group(0)])
  if electronVars.len != 1:
    echo "  [FAIL] built-in MCP open-url handler: expected exactly 1 distinct " &
      "electron ns var via safeStorage.decryptString in the injection-site " &
      "chunk, found " & $electronVars.len
    quit(1)
  var electronVar = ""
  for v in electronVars:
    electronVar = v

  let spliceEnd = injPos + headText.len + ifHeadText.len
  let injection =
    "if((" & msgVar & "?.type)===\"open-url\"&&typeof " & msgVar &
    ".url==\"string\"&&" & msgVar & ".url.startsWith(\"https://\")){" & electronVar &
    ".shell.openExternal(" & msgVar & ".url).catch(()=>{});return}"
  result =
    input[0 ..< injPos] & headText & injection & ifHeadText & input[spliceEnd .. ^1]

  echo "  [OK] built-in MCP open-url handler: shell.openExternal branch added"

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_builtin_mcp_open_url_handler <file>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: fix_builtin_mcp_open_url_handler ==="
  echo "  Target: " & filePath
  let input = readFile(filePath)
  let output = apply(input)
  writeFile(filePath, output)
  echo "  [PASS] built-in MCP open-url handler patched successfully"
