require 'tmpdir'

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

    ## state machine transition guards

    def has_required_xcode_version?
      # TODO: bring in from build_runner
      rand(10) > 3 # 1 in 3 chance of failure
    end
  end
end
