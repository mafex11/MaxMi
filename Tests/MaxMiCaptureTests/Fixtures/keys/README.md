# Key fixtures

Every parser must prove its thread keys are **clean** and **stable** before merge.

To add a parser:
1. Capture 2+ real samples of the SAME logical entity (e.g. two views of one page,
   two ticks in one terminal cwd, two pans of one map).
2. Add a `(app, [rawKey1, rawKey2, ...])` group to `KeyFixturesTests.testKeysAreCleanAndStablePerApp`.
3. The test asserts all variants derive to ONE clean key. If they don't, fix the
   parser's key HINT or add a rule to `ThreadKeyDeriver` — never loosen the assertion.

"Clean" = lowercased scheme, no whitespace/ellipsis/bracket junk, no file-extension leaf, <=200 chars.
"Stable" = volatile detail (coords, tabs, timestamps, file args) does NOT change the key.
