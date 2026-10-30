class RunsController < ApplicationController
  before_action :set_run

  def show
    respond_to do |format|
      format.html
      format.json do
        render json: { log: @run.log, length: @run.log.length,
                       status_html: render_to_string(partial: "runs/status", formats: :html, locals: { run: @run }) }
      end
    end
  end

  def stop
    ScriptRunner.stop(@run) if @run.running?
    redirect_to run_path(@run)
  end

  private

  def set_run
    @run = Run.find(params[:id])
  end
end
