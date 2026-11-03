# Shell Commands

A small Rails app that turns your own bash scripts into buttons. Create and
edit scripts in the browser, click to run them, watch the output live, and
read the logs of past runs.

> **This app runs arbitrary code on your machine.** It only listens on
> `127.0.0.1` and has no login. Keep it local.

## Run it

```bash
bin/setup --skip-server   # install gems, prepare the database
bin/rails server          # http://localhost:3000
```

## How it works

- **Scripts** are files in `scripts/<name>.sh`. Any `.sh` file you put there
  shows up as a button the next time you open the home page, and edits in
  the app are written straight to that file. The folder is gitignored, so
  your scripts stay on your machine.
- **Runs** start with `bash -l`, from your home folder, so they get the same
  `PATH`, rbenv, nvm and so on as a new terminal. stdout and stderr appear
  together in the log.
- **Stop** sends `TERM` to the script and everything it started, then
  `KILL` after 5 seconds. Stopping the server stops running scripts too.
- **History:** every run is kept, with its log, exit code, duration, and
  the exact code that ran. Deleting a script deletes its runs.

## Tests

Use Node.js 18+ for the dependency-free live-log client regression test,
which is invoked by the Minitest suite.

```bash
bin/rails test
bin/rubocop
```

## Script parameters

Scripts may declare ordered arguments using `# @param NAME=default` comments.
Parameterized scripts show a small form before Run; normal scripts still run in one click.
See [script parameter documentation](docs/script-parameters.md).

## Continuous integration (GitHub Actions)

Every pull request targeting `main`, and every push to `main`, runs the
[**Rails CI** workflow](.github/workflows/rails-ci.yml). It uses the existing
`bin/ci` script, so the exact same checks can run locally:

```bash
bin/ci
```

The suite installs dependencies, prepares the test SQLite database, checks
Ruby style, audits dependencies and importmap packages, runs Brakeman, Rails
tests, and validates seeds. A failed command makes the check fail.

### Require passing checks before merge

After the workflow has run at least once, visit **Settings → Branches** (or
**Settings → Rules → Rulesets**) for this repository and protect `main`:

1. Enable **Require a pull request before merging**.
2. Enable **Require status checks to pass before merging**.
3. Select the check named **Rails checks** from the **Rails CI** workflow.
4. Optionally require up-to-date branches and restrict bypass permissions.

Creating a workflow alone does **not** prevent merging failed PRs. The
branch rule is what enforces the check. This app has no configured deployment
pipeline; no automatic deployment is performed by this workflow.

## Script icons

Optionally attach a small PNG, JPEG, or WebP image (up to 1 MB) using the
script's **Edit** form. The image appears beside its name on the home page.
You can replace or remove it from the same form. Icons live locally in
`scripts/.icons/` (already gitignored), are not committed to Git, and
are deleted when their script is deleted. No migration or external storage
service is needed.

## Execution limits and confirmation

Configuration can be set through environment variables before starting Rails:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCRIPT_TIMEOUT_SECONDS` | `600` | Maximum duration, including waiting for inherited output pipes |
| `SCRIPT_MAX_LOG_BYTES` | `5242880` | Per-run captured output limit, including the truncation notice; minimum 1024 |
| `SCRIPT_MAX_CONCURRENT_RUNS` | `8` | Maximum active runs in this server process |

Timeouts send TERM to the process group, then KILL after five seconds, and
finish as `failed`. Manual Stop finishes as `stopped`. Reasons remain visible
even after logs are truncated. Output continues to be drained after truncation.
The concurrency limit rejects extra launches with a failed history entry.

Each execution uses the recorded code through a private, read-only, unlinked
snapshot descriptor. Editing or deleting the source cannot change that run,
and there is no named snapshot left after a crash. `$0` and `BASH_SOURCE` refer
to `/proc/self/fd/3`, rather than the original script path. Arguments, working
directory, and the restricted environment remain unchanged.

Add metadata to request a confirmation screen, optionally with parameters:

```bash
# @confirm=true
# @description=Stops processes listening on a specified port
# @param PORT=8000
```

The server requires an expiring confirmation token tied to the exact code.
Editing that code requires confirmation again. Run again uses the same flow.
Confirmation prevents accidental clicks; arbitrary scripts still run with your
user's privileges. Do not expose the app beyond localhost.

Use one Rails server process. The registry and concurrency limit are local to
that process. Normal background children are cleaned up when Bash exits;
scripts that deliberately detach with `setsid` can escape process-group
control. After an abrupt server death, startup verifies recorded Linux process
identities before signaling orphan groups. Legacy/unverifiable identities are
marked failed without signaling. Linux `/proc` is required for execution.

Icon uploads accept PNG, JPEG, and WebP files up to 1 MB. Validation checks
file signatures and size without decoding the image or requiring external
image tools. The server determines the response MIME type from the signature.
