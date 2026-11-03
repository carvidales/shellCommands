# One execution of a script. The log is appended as output arrives and
# streamed to anyone watching the run page.
class Run < ApplicationRecord
  STATUSES = %w[running succeeded failed stopped].freeze

  belongs_to :script

  validates :status, inclusion: { in: STATUSES }

  def running? = status == "running"

  def duration
    return unless started_at
    (finished_at || Time.current) - started_at
  end

  # Concatenates in SQL so concurrent appends never overwrite each other.
  # Each broadcast chunk carries its character range in the log so the run
  # page can drop chunks it already has and notice ones it missed.
  def append_log!(chunk)
    # UPDATE RETURNING obtains offsets from the same atomic SQLite write.
    # Broadcast only after the write releases its database lock.
    limit = Rails.configuration.x.max_log_bytes
    notice = "\n[runner] Output truncated: log size limit reached.\n"
    budget = limit - notice.bytesize
    result = self.class.connection_pool.with_connection do |connection|
      sql = self.class.sanitize_sql_array([
        "UPDATE runs SET log = log || ? WHERE id = ? AND length(CAST(log AS BLOB)) <= ? RETURNING log", chunk, id, budget
      ])
      # Keep the read/trim/write atomic across writers; no broadcasts here.
      connection.transaction do
        row = connection.exec_query(sql).first
        next unless row
        text = row.fetch("log")
        previous = text.bytesize - chunk.bytesize
        if text.bytesize > budget
          text = text.byteslice(0, budget).force_encoding(Encoding::UTF_8).scrub("") + notice
          connection.exec_update(self.class.sanitize_sql_array([ "UPDATE runs SET log = ? WHERE id = ?", text, id ]))
        end
        start_text = text.byteslice(0, previous)
        [ text.byteslice(previous..), start_text.length ]
      end
    end
    return unless result
    chunk, log_start = result
    span = ApplicationController.helpers.tag.span(chunk, data: { start: log_start, end: log_start + chunk.length })
    broadcast_append_to self, target: "run_#{id}_log", html: span
  end

  def finish!(status:, exit_code: nil, note: nil)
    append_log!(note) if note
    update!(status: status, exit_code: exit_code, finished_at: Time.current, pid: nil, termination_note: note)
    broadcast_replace_to self, target: "run_#{id}_status", partial: "runs/status", locals: { run: self }
  end
end
