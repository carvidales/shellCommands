# Script parameters

Add one metadata comment per parameter to the Bash script:

```bash
#!/usr/bin/env bash
# @param PORT=3000
# @param URL=https://example.com
printf 'Port: %s\\nURL: %s\\n' "$1" "$2"
```

The metadata lines define the order of positional arguments. When you click
**Run**, the app displays a form prefilled with the declared defaults.

Scripts without declarations keep their existing one-click behavior.

Values are passed directly as separate arguments to `bash -l script.sh`,
not interpolated into a shell command. Quote positional parameters in Bash
(e.g., `"$1"`) to preserve spaces and avoid glob expansion.

Limits: up to 10 unique parameters, each up to 1024 bytes. Parameter values
must be plain strings without NUL characters. Unexpected fields are rejected.

The app stores script source and command output in run history, but does not
store a separate record of the submitted parameter values. Avoid printing
secrets in your scripts, because output logs are retained.

The script remains executable directly from the terminal:

```bash
bash scripts/check-port.sh 8080 https://example.com
```

The form currently supports text values only. The metadata defaults are
literal strings and should not contain credentials. As with all scripts in
this application, only use the service on localhost.

## Confirmation metadata

`# @confirm=true` requires a server-verified confirmation before execution.
`# @description=...` supplies plain text on that screen. Confirmation works
with or without parameters and also applies to **Run again**. Tokens expire
after 15 minutes and become invalid if the code changes. Duplicate or malformed
reserved metadata is rejected at execution; ordinary Bash comments are unaffected.

Descriptions also appear on dashboard cards. The optional **Description**
field in the script editor manages this comment automatically, with a limit
of 200 characters on one line. Clearing the field removes the comment.
