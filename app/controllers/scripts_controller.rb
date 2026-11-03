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

  def icon
    return head :not_found unless @script.icon?

    bytes = File.binread(@script.icon_path)
    type = Script.icon_content_type(bytes)
    return head :not_found unless type

    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data bytes, type: type, disposition: "inline"
  end

  def update
    if @script.update(script_params)
      redirect_to edit_script_path(@script), notice: "Script saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def parameters
    @definitions = @script.parameters
    @requires_confirmation = @script.confirmation_required?
    @description = @script.description
    if @requires_confirmation
      @confirmation_token = confirmation_verifier.generate(@script.confirmation_identity, expires_in: 15.minutes, purpose: "script-execution")
    elsif @definitions.empty?
      redirect_to edit_script_path(@script)
    end
  rescue Script::ParameterError => error
    redirect_to edit_script_path(@script), alert: error.message
  end

  def run
    @script.description # Validate reserved metadata even without confirmation.
    if @script.confirmation_required?
      identity = confirmation_verifier.verified(params[:confirmation_token], purpose: "script-execution")
      unless identity == @script.confirmation_identity
        return redirect_to parameters_script_path(@script), alert: "Confirm this script before running it."
      end
    end
    definitions = @script.parameters
    args = definitions.empty? ? [] : @script.arguments_for(params[:arguments])
    run = definitions.empty? ? ScriptRunner.start(@script) : ScriptRunner.start(@script, args: args)
    redirect_to run_path(run)
  rescue ScriptRunner::Error, Script::ParameterError => error
    redirect_to edit_script_path(@script), alert: error.message
  end

  def destroy
    if @script.destroy
      redirect_to root_path, notice: "Deleted #{@script.name}."
    else
      redirect_to edit_script_path(@script), alert: @script.errors.full_messages.to_sentence
    end
  end

  private

  def confirmation_verifier = Rails.application.message_verifier("script-confirmation")

  def set_script
    @script = Script.find(params[:id])
  end

  def script_params
    params.expect(script: %i[name code icon_file remove_icon description])
  end
end
