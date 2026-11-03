require "test_helper"

class RunConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    Run.delete_all
    Script.delete_all
  end

  test "concurrent writers broadcast exact committed character ranges" do
    script = Script.create!(name: "concurrent_log", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: script.code)
    spans = Queue.new
    run.define_singleton_method(:broadcast_append_to) { |*args, **options| spans << options[:html] }
    threads = 4.times.map do |writer|
      Thread.new do
        10.times { |index| run.append_log!("#{writer}:#{index}é😀\n") }
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    threads.each { |thread| assert thread.join(10), "log writer did not finish"; thread.value }
    log = run.reload.log
    assert_equal 40, log.lines.length
    ranges = Array.new(40) { Nokogiri::HTML5.fragment(spans.pop).at_css("span") }
    expected = 0
    ranges.sort_by { |span| span["data-start"].to_i }.each do |span|
      start = span["data-start"].to_i
      finish = span["data-end"].to_i
      assert_equal expected, start
      assert_equal log[start...finish], span.text
      expected = finish
    end
    assert_equal log.length, expected
  end

  test "a slow broadcast does not hold a database write lock" do
    script = Script.create!(name: "slow_broadcast", code: "echo hi")
    run = script.runs.create!(started_at: Time.current, code_snapshot: script.code)
    entered = Queue.new
    release = Queue.new
    run.define_singleton_method(:broadcast_append_to) { |*args, **options| entered << true; release.pop }
    thread = Thread.new do
      run.append_log!("first")
    ensure
      ActiveRecord::Base.connection_handler.clear_active_connections!
    end
    Timeout.timeout(5) { entered.pop }
    Run.find(run.id).append_log!("second")
    assert_equal "firstsecond", run.reload.log
  ensure
    release << true if release
    thread&.join(5)
    thread&.value
  end
end
