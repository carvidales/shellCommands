class ScriptsController < ApplicationController
  before_action :set_script, except: %i[index new create]

  def index
    Script.sync_from_directory!
    @scripts = Script.order(:name).includes(:runs)
  end

  def show
    redirect_to edit_script_path(@script)
  end

  def new
    @script = Script.new(code: "#!/bin/bash\n\n")
  end

  def create
    @script = Script.new(script_params)
    if @script.save
      redirect_to edit_script_path(@script), notice: "Script created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @script.update(script_params)
      redirect_to edit_script_path(@script), notice: "Script saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @script.destroy
      redirect_to root_path, notice: "Deleted #{@script.name}."
    else
      redirect_to edit_script_path(@script), alert: @script.errors.full_messages.to_sentence
    end
  end

  private

  def set_script
    @script = Script.find(params[:id])
  end

  def script_params
    params.expect(script: %i[name code])
  end
end
