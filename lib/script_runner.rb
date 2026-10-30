require "open3"

# Runs scripts in the background and owns their processes so they can be
# stopped, and killed when the server exits.
#
# Lives in lib/ and is excluded from autoloading: the registry of running
# processes is in-memory, and a development code reload must not forget it.
module ScriptRunner
  class Error < StandardError; end

  STOP_GRACE_PERIOD = 5 # seconds between TERM and KILL
  CHUNK_SIZE = 4096
  LEAKED_ENV = %w[RAILS_ENV RACK_ENV].freeze

  @registry = {}
  @mutex = Mutex.new

  class << self
    def start(script)
      raise Error, "Script file is missing" if script.file_missing?

      run = script.runs.create!(status: "running", started_at: Time.current, code_snapshot: script.code)
      env = Bundler.unbundled_env.except(*LEAKED_ENV)
      input, output, process = Open3.popen2e(env, "bash", "-l", script.path.to_s,
        chdir: Rails.configuration.x.script_cwd, pgroup: true, unsetenv_others: true)
      input.close # scripts take no input
      run.update_columns(pid: process.pid)

      @mutex.synchronize do
        @registry[run.id] = { pid: process.pid, stop_requested: false }
        @registry[run.id][:thread] = Thread.new { stream(run, output, process) }
      end
      run
    end

    def stop(run)
      pid = @mutex.synchronize do
        entry = @registry[run.id] or return
        entry[:stop_requested] = true
        entry[:pid]
      end
      signal_group("TERM", pid)
      Thread.new do
        sleep STOP_GRACE_PERIOD
        signal_group("KILL", pid) if group_alive?(pid)
      end
    end

    def stop_all
      run_ids = @mutex.synchronize { @registry.keys }
      run_ids.each { |id| stop(Run.new(id: id)) }
      threads = @mutex.synchronize { @registry.values.map { |entry| entry[:thread] } }
      threads.each { |thread| thread.join(STOP_GRACE_PERIOD + 3) }
    end

    # Blocks until the run's output is fully read and its status saved.
    def wait(run, timeout: 10)
      thread = @mutex.synchronize { @registry.dig(run.id, :thread) }
      thread&.join(timeout)
    end

    # A run still marked running at boot belonged to a previous server.
    def recover_orphans!
      Run.where(status: "running").find_each do |run|
        run.finish!(status: "failed", note: "\n[runner] Server restarted while this run was in progress.\n")
      end
    end

    private

    def stream(run, output, process)
      Rails.application.executor.wrap do
        loop { run.append_log!(output.readpartial(CHUNK_SIZE).force_encoding(Encoding::UTF_8).scrub) }
      rescue EOFError
        status = process.value
        stopped = @mutex.synchronize { @registry.dig(run.id, :stop_requested) }
        run.finish!(status: final_status(status, stopped), exit_code: status.exitstatus)
      ensure
        output.close unless output.closed?
      end
    ensure
      @mutex.synchronize { @registry.delete(run.id) }
    end

    def final_status(status, stopped)
      return "stopped" if stopped
      status.success? ? "succeeded" : "failed"
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      # Already gone.
    end

    def group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end
