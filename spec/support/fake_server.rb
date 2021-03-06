require 'json'
require 'socket'

class FakeBeaconThreadCancelled < Exception; end
class FakeServerThreadCancelled < Exception; end

class UnexpectedRegisterText < Exception; end
class UnexpectedSystemVersion < Exception; end

module NoamTest
  class FakeBeacon
    LOOP_DELAY = 0.001

    def initialize(udp_broadcast_port)
      @socket = UDPSocket.new
      @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
    end

    def start
      @thread = Thread.new do |t|
        begin
          loop do
            # This is normally at 5.0 seconds, but we run faster in order to
            # make tests faster.
            sleep(LOOP_DELAY)
          end
        rescue FakeBeaconThreadCancelled
          # going down
        ensure
          @socket.close
        end
      end
    end

    def stop
      @thread.raise(FakeBeaconThreadCancelled)
      @thread.join
      @thread = nil
    end
  end

  class FakeServer
    PORT = 7733

    def initialize
      @sock = TCPServer.new(FakeServer::PORT)
    end

    def start
      @clients = []
      @thread = Thread.new do |t|
        begin
          loop do
            s = @sock.accept
            @clients << (c = Client.new(s))
            c.start
          end
        rescue FakeServerThreadCancelled
          # going down
        ensure
          @sock.close
        end
      end
    end

    def stop
      @thread.raise(FakeServerThreadCancelled)
      @thread.join
      @thread = nil

      @clients.each do |c|
        c.stop
      end
      @clients = nil
    end

    def clients
      @clients.reject {|c| c.closed}
    end

    def messages
      clients.map {|c| c.messages}.flatten(1)
    end

    def send_message(m)
      s = m.to_json
      l = "%06u" % s.length

      msg = l + s

      clients.each do |c|
        c.send_message(msg)
      end
    end
  end

  class Client
    attr_reader :closed, :responder, :port, :hears, :speaks

    def initialize(client_socket)
      @sock = client_socket
      @client_host = @sock.peeraddr[2]
      @queue = Queue.new
    end

    def start
      @thread = Thread.new do |t|
        begin
          read_register_msg
          @responder = ClientResponder.new(@client_host, @port)

          loop do
            # Ignoring bad message.
            #
            # It seems the order in which sockets get shut down are a little
            # weird.  The following two checks give us a means to try and bail
            # out in the circumstance that a socket dies. In that case, it
            # *should* have been shut down and we're probably just spinning
            # until the exception finally bubbles up.
            if (len = @sock.read(6)) == ""
              next
            end
            if (str = @sock.read(len.to_i)) == ""
              next
            end

            msg = JSON.parse(str)
            @queue.push(msg)
          end
        rescue FakeServerThreadCancelled
          # going down
          @closed = true
          @responder.stop
        ensure
          @sock.close
        end
      end
    end

    def stop
      @thread.raise(FakeServerThreadCancelled)
      @thread.join
    end

    def messages
      @queue.length.times.map { @queue.pop }
    end

    def send_message(m)
      @responder.send_message(m)
    end

    private

    def read_register_msg
       len = @sock.read(6)
       m = JSON.parse(@sock.read(len.to_i))
       txt, _, @port, @hears, @speaks, _, ver = m

       unless txt == "register"
         raise UnexpectedRegisterText.new(txt)
       end

       unless ver == Noam::VERSION
         raise UnexpectedSystemVersion.new(ver)
       end
    end
  end

  class ClientResponder
    def initialize(host, port)
      @sock = TCPSocket.new(host, port)
    end

    def send_message(m)
      @sock.write(m)
      @sock.flush
    end

    def stop
      @sock.close
    end
  end
end
