#!/usr/bin/env ruby

require 'rubygems'
require 'commander/import'
require 'colorize'
require './IpaUtilities'

HighLine.track_eof = false # Fix for built-in Ruby
Signal.trap("INT") {} # Suppress backtrace when exiting command

program :version, '0.0.1'
program :description, 'A command-line interface for dealing with ipas'

program :help, 'Author', 'Omar Abdelhafith <o.arrabi@me.com>'
program :help, 'Website', 'http://nsomar.com'
program :help_formatter, :compact

global_option('--verbose') { $verbose = true }
$verbose = true

default_command :help

command :verify do |c|
  c.syntax = 'ipa_utils verify ipa_path [...]'
  c.summary = 'Verifies the ipa provision and signature information'

  c.example 'description', 'ipa_utils verify ipa_path'
  c.option '-c', '--certificate certificate', 'Path of the push notification PEM certificate'
  c.option '-d', '--device udid', 'UDID of device to check if its included in embedded provision profile'

  c.action do |args, options|

    path = checkArgs args, "ipa"
    exit unless path

    certificate = options.certificate
    device = options.device

    begin
      errors = 0
      puts

      ipa = IpaUtilities.new path
      ipa.unzipAndParse

      parser = ipa.provisionParser

      puts "Reading general information"
      puts "Application Bundle ID " + parser.appBundleID.green
      puts "APNS Enviroment: " + parser.apnsEnviroment.green
      puts "App Enviroment: " + parser.buildEnviroment.green
      puts

      puts "Verifying bundle signature " + ipa.verifyCodeSign

      status = parser.isAPNSandAppSameEnviroment ? "Yes".green : "No".red
      puts "Checking embedde provision profile APNS Entitlement vs App enviroments"
      puts "Is App and APNS on same enviroment: " + status

      if parser.isAPNSandAppSameEnviroment
        gateway = parser.isAPNSProduction ? "gateway.push.apple.com:2195".green : "gateway.sandbox.push.apple.com:2195".green
        puts "APNS connection gateway: " + gateway
      else
        appStatus = parser.isBuildRelease ? "false (Release)" : "true (debug)"
        apnStatus = parser.apnsEnviroment
        puts "The application was build with get-task-allow set to #{appStatus} while the aps-environment is set to #{apnStatus}, To fix this issue regenerated the provision profile from apple developer then rebuild the app using it".red
        errors += 1
      end

      if certificate
        puts
        puts "Checking certificates"
        # puts parser.signingIdentities
        pem = PemParser.new certificate

        if pem.isAPNS
          puts "Certificate Name " + pem.name.green
          puts "Certificate Enviroment: " + "#{pem.enviroment}".green
          puts "Certificate Bundle ID: " + "#{pem.bundleID}".green

          status = parser.appBundleID == pem.bundleID ? "Yes".green : "No".red
          errors += 1 if parser.appBundleID != pem.bundleID

          puts "Certificate bundleId identical to app #{status}"

          status = pem.isProduction == parser.isAPNSProduction ? "Yes".green : "No".red
          puts "Is provided certificate correct for passed ipa: " + status

          if pem.isProduction != parser.isAPNSProduction
            puts "The application was build with a provision profile containing aps-environment in #{apnStatus} enviroment while the passed certificate environment is set to #{pem.enviroment}\nTo fix this issue either export the correct iOS Push #{pem.enviroment} certificate from keychain or rebuild your app with the correct provision profile".red
            errors += 1
          end
        else
          apnStatus = parser.apnsEnviroment
          puts "The passed certificate is not an APNS certificate".red
          errors += 1
        end

      end

      if device
        puts
        puts "Checking provisioned devices"

        if parser.isBuildDistro
          puts "Distribution build do not contain provisioned devices".red
          errors += 1
        else
          puts "Embedded profile contains " + "#{parser.provisionedDevices.count}".green + " devices"
          status = parser.provisionedDevices.include?(device) ? "Device with UDID #{device} found".green :
            "Device with UDID #{device} not found".red
          puts status
          errors += 1 if !parser.provisionedDevices.include?(device)
        end
      end

      puts
      puts "No errors encountered".green if errors == 0
      puts "#{errors} errors encountered!".red if errors > 0

    ensure
      ipa.cleanUp
    end
  end
end

command :convert do |c|
  c.syntax = 'ipa_utils convert p12_path [...]'
  c.summary = 'Convert a p12 to PEM'

  c.example 'description', 'ipa_utils convert p12_file_path'
  c.option '-o', '--out outpath', 'Out put file for the Pem file'
  # c.option '-d', '--device udid', 'UDID of device to check if its included in embedded provision profile'

  c.action do |args, options|

    path = checkArgs args, "p12"
    exit unless path

    outpath = options.out || "~/Desktop/out.pem"

    begin

      puts
      puts "Converting P12 to Pem"
      system "openssl pkcs12 -in #{path} -out #{outpath} -nodes -clcerts"
      puts "Pem saved at " + outpath.green

    ensure

    end
  end
end

command :certificate do |c|
  c.syntax = 'ipa_utils certificate ipa [...]'
  c.summary = 'fetch the correct push identity from the provided ipa (WIP)'

  c.example 'description', 'ipa_utils certificate ipa_path (WIP)'

  c.action do |args, options|

    path = checkArgs args, "ipa"
    exit unless path

    begin
      #Todo
      puts
      ipa = IpaUtilities.new path
      ipa.unzipAndParse
      parser = ipa.provisionParser

      apnsEnviroment = parser.isAPNSProduction ? "Production" : "Development"
      identityName = "Apple #{apnsEnviroment} IOS Push Services: #{parser.appBundleID}"

      puts "Searching Keychain for identity " + identityName.green

      identities = `security find-identity -v -p ssl-client`
      puts "Item found please export it from your keychain".green if identities.lines.index{|s| s.include?(identityName)}
      puts "Item couldnt be found in your keychain".red if !identities.lines.index{|s| s.include?(identityName)}

    ensure
      ipa.cleanUp
    end
  end
end

command :resign do |c|
  c.syntax = 'ipa_utils resign ipa -c new_profile'
  c.summary = 'Resigns the passed ipa to the new passed profile'

  c.example 'description', 'ipa_utils certificate ipa_path -c profile'
  c.option '-p', '--profile profile', 'Path of the provision profile to use'
  c.option '-o', '--out outpath', 'Out put file for the Pem file'

  c.action do |args, options|

    puts

    path = checkArgs args, "ipa"
    exit unless path

    profile = options.profile
    if !profile
      say_error "pass a profile with -p profile-path"
      exit
    end

    exit unless checkFileExists "provision profile", profile

    outpath = options.out || "~/Desktop/resigned.ipa"

    begin

      ipa = IpaUtilities.new path

      ipa.unzipAndParse
      ipa.deleteOldSignature

      parser = ipa.provisionParser

      puts "Copying the new provision profile to app bundle"
      system "cp \"#{profile}\" \"Payload/#{ipa.bundleName}/embedded.mobileprovision\""

      file = File.read "Original.Entitlements.plist"
      file.sub! "BUNDLE_ID", "#{parser.teamIdentifier}.#{parser.appBundleID}"
      file.sub! "GET_TASK_ALLOW", parser.isBuildRelease ? "false" : "true"

      puts "Writing Entitlements.plist"
      File.write "Entitlements.plist", file

      buildName = parser.isBuildRelease ? "Distribution" : "Development"
      system "codesign -s \"iPhone #{buildName}: #{parser.teamName} (#{parser.teamIdentifier})\" --entitlements Entitlements.plist \"Payload/DummyApp.app\" -f"

      puts
      ipa.zip outpath

    ensure
      ipa.cleanUp
    end
  end
end

def checkArgs args, title
  if args.nil? || args.empty?
    say_error "Path to #{title} is required"
    return nil
  end

  checkFileExists title, args.first
end

def checkFileExists title, path

  if !File.exist?path
    say_error "Couldn't find #{title} with path #{path}"
    return nil
  end

  path
end
