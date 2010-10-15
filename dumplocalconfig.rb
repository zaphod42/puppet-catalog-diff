#!/usr/bin/ruby

# Reads a catalog file created with puppet 0.24.x, 0.25.x or 2.6.x
# and dumps it to an intermediate format.
#
# We dump it to our own format to work around format differences in
# Puppet catalogs, later the accompanying tool diffcatalogs.rb
# will be able to print differences between our intermediate format
#
# For catalogs built using puppet master --compile
#
#   dumplocalconfig.rb --format pson fqdn.pson
#
# For catalogs found on running machines:
#
#   dumplocalconfig.rb --format yaml fqdn.yaml
#
# You can also try --format marshal
#
# This will create a directory dump/<version>/ with our intermediate
# format data.
#
# Contact:
# R.I.Pienaar <rip@devco.net> - www.devco.net - @ripienaar

# fool it into giving me the right config later on so I can guess
# about the location of localconfig.yaml as the puppetd would see things
$0 = "puppetd"

require 'puppet'
require 'yaml'
require 'optparse'
require 'facter'
require 'pp'
require 'fileutils'
require 'digest/md5'

@notags = false
@format = :yaml
@resources = []

OptionParser.new do |opt|
    opt.banner = "Usage: #{__FILE__} [options] [catalog]"

    opt.on("--config [FILE]", "-c", "Config file") do |v|
        Puppet[:config] = v
    end

    opt.on("--format [FORMAT]", "-f", "Catalog format yaml|pson|marshal") do |v|
        @format = v.to_sym
    end

    opt.on("--help", "-h", "Help") do |v|
        puts opt
        exit
    end
end.parse!

Puppet.parse_config

if Puppet.version =~ /^([0-9]+[.][0-9]+)[.][0-9]+$/
    @version = $1

    unless ["0.25", "0.24", "2.6"].include?(@version)
        puts("Don't know how to print catalogs for verion #{Puppet.version} only 0.24, 0.25 and 2.6 is supported")
        exit 1
    end
else
    puts("Could not figure out version from #{Puppet.version}")
    exit 1
end

if File.exist?("dump/#{@version}")
    puts "Output directory ./dump/#{@version} already exist"
    exit 1
else
    FileUtils.mkdir_p("dump/#{@version}")
end

localconfig = ARGV[0]

unless File.exist?(localconfig)
    puts("Please specify a path to a catalog")
    exit 1
end

lc = File.open(localconfig)

case @format
when :yaml
    pup = YAML.load(lc)
when :marshal
    pup = Marshal.load(lc)
when :pson
    pup = PSON.load(lc)
end


# Converts Puppet 0.24 and possibly earlier catalogs
# to our intermediate format
def convert24(bucket)
    if bucket.class == Puppet::TransBucket
        bucket.each do |b|
            convert24(b)
        end
    elsif bucket.class == Puppet::TransObject
        manifestfile = bucket.file.gsub("/etc/puppet/manifests/", "")

        resource = {:type => bucket.type,
                    :title => bucket.name,
                    :parameters => {}}

        bucket.each do |param, value|
            resource[:parameters][param.to_sym] = value
        end

        pp resource
        if resource[:parameters].include?(:content)
            resource[:parameters][:content] = Digest::MD5.hexdigest(resource[:parameters][:content])
        end

        resource[:resource_id] = "#{bucket.type.downcase}[#{bucket.name}]"
        @resources << resource
    end
end

# Converts Puppet 0.25 and 2.6.x catalogs to our intermediate format
def convert25(resource)
    if resource.class == Puppet::Resource::Catalog
        resource.edges.each do |b|
            convert25(b)
        end
    elsif resource.class == Puppet::Relationship and resource.target.class == Puppet::Resource and resource.target.title != nil and resource.target.file != nil
        target = resource.target
        manifestfile = target.file.gsub("/etc/puppet/manifests/", "")

        resource = {:type => target.type,
                    :title => target.title,
                    :parameters => {}}

        target.each do |param, value|
            resource[:parameters][param] = value
        end

        if resource[:parameters].include?(:content)
            resource[:parameters][:content] = Digest::MD5.hexdigest(resource[:parameters][:content])
        end

        resource[:resource_id] = "#{target.type.downcase}[#{target.title}]"
        @resources << resource
    end
end

@resources = []

if @version == "0.24"
    convert24(pup)
else
    convert25(pup)
end

File.open("dump/#{@version}/resources.yaml", "w") do |r|
    r.print(YAML.dump(@resources))
end