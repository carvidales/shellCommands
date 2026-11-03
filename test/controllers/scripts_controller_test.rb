require "test_helper"

class ScriptsControllerTest < ActionDispatch::IntegrationTest
  test "index imports files and lists cards" do
    FileUtils.mkdir_p(scripts_dir)
    File.write(scripts_dir.join("from_terminal.sh"), "echo hi")

    get root_path

    assert_response :success
    assert_select ".card", text: /from_terminal/
    assert_select ".card", text: /never run/
  end

  test "index flags missing files and disables run" do
    script = Script.create!(name: "gone", code: "echo hi")
    File.delete(script.path)

    get root_path

    assert_select ".card .badge-missing", text: "file missing"
    assert_select "form[action='#{run_script_path(script)}'] button[disabled]"
  end

  test "create writes file and redirects to edit" do
    post scripts_path, params: { script: { name: "hello", code: "echo hi\n" } }

    script = Script.find_by!(name: "hello")
    assert_redirected_to edit_script_path(script)
    assert_equal "echo hi\n", File.read(script.path)
  end

  test "invalid name re-renders with 422" do
    post scripts_path, params: { script: { name: "bad name", code: "echo" } }
    assert_response :unprocessable_entity
    assert_select ".errors", text: /Name/
  end

  test "update changes code on disk" do
    script = Script.create!(name: "hello", code: "echo 1\n")
    patch script_path(script), params: { script: { name: "hello", code: "echo 2\n" } }

    assert_redirected_to edit_script_path(script)
    assert_equal "echo 2\n", File.read(script.path)
  end

  test "destroy removes script, runs, and file" do
    script = Script.create!(name: "hello", code: "echo 1\n")
    script.runs.create!(status: "succeeded", started_at: 1.minute.ago, finished_at: Time.current, code_snapshot: "echo 1\n")

    delete script_path(script)

    assert_redirected_to root_path
    assert_not Script.exists?(script.id)
    assert_equal 0, Run.count
    assert_not File.exist?(script.path)
  end

  test "destroy blocked while running" do
    script = Script.create!(name: "hello", code: "sleep 1")
    script.runs.create!(started_at: Time.current, code_snapshot: "sleep 1")

    delete script_path(script)

    assert_redirected_to edit_script_path(script)
    assert_equal "Can't delete a running script", flash[:alert]
    assert Script.exists?(script.id)
  end

  test "edit lists past runs" do
    script = Script.create!(name: "hello", code: "echo 1\n")
    run = script.runs.create!(status: "failed", exit_code: 2, started_at: 1.minute.ago, finished_at: Time.current, code_snapshot: "x")

    get edit_script_path(script)

    assert_response :success
    assert_select "textarea[name='script[code]']", text: "echo 1\n"
    assert_select ".past-runs a[href='#{run_path(run)}']"
  end

  test "show redirects to edit" do
    script = Script.create!(name: "hello", code: "echo 1\n")
    get script_path(script)
    assert_redirected_to edit_script_path(script)
  end

  test "create normalizes CRLF line endings" do
    post scripts_path, params: { script: { name: "crlf", code: "echo a\r\necho b\r\n" } }
    assert_equal "echo a\necho b\n", File.binread(Script.find_by!(name: "crlf").path)
  end

  test "create and edit expose optional descriptions and display them on cards" do
    get new_script_path
    assert_select "input[name='script[description]'][maxlength='200']"
    post scripts_path, params: { script: { name: "described", code: "#!/bin/bash\necho hi\n", description: "Show system status" } }
    script = Script.find_by!(name: "described")
    assert_redirected_to edit_script_path(script)
    get edit_script_path(script)
    assert_select "input[name='script[description]'][value='Show system status']"
    get root_path
    assert_select ".card .card-description", text: "Show system status"
    patch script_path(script), params: { script: { description: "Updated summary" } }
    get root_path
    assert_select ".card .card-description", text: "Updated summary"
    patch script_path(script), params: { script: { description: "" } }
    get root_path
    assert_select ".card-description", count: 0
  end

  test "card descriptions use existing metadata and escape HTML" do
    Script.create!(name: "escaped_description", code: "# @description=<script>alert(1)</script>\necho hi")
    get root_path
    assert_response :success
    assert_select ".card-description", text: "<script>alert(1)</script>"
    assert_select ".card-description script", count: 0
  end

  test "invalid descriptions re-render the editor without changing the script" do
    script = Script.create!(name: "invalid_description", code: "echo original\n")
    patch script_path(script), params: { script: { description: "one\necho injected", code: "echo changed" } }
    assert_response :unprocessable_entity
    assert_select ".errors", text: /Description/
    assert_equal "echo original\n", File.read(script.path)
  end

  test "malformed description metadata remains editable and can be corrected" do
    script = Script.create!(name: "broken_description", code: "# @description one\n# @description=two\necho hi\n")
    get root_path
    assert_response :success
    get edit_script_path(script)
    assert_response :success
    patch script_path(script), params: { script: { description: "Corrected" } }
    assert_redirected_to edit_script_path(script)
    assert_equal "# @description=Corrected\necho hi\n", File.read(script.path)
  end
end
