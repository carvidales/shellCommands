class RunsController < ApplicationController
  before_action :set_run

  def show
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
