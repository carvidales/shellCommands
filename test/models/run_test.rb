require "test_helper"

class RunTest < ActiveSupport::TestCase
  setup do
    @script = Script.create!(name: "hello", code: "echo hi\n")
    @run = @script.runs.create!(started_at: Time.current, code_snapshot: @script.code)
  end

  test "append_log! concatenates" do
    @run.append_log!("a")
    @run.append_log!("b")
    assert_equal "ab", @run.reload.log
  end

  test "append_log! broadcasts escaped html" do
    broadcasts = capture_turbo_stream_broadcasts(@run) { @run.append_log!("<script>alert(1)</script>") }

    html = broadcasts.first.to_html
    assert_equal "append", broadcasts.first["action"]
    assert_equal "run_#{@run.id}_log", broadcasts.first["target"]
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>alert"
  end

  test "finish! sets fields and note" do
    @run.update!(pid: 123)
    @run.finish!(status: "failed", exit_code: 1, note: "x\n")
    @run.reload

    assert_equal "failed", @run.status
    assert_equal 1, @run.exit_code
    assert @run.finished_at
    assert_nil @run.pid
    assert @run.log.end_with?("x\n")
  end

  test "finish! broadcasts the status" do
    broadcasts = capture_turbo_stream_broadcasts(@run) { @run.finish!(status: "succeeded", exit_code: 0) }
    replace = broadcasts.find { |b| b["action"] == "replace" }
    assert_equal "run_#{@run.id}_status", replace["target"]
  end

  test "status must be in STATUSES" do
    @run.status = "bogus"
    assert_not @run.valid?
  end

  test "duration" do
    @run.update!(started_at: 10.seconds.ago, finished_at: 7.seconds.ago)
    assert_in_delta 3.0, @run.duration, 0.1
  end

  test "script with running run cannot be destroyed" do
    assert_not @script.destroy
    assert File.exist?(@script.path)
    assert_includes @script.errors[:base], "Can't delete a running script"
  end

  test "destroying a script removes its runs" do
    @run.finish!(status: "succeeded", exit_code: 0)
    assert_difference("Run.count", -1) { @script.destroy! }
  end

  test "append_log! broadcasts each chunk with its position in the log" do
    @run.append_log!("héllo ")
    broadcasts = capture_turbo_stream_broadcasts(@run) { @run.append_log!("wörld") }

    span = Nokogiri::HTML5.fragment(broadcasts.first.at_css("template").inner_html).at_css("span")
    assert_equal "6", span["data-start"]
    assert_equal "11", span["data-end"]
    assert_equal "wörld", span.text
  end
end
