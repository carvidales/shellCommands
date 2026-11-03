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

  test "show.json returns the log, its length, and the status html" do
    script = Script.create!(name: "hello", code: "echo hi")
    run = script.runs.create!(status: "succeeded", exit_code: 0, started_at: 1.second.ago, finished_at: Time.current,
      code_snapshot: "echo hi", log: "héllo\n")

    get run_path(run, format: :json)

    body = response.parsed_body
    assert_equal "héllo\n", body["log"]
    assert_equal 6, body["length"]
    assert_includes body["status_html"], "run_#{run.id}_status"
  end

  test "show renders the log length for the live view" do
    script = Script.create!(name: "hello", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: "echo hi", log: "héllo\n")

    get run_path(run)

    assert_select "[data-controller~='run-log'][data-run-log-length-value='6'][data-run-log-url-value='#{run_path(run, format: :json)}']"
  end

  test "run again links to parameter form for parameterized scripts" do
    script = Script.create!(name: "params", code: "# @param PORT=3000\necho \"$1\"\n")
    run = script.runs.create!(status: "succeeded", started_at: 1.second.ago,
      finished_at: Time.current, code_snapshot: script.code)

    get run_path(run)

    assert_response :success
    assert_select "a[href='#{parameters_script_path(script)}']", text: /Run again/
    assert_select "form[action='#{run_script_path(script)}']", count: 0
  end

  test "run again stays one click for scripts without parameters" do
    script = Script.create!(name: "plain", code: "echo hi\n")
    run = script.runs.create!(status: "succeeded", started_at: 1.second.ago,
      finished_at: Time.current, code_snapshot: script.code)

    get run_path(run)

    assert_response :success
    assert_select "form[action='#{run_script_path(script)}']", count: 1
  end
  test "confirmation is enforced on direct POST and Run again" do
    script = Script.create!(name: "danger", code: "# @confirm=true\n# @description=Stop something\n# @param PORT=3000\necho \"$1\"")
    assert_no_difference("Run.count") { post run_script_path(script), params: { arguments: { PORT: "4000" } } }
    assert_redirected_to parameters_script_path(script)
    get parameters_script_path(script)
    assert_response :success
    assert_includes response.body, "Stop something"
    token = css_select("input[name='confirmation_token']").first["value"]
    post run_script_path(script), params: { confirmation_token: token, arguments: { PORT: "4000" } }
    run = script.runs.last
    ScriptRunner.wait(run)
    assert_equal "4000\n", run.reload.log
    get run_path(run)
    assert_select "a[href='#{parameters_script_path(script)}']", text: /Run again/
    script.update!(code: "# @confirm=true\necho changed")
    assert_no_difference("Run.count") { post run_script_path(script), params: { confirmation_token: token } }
  end

  test "confirmation works without parameters and rejects forged tokens" do
    script = Script.create!(name: "confirm_plain", code: "# @confirm=true\necho ok")
    assert_no_difference("Run.count") { post run_script_path(script), params: { confirmation_token: "forged" } }
    get parameters_script_path(script)
    token = css_select("input[name='confirmation_token']").first["value"]
    post run_script_path(script), params: { confirmation_token: token }
    run = script.runs.last
    ScriptRunner.wait(run)
    assert_equal "ok\n", run.reload.log
  end
  test "confirmation expires and cannot authorize a different script" do
    script = Script.create!(name: "expiring", code: "# @confirm=true\necho ok")
    other = Script.create!(name: "other_confirmation", code: script.code)
    get parameters_script_path(script)
    token = css_select("input[name='confirmation_token']").first["value"]
    assert_no_difference("Run.count") { post run_script_path(other), params: { confirmation_token: token } }
    travel 16.minutes do
      assert_no_difference("Run.count") { post run_script_path(script), params: { confirmation_token: token } }
      assert_redirected_to parameters_script_path(script)
    end
  end
end
