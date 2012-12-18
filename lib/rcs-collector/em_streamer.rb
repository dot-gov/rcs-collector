require 'eventmachine'

module EventMachine

  class FilesystemStreamer
    include EventMachine::Deferrable

      # Wait until next tick to send more data when 50k is still in the outgoing buffer
      BackpressureLevel = 50000
      # Send 16k chunks at a time
      ChunkSize = 16384

      # @param [EventMachine::Connection] connection
      # @param [String] filename Filesystem filename
      #
      # @option args [Boolean] :http_chunks (false) Use HTTP 1.1 style chunked-encoding semantics.
      def initialize(connection, filename, args = {})
        @connection = connection
        stream_without_mapping filename
      end

      # @private
      def stream_without_mapping(filename)
        if File.exist?(filename)
          @file_io = File.open(filename, "rb")
          @size = File.size(filename)
          stream_one_chunk
        else
          raise "FilesystemStreamer: File not found (#{filename})"
        end
      end
      private :stream_without_mapping

      # Used internally to stream one chunk at a time over multiple reactor ticks
      # @private
      def stream_one_chunk
        loop do
          break if @connection.closed?
          if @file_io.pos < @size
            if @connection.get_outbound_data_size > BackpressureLevel
                # recursively call myself
                EventMachine::next_tick {stream_one_chunk}
                break
            else
              break unless @file_io.pos < @size

              len = @size - @file_io.pos
              len = ChunkSize if (len > ChunkSize)

              @connection.send_data(@file_io.read( len ))
            end
          else
            succeed
            @file_io.close
            break
          end
        end
      rescue Exception => e
        # catch all exceptions otherwise it will propagate up to the reactor and terminate the main program
      end
  end

end