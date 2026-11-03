require "test_helper"
require "open3"

class RunLogControllerTest < ActiveSupport::TestCase
  test "live log client handles concurrent ranges and reconnection" do
    output, status = Open3.capture2e("node", "test/javascript/run_log_controller.mjs", chdir: Rails.root)
    assert status.success?, output
    assert_includes output, "resync passed"
  end
end
