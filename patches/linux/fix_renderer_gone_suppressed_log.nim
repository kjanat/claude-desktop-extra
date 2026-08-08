# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim
#
# Log silently-suppressed main-webview renderer deaths (#128).
#
# The main webview's "render-process-gone" handler skips all visible
# handling (no log, no reload, no Sentry report) with NO trace when a
# compound guard evaluates false. A Linux kernel OOM SIGKILL surfaces as
# reason==="killed", so an OOM-killed renderer (-> blank view, claude.ai
# re-login) can leave no trace in main.log. Insert a logger call as the
# FIRST statement of the handler, unconditional on the guard, so a
# reason==="killed" event is always visible in main.log regardless of
# which branch of the guard ends up skipping the rest of the handler.
# Pure observability -- the existing guard and its consequences (reload
# or not) are untouched.
#
# v1.25927.0 replaced the old shape:
#   .on("render-process-gone",async(i,r)=>{if(KG>0||r.reason==="killed"||r.reason==="clean-exit"){KG>0&&KG--;return}if(D.info(...
# (an expected-kill counter gating a silent early return) with a compound
# boolean guard that gates the visible-handling block directly instead of
# early-returning out of a separate silent branch:
#   .on(`render-process-gone`,async(t,a)=>{if(Sa(a)&&!(a.reason===`killed`&&(await new Promise(e=>setTimeout(e,ya)),e.isDestroyed()||m.li()))&&!e.isDestroyed()){if(o.o.info(`Main webview render process gone: %o`,a),...
# There is no longer a separate silent-return branch to inject into: the
# suppression is baked into the guard itself. Since nim-regex (NFA) has no
# backreferences, we capture each repeated identifier (the details param,
# the window var) independently and verify they agree at runtime rather
# than relying on a backreference.

import std/[os, strutils]
import regex

# Literal substring of the injected log line; absent from the fresh bundle.
const AppliedMarker = "Main webview render process gone (reason=killed)"

proc apply*(input: string): string =
  if AppliedMarker in input:
    echo "  [OK] renderer-gone (reason=killed) log: already applied"
    return input

  # The trailing `.info("Main webview render process gone: %o` both pins
  # this site (multiple render-process-gone registrations exist; only this
  # one logs that message) and captures the logger identifier.
  # The final group captures the OPENING QUOTE of the log-message literal so
  # the replacement can re-emit the same character: the tail of that literal
  # (closing quote + `,a)...`) stays in the source after the match, and since
  # v1.25927.0 it is a backtick — re-emitting a hardcoded `"` there leaves the
  # literal unterminated (SyntaxError caught by node --check on index.js).
  let pattern = re2"""\.on\([`"]render-process-gone[`"],async\(([\w$]+),([\w$]+)\)=>\{if\(([\w$]+)\(([\w$]+)\)&&!\(([\w$]+)\.reason===[`"]killed[`"]&&\(await new Promise\([\w$]+=>setTimeout\([\w$]+,([\w$]+)\)\),([\w$]+)\.isDestroyed\(\)\|\|([\w$]+)\.li\(\)\)\)&&!([\w$]+)\.isDestroyed\(\)\)\{if\(([\w$]+(?:\.[\w$]+)?)\.info\(([`"])Main webview render process gone: %o"""
  var count = 0
  result = input.replace(
    pattern,
    proc(m: RegexMatch2, s: string): string =
      let evtParam = s[m.group(0)]
      let details1 = s[m.group(1)]
      let predicateFn = s[m.group(2)]
      let details2 = s[m.group(3)]
      let details3 = s[m.group(4)]
      let timeoutVar = s[m.group(5)]
      let winVar1 = s[m.group(6)]
      let liOwner = s[m.group(7)]
      let winVar2 = s[m.group(8)]
      let logger = s[m.group(9)]
      let msgQuote = s[m.group(10)]
      if details1 != details2 or details1 != details3 or winVar1 != winVar2:
        return s[m.boundaries] # identifiers disagree -- bail, don't touch
      inc count
      let injected =
        "if(" & details1 & """.reason==="killed"){""" & logger &
        """.info("Main webview render process gone (reason=killed): %o",{reason:""" &
        details1 & ".reason,exitCode:" & details1 & ".exitCode})}"
      ".on(\"render-process-gone\",async(" & evtParam & "," & details1 & ")=>{" &
        injected & "if(" & predicateFn & "(" & details1 & ")&&!(" & details1 &
        """.reason==="killed"&&(await new Promise(_qr=>setTimeout(_qr,""" & timeoutVar &
        "))," & winVar1 & ".isDestroyed()||" & liOwner & ".li()))&&!" & winVar1 &
        ".isDestroyed()){if(" & logger & ".info(" & msgQuote &
        "Main webview render process gone: %o",
  )
  if count == 0:
    if "Main webview render process gone" in input:
      echo "  [INFO] Found 'Main webview render process gone' in file but pattern didn't match"
    echo "  [FAIL] renderer-gone (reason=killed) pattern: 0 matches (may need pattern update)"
    quit(1)
  echo "  [OK] renderer-gone (reason=killed) log: " & $count & " match(es)"

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_renderer_gone_suppressed_log <file>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: fix_renderer_gone_suppressed_log ==="
  echo "  Target: " & filePath
  let input = readFile(filePath)
  let output = apply(input)
  writeFile(filePath, output)
  echo "  [PASS] Suppressed renderer-gone log patched successfully"
