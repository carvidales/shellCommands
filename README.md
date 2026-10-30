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

```bash
bin/rails test
bin/rubocop
```
