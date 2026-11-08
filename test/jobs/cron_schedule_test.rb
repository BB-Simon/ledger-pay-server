require "test_helper"

# AGENTS.md: every class in the cron schedule must exist. A typo or a moved
# job would otherwise only fail inside Sidekiq, silently skipping the run.
class CronScheduleTest < ActiveSupport::TestCase
  SCHEDULE = Rails.root.join("config/initializers/sidekiq_cron.rb")

  def scheduled_class_names
    File.read(SCHEDULE).scan(/"class"\s*=>\s*"([^"]+)"/).flatten
  end

  test "the schedule lists jobs" do
    assert_operator scheduled_class_names.size, :>=, 4
  end

  test "every scheduled class exists and is a Sidekiq job" do
    scheduled_class_names.each do |name|
      job_class = name.safe_constantize

      assert job_class, "#{name} in sidekiq_cron.rb doesn't exist"
      assert_includes job_class.ancestors, Sidekiq::Job, "#{name} isn't a Sidekiq job"
    end
  end
end
