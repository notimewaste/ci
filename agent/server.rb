require "logger"
require "open3"
require_relative "agent"

module FastlaneCI
  module Agent
    ##
    # A simple implementation of the agent service.
    class Server < Service
      ##
      # this class is used to create a lazy enumerator
      # that will yield back lines from the stdout/err of the process
      # as well as the exit status when it is complete.
      class ProcessOutputEnumerator
        extend Forwardable
        include Enumerable

        def_delegators :@enumerator, :each, :next

        def initialize(io, thread)
          @enumerator = Enumerator.new do |yielder|
            yielder.yield(io.gets) while thread.alive?
            io.close
          end
        end
      end

      class FileEnumerator
        extend Forwardable
        include Enumerable

        def_delegators :@enumerator, :each, :next

        def initialize(io, thread, chunk_size = 1024*1024)
          @enumerator = Enumerator.new do |yielder|

            # loop until the thread dies and the file has be read completely
            while thread.alive? || !io.eof?
              chunk = io.read(chunk_size)
              yielder.yield(chunk)
            end

            io.close
          end
        end
      end

      def self.server
        GRPC::RpcServer.new.tap do |server|
          server.add_http2_port("#{HOST}:#{PORT}", :this_port_is_insecure)
          server.handle(new)
        end
      end

      def initialize
        @logger = Logger.new(STDOUT)
      end

      ##
      # spawns a command using popen2e. Merging stdout and stderr,
      # because its easiest to return the lazy stream when both stdout and stderr pipes are together.
      # otherwise, we run the risk of deadlock if we dont properly flush both pipes as per:
      # https://ruby-doc.org/stdlib-2.1.0/libdoc/open3/rdoc/Open3.html#method-c-popen3
      #
      # @input FastlaneCI::Agent::Command
      # @output Enumerable::Lazy<FastlaneCI::Agent::Log> A lazy enumerable with log lines.
      def spawn(command, _call)
        @logger.info("spawning process with command: #{command.bin} #{command.parameters}, env: #{command.env.to_h}")
        stdin, stdouterr, wait_thrd = Open3.popen2e(command.env.to_h, command.bin, *command.parameters)
        stdin.close

        @logger.info("spawned process with pid: #{wait_thrd.pid}")

        output_enumerator = ProcessOutputEnumerator.new(stdouterr, wait_thrd)
        # convert every line from io to a Log object in a lazy stream
        output_enumerator.lazy.flat_map do |line, status|
          # proto3 doesn't have nullable fields, afaik
          puts line
          Log.new(message: (line || NULL_CHAR), status: (status || 0))
        end
      end

      def run_fastlane(build_request, _call)
        command = build_request.command
        @logger.info("spawning process with command: #{command.bin} #{command.parameters}, env: #{command.env.to_h}")

        artifact_path = command.env.to_h['FASTLANE_CI_ARTIFACTS']

        stdin, stdouterr, thread = Open3.popen2e(command.env.to_h, command.bin, *command.parameters)
        stdin.close

        @logger.info("spawned process with pid: #{thread.pid}")

        # TODO: encapsulate this workflow in a Build class that uses a proper Finite State Machine.
        Enumerator.new do |yeilder|
          status = BuildResponse::Status.new(state: :RUNNING)
          yeilder << BuildResponse.new(status: status)

          while message = stdouterr.gets
            log = Log.new(message: message)
            yeilder << BuildResponse.new(log: log)
          end

          if thread.value.exitstatus == 0
            status = BuildResponse::Status.new(state: :FINISHING)
            yeilder << BuildResponse.new(status: status)
          else
            status = BuildResponse::Status.new(state: :ERROR)
            yeilder << BuildResponse.new(status: status)
            next
          end

          Dir.chdir(artifact_path) do
            system("tar -cvzf Archive.tgz .")
          end

          file = File.open(File.join(artifact_path, 'Archive.tgz'), 'rb') #TODO make sure this is binary

          until file.eof?
            artifact = BuildResponse::Artifact.new
            artifact.chunk = file.read(chunk_size)

            yeilder << BuildResponse.new(artifact: artifact)
          end

          status = BuildResponse::Status.new(state: :SUCCESS)
          yeilder << BuildResponse.new(status: status)
        end
      end
    end
  end
end


if $0 == __FILE__
  server = FastlaneCI::Agent::Server.server

  Signal.trap("SIGINT") do
    Thread.new { server.stop }.join # Mutex#synchronize can't be called in trap context. Put it on a thread.
  end

  puts("Agent (#{FastlaneCI::Agent::VERSION}) is running on #{FastlaneCI::Agent::HOST}:#{FastlaneCI::Agent::PORT}")
  server.run_till_terminated
end
