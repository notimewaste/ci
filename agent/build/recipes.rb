require 'tmpdir'
require_relative "../agent"

module FastlaneCI::Agent

  ##
  # stateless build recipes go here
  module Recipes

    # all method below this are module functions, callable on the module directly.
    module_function

    def output_queue=(value)
      @output_queue = value
    end

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
  end
end
