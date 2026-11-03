require "test_helper"

# Lets a test make Run#append_log! blow up, like a DB or broadcast error would.
module FailingAppend
  mattr_accessor :enabled, default: false

  def append_log!(chunk)
    raise "database is locked" if FailingAppend.enabled
    super
  end
end
Run.prepend(FailingAppend)

# Counts executor wraps that are open, to check the runner doesn't hold one
# for the whole run (in development that blocks code reloading).
module OpenWraps
  mattr_accessor :count, default: 0
  def self.run = self.count += 1
  def self.complete(_) = self.count -= 1
end
Rails.application.executor.register_hook(OpenWraps)

class ScriptRunnerTest < ActiveSupport::TestCase
  # The reader thread writes through its own DB connection, so its writes
  # must be committed and visible to the test.
  self.use_transactional_tests = false

  teardown do
    FailingAppend.enabled = false
    ScriptRunner.stop_all
    Run.delete_all
    Script.delete_all
  end

  def run_script(code)
    script = Script.create!(name: "s#{SecureRandom.hex(4)}", code: code)
    run = ScriptRunner.start(script)
    ScriptRunner.wait(run)
    run.reload
  end

  test "success captures output and exit 0" do
    run = run_script("echo out; echo err >&2")
    assert_equal "succeeded", run.status
    assert_equal 0, run.exit_code
    assert_includes run.log, "out"
    assert_includes run.log, "err"
    assert run.finished_at
    assert_equal "echo out; echo err >&2", run.code_snapshot
  end

  test "nonzero exit is failed" do
    run = run_script("exit 3")
    assert_equal "failed", run.status
    assert_equal 3, run.exit_code
  end

  test "runs in script_cwd" do
    run = run_script("pwd")
    assert_includes run.log, File.realpath(Rails.configuration.x.script_cwd)
  end

  test "bundler env does not leak" do
    run = run_script('echo "G=${BUNDLE_GEMFILE:-none}"')
    assert_includes run.log, "G=none"
  end

  test "partial lines joined" do
    run = run_script("printf a; sleep 0.3; printf b")
    assert run.log.end_with?("ab"), run.log.inspect
  end

  test "stop kills process group" do
    script = Script.create!(name: "sleepy", code: "sleep 30 &\necho $! > child.pid\nwait\n")
    pid_file = File.join(Rails.configuration.x.script_cwd, "child.pid")
    run = ScriptRunner.start(script)
    Timeout.timeout(5) { sleep 0.05 until File.size?(pid_file) }
    child_pid = File.read(pid_file).to_i

    ScriptRunner.stop(run)
    ScriptRunner.wait(run, timeout: 8)

    assert_equal "stopped", run.reload.status
    assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
  end

  test "missing file raises" do
    script = Script.create!(name: "gone", code: "echo hi")
    File.delete(script.path)
    error = assert_raises(ScriptRunner::Error) { ScriptRunner.start(script) }
    assert_equal "Script file is missing", error.message
  end

  test "recover_orphans! fails running runs" do
    script = Script.create!(name: "orphan", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "echo hi", pid: 999_999)

    ScriptRunner.recover_orphans!

    run.reload
    assert_equal "failed", run.status
    assert_includes run.log, "Server restarted while this run was in progress."
  end

  test "recovery and shutdown hooks only run in the server" do
    assert_not defined?(Rails::Server)
    source = File.read(Rails.root.join("config/initializers/script_runner.rb"))
    assert_match "defined?(Rails::Server)", source
  end

  test "multibyte output split across reads stays intact" do
    run = run_script(%q(head -c 4095 /dev/zero | tr '\\0' a; printf '\\xc3'; sleep 0.2; printf '\\xa9 done'))
    assert run.log.end_with?("é done"), run.log[-20..].inspect
    assert_not_includes run.log, "\uFFFD"
  end

  test "a running script does not hold the executor open" do
    baseline = OpenWraps.count # the test itself runs inside an executor wrap
    script = Script.create!(name: "slow", code: "echo started; sleep 4")
    run = ScriptRunner.start(script)
    Timeout.timeout(5) { sleep 0.05 until run.reload.log.include?("started") }

    # Writing the first line takes a moment; after that the script is just
    # sleeping and nothing should be held open.
    deadline = Time.current + 2
    sleep 0.05 until OpenWraps.count == baseline || Time.current > deadline
    assert_equal baseline, OpenWraps.count
    assert run.reload.running?, "the script should still be running"

    ScriptRunner.stop(run)
    ScriptRunner.wait(run)
  end

  test "an error while streaming fails the run and kills the script" do
    FailingAppend.enabled = true
    script = Script.create!(name: "boom", code: "echo $$ > boom.pid; echo hi; sleep 30")
    pid_file = File.join(Rails.configuration.x.script_cwd, "boom.pid")
    run = ScriptRunner.start(script)
    Timeout.timeout(5) { sleep 0.05 until File.size?(pid_file) }
    ScriptRunner.wait(run, timeout: 8)
    FailingAppend.enabled = false

    run.reload
    assert_equal "failed", run.status
    assert_includes run.log, "database is locked"
    Timeout.timeout(8) { sleep 0.05 while alive?(-File.read(pid_file).to_i) }
  end

  test "start records the server pid" do
    run = run_script("true")
    assert_equal Process.pid, run.server_pid
  end

  test "recover_orphans! leaves runs owned by another live server alone" do
    script = Script.create!(name: "other", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "x", server_pid: Process.ppid)

    ScriptRunner.recover_orphans!

    assert_equal "running", run.reload.status
  end

  test "recover_orphans! kills the orphaned script" do
    orphan = Process.spawn("sleep", "30", pgroup: true)
    Process.detach(orphan)
    script = Script.create!(name: "orphan2", code: "sleep 30")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "x", pid: orphan, server_pid: dead_pid,
      process_start_token: ScriptRunner.send(:process_start_token, orphan))

    ScriptRunner.recover_orphans!

    assert_equal "failed", run.reload.status
    Timeout.timeout(5) { sleep 0.05 while alive?(orphan) }
  end

  test "stop is idempotent" do
    script = Script.create!(name: "idempotent", code: "sleep 30")
    run = ScriptRunner.start(script)
    assert ScriptRunner.stop(run)
    assert_not ScriptRunner.stop(run)
    ScriptRunner.wait(run, timeout: 8)
    assert_equal "stopped", run.reload.status
  end

  test "does not leak Rails environment secrets to scripts" do
    ENV["SECRET_FOR_RUNNER_TEST"] = "private"
    run = run_script('echo "SECRET=${SECRET_FOR_RUNNER_TEST:-none}"')
    assert_includes run.log, "SECRET=none"
  ensure
    ENV.delete("SECRET_FOR_RUNNER_TEST")
  end

  test "orphan recovery never signals unverifiable PIDs" do
    script = Script.create!(name: "unknown", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "x", pid: Process.pid)
    ScriptRunner.recover_orphans!
    assert_equal "failed", run.reload.status
    assert_includes run.log, "Could not verify the old process identity"
  end

  test "process start token is stable for a running process" do
    token = ScriptRunner.send(:process_start_token, Process.pid)
    assert_equal token, ScriptRunner.send(:process_start_token, Process.pid)
    assert token if File.directory?("/proc")
  end

  test "executes the recorded snapshot even when source changes before spawn" do
    script = Script.create!(name: "snapshot", code: 'printf "%s:%s" old "$1"')
    original = Open3.method(:popen2e)
    snapshot_path = nil
    Open3.define_singleton_method(:popen2e) do |*args, **options|
      snapshot_path = options.fetch(3).path
      File.write(script.path, "echo changed")
      assert_mode = options.fetch(3).stat.mode & 0o777
      raise "insecure snapshot" unless assert_mode == 0o400
      original.call(*args, **options)
    end
    run = ScriptRunner.start(script, args: [ "a;echo injected" ])
    ScriptRunner.wait(run)
    assert_equal 'printf "%s:%s" old "$1"', run.reload.code_snapshot
    assert_equal "old:a;echo injected", run.log
    assert_not File.exist?(snapshot_path)
  ensure
    Open3.define_singleton_method(:popen2e, original) if original
  end

  test "editing a source during execution cannot alter the running snapshot" do
    script = Script.create!(name: "changing", code: "touch ready; while [ ! -f release ]; do sleep 0.02; done; echo original")
    run = ScriptRunner.start(script)
    await_file("ready")
    File.write(script.path, "echo changed")
    File.write(File.join(Rails.configuration.x.script_cwd, "release"), "")
    ScriptRunner.wait(run)
    assert_equal "original\n", run.reload.log
  end

  test "timeout terminates a TERM resistant group and records failure" do
    old = Rails.configuration.x.execution_timeout
    Rails.configuration.x.execution_timeout = 0.2
    run = run_script("trap '' TERM; echo ready; while :; do sleep 1; done")
    assert_equal "failed", run.status
    assert_includes run.termination_note, "timed out"
    assert_nil run.pid
  ensure
    Rails.configuration.x.execution_timeout = old
  end

  test "output is bounded and drained after truncation with valid UTF8" do
    old = Rails.configuration.x.max_log_bytes
    Rails.configuration.x.max_log_bytes = 1024
    run = run_script("yes é | head -c 100000; echo done > drained")
    assert_equal "succeeded", run.status
    assert File.exist?(File.join(Rails.configuration.x.script_cwd, "drained"))
    assert_operator run.log.bytesize, :<=, 1024
    assert run.log.valid_encoding?
    assert_equal 1, run.log.scan("Output truncated").length
  ensure
    Rails.configuration.x.max_log_bytes = old
  end

  test "background children are cleaned up even after the leader exits" do
    run = run_script("sleep 30 > /dev/null 2>&1 & echo $! > background.pid")
    assert_equal "succeeded", run.status
    pid = File.read(File.join(Rails.configuration.x.script_cwd, "background.pid")).to_i
    # A reparented zombie is dead but can remain visible until PID 1 reaps it.
    stat = File.read("/proc/#{pid}/stat") if File.exist?("/proc/#{pid}/stat")
    assert stat.nil? || stat.rpartition(") ").last.start_with?("Z "), stat
  end

  test "simultaneous runs of one script have independent output and stop state" do
    script = Script.create!(name: "parallel", code: 'echo "$1"; sleep 30')
    first = ScriptRunner.start(script, args: [ "one" ])
    second = ScriptRunner.start(script, args: [ "two" ])
    Timeout.timeout(5) { sleep 0.02 until first.reload.log.include?("one") && second.reload.log.include?("two") }
    ScriptRunner.stop(first)
    ScriptRunner.wait(first)
    assert_equal "stopped", first.reload.status
    assert second.reload.running?
    ScriptRunner.stop(second)
    ScriptRunner.wait(second)
    assert_equal "two\n", second.reload.log.lines.first
  end

  test "spawn failure cleans up the snapshot and records failure" do
    original = Open3.method(:popen2e)
    snapshot_path = nil
    Open3.define_singleton_method(:popen2e) do |*args, **options|
      snapshot_path = options.fetch(3).path
      raise Errno::ENOENT, "test spawn failure"
    end
    run = run_script("echo unused")
    assert_equal "failed", run.status
    assert_includes run.log, "Could not start"
    assert_not File.exist?(snapshot_path)
  ensure
    Open3.define_singleton_method(:popen2e, original) if original
  end

  test "concurrency limit rejects another launch without spawning it" do
    old = Rails.configuration.x.max_concurrent_runs
    Rails.configuration.x.max_concurrent_runs = 1
    script = Script.create!(name: "limited", code: "sleep 30")
    first = ScriptRunner.start(script)
    second = ScriptRunner.start(script)
    assert_equal "failed", second.reload.status
    assert_includes second.log, "Maximum concurrent executions"
    assert first.reload.running?
  ensure
    Rails.configuration.x.max_concurrent_runs = old
  end

  test "recovery does not signal a reused process identity" do
    child = Process.spawn("sleep", "30", pgroup: true)
    script = Script.create!(name: "reused", code: "echo unused")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "echo unused", pid: child,
      server_pid: dead_pid, process_start_token: "incorrect-start-token")
    ScriptRunner.recover_orphans!
    assert_equal "failed", run.reload.status
    assert alive?(child)
    assert_includes run.termination_note, "Could not verify"
  ensure
    if child
      Process.kill("KILL", child) rescue nil
      Process.wait(child) rescue nil
    end
  end

  def await_file(name)
    Timeout.timeout(5) { sleep 0.02 until File.exist?(File.join(Rails.configuration.x.script_cwd, name)) }
  end

  private

  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
