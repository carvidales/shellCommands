require "open3"
require "tempfile"

# Runs scripts in the background and owns their processes so they can be
# stopped, and killed when the server exits.
#
# Lives in lib/ and is excluded from autoloading: the registry of running
# processes is in-memory, and a development code reload must not forget it.
module ScriptRunner
  class Error < StandardError; end

  STOP_GRACE_PERIOD = 5
  CHUNK_SIZE = 4096
  LOG_FLUSH_BYTES = 16 * 1024
  LOG_FLUSH_INTERVAL = 0.1
  # Only forward basic shell variables, not credentials from the Rails server.
  # Shell startup files can still set variables; this is not a sandbox.
  SCRIPT_ENV = %w[HOME USER LOGNAME SHELL PATH LANG LC_ALL LC_CTYPE TERM TMPDIR
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR].freeze

  # Turns raw output bytes into UTF-8 text, holding back a character that is
  # split across two reads instead of mangling both halves.
  class Utf8Chunker
    def initialize
      @pending = "".b
    end

    def call(bytes)
      data = @pending + bytes.b
      held = incomplete_tail_length(data)
      @pending = data.byteslice(data.bytesize - held, held)
      to_text(data.byteslice(0, data.bytesize - held))
    end

    def flush
      rest, @pending = @pending, "".b
      to_text(rest)
    end

    private

    def to_text(bytes) = bytes.force_encoding(Encoding::UTF_8).scrub

    # Bytes at the end that start a multibyte character but don't finish it.
    def incomplete_tail_length(data)
      (1..[ 3, data.bytesize ].min).each do |back|
        byte = data.getbyte(data.bytesize - back)
        next if byte & 0xC0 == 0x80 # continuation byte, keep looking for the lead

        needed = if byte >= 0xF0 then 4 elsif byte >= 0xE0 then 3 elsif byte >= 0xC0 then 2 else 1 end
        return needed > back ? back : 0
      end
      0
    end
  end

  @registry = {}
  @mutex = Mutex.new

  class << self
    def start(script, args: [])
      raise Error, "Script file is missing" if script.file_missing?

      run = script.runs.create!(status: "running", started_at: Time.current,
        code_snapshot: script.code, server_pid: Process.pid,
        server_start_token: process_start_token(Process.pid))
      input = output = process = snapshot = nil
      begin
        snapshot = Tempfile.create([ "shell-command-", ".sh" ])
        snapshot.write(run.code_snapshot)
        snapshot.flush
        snapshot.chmod(0o400)
        writable_snapshot = snapshot
        snapshot = File.open(writable_snapshot.path, "rb")
        writable_snapshot.close
        # Linux keeps the inode alive through the inherited descriptor. There
        # is no pathname to leak even if the Rails server is SIGKILLed.
        File.unlink(snapshot.path)
        env = Bundler.unbundled_env.slice(*SCRIPT_ENV)
        # Stop must not observe a spawned process before it is registered.
        @mutex.synchronize do
          raise Error, "Maximum concurrent executions reached" if @registry.size >= Rails.configuration.x.max_concurrent_runs
          input, output, process = Open3.popen2e(env, "bash", "-l", "-c",
            'IFS= read -r ready || exit 125; exec "$BASH" "$@"', "shell-commands", "/proc/self/fd/3", *args,
            chdir: Rails.configuration.x.script_cwd, pgroup: true, unsetenv_others: true, 3 => snapshot)
          token = process_start_token(process.pid)
          run.update_columns(pid: process.pid, process_start_token: token)
          @registry[run.id] = { pid: process.pid, token: token, stop_requested: false,
            deadline: monotonic + Rails.configuration.x.execution_timeout }
          @registry[run.id][:thread] = Thread.new { stream(run.id, output, process, snapshot) }
          # Keep the Bash leader alive until its identity and registry entry
          # are known, including for scripts that immediately background work.
          input.write("ready\n")
          input.close
        end
      rescue StandardError => error
        # A child can start successfully before persisting its PID fails.
        signal_group("KILL", process.pid) if process
        process.value if process
        snapshot.close if snapshot && !snapshot.closed?
        File.unlink(snapshot.path) if snapshot && File.exist?(snapshot.path)
        input.close if input && !input.closed?
        output.close if output && !output.closed?
        @mutex.synchronize { @registry.delete(run.id) }
        begin
          run.finish!(status: "failed", note: "[runner] Could not start the script: #{error.message}\n")
        rescue StandardError => persistence_error
          Rails.logger.error("[runner] run #{run.id}: #{persistence_error.class}: #{persistence_error.message}")
          raise
        end
      end
      run
    end

    # Stop is idempotent. Signal while holding the lock so streaming cleanup
    # cannot remove the registry entry before the first signal.
    def stop(run)
      @mutex.synchronize do
        entry = @registry[run.id]
        return false unless entry && !entry[:stop_requested]

        request_stop(entry, :manual)
      end
      true
    end

    def stop_all
      entries = @mutex.synchronize { @registry.map { |id, entry| [ id, entry[:thread] ] } }
      entries.each { |id, _| stop(Run.new(id: id)) }
      entries.each { |_, thread| thread&.join(STOP_GRACE_PERIOD + 3) }
    end

    # Blocks until the run's output is fully read and its status saved.
    def wait(run, timeout: 10)
      thread = @mutex.synchronize { @registry.dig(run.id, :thread) }
      thread&.join(timeout)
    end

    # A persisted PID is unsafe to signal without verifying process identity.
    # /proc provides a kernel start token on Linux; on other platforms (or
    # older rows without tokens) mark failed but do not signal an unknown PID.
    def recover_orphans!
      Run.where(status: "running").find_each do |run|
        next if other_server_owns?(run)

        owned = run.pid && run.process_start_token && owned_group?(run.pid, run.process_start_token)
        if owned
          signal_group("TERM", run.pid)
          Thread.new do
            sleep STOP_GRACE_PERIOD
            signal_group("KILL", run.pid) if owned_group?(run.pid, run.process_start_token)
          end
        end
        note = "\n[runner] Server restarted while this run was in progress.\n"
        note += "[runner] Could not verify the old process identity; no signal was sent.\n" if run.pid && !owned
        run.finish!(status: "failed", note: note)
      end
    end

    private

    # Field 22 in /proc/<pid>/stat (starting with field 3 after the closing
    # parenthesis). Use the last ') ' to support spaces in process names.
    def process_start_token(pid)
      data = File.read("/proc/#{pid}/stat")
      data.rpartition(") ").last.split[19]
    rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
      nil
    end

    def other_server_owns?(run)
      return false unless run.server_pid && run.server_pid != Process.pid && process_alive?(run.server_pid)
      return true unless run.server_start_token # legacy row: fail closed

      process_start_token(run.server_pid) == run.server_start_token
    end

    def owned_group?(pid, token)
      return false unless pid && group_alive?(pid)
      if token
        current = process_start_token(pid)
        return current == token if current
        # Linux reserves a PGID while members remain, even after its leader
        # has been reaped. A new leader at this PID would have a new token.
        return !File.exist?("/proc/#{pid}")
      end
      Process.getpgid(pid) == pid
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Flush small chunks promptly, but batch noisy commands to avoid a database
    # update and Turbo broadcast for every 4 KB read.
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def request_stop(entry, reason)
      return if entry[:stop_requested]
      entry[:stop_requested] = reason
      entry[:kill_at] = monotonic + STOP_GRACE_PERIOD
      signal_group("TERM", entry[:pid]) if owned_group?(entry[:pid], entry[:token])
    end

    def stream(run_id, output, process, snapshot)
      chunker = Utf8Chunker.new
      buffer = +""
      last_flush = monotonic
      eof = false
      begin
        loop do
          if !eof && IO.select([ output ], nil, nil, LOG_FLUSH_INTERVAL)
            begin
              buffer << chunker.call(output.readpartial(CHUNK_SIZE))
            rescue EOFError
              buffer << chunker.flush
              eof = true
            end
          elsif eof
            sleep LOG_FLUSH_INTERVAL
          end
          now = monotonic
          if eof || buffer.bytesize >= LOG_FLUSH_BYTES || now - last_flush >= LOG_FLUSH_INTERVAL
            flush_log(run_id, buffer)
            last_flush = now
          end
          completed = process.join(0)
          reason, done, killed = @mutex.synchronize do
            entry = @registry.fetch(run_id)
            alive = owned_group?(entry[:pid], entry[:token])
            if !entry[:stop_requested]
              if now >= entry[:deadline] && (!completed || !eof)
                request_stop(entry, :timeout)
              elsif completed && alive
                request_stop(entry, :children)
              end
            end
            if entry[:kill_at] && now >= entry[:kill_at] && !entry[:killed]
              signal_group("KILL", entry[:pid]) if alive
              entry[:killed] = true
            end
            [ entry[:stop_requested], completed && (!alive || entry[:killed]), entry[:killed] ]
          end
          next unless done && (eof || killed)
          unless eof
            buffer << chunker.flush
            flush_log(run_id, buffer)
          end

          status = process.value
          note = case reason
          when :timeout then "\n[runner] Execution timed out.\n"
          when :manual then "\n[runner] Stopped by user.\n"
          when :children then "\n[runner] Cleaned up background processes after Bash exited.\n"
          end
          with_run(run_id) do |run|
            run.finish!(status: reason == :timeout ? "failed" : final_status(status, reason == :manual),
              exit_code: status.exitstatus, note: note)
          end
          break
        end
      rescue StandardError => error
        abandon(run_id, process, error)
      ensure
        output.close unless output.closed?
        snapshot.close unless snapshot.closed?
        File.unlink(snapshot.path) if File.exist?(snapshot.path)
        @mutex.synchronize { @registry.delete(run_id) }
      end
    end

    def flush_log(run_id, buffer)
      return if buffer.empty?
      text = buffer.dup
      with_run(run_id) { |run| run.append_log!(text) }
      buffer.clear
    end

    # Something broke while streaming (DB, broadcast...). Kill the script and
    # record the failure without relying on the code path that just failed.
    def abandon(run_id, process, error)
      entry = @mutex.synchronize { @registry[run_id] }
      signal_group("KILL", process.pid) if entry && owned_group?(entry[:pid], entry[:token])
      process.value
      Rails.application.executor.wrap do
        scope = Run.where(id: run_id)
        note = "\n[runner] #{error.class}: #{error.message}\n".truncate_bytes(4096)
        limit = Rails.configuration.x.max_log_bytes
        scope.update_all([ "log = CASE WHEN length(CAST(log AS BLOB)) + ? <= ? THEN log || ? ELSE log END", note.bytesize, limit, note ])
        scope.update_all(status: "failed", finished_at: Time.current, pid: nil, termination_note: note)
        run = Run.find_by(id: run_id)
        run&.broadcast_replace_to(run, target: "run_#{run_id}_status",
          partial: "runs/status", locals: { run: run })
      rescue StandardError => broadcast_error
        Rails.logger.error("[runner] run #{run_id}: #{broadcast_error.message}")
      end
    end

    # Each DB write gets its own short executor wrap. Holding one for the whole
    # run would block development code reloading until the script ends.
    def with_run(run_id)
      Rails.application.executor.wrap { yield Run.find(run_id) }
    end

    def final_status(status, stopped)
      return "stopped" if stopped
      status.success? ? "succeeded" : "failed"
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      # Already gone, or the pid now belongs to someone else.
    end

    def group_alive?(pid) = process_alive?(-pid)

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
