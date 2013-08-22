module ZooKeeperHelper
  @processes = []

  def zookeeper
    @zookeeper ||= DSL.new
  end

  class << self
    attr_accessor :processes

    def sockets
      processes.map(&:client_socket)
    end

    def zk
      processes[0].zk
    end
  end

  class DSL

    def single;    @single    ||= Single.new;    end
    def clustered; @clustered ||= Clustered.new; end

    def processes
      ZooKeeperHelper.processes
    end

    def zk
      # Arbitrarily pick the first. Sampling wouldn't be deterministic.
      processes[0].zk
    end

    def get(path)
      zk.get(path)
    end

    def children(path)
      zk.children(path)
    end

    class Single
      attr_reader :process

      def start(options={})
        zoocfg = options[:zoocfg] || {}

        @process = Nerve::ZooKeeperProcess.new(:zoocfg => zoocfg)
        @process.start
        ZooKeeperHelper.processes = [@process]
      end

      def stop(options={})
        @process.stop(options)
        @process = nil
        ZooKeeperHelper.processes.clear
      end

      def restart_one(options={})
        @process[1].restart(options)
      end

      def wait_for_up(timeout=30)
        until_timeout(timeout, "Zookeeper never came up") do
          raise unless @process.up?
        end
      rescue Timeout::Error => e
        @process.wait(:timeout => 1)
        puts "\nZOOKEEPER ERROR:"
        puts @process.stderr
        raise e
      end

    end

    class Clustered
      attr_reader :ensemble_size
      attr_reader :processes

      def start(options={})
        @ensemble_size = options[:ensemble_size] || 3
        additional_zoocfg = options[:zoocfg] || {}

        @processes = (1..ensemble_size).map do |index|
          Nerve::ZooKeeperProcess.new(
            :myid => index,
            :ensemble_size => ensemble_size,
            :zoocfg => {
              :initLimit => 5,
              :syncLimit => 2
            }.merge(additional_zoocfg))
        end
        @processes.each { |p| p.start }
        ZooKeeperHelper.processes = @processes
      end

      def stop(options={})
        @processes.each { |p| p.stop(options) }
        @processes = nil
        ZooKeeperHelper.processes.clear
      end

      def restart_one(options={})
        @processes[1].restart(options={})
      end

      def wait_for_up(timeout=30)
        not_up_yet = processes.dup
        until_timeout(timeout, "Zookeeper cluster never came up") do
          not_up_yet.delete_if { |p| p.up? }
          raise unless not_up_yet.empty?
        end
      rescue Timeout::Error => e
        not_up_yet.each do |p|
          p.wait(:timeout => 1)
          puts "\nZOOKEEPER ERROR (#{p.client_port}):"
          puts p.stderr
        end
        raise e
      end

    end

  end

end
