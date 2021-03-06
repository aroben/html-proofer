require 'nokogiri'
require 'yell'

require File.dirname(__FILE__) + '/proofer/checkable'
require File.dirname(__FILE__) + '/proofer/checks'

module HTML
  class Proofer
    include Yell::Loggable

    attr_accessor :failed_tests

    def initialize(src, opts={})
      @src = src

      @proofer_opts = {
        :ext => ".html",
        :favicon => false,
        :href_swap => [],
        :href_ignore => [],
        :alt_ignore => [],
        :disable_external => false,
        :verbose => false,
        :as_link_array => false
      }
      @options = @proofer_opts.merge({:followlocation => true}).merge(opts)

      @failed_tests = []

      Yell.new({ :format => false, :name => "HTML::Proofer", :level => "gte.#{log_level}" }) do |l|
        l.adapter :stdout, level: [:debug, :info, :warn]
        l.adapter :stderr, level: [:error, :fatal]
      end
    end

    def run
      unless @options[:as_link_array]
        total_files = 0
        external_urls = {}

        logger.info "Running #{get_checks} checks on #{@src} on *#{@options[:ext]}... \n\n".white

        files.each do |path|
          total_files += 1
          html = HTML::Proofer.create_nokogiri(path)

          get_checks.each do |klass|
            logger.debug "Checking #{klass.to_s.downcase} on #{path} ...".blue
            check =  Object.const_get(klass).new(@src, path, html, @options)
            check.run
            external_urls.merge!(check.external_urls)
            @failed_tests.concat(check.issues) if check.issues.length > 0
          end
        end

        external_link_checker(external_urls) unless @options[:disable_external]

        logger.info "Ran on #{total_files} files!\n\n".green
      else
        external_urls = Hash[*@src.map{ |s| [s, nil] }.flatten]
        external_link_checker(external_urls) unless @options[:disable_external]
      end

      if @failed_tests.empty?
        logger.info "HTML-Proofer finished successfully.".green
      else
        @failed_tests.sort.each do |issue|
          logger.error issue.to_s.red
        end

        raise "HTML-Proofer found #{@failed_tests.length} failures!".red
      end
    end

    # the hypothesis is that Proofer runs way faster if we pull out
    # all the external URLs and run the checks at the end. Otherwise, we're halting
    # the consuming process for every file. In addition, sorting the list lets
    # libcurl keep connections to hosts alive. Finally, we'll make a HEAD request,
    # rather than GETing all the contents
    def external_link_checker(external_urls)
      external_urls = Hash[external_urls.sort]

      logger.info "Checking #{external_urls.length} external links...".yellow

      # Typhoeus won't let you pass any non-Typhoeus option
      @proofer_opts.each_key do |opt|
        @options.delete opt
      end

      Ethon.logger = logger # log from Typhoeus/Ethon

      external_urls.each_pair do |href, filenames|
        request = Typhoeus::Request.new(href, @options.merge({:method => :head}))
        request.on_complete { |response| response_handler(response, filenames) }
        hydra.queue request
      end
      logger.debug "Running requests for all #{hydra.queued_requests.size} external URLs...".yellow
      hydra.run
    end

    def response_handler(response, filenames)
      href = response.options[:effective_url]
      method = response.request.options[:method]
      response_code = response.code

      debug_msg = "Received a #{response_code} for #{href}"
      debug_msg << " in #{filenames.join(' ')}" unless filenames.nil?
      logger.debug debug_msg

      if response_code.between?(200, 299)
        # continue with no op
      elsif response.timed_out?
        failed_test_msg = "External link #{href} failed: got a time out"
        failed_test_msg.insert(0, "#{filenames.join(' ').blue}: ") unless filenames.nil?
        @failed_tests << failed_test_msg
      elsif (response_code == 405 || response_code == 420 || response_code == 503) && method == :head
        # 420s usually come from rate limiting; let's ignore the query and try just the path with a GET
        uri = URI(href)
        next_response = Typhoeus.get(uri.scheme + "://" + uri.host + uri.path, @options)
        response_handler(next_response, filenames)
      # just be lazy; perform an explicit get request. some servers are apparently not configured to
      # intercept HTTP HEAD
      elsif method == :head
        next_response = Typhoeus.get(href, @options)
        response_handler(next_response, filenames)
      else
        # Received a non-successful http response.
        failed_test_msg = "External link #{href} failed: #{response_code} #{response.return_message}"
        failed_test_msg.insert(0, "#{filenames.join(' ').blue}: ") unless filenames.nil?
        @failed_tests << failed_test_msg
      end
    end

    def hydra
      @hydra ||= Typhoeus::Hydra.new
    end

    def files
      if File.directory? @src
        Dir.glob("#{@src}/**/*#{@options[:ext]}")
      else
        File.extname(@src) == @options[:ext] ? [@src] : []
      end
    end

    def self.create_nokogiri(path)
      path << "/index.html" if File.directory? path # support for Jekyll-style links
      content = File.open(path, "rb") {|f| f.read }
      Nokogiri::HTML(content)
    end

    def get_checks
      checks = HTML::Proofer::Checks::Check.subclasses.map { |c| c.name }
      checks.delete("Favicons") unless @options[:favicon]
      checks
    end

    def log_level
      @options[:verbose] ? :debug : :info
    end
  end
end
