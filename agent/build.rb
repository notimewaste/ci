require 'tmpdir'
require_relative "agent"
require_relative "build/recipes"
require_relative "build/state_machine"

module FastlaneCI::Agent
  class Build
    prepend StateMachine

    def initialize(build_request, yielder)
      @build_request = build_request
      @yielder = yielder
      @output_queue = Queue.new
      Recipes.output_queue = @output_queue
    end

    ## state machine actions

    def run
      # send logs that get put on the output queue.
      # this needs to be on a separate thread since Queue is a threadsafe blocking queue.
      Thread.new do
        send_log(@output_queue.pop) while state == "running"
      end

      git_url = command_env(:GIT_URL)

      Recipes.setup_repo(git_url)

      unless has_required_xcode_version?
        reject("Does not have required xcode version!. This is hardcode to be random.")
        return
      end

      if Recipes.run_fastlane(@build_request.command.env.to_h)
        finish
      else
        # fail is a keyword, so we must call self.
        # rubocop:disable Style/RedundantSelf
        self.fail
      end
    end

    def finish
      artifact_path = command_env(:FASTLANE_CI_ARTIFACTS)

      Recipes.archive_artifacts(artifact_path)
      Recipes.send_archive(artifact_path)
      succeed
    end

    def fail
    end

    def succeed
    end

    def reject(reason)
    end

    def throw(exception)
      logger.error("Caught Error: #{exception}")

      error = FastlaneCI::Proto::BuildResponse::BuildError.new
      error.stacktrace = exception.backtrace.join("\n")
      error.error_description = exception.message

      @yielder << FastlaneCI::Proto::BuildResponse.new(build_error: error)
    end

    ## state machine transition guards

    def has_required_xcode_version?
      # TODO: bring in from build_runner
      rand(10) > 3 # 1 in 3 chance of failure
    end

    # responder methods

    def send_status(event, payload)
      logger.debug("Status changed. Event `#{event}` => #{state}")

      status = FastlaneCI::Proto::BuildResponse::Status.new
      status.state = state.to_s.upcase.to_sym
      status.description = payload.to_s unless payload.nil?

      @yielder << FastlaneCI::Proto::BuildResponse.new(status: status)
    end

    def send_log(line)
      log = FastlaneCI::Proto::Log.new(message: line)
      @yielder << FastlaneCI::Proto::BuildResponse.new(log: log)
    end

    def send_archive(artifact_path, chunk_size: 1024 * 1024)
      archive_path = File.join(artifact_path, "Archive.tgz")
      unless File.exist?(archive_path)
        logger.debug("No Archive found at #{archive_path}. Skipping sending the archive.")
        return
      end

      file = File.open(archive_path, "rb")

      until file.eof?
        artifact = FastlaneCI::Proto::BuildResponse::Artifact.new
        artifact.chunk = file.read(chunk_size)

        @yielder << FastlaneCI::Proto::BuildResponse.new(artifact: artifact)
      end
    end

    private

    def command_env(key)
      key = key.to_s
      env = @build_request.command.env.to_h
      if env.key?(key)
        env[key]
      else
        raise NameError, "`#{env}` does not have a key `#{key}`"
      end
    end
  end
end
