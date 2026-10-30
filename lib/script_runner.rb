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
    def start(script)
      raise Error, "Script file is missing" if script.file_missing?

      run = script.runs.create!(status: "running", started_at: Time.current,
        code_snapshot: script.code, server_pid: Process.pid)
      begin
        env = Bundler.unbundled_env.except(*LEAKED_ENV)
        input, output, process = Open3.popen2e(env, "bash", "-l", script.path.to_s,
          chdir: Rails.configuration.x.script_cwd, pgroup: true, unsetenv_others: true)
      rescue SystemCallError => error
        run.finish!(status: "failed", note: "[runner] Could not start the script: #{error.message}\n")
        return run
      end
      input.close # scripts take no input
      run.update_columns(pid: process.pid)

      @mutex.synchronize do
        @registry[run.id] = { pid: process.pid, stop_requested: false }
        @registry[run.id][:thread] = Thread.new { stream(run.id, output, process) }
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

    # A run still marked running at boot belonged to a server that is gone,
    # unless another server process (started by accident) still owns it.
    def recover_orphans!
      Run.where(status: "running").find_each do |run|
        next if run.server_pid && run.server_pid != Process.pid && process_alive?(run.server_pid)

        signal_group("TERM", run.pid) if run.pid
        run.finish!(status: "failed", note: "\n[runner] Server restarted while this run was in progress.\n")
      end
    end

    private

    def stream(run_id, output, process)
      chunker = Utf8Chunker.new
      begin
        loop do
          text = chunker.call(output.readpartial(CHUNK_SIZE))
          with_run(run_id) { |run| run.append_log!(text) } unless text.empty?
        end
      rescue EOFError
        rest = chunker.flush
        status = process.value
        stopped = @mutex.synchronize { @registry.dig(run_id, :stop_requested) }
        with_run(run_id) do |run|
          run.append_log!(rest) unless rest.empty?
          run.finish!(status: final_status(status, stopped), exit_code: status.exitstatus)
        end
      end
    rescue StandardError => error
      abandon(run_id, process, error)
    ensure
      output.close unless output.closed?
      @mutex.synchronize { @registry.delete(run_id) }
    end

    # Something broke while streaming (DB, broadcast...). Kill the script and
    # record the failure without relying on the code path that just failed.
    def abandon(run_id, process, error)
      signal_group("KILL", process.pid)
      process.value
      Rails.application.executor.wrap do
        Run.where(id: run_id).update_all([ "log = log || ?", "\n[runner] #{error.class}: #{error.message}\n" ])
        Run.where(id: run_id).update_all(status: "failed", finished_at: Time.current, pid: nil)
        Run.find(run_id).broadcast_replace_to(Run.find(run_id), target: "run_#{run_id}_status",
          partial: "runs/status", locals: { run: Run.find(run_id) })
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
