require "test_helper"

class RunsControllerTest < ActionDispatch::IntegrationTest
  # Runs execute in a background thread with its own DB connection.
  self.use_transactional_tests = false

  teardown do
    ScriptRunner.stop_all
    Run.delete_all
    Script.delete_all
  end

  test "run starts and redirects to run page" do
    script = Script.create!(name: "hello", code: "echo hi")

    post run_script_path(script)

    run = script.runs.first
    assert_redirected_to run_path(run)
    ScriptRunner.wait(run)
    assert_equal "succeeded", run.reload.status
  end

  test "run with missing file shows alert" do
    script = Script.create!(name: "gone", code: "echo hi")
    File.delete(script.path)

    post run_script_path(script)

    assert_redirected_to edit_script_path(script)
    assert_equal "Script file is missing", flash[:alert]
    assert_equal 0, Run.count
  end

  test "show escapes html in log" do
    script = Script.create!(name: "hello", code: "echo hi")
    run = script.runs.create!(status: "succeeded", exit_code: 0, started_at: 1.second.ago, finished_at: Time.current,
      code_snapshot: "echo hi", log: "<b>x</b>\n")

    get run_path(run)

    assert_response :success
    assert_includes response.body, "&lt;b&gt;x&lt;/b&gt;"
    assert_select "pre#run_#{run.id}_log.console"
    assert_select "#run_#{run.id}_status", text: /Succeeded/
  end

  test "show subscribes to the run stream" do
    script = Script.create!(name: "hello", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "echo hi")

    get run_path(run)

    assert_select "turbo-cable-stream-source"
    assert_select "form[action='#{stop_run_path(run)}']"
  end

  test "stop stops a running run" do
    script = Script.create!(name: "sleepy", code: "sleep 30")
    post run_script_path(script)
    run = script.runs.first

    post stop_run_path(run)

    assert_redirected_to run_path(run)
    ScriptRunner.wait(run, timeout: 8)
    assert_equal "stopped", run.reload.status
  end
end
