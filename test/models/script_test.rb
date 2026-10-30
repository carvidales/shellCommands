require "test_helper"

class ScriptTest < ActiveSupport::TestCase
  test "saving writes executable file" do
    script = Script.create!(name: "hello", code: "echo hi\n")

    assert_equal "echo hi\n", File.read(script.path)
    assert_equal 0o755, File.stat(script.path).mode & 0o777
  end

  test "name format rejected" do
    [ "../evil", "a b", "" ].each do |name|
      script = Script.new(name: name, code: "echo x")
      assert_not script.save, "expected #{name.inspect} to be invalid"
    end
    assert_empty Dir.glob(File.join(scripts_dir.parent, "**", "*.sh"))
  end

  test "duplicate name rejected" do
    Script.create!(name: "hello", code: "echo 1")
    assert_not Script.new(name: "hello", code: "echo 2").valid?
  end

  test "rename moves file" do
    script = Script.create!(name: "hello", code: "echo hi\n")
    old_path = script.path

    script.update!(name: "hi")

    assert_not File.exist?(old_path)
    assert_equal "echo hi\n", File.read(scripts_dir.join("hi.sh"))
  end

  test "rename onto existing name rejected and files untouched" do
    Script.create!(name: "a", code: "echo a\n")
    b = Script.create!(name: "b", code: "echo b\n")

    assert_not b.update(name: "a")

    assert_equal "echo a\n", File.read(scripts_dir.join("a.sh"))
    assert_equal "echo b\n", File.read(scripts_dir.join("b.sh"))
  end

  test "updating code rewrites file" do
    script = Script.create!(name: "hello", code: "echo 1\n")
    script.update!(code: "echo 2\n")
    assert_equal "echo 2\n", File.read(script.path)
    assert_equal "echo 2\n", Script.find(script.id).code
  end

  test "destroy deletes file" do
    script = Script.create!(name: "hello", code: "echo hi")
    script.destroy!
    assert_not File.exist?(script.path)
  end

  test "sync imports untracked files" do
    FileUtils.mkdir_p(scripts_dir)
    File.write(scripts_dir.join("x.sh"), "echo x")
    File.write(scripts_dir.join("bad name.sh"), "echo bad")

    Script.sync_from_directory!
    assert_equal [ "x" ], Script.pluck(:name)

    assert_no_difference("Script.count") { Script.sync_from_directory! }
  end

  test "file_missing? when file deleted" do
    script = Script.create!(name: "hello", code: "echo hi")
    assert_not script.file_missing?
    File.delete(script.path)
    assert script.file_missing?
  end

  test "creating over an untracked file is rejected and the file kept" do
    FileUtils.mkdir_p(scripts_dir)
    File.write(scripts_dir.join("x.sh"), "echo mine\n")

    assert_not Script.new(name: "x", code: "echo app\n").save
    assert_equal "echo mine\n", File.read(scripts_dir.join("x.sh"))
  end

  test "CRLF from browser textareas is normalized to LF" do
    script = Script.create!(name: "crlf", code: "if true; then\r\n  echo ok\r\nfi\r\n")
    assert_equal "if true; then\n  echo ok\nfi\n", File.binread(script.path)
  end

  test "saving replaces the file instead of rewriting it in place" do
    script = Script.create!(name: "swap", code: "echo old\n")
    File.open(script.path) do |running_copy|
      script.update!(code: "echo new\n")
      assert_equal "echo old\n", running_copy.read
    end
    assert_equal "echo new\n", File.read(script.path)
    assert_equal 0o755, File.stat(script.path).mode & 0o777
  end
end
