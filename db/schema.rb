# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_30_180356) do
  create_table "runs", force: :cascade do |t|
    t.integer "script_id", null: false
    t.string "status", default: "running", null: false
    t.integer "exit_code"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.text "log", default: "", null: false
    t.integer "pid"
    t.text "code_snapshot", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "server_pid"
    t.index ["script_id"], name: "index_runs_on_script_id"
  end

  create_table "scripts", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_scripts_on_name", unique: true
  end

  add_foreign_key "runs", "scripts"
end
