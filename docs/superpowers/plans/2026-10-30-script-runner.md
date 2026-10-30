# Script Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local-only Rails app with a dashboard of buttons that run user-written bash scripts, stream their output live, and keep every run's log.

**Architecture:** Scripts are DB records whose code lives in `scripts/<name>.sh` (the folder is the authority). A plain-Ruby `ScriptRunner` spawns each run in its own process group from an in-process thread, appends output to the `Run` row and broadcasts it with Turbo Streams. No job queue: the runner must own the child processes to stop them and kill them on shutdown.

**Tech Stack:** Ruby 3.4.12, Rails 8.1.4, SQLite, Hotwire (Turbo + Stimulus via importmap), Minitest.

**Spec:** `docs/superpowers/specs/2026-10-30-script-runner-design.md`

## Global Constraints

- Build only from this repo (`shellCommands/`); never read or reference sibling folders.
- Server binds to `127.0.0.1` only.
- Script names match `/\A[a-zA-Z0-9_-]+\z/`, unique; file is `scripts/<name>.sh`, mode `0755`.
- Run command: `bash -l <absolute path>`, `chdir:` user's home, inside `Bundler.with_unbundled_env`, `pgroup: true`, stdout+stderr merged.
- Run statuses exactly: `running`, `succeeded`, `failed`, `stopped`.
- `scripts/`, `db/*.sqlite3*`, `.superpowers/` are gitignored.
- No CSS framework; no syntax-highlighting library; plain `<textarea>` editor.
- Footer copy: "This app runs arbitrary code on your machine. Keep it local."
- Tests must never touch the real `scripts/` folder or the real home folder: they set `Rails.configuration.x.scripts_dir` and `Rails.configuration.x.script_cwd` to tmp dirs.

## Review Focus

1. **HTML in script output** (e.g. `echo "<script>alert(1)</script>"`) must appear as literal text, live and on reload — Task 3 test.
2. **A `rails console`/`rails test`/`db:migrate` started while the server runs scripts must not mark live runs `failed`** — recovery only runs when booting the server (`defined?(Rails::Server)`) — Task 4 test.
3. **A script that spawns children (`sleep 30 &; wait`) must be fully killed by Stop**, not just the bash parent — Task 4 test.
4. **Output without a trailing newline / partial lines** (`printf "a"; sleep 1; printf "b"`) must end up in the log as `ab` — Task 4 test (read with `readpartial`, not `gets`).
5. **Renaming a script to an existing name or to `../evil`** must be rejected without touching files — Task 2 test.

---

### Task 1: App skeleton

**Files:**
- Create: Rails app in repo root (`rails new . --database=sqlite3 --skip-git --skip-docker --skip-kamal --skip-thruster --skip-ci --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-storage --skip-jbuilder --skip-system-test`)
- Modify: `.gitignore`, `config/application.rb`, `config/puma.rb`, `app/views/layouts/application.html.erb`
- Create: `scripts/.keep` is NOT created (folder is created on demand)

**Interfaces:**
- Produces: `Rails.configuration.x.scripts_dir` (Pathname, default `Rails.root.join("scripts")`), `Rails.configuration.x.script_cwd` (String, default `Dir.home`).

- [ ] **Step 1:** Generate the app with the command above (answer "no" to overwriting nothing — repo is empty except `docs/` and `.superpowers/`).
- [ ] **Step 2:** Append to `.gitignore`: `/scripts/`, `/.superpowers/`. Confirm `/db/*.sqlite3*`/`/storage/*` already ignore the DB (Rails 8 puts SQLite in `storage/`).
- [ ] **Step 3:** In `config/application.rb` set the two `config.x` values. In `config/puma.rb` replace `port ENV.fetch("PORT", 3000)` with `bind "tcp://127.0.0.1:#{ENV.fetch("PORT", 3000)}"`.
- [ ] **Step 4:** Layout: `<main>` container plus footer with the exact copy from Global Constraints.
- [ ] **Step 5:** Run `bin/rails db:prepare && bin/rails test`. Expected: 0 failures.
- [ ] **Step 6:** Commit `chore: generate Rails app`.

### Task 2: Script model backed by files

**Files:**
- Create: migration `create_scripts` (`name:string` not null, unique index), `app/models/script.rb`
- Test: `test/models/script_test.rb`, `test/test_helper.rb` (tmp-dir setup)

**Interfaces:**
- Consumes: `config.x.scripts_dir`.
- Produces on `Script`:
  - `code` / `code=` (String; reads the file, `""` if missing; written on save)
  - `path -> Pathname` (`scripts_dir/"#{name}.sh"`)
  - `file_missing? -> Boolean`
  - `running? -> Boolean` (any `runs.where(status: "running")`; `has_many :runs, dependent: :destroy` added in Task 3)
  - `Script.sync_from_directory! -> void` (creates records for `*.sh` files without one; ignores files whose basename fails the name format)

`test_helper.rb`: in `ActiveSupport::TestCase` setup, point `scripts_dir` and `script_cwd` at fresh `Dir.mktmpdir`s, restore + remove in teardown.

- [ ] **Step 1: Write failing tests**
  - `test "saving writes executable file"`: create `name: "hello", code: "echo hi\n"` → `File.read(path) == "echo hi\n"`, `File.stat(path).mode & 0o777 == 0o755`.
  - `test "name format rejected"`: `"../evil"`, `"a b"`, `""` each invalid; no file created in scripts_dir or its parent.
  - `test "duplicate name rejected"`.
  - `test "rename moves file"`: rename `hello`→`hi` → old path gone, new path has code.
  - `test "rename onto existing name rejected and files untouched"`.
  - `test "destroy deletes file"`.
  - `test "sync imports untracked files"`: write `scripts_dir/"x.sh"` and `scripts_dir/"bad name.sh"` → after sync, `Script.pluck(:name) == ["x"]`; second sync creates nothing new.
  - `test "file_missing? when file deleted"`.
- [ ] **Step 2:** `bin/rails test test/models/script_test.rb` → FAIL.
- [ ] **Step 3:** Implement. File writes happen in `after_save` (mkdir_p, rename old file if `name` changed via `saved_change_to_name`, write, chmod); delete in `after_destroy_commit`.
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat: Script model stored as files`.

### Task 3: Run model and log broadcasting

**Files:**
- Create: migration `create_runs` (`script:references` not null, `status:string` not null default `"running"`, `exit_code:integer`, `started_at:datetime` not null, `finished_at:datetime`, `log:text` not null default `""`, `pid:integer`, `code_snapshot:text` not null), `app/models/run.rb`, `app/views/runs/_status.html.erb`
- Modify: `app/models/script.rb` (`has_many :runs, -> { order(started_at: :desc) }, dependent: :destroy`; `before_destroy` aborts with error "Can't delete a running script" if `running?`)
- Test: `test/models/run_test.rb`

**Interfaces:**
- Produces on `Run`:
  - `STATUSES = %w[running succeeded failed stopped]`
  - `append_log!(chunk) -> void`: SQL concat (`update_all(["log = log || ?", chunk])`, no read-modify-write), then `broadcast_append_to self, target: "run_#{id}_log", html: ERB::Util.html_escape(chunk)`.
  - `finish!(status:, exit_code: nil, note: nil) -> void`: appends `note` (if any) via `append_log!`, sets status/exit_code/finished_at/pid nil, `broadcast_replace_to self, target: "run_#{id}_status", partial: "runs/status", locals: { run: self }`.
  - `duration -> Float | nil` (seconds; uses `Time.current` while running).
  - `running? -> Boolean`.
- `_status.html.erb`: `<div id="run_<%= run.id %>_status">` with status label, exit code, duration, and the Stop button (`button_to "Stop", stop_run_path(run)`) only while running. (Route arrives in Task 6; until then guard the partial test by rendering only finished runs, or add the routes now — add `resources :runs, only: :show do post :stop, on: :member end` here.)

- [ ] **Step 1: Failing tests**
  - `test "append_log! concatenates"`: two appends `"a"`, `"b"` → `reload.log == "ab"`.
  - `test "append_log! broadcasts escaped html"` using `assert_turbo_stream_broadcasts run` (turbo-rails test helper) and assert the captured payload includes `&lt;script&gt;` and not `<script>alert`.
  - `test "finish! sets fields and note"`: status `failed`, exit_code 1, note `"x\n"` → finished_at present, pid nil, log ends with `"x\n"`.
  - `test "status must be in STATUSES"`.
  - `test "script with running run cannot be destroyed"`: `destroy` returns false, file still exists.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: Run model with streamed log`.

### Task 4: ScriptRunner, stop, shutdown, recovery

**Files:**
- Create: `app/services/script_runner.rb`, `config/initializers/script_runner.rb`
- Test: `test/services/script_runner_test.rb`

**Interfaces:**
- Consumes: `Script#path`, `Script#code`, `Run#append_log!`, `Run#finish!`, `config.x.script_cwd`.
- Produces (module functions on `ScriptRunner`):
  - `start(script) -> Run` — raises `ScriptRunner::Error, "Script file is missing"` if `file_missing?`. Creates run (`status: "running"`, `started_at: now`, `code_snapshot: script.code`), spawns via `Open3.popen2e("bash", "-l", script.path.to_s, chdir: cwd, pgroup: true)` inside `Bundler.with_unbundled_env`, stores `pid`, registers it, and starts a reader thread that loops `readpartial(4096)` → `append_log!` (force UTF-8, `scrub`), then on EOF waits and calls `finish!(status: exit 0 ? "succeeded" : "failed", exit_code:)` — or `"stopped"` if the run was stopped. Thread body wrapped in `Rails.application.executor.wrap`.
  - `stop(run) -> void` — marks the run as stop-requested in the registry, `Process.kill("TERM", -pid)`; after 5 s still alive → `KILL`. Ignores `Errno::ESRCH`.
  - `stop_all -> void` — `stop` every registered run, then join reader threads (bounded wait).
  - `wait(run, timeout: 10) -> void` — test helper: joins that run's reader thread.
  - `recover_orphans! -> void` — every `Run.where(status: "running")` → `finish!(status: "failed", note: "\n[runner] Server restarted while this run was in progress.\n")`.
- Initializer: `Rails.application.config.after_initialize { if defined?(Rails::Server) then ScriptRunner.recover_orphans!; at_exit { ScriptRunner.stop_all } end }`.

Registry: a `Mutex`-guarded Hash `run_id => { pid:, thread:, stop_requested: }`. The registry is the only in-memory state.

- [ ] **Step 1: Failing tests** (all with `script_cwd`/`scripts_dir` tmp dirs; use `ScriptRunner.wait`)
  - `test "success captures output and exit 0"`: code `echo out; echo err >&2` → status `succeeded`, exit_code 0, log includes `out` and `err`.
  - `test "nonzero exit is failed"`: `exit 3` → `failed`, 3.
  - `test "runs in script_cwd"`: `pwd` → log includes the tmp cwd realpath.
  - `test "bundler env does not leak"`: `echo "G=${BUNDLE_GEMFILE:-none}"` → log includes `G=none`.
  - `test "partial lines joined"`: `printf a; sleep 0.3; printf b` → log == `"ab"`.
  - `test "stop kills process group"`: code `sleep 30 & echo $! > child.pid; wait` (child.pid written into cwd); start, wait until file exists, `stop` → status `stopped` within 6 s, and `Process.kill(0, child_pid)` raises `Errno::ESRCH`.
  - `test "missing file raises"`.
  - `test "recover_orphans! fails running runs"`.
  - `test "recovery not run outside server"`: boot already happened in test env → a run created as `running` before `Rails.application.config.after_initialize` hooks… simpler: assert `defined?(Rails::Server)` is falsy in tests and that the initializer source guards on it (`assert_match "Rails::Server", File.read(initializer)`).
  - Disable transactional tests in this file (`self.use_transactional_tests = false`, clean up in teardown) because the reader thread uses its own DB connection.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS (run file 3× to check flakiness).
- [ ] **Step 5:** Commit `feat: ScriptRunner with stop and shutdown handling`.

### Task 5: Dashboard and script editing (UI option B)

**Files:**
- Create: `app/controllers/scripts_controller.rb`, `app/views/scripts/{index,new,edit,_form,_card}.html.erb`, `app/javascript/controllers/tab_textarea_controller.js`
- Modify: `config/routes.rb`, `app/assets/stylesheets/application.css`
- Test: `test/controllers/scripts_controller_test.rb`

**Interfaces:**
- Routes: `root "scripts#index"`, `resources :scripts, except: :show do post :run, on: :member end` (`run` implemented in Task 6). `GET /scripts/:id` redirects to edit.
- `index`: calls `Script.sync_from_directory!` first. Heading "My scripts", "+ New script" link, grid of `_card`: name, last run (`✅`/`❌`/`⏹`/`●` + time, or "never run"), "file missing" badge, green "▶ Run" `button_to run_script_path` (disabled if `file_missing?`), "Edit" link.
- `edit` (the script page): `_form` (name field, monospace `<textarea name="script[code]" data-controller="tab-textarea">`, Save), Run button, Delete `button_to` with `data: { turbo_confirm: "Delete <name> and all its runs?" }` (disabled while `running?`), then past runs list: status icon, `started_at`, duration, exit code, each linking to `run_path`.
- `destroy` on a running script: redirect to edit with alert "Can't delete a running script".
- Stimulus `tab-textarea`: Tab key inserts `"\t"` at cursor instead of moving focus.

- [ ] **Step 1: Failing tests**
  - `test "index imports files and lists cards"`: write `scripts_dir/"a.sh"` → GET root → 200, body includes `a`.
  - `test "create writes file and redirects to edit"`.
  - `test "invalid name re-renders with 422"`.
  - `test "update changes code on disk"`.
  - `test "destroy removes script, runs, and file"`.
  - `test "destroy blocked while running"`: run with status `running` → script still exists, flash alert.
  - `test "edit lists past runs"`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement + CSS (grid of cards, green run button, dark monospace console class `.console` used in Task 6). **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: script dashboard and editor`.

### Task 6: Running, live log page, stop

**Files:**
- Create: `app/controllers/runs_controller.rb`, `app/views/runs/show.html.erb`, `app/javascript/controllers/autoscroll_controller.js`
- Modify: `app/controllers/scripts_controller.rb` (`run` action)
- Test: `test/controllers/runs_controller_test.rb`

**Interfaces:**
- Consumes: `ScriptRunner.start/stop`, `runs/_status` partial, `Run` targets `run_#{id}_log` / `run_#{id}_status`.
- `ScriptsController#run`: `ScriptRunner.start(@script)` → redirect to `run_path(run)`; on `ScriptRunner::Error` redirect to edit with that message as alert.
- `RunsController#show`: `turbo_stream_from @run`; script name linking back to edit; "Run again" button; `render "runs/status"`; `<pre id="run_<id>_log" class="console" data-controller="autoscroll"><%= @run.log %></pre>`; code snapshot in a collapsed `<details>` "Code that ran".
- `RunsController#stop`: `ScriptRunner.stop(@run)` if running → redirect to show.
- Stimulus `autoscroll`: MutationObserver scrolls to bottom on new content only if the user was already within 40px of the bottom.

- [ ] **Step 1: Failing tests** (non-transactional, tmp dirs)
  - `test "run starts and redirects to run page"`: POST run → redirect to `/runs/:id`; `ScriptRunner.wait`; run `succeeded`.
  - `test "run with missing file shows alert"`.
  - `test "show escapes html in log"`: run with log `<b>x</b>` → body includes `&lt;b&gt;x&lt;/b&gt;`.
  - `test "show subscribes to the run stream"`: body includes `turbo-cable-stream-source`.
  - `test "stop stops a running run"`: code `sleep 30` → POST stop → after wait, `stopped`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: live run page with stop`.

### Task 7: README and end-to-end check

**Files:**
- Create/replace: `README.md` (what it is, `bin/setup`, `bin/rails server`, open `http://localhost:3000`, scripts live in `scripts/` and are gitignored, runs start in `~` with a login shell, local-only warning)

- [ ] **Step 1:** Full suite: `bin/rails test` → 0 failures; `bin/rubocop` → no offenses.
- [ ] **Step 2:** Start `bin/rails server`; confirm `ss -ltnp | grep 3000` shows `127.0.0.1:3000` only.
- [ ] **Step 3:** In a browser: create `demo` with `for i in 1 2 3 4 5; do echo "tick $i"; sleep 1; done`, Run, watch lines arrive one per second, status turns succeeded; reload mid-run shows earlier lines then continues; Stop a `sleep 60` script; see both runs on the script page.
- [ ] **Step 4:** Ctrl-C the server while `sleep 60` runs → `pgrep -f "sleep 60"` empty.
- [ ] **Step 5:** Commit `docs: README`.
