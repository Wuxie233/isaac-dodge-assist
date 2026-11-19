# Isaac Dodge Assist (以撒躲避助手)

Repentance+ dodge & combat assist mod (`mod/isaac_dodge_assist/`) plus 60Hz native memory-read DLL and x86 host (`native/`).

## Reference Docs
- Local host paths, deploy workflow, and run-log notes: `AGENTS.local.md` (gitignored, present on local dev host).
- Project overview & test matrix: `README.md`, `native/README.md`, `GLOSSARY.md`, `SPEC.md`, `COVERAGE.md`.

## Local Verification (Run Serially)
- Native 60Hz tests (run without concurrent heavy CPU tasks so latency bounds stay stable):
  `g++ -std=c++17 -O2 -Wall -Wextra -Werror native/tests/native_60hz_test.cpp -o /tmp/native_60hz_test && /tmp/native_60hz_test && rm -f /tmp/native_60hz_test`
- Lua syntax, regression & perf suites:
  `python3 native/tests/planner_regression.py`
- Cross-compile native DLL (Linux):
  `bash native/build-dll.sh`
- Pre-commit hook (runs `native_60hz_test` then `planner_regression.py` serially):
  `git config core.hooksPath .githooks` (or `bash .githooks/pre-commit`)
