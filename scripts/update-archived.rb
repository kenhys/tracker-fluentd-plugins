require 'json'
require 'logger'
require 'optparse'
require 'yaml'
require 'time'
require 'timeout'
require 'open-uri'
require 'nokogiri'

=begin

Update whether archived repository in data/checked.yml manually

  Usage: ruby scripts/update-archived.rb

=end

options = {
  log_level: Logger::INFO,
  check_interval: (60 * 60 * 24 * 7)
}

opt = OptionParser.new
opt.on("--log-level LEVEL", "Specify max processing GEMS") { |v|
  case v
  when "info"
    options[:log_level] = Logger::INFO
  when "debug"
    options[:log_level] = Logger::DEBUG
  else
    options[:log_level] = Logger::INFO
  end
}
opt.parse!(ARGV)

@logger = Logger.new(STDOUT)
@logger.level = options[:log_level]
@logger.formatter = proc { |severity, datetime, progname, message|
  "#{severity}: #{message}\n"
}

checked_yaml_path = File.expand_path(File.join(__dir__, "../data/checked.yml"))

plugins = File.open(checked_yaml_path) { |file| YAML.safe_load(file.read) }


def checked?(metadata, options={})
  return false unless metadata["checked_at"]
  if Time.parse(metadata["checked_at"]) < (Time.now - options[:check_interval])
    false
  else
    true
  end
end

unless ENV["GITHUB_ACCESS_TOKEN"]
  @logger.error("Fine grained personal access token should be set: <GITHUB_ACCESS_TOKEN>")
  exit 1
end

def fetch_github_repo_info(owner_and_repository, token)
  if owner_and_repository.end_with?("/")
    owner_and_repository = owner_and_repository[..-2]
  end
  if owner_and_repository.end_with?(".git")
    owner_and_repository = owner_and_repository[..-5]
  end
  URI.open("https://api.github.com/repos/#{owner_and_repository}",
           "Accept" => "application/vnd.github+json",
           "Authorization" => "Bearer #{token}",
           "X-GitHub-Api-Version" => "2022-11-28") do |response|
    yield JSON.parse(response.read)
  end
end

checked = {}
skip_count = 0
no_vcs_count = 0
archived_count = 0
timeout_count = 0
error_count = 0
error_uris = []

=begin
plugins = [
  ["fluent-plugin-mysqlslowquery", {
     "vcs" => "https://github.com/yuku-t/fluent-plugin-mysqlslowquery",
     "arvhived" => true,
     "checked_at" => "2025-06-13"
   }
  ],
  [
    "fluent-plugin-json-in-json", {
     "vcs" => "https://github.com/gmr/fluent-plugin-json-in-json",
     "arvhived" => true,
     "checked_at" => "2025-06-13"
    }
  ]
]
=end

plugins.each_with_index do |plugin, index|
  plugin_name, metadata = plugin
  if checked?(metadata, options)
    @logger.debug("<#{plugin_name}> was already checked at: #{metadata['checked_at']}")
    checked[plugin_name] = metadata
    skip_count += 1
    next
  end
  unless metadata["vcs"]
    @logger.info("no vcs for <#{plugin_name}>, skip it")
    checked[plugin_name] = metadata
    no_vcs_count += 1
    next
  end
  if metadata["archived"]
    @logger.info("skip already archived <#{plugin_name}>")
    checked[plugin_name] = metadata
    archived_count += 1
    next
  end
  begin
    @logger.info("[#{index+1}/#{plugins.size}] Checking #{plugin_name}...")
    if metadata["vcs"].start_with?("http://github.com")
      @logger.warn("obsolete HTTP: <#{metadata['vcs']}>")
    end
    Timeout.timeout(10) do
      if metadata["vcs"].start_with?("https://github.com")
        uri = URI.parse(metadata["vcs"])
        # trim first /
        owner_and_repository = uri.path[1..]
        fetch_github_repo_info(owner_and_repository, ENV["GITHUB_ACCESS_TOKEN"]) do |data|
          if data["archived"]
            metadata["archived"] = data["archived"]
            # guess newer pushed_at
            html = URI.open(metadata["vcs"]).read
            doc = Nokogiri::HTML.parse(html, nil, 'UTF-8')
            yyyymmdd = ""
            doc.xpath("//main[@id='js-repo-pjax-container']").each do |main|
              main.xpath(".//div[@class='flash flash-warn flash-full border-top-0 text-center text-bold py-2']").each do |div|
                if div.text =~ /on(.+)./
                  metadata["archived_at"] = Time.parse($1).strftime("%Y-%m-%d")
                end
              end
            end
            @logger.warn("<#{plugin_name}> was archived at: #{metadata['archived_at']} pushed at: #{data['pushed_at']} updated at: #{data['updated_at']}")
          end
        end
      else
        @logger.info("REST access for <#{metadata['vcs']}> is not supported")
      end
    end
    metadata["checked_at"] = Time.now.strftime("%Y-%m-%d")
  rescue Timeout::Error
    @logger.info("Invalid VCS: <#{metadata['vcs']}> for <#{plugin_name}>, skip it")
    metadata["vcs"] = false
    metadata.delete("ci")
    timeout_count += 1
  rescue OpenURI::HTTPError
    @logger.warn("Might be reached API limits: <#{metadata['vcs']}> for <#{plugin_name}>")
    error_count += 1
    error_uris << metadata['vcs']
  end
  @logger.debug("<#{plugin_name}>, #{metadata}")
  if metadata["archived"]
    sleep(10)
  end
  checked[plugin_name] = metadata
end
checked_yaml_path = "checked.yml"
File.open(checked_yaml_path, "w+") do |file|
  file.write(YAML.dump(checked))
end
summary = <<EOS
Total: #{plugins.size}
  Skipped: #{skip_count}
  No VCS: #{no_vcs_count}
  Archived: #{archived_count}
  Timeout error: #{timeout_count}
  Error: #{error_count}
  Error reported URL:
	#{error_uris.join("\n\t")}
EOS
puts summary
