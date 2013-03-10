# encoding: utf-8
namespace :dataimport do
  namespace :log do
    desc 'Set expiration of DataImport logs to 2 days'
    task :set_expiration => :environment do
      redis           = $redis_migrator_logs || Redis.new
      two_days_in_ms  = 1000 * 3600 * 24 * 2 # 2 days
      block           = lambda { |key| redis.pexpire(key, two_days_in_ms) }

      redis.keys("*importer:log:*").each(&block)
      redis.keys("*importer:entry:*").each(&block)
    end # set_expiration
  end # log
end # dataimport
