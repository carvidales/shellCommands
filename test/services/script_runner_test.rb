require "test_helper"

class ScriptRunnerTest < ActiveSupport::TestCase
  # The reader thread writes through its own DB connection, so its writes
  # must be committed and visible to the test.
  self.use_transactional_tests = false

  teardown do
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
end
