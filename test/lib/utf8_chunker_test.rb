require "test_helper"

class Utf8ChunkerTest < ActiveSupport::TestCase
  test "joins a multibyte character split across chunks" do
    chunker = ScriptRunner::Utf8Chunker.new
    first = chunker.call("a\xC3".b)
    second = chunker.call("\xA9b".b)

    assert_equal "a", first
    assert_equal "éb", second
    assert_equal "", chunker.flush
  end

  test "scrubs bytes that can never form a character" do
    chunker = ScriptRunner::Utf8Chunker.new
    assert_equal "x�y", chunker.call("x\xFFy".b)
  end

  test "flush scrubs a truncated character left at the end" do
    chunker = ScriptRunner::Utf8Chunker.new
    assert_equal "a", chunker.call("a\xE2\x82".b)
    assert_equal "�", chunker.flush
  end
end
