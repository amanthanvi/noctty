# Accessibility release evidence

Optional manual acceptance evidence may be recorded as `v<version>.json` and
validated by `scripts/check-accessibility-evidence.ps1`. The report is a human
attestation, not a substitute for the automated UI Automation harness. It
records the exact tested commit and the GitHub Actions run containing the
matching automated evidence. Stable release preflight does not require this
manual report.

When a manual report is recorded, the acceptance matrix covers Narrator and
NVDA at 100%, 200%, and 300% display scaling, with high contrast both off and
on. Every cell exercises tab and pane navigation, terminal reading,
command-palette invocation/filtering, settings editing, and dismissal of
transient UI. A code change after the tested commit invalidates the report;
only the report itself may change afterward. The validator also queries GitHub
to require a successful `Test` run for that exact commit, its successful
interactive job, and its unexpired evidence artifact.
