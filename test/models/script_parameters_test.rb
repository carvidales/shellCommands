require "test_helper"

class ScriptParametersTest < ActiveSupport::TestCase
  test "parses parameter declarations in script order" do
    script = Script.new(name: "example", code: "#!/bin/bash\n# @param PORT=3000\n# @param URL=https://example.com\necho \"$1 $2\"\n")
    assert_equal [ { name: "PORT", default: "3000" }, { name: "URL", default: "https://example.com" } ], script.parameters
  end

  test "arguments are passed as strings without shell parsing" do
    script = Script.new(name: "example", code: "# @param VALUE=default\n")
    assert_equal [ "$(touch /tmp/do-not-execute)" ], script.arguments_for(
      ActionController::Parameters.new("VALUE" => "$(touch /tmp/do-not-execute)")
    )
  end

  test "unknown fields are rejected" do
    script = Script.new(name: "example", code: "# @param PORT=3000\n")
    assert_raises(Script::ParameterError) do
      script.arguments_for(ActionController::Parameters.new("PORT" => "4000", "EXTRA" => "value"))
    end
  end

  test "duplicate names are rejected" do
    script = Script.new(name: "example", code: "# @param PORT=3000\n# @param PORT=4000\n")
    assert_raises(Script::ParameterError) { script.parameters }
  end
  test "rejects malformed declarations and unsafe parameter values" do
    [ "# @param MISSING", "# @param PORT=x\n# @param PORT=y", "# @param PORT=\u0000" ].each do |code|
      assert_raises(Script::ParameterError) { Script.new(code: code).parameters }
    end
    script = Script.new(code: "# @param VALUE=x")
    [ [], {}, "x" * 1025, "a\u0000b" ].each do |value|
      assert_raises(Script::ParameterError) { script.arguments_for(ActionController::Parameters.new("VALUE" => value)) }
    end
  end

  test "confirmation metadata is strict and ordinary scripts remain unchanged" do
    assert_not Script.new(code: "echo hi").confirmation_required?
    [ "# @confirm=yes", "# @confirm true", "# @confirm=true\n# @confirm=false" ].each do |code|
      assert_raises(Script::ParameterError) { Script.new(code: code).confirmation_required? }
    end
  end
end
