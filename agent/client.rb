require_relative "agent"

module FastlaneCI
  module Agent
    ##
    # A sample client that can be used to make a request to the server.
    class Client
      def initialize(host)
        @stub = Stub.new("#{host}:#{PORT}", :this_channel_is_insecure)
      end

      def request_spawn(bin, *params, env: {})
        command = Command.new(bin: bin, parameters: params, env: env)
        @stub.spawn(command)
      end

      def request_send_file()
        file_request = FileRequest.new
        @stub.send_file(file_request)
      end

      def request_run_fastlane(bin, *params, env: {})
        command = Command.new(bin: bin, parameters: params, env: env)
        @stub.run_fastlane(BuildRequest.new(command: command))
      end
    end
  end
end

if $0 == __FILE__
  client = FastlaneCI::Agent::Client.new("localhost")
  response = client.request_run_fastlane("actions", env: {'FASTLANE_CI_ARTIFACTS' => 'artifacts', 'GIT_URL' => 'https://github.com/snatchev/themoji-ios'})
  @file = nil
  response.each do |r|
    puts "Log: #{r.log.message}" if r.log

    puts "Status: #{r.status.state}" if r.status


    puts "Error: #{r.build_error.error_description} #{r.build_error.stacktrace}" if r.build_error

    if r.artifact
      puts "Chunk: writing to #{r.artifact.filename}"
      @file ||= File.new(r.artifact.filename, 'wb')
      @file.write(r.artifact.chunk)
    end
  end
  @file && @file.close
end
