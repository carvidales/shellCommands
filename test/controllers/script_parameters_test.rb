require "test_helper"

class ScriptParametersControllerTest < ActionDispatch::IntegrationTest
  test "parameterized scripts show an input form" do
    script = Script.create!(name: "port_check", code: "# @param PORT=3000\necho \"$1\"\n")
    get parameters_script_path(script)
    assert_response :success
    assert_select "input[name='arguments[PORT]'][value='3000']"
  end

  test "submitting arguments starts a normal run" do
    script = Script.create!(name: "port_check", code: "# @param PORT=3000\nprintf '%s\\n' \"$1\"\n")
    post run_script_path(script), params: { arguments: { PORT: "4321" } }
    run = script.runs.last
    assert_redirected_to run_path(run)
    ScriptRunner.wait(run)
    assert_equal "4321\n", run.reload.log
  end

  test "unrecognized arguments cannot be submitted" do
    script = Script.create!(name: "port_check", code: "# @param PORT=3000\necho \"$1\"\n")
    assert_no_difference("Run.count") do
      post run_script_path(script), params: { arguments: { PORT: "3000", OTHER: "x" } }
    end
    assert_redirected_to edit_script_path(script)
  end
end
