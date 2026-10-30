# Script Runner — Design

Date: 2026-10-30
Status: Approved; builder check done and answered

## Intent

A small, local-only Rails web app where the user creates, edits, and runs their
own shell scripts from a browser. Each script is a button. Clicking it runs the
script and the user can watch its output live, and come back later to read the
logs of past runs.

Why: the user wants one place to keep their personal scripts and run them with a
click, without dropping into a terminal, while still being able to see exactly
what each run did.

## Goals

- Create a new script from inside the app (name + code).
- Edit any existing script's code from inside the app.
- Delete a script.
- Run a script with one click from the home page.
- Watch the script's output (stdout and stderr) stream live while it runs.
- Stop a running script.
- Every run is saved: start time, duration, exit code, status, full log.
- Browse a script's past runs and open any of them to read the full log.

## Non-goals

- Multiple users, accounts, or login.
- Scheduling / cron / triggering runs automatically.
- Passing arguments or input to scripts at run time.
- Script languages other than bash (scripts may still call any program).
- Deployment anywhere other than the user's own machine.

## Anti-goals (a failure even if it works)

- The app being reachable from any other machine. It executes arbitrary code;
  it must bind to `127.0.0.1` only.
- Losing a run's log because the browser tab was closed or refreshed mid-run.
  The run continues on the server and the log is persisted as it streams.
- Scripts that exist only in the database. They must also exist as real files.

## Constraints

- Ruby on Rails (user's choice). Installed: Ruby 3.4.12, Rails 8.1.4.
- Built only from what is in this repo (`shellCommands/`); the repo is
  currently empty. Do not use or reference sibling folders.
- Database: SQLite (Rails 8 default).
- Runs on Linux / WSL.

## Decided by the user

- Framework: Rails.
- Scripts are created and edited inside the app.
- Output is watched live.
- Past runs are saved and viewable later.
- Layout: **Option B, dashboard of buttons** (mockup in
  `.superpowers/brainstorm/`):
  - **Home page:** a heading "My scripts", a "+ New script" button, and a grid
    of cards. Each card shows the script name, its last run status/time (or
    "never run"), a green "▶ Run" button and an "Edit" button.
  - **Run page:** opened by clicking Run. Shows the live output in a dark,
    monospace console that auto-scrolls, a status (running / succeeded /
    failed / stopped), a Stop button while running, and exit code and
    duration when finished. The same page shows a finished past run.
  - **Script page (Edit):** name field, code editor, Save, Delete, Run, and the
    list of past runs (status icon, start time, duration, exit code), each
    linking to its run page.

## Decided by Claude (user saw and agreed to the overall description)

- **Script storage:** each script is a DB record (`Script`: name, timestamps)
  plus a file at `scripts/<name>.sh` holding the code. The file is the source
  of truth for the code; the app reads and writes it. Names are restricted to
  `[a-zA-Z0-9_-]` and are unique so they map safely to filenames. Renaming a
  script renames the file. Saved files are made executable.
- **Git:** `scripts/` and the SQLite database files are gitignored (user's
  choice). Only app code is committed.
- **Folder ↔ DB sync:** the `scripts/` folder is the authority on which scripts
  exist. Loading the home page imports any `scripts/*.sh` file that has no
  record (so files created in a terminal appear as buttons). A record whose
  file is missing shows a "file missing" badge and its Run button is disabled.
- **Delete:** removes the file, the record, and all its runs, after a browser
  confirm. Blocked (button disabled, server rejects) while the script has a
  running run.
- **Execution:** scripts run as `bash -l <absolute path to scripts/<name>.sh>`
  in a login shell so the user's normal PATH/rbenv/nvm load, with working
  directory = the user's home folder (user's choice), inside
  `Bundler.with_unbundled_env` so the app's Bundler/Rails env vars don't leak
  into scripts. Run in the background so the web request returns immediately.
  stdout and stderr are merged into one stream in the order they arrive.
- **Server shutdown:** running scripts are killed (SIGTERM to each process
  group) when the Rails server exits; their runs are marked `stopped`.
- **Run record:** `Run` belongs to `Script`: status (`running`, `succeeded`,
  `failed`, `stopped`), exit code, started_at, finished_at, log text, and the
  process id while running. A snapshot of the script code that was run is
  stored on the run so old logs still make sense after edits.
- **Live streaming:** Hotwire (Turbo Streams over Action Cable), which ships
  with Rails 8. Output lines are appended to the run's log in the DB and
  broadcast to the run page. Opening a run page mid-run shows what's logged
  so far, then continues live.
- **Stop:** sends SIGTERM to the script's process group; marks the run
  `stopped`.
- **Concurrency:** different scripts may run at the same time. The same script
  may also be started again while running (each run is independent).
- **Startup recovery:** on boot, any run still marked `running` (e.g. the
  server was killed) is marked `failed` with a note in its log.
- **Editor:** a plain monospace `<textarea>` (tab key inserts a tab). No
  syntax highlighting library in v1.
- **Security:** server binds to `127.0.0.1`. No auth. A visible note in the
  app's footer says it runs arbitrary code locally.
- **Styling:** simple, clean CSS without a framework.

## Left to the builder

- Background job mechanism (Solid Queue, a plain thread, etc.), as long as runs
  survive the browser disconnecting and the log streams live.
- Exact way of reading output incrementally (e.g. `Open3.popen2e`).
- Log size limits / truncation for very chatty scripts.
- Test strategy and test framework details.
- Visual details beyond the layout above.
