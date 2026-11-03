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

  test "description is stored below the shebang and preserves other metadata" do
    source = "#!/bin/bash\n# @confirm=true\n# @param PORT=8000\necho \"$1\"\n"
    script = Script.create!(name: "described", code: source, description: "Check a port")
    assert_equal source.sub("#!/bin/bash\n", "#!/bin/bash\n# @description=Check a port\n"), File.read(script.path)
    assert_equal "Check a port", Script.find(script.id).description
    assert script.confirmation_required?
    assert_equal "PORT", script.parameters.first[:name]
  end

  test "description can be updated and cleared without duplicating metadata" do
    script = Script.create!(name: "described", code: "# @description=Old\necho hi\n")
    script.update!(description: "New")
    assert_equal "# @description=New\necho hi\n", File.read(script.path)
    script.update!(description: "")
    assert_equal "echo hi\n", File.read(script.path)
    assert_nil script.description
  end

  test "description assignment order does not discard submitted code" do
    script = Script.new(name: "ordered", description: "New", code: "echo latest\n")
    script.save!
    assert_equal "# @description=New\necho latest\n", File.read(script.path)
    script.update!(code: "# @description=From code\necho edited\n")
    assert_equal "From code", script.description
  end

  test "invalid descriptions cannot inject script lines or overwrite existing code" do
    script = Script.create!(name: "safe_description", code: "echo original\n")
    [ "x" * (Script::MAX_DESCRIPTION_LENGTH + 1), "one\necho injected", "one\recho injected", "one\u0000two" ].each do |description|
      assert_not script.update(description: description)
      assert script.errors[:description].any?
      assert_equal "echo original\n", File.read(script.path)
    end
  end

  test "description-only saves preserve a shebang without a newline" do
    script = Script.create!(name: "shebang", code: "#!/bin/bash")
    script.update!(description: "Hello")
    assert_equal "#!/bin/bash\n# @description=Hello\n", File.read(script.path)
  end

  test "saving without a description field leaves legacy source unchanged" do
    source = "#!/bin/bash\n# @description=Existing\necho hi\n"
    script = Script.create!(name: "legacy_description", code: source)
    script.update!(name: "renamed_description")
    assert_equal source, File.read(script.path)
    assert_equal "Existing", script.description
  end
end
