require "test_helper"
require "tempfile"

class ScriptIconsTest < ActionDispatch::IntegrationTest
  PNG_BYTES = "\x89PNG\r\n\x1a\n".b + "small-test-image".b

  def upload(bytes, content_type: "image/png")
    Tempfile.create([ "test-icon", ".png" ]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield Rack::Test::UploadedFile.new(file.path, content_type)
    end
  end

  test "uploading an icon shows it on the dashboard and serves it as an image" do
    script = Script.create!(name: "icon_test", code: "echo hi")
    upload(PNG_BYTES) do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end

    assert_redirected_to edit_script_path(script)
    assert script.icon?
    get root_path
    assert_select ".card img.script-icon[src='#{icon_script_path(script)}']"

    get icon_script_path(script)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal PNG_BYTES, response.body.b
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  ensure
    script&.destroy!
  end

  test "a script without an icon has no image and an icon request is 404" do
    script = Script.create!(name: "no_icon_test", code: "echo hi")
    get root_path
    assert_select ".card img.script-icon", count: 0
    get icon_script_path(script)
    assert_response :not_found
  ensure
    script&.destroy!
  end

  test "uploading a second icon replaces the previous one" do
    script = Script.create!(name: "replacement_test", code: "echo hi")
    upload(PNG_BYTES) do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end
    replacement = "\xff\xd8\xff".b + "small-jpeg-test".b
    upload(replacement, content_type: "image/jpeg") do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end
    get icon_script_path(script)
    assert_equal "image/jpeg", response.media_type
    assert_equal replacement, response.body.b
  ensure
    script&.destroy!
  end

  test "removing an icon deletes the local image" do
    script = Script.create!(name: "remove_icon_test", code: "echo hi")
    upload(PNG_BYTES) do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end
    assert script.icon?
    patch script_path(script), params: { script: { name: script.name, code: script.code, remove_icon: "1" } }
    assert_redirected_to edit_script_path(script)
    assert_not script.icon?
  ensure
    script&.destroy!
  end

  test "invalid or oversized images are rejected without replacing the existing icon" do
    script = Script.create!(name: "invalid_icon_test", code: "echo hi")
    upload(PNG_BYTES) do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end
    [ "<svg>unsafe</svg>", "x" * (Script::MAX_ICON_BYTES + 1) ].each do |invalid|
      upload(invalid) do |file|
        patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
      end
      assert_response :unprocessable_entity
      assert_equal PNG_BYTES, File.binread(script.icon_path)
    end
  ensure
    script&.destroy!
  end

  test "deleting a script deletes its local icon" do
    script = Script.create!(name: "delete_icon_test", code: "echo hi")
    upload(PNG_BYTES) do |file|
      patch script_path(script), params: { script: { name: script.name, code: script.code, icon_file: file } }
    end
    path = script.icon_path
    delete script_path(script)
    assert_redirected_to root_path
    assert_not File.exist?(path)
  end
end
