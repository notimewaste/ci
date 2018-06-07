require "micromachine"
require "tmpdir"

require_relative "agent"

module FastlaneCI::Agent
  class Build
    include Logging

    module Receipes
      # TODO: move receipes here.
    end

    def initialize(build_request, yielder)
      @build_request = build_request
      @yielder = yielder

      @output_queue = Queue.new

      @state = MicroMachine.new('pending').tap do |fsm|
        fsm.when(:run,     'pending'   => 'running')
        fsm.when(:finish,  'running'   => 'finishing')
        fsm.when(:succeed, 'finishing' => 'succeeded')
        fsm.when(:reject,  'running'   => 'rejected')
        fsm.when(:fail,    'running'   => 'failed')

        # TODO: this is unused for now. throwing/catching is handled by the listener.
        fsm.when(:throw,   'pending'   => 'caught',
                           'running'   => 'caught',
                           'finishing' => 'caught')


        # send update whenever we transition states.
        fsm.on(:any) do |event, payload|
          send_status(event, payload)
        end

      end
    end

    ## state machine actions

    def run
      return unless @state.trigger(:run)

      # send logs that get put on the output queue.
      # this needs to be on a separate thread since Queue is a threadsafe blocking queue.
      Thread.new do
        while @state.state == 'running'
          send_log(@output_queue.pop)
        end
      end

      git_url = command_env(:GIT_URL)

      setup_repo(git_url)

      unless has_required_xcode_version?
        reject("Does not have required xcode version!. This is hardcode to be random.")
        return
      end

      if run_fastlane(@build_request.command.env.to_h)
        finish
      else
        # fail is a keyword, so we must call self.
        self.fail
      end
    end

    def finish
      return unless @state.trigger(:finish)

      artifact_path = command_env(:FASTLANE_CI_ARTIFACTS)

      archive_artifacts(artifact_path)
      send_archive(artifact_path)
      succeed
    end

    def fail
      return unless @state.trigger(:fail)
    end

    def succeed
      return unless @state.trigger(:succeed)
    end

    def reject(reason)
      return unless @state.trigger(:reject, reason)
    end

    ## build recipe methods

    def setup_repo(git_url)
      dir = Dir.mktmpdir("fastlane-ci")
      Dir.chdir(dir)
      logger.debug("Changing into working directory #{dir}.")

      sh("git clone --depth 1 #{git_url} repo")

      Dir.chdir("repo")
      sh("gem install bundler --no-doc")
      sh("bundle install --deployment")

      sh("gem install cocoapods --no-doc")
      sh("pod install")
    end

    def run_fastlane(env)
      logger.debug("invoking fastlane.")
      # TODO: send the env to fastlane.
      sh("bundle exec fastlane actions")

      # TODO: return true/false depending on tests passing?
      true
    end

    def archive_artifacts(artifact_path)
      unless Dir.exist?(artifact_path)
        logger.debug("No artifacts found in #{File.expand_path(artifact_path)}.")
        return false
      end
      logger.debug("Archiving directory #{artifact_path}")

      Dir.chdir(artifact_path) do
        sh("tar -cvzf Archive.tgz .")
      end

      return true
    end

    ## state machine transition guards

    def has_required_xcode_version?
      # TODO: bring in from build_runner
      rand(10) > 3 # 1 in 3 chance of failure
    end

    # responder methods

    def send_status(event, payload)
      logger.debug("Status changed. Event `#{event}` => #{@state.state}")

      status = FastlaneCI::BuildResponse::Status.new
      status.state = @state.state.to_s.upcase.to_sym
      status.description = payload unless payload.nil?

      @yielder << FastlaneCI::BuildResponse.new(status: status)
    end

    def send_log(line)
      log = FastlaneCI::Log.new(message: line)
      @yielder << FastlaneCI::BuildResponse.new(log: log)
    end

    def send_archive(artifact_path, chunk_size: 1024*1024)
      archive_path = File.join(artifact_path, 'Archive.tgz')
      unless File.exist?(archive_path)
        logger.debug("No Archive found at #{archive_path}. Skipping sending the archive.")
        return
      end

      file = File.open(archive_path, 'rb')

      until file.eof?
        artifact = FastlaneCI::BuildResponse::Artifact.new
        artifact.chunk = file.read(chunk_size)

        @yielder << FastlaneCI::BuildResponse.new(artifact: artifact)
      end
    end

    # use this to execute shell commands so the output can be streamed back as a response.
    def sh(*params, env: {})
      @output_queue.push(params.join(" "))
      stdin, stdouterr, thread = Open3.popen2e(*params)
      stdin.close

      # `gets` on a pipe will block until the pipe is closed, then returns nil.
      while line = stdouterr.gets
        logger.debug(line)
        @output_queue.push(line)
      end

      exit_status = thread.value.exitstatus
      if exit_status != 0
        raise SystemCallError.new(line, exit_status)
      end
    end

    private

    def command_env(key)
      key = key.to_s
      env = @build_request.command.env.to_h
      if env.has_key?(key)
        env[key]
      else
        raise NameError, "`#{env}` does not have a key `#{key}`"
      end
    end

  end
end
