# encoding: utf-8

class Link < ::HTML::Proofer::Checkable

  def href
    @href unless @href.nil? || @href.empty?
  end

  def missing_href?
    href.nil? and @name.nil? and @id.nil?
  end

  def unslashed_directory?
    File.directory? absolute_path and !absolute_path.end_with? File::SEPARATOR
  end

end

class Links < ::HTML::Proofer::Checks::Check

  def run
    @html.css("a, link").each do |l|
      link = Link.new l, "link", self

      next if link.ignore?
      next if link.href =~ /^javascript:/ # can't put this in ignore? because the URI does not parse

      # is it even a valid URL?
      unless link.valid?
        self.add_issue "#{link.href} is an invalid URL"
        next
      end

      # is there even a href?
      if link.missing_href?
        self.add_issue("anchor has no href attribute")
        next
      end

      # does the file even exist?
      if link.remote?
        add_to_external_urls link.href
      else
        self.add_issue "internally linking to #{link.href}, which does not exist" unless link.exists?
      end

      # has the local directory a trailing slash?
      if !@options[:followlocation] and !link.remote? and link.unslashed_directory?
        self.add_issue("internally linking to a directory #{link.absolute_path} without trailing slash")
        next
      end

      # verify the target hash
      if link.hash
        if link.remote?
          add_to_external_urls link.href
        elsif link.internal?
          self.add_issue "linking to internal hash ##{link.hash} that does not exist" unless hash_check @html, link.hash
        elsif link.external?
          unless link.exists?
            self.add_issue "trying to find hash of #{link.href}, but #{link.absolute_path} does not exist"
          else
            target_html = HTML::Proofer.create_nokogiri link.absolute_path
            self.add_issue "linking to #{link.href}, but #{link.hash} does not exist" unless hash_check target_html, link.hash
          end
        end
      end
    end

    external_urls
  end

  def hash_check(html, href_hash)
    html.xpath("//*[@id='#{href_hash}']", "//*[@name='#{href_hash}']").length > 0
  end

end
